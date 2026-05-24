#!/bin/bash
# ==============================================================================
# Shared Vlocity Build Helpers
# ==============================================================================
# Functions used by scripts/vlocity_deploy.sh and scripts/vlocity_validate.sh to
# detect Vlocity / OmniStudio changes, authenticate the vlocity CLI to the
# correct org, and run packDeploy with a packRetry fallback.
#
# This is the GitHub Actions equivalent of the Jenkins shared-library function:
#
#     def vlocityDeploy(targetEnv, deployUrl, salesforceCreds, deployfile)
#
# Source this file from another script:
#     # shellcheck source=./_vlocity_lib.sh
#     source "$(dirname "$0")/_vlocity_lib.sh"
# ==============================================================================

# Idempotent guard so multiple `source` calls don't redefine functions.
if [ -n "${__VLOCITY_LIB_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
__VLOCITY_LIB_LOADED=1

# Defaults (callers may override via env)
: "${VLOCITY_JOB_FILE:=vlocity/deploy.yaml}"
: "${VLOCITY_PROJECT_PATH:=vlocity/datapacks}"
: "${VLOCITY_REPORTS_DIR:=reports/vlocity}"
: "${VLOCITY_RETRY_LIMIT:=1}"

# Vlocity / OmniStudio metadata extensions and directories that should trigger
# a Vlocity deploy when they appear in a git diff. These mirror the Jenkins
# `changes()` function which watches for files under:
#   force-app/main/default/src-base/commscloud/vlocity
#   force-app/main/default/src-base/prm/vlocity
# while also accepting the source-format OmniStudio folders this repo uses.
VLOCITY_FILE_PATTERNS=(
  '*.oip-meta.xml'        # OmniIntegrationProcedure
  '*.omniscript-meta.xml' # OmniScript
  '*.rpt-meta.xml'        # OmniDataTransform / Report metadata
  '*.dataPack'            # raw Vlocity datapack
)

VLOCITY_DIR_PATTERNS=(
  'force-app/main/default/omniIntegrationProcedures'
  'force-app/main/default/omniDataTransforms'
  'force-app/main/default/omniScripts'
  'force-app/main/default/omniDataMappings'
  'force-app/main/default/src-base/commscloud/vlocity'
  'force-app/main/default/src-base/prm/vlocity'
  'vlocity/datapacks'
)

# ------------------------------------------------------------------------------
# vlocity_log <message>
# Timestamped log line. All Vlocity steps share this format so the GH Actions
# log is easy to scan.
# ------------------------------------------------------------------------------
vlocity_log() {
  printf '%s ⚡ %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

# ------------------------------------------------------------------------------
# detect_vlocity_changes <from-ref> <to-ref>
# Inspects the git diff between two refs and sets globals:
#   HAS_VLOCITY_CHANGES   "true" | "false"
#   VLOCITY_CHANGED_COUNT integer
#   VLOCITY_CHANGED_LIST  newline-separated file list
#
# When FROM/TO refs are not provided, falls back to comparing the current HEAD
# against the merge-base of origin/<TARGET_BRANCH>, which matches the behavior
# of generate_delta.sh in this repo.
# ------------------------------------------------------------------------------
detect_vlocity_changes() {
  local from_ref="${1:-${FROM_REF:-}}"
  local to_ref="${2:-${TO_REF:-HEAD}}"

  HAS_VLOCITY_CHANGES="false"
  VLOCITY_CHANGED_COUNT=0
  VLOCITY_CHANGED_LIST=""

  # If we still don't have a from-ref, derive one (mirrors generate_delta.sh)
  if [ -z "$from_ref" ]; then
    local target="${TARGET_BRANCH:-${GITHUB_BASE_REF:-${GITHUB_REF_NAME:-main}}}"
    if git rev-parse -q --verify "origin/${target}" >/dev/null 2>&1; then
      from_ref="origin/${target}"
    else
      from_ref="HEAD~1"
    fi
  fi

  # Build a single grep pattern from VLOCITY_DIR_PATTERNS / VLOCITY_FILE_PATTERNS.
  local dir_regex file_regex
  dir_regex=$(printf '%s|' "${VLOCITY_DIR_PATTERNS[@]}")
  dir_regex="${dir_regex%|}"
  file_regex=$(printf '%s|' "${VLOCITY_FILE_PATTERNS[@]}")
  file_regex="${file_regex%|}"
  # Convert glob asterisks to regex .*  (we only use *.ext patterns)
  file_regex="${file_regex//\*/.*}"

  local diff_files
  diff_files=$(git diff --name-only --diff-filter=ACMRT "$from_ref" "$to_ref" 2>/dev/null || true)

  if [ -z "$diff_files" ]; then
    return 0
  fi

  local matched
  matched=$(printf '%s\n' "$diff_files" \
    | grep -E "(${dir_regex})/|(${file_regex})$" \
    || true)

  if [ -n "$matched" ]; then
    HAS_VLOCITY_CHANGES="true"
    VLOCITY_CHANGED_LIST="$matched"
    VLOCITY_CHANGED_COUNT=$(printf '%s\n' "$matched" | grep -c . || echo 0)
  fi
}

# ------------------------------------------------------------------------------
# emit_vlocity_github_outputs
# Persists detection state into GITHUB_ENV / GITHUB_OUTPUT so downstream steps
# can gate on `env.HAS_VLOCITY_CHANGES`. No-op outside GitHub Actions.
# ------------------------------------------------------------------------------
emit_vlocity_github_outputs() {
  if [ -n "${GITHUB_ENV:-}" ] && [ -w "${GITHUB_ENV}" ]; then
    {
      echo "HAS_VLOCITY_CHANGES=${HAS_VLOCITY_CHANGES:-false}"
      echo "VLOCITY_CHANGED_COUNT=${VLOCITY_CHANGED_COUNT:-0}"
    } >> "$GITHUB_ENV"
  fi
  if [ -n "${GITHUB_OUTPUT:-}" ] && [ -w "${GITHUB_OUTPUT}" ]; then
    {
      echo "has-vlocity-changes=${HAS_VLOCITY_CHANGES:-false}"
      echo "vlocity-changed-count=${VLOCITY_CHANGED_COUNT:-0}"
    } >> "$GITHUB_OUTPUT"
  fi
}

# ------------------------------------------------------------------------------
# print_vlocity_preview
# Human-readable summary of detected Vlocity changes.
# ------------------------------------------------------------------------------
print_vlocity_preview() {
  if [ "${HAS_VLOCITY_CHANGES:-false}" != "true" ]; then
    vlocity_log "No Vlocity / OmniStudio changes detected"
    return 0
  fi
  echo ""
  echo "⚡ VLOCITY CHANGES PREVIEW"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  • Files changed: ${VLOCITY_CHANGED_COUNT}"
  echo ""
  printf '%s\n' "$VLOCITY_CHANGED_LIST" | sed 's/^/      • /'
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}

# ------------------------------------------------------------------------------
# install_vlocity_cli
# Installs the Vlocity Build Tool globally if not already on PATH.
# Pinned to the LTS major @latest tag; override with VLOCITY_BUILD_VERSION.
# ------------------------------------------------------------------------------
install_vlocity_cli() {
  if command -v vlocity >/dev/null 2>&1; then
    vlocity_log "vlocity CLI already installed: $(vlocity --version 2>/dev/null || echo unknown)"
    return 0
  fi
  vlocity_log "Installing vlocity build tool (npm i -g vlocity@${VLOCITY_BUILD_VERSION:-latest})"
  npm install -g "vlocity@${VLOCITY_BUILD_VERSION:-latest}" --silent
}

# ------------------------------------------------------------------------------
# configure_puppeteer <target-env>
# Matches the Jenkins behavior:
#   if (targetEnv == env.SF_REL_ENV) { npm uninstall puppeteer -g }
#   else                              { npm install   puppeteer -g }
# i.e. puppeteer is *removed* for the production-equivalent environment (LWC
# OmniScript compilation is skipped on prod by convention) and installed
# everywhere else so the build tool can compile LWC OmniScripts headlessly.
#
# The post-merge workflow only deploys to dev/qa/intuat (no prod target), so
# puppeteer is always installed unless ORG_NAME matches VLOCITY_PROD_ALIASES.
# ------------------------------------------------------------------------------
configure_puppeteer() {
  local target="${1:-${ORG_NAME:-sandbox}}"
  local prod_aliases="${VLOCITY_PROD_ALIASES:-prod production}"

  local is_prod="false"
  for a in $prod_aliases; do
    if [ "$target" = "$a" ]; then
      is_prod="true"
      break
    fi
  done

  if [ "$is_prod" = "true" ]; then
    vlocity_log "Target=${target} matches PROD aliases → removing puppeteer (skip LWC compile)"
    npm uninstall puppeteer -g >/dev/null 2>&1 || true
  else
    vlocity_log "Target=${target} → installing puppeteer for LWC OmniScript compile"
    if ! npm list -g puppeteer >/dev/null 2>&1; then
      npm install puppeteer -g --silent >/dev/null 2>&1 || \
        vlocity_log "WARN: puppeteer install failed; LWC OmniScript compile may be skipped"
    fi
  fi
}

# ------------------------------------------------------------------------------
# resolve_vlocity_username <sf-org-alias>
# The vlocity build tool authenticates by SFDX username. We pull it from the
# already-logged-in sf org so we don't need a second login round-trip.
# Echoes the username on stdout (empty string on failure).
# ------------------------------------------------------------------------------
resolve_vlocity_username() {
  local alias="${1:-${ORG_NAME:-sandbox}}"
  sf org display --target-org "$alias" --json 2>/dev/null \
    | jq -r '.result.username // empty' \
    || true
}

# ------------------------------------------------------------------------------
# run_vlocity_pack <command> <job-file> <sf-username> [extra-args...]
# Executes a single Vlocity Build Tool command and tees the log into
# $VLOCITY_REPORTS_DIR/<command>.log. Returns the underlying exit code.
# ------------------------------------------------------------------------------
run_vlocity_pack() {
  local cmd="${1:?command required}"
  local job_file="${2:-$VLOCITY_JOB_FILE}"
  local sf_user="${3:-}"
  shift 3 || true

  mkdir -p "$VLOCITY_REPORTS_DIR"
  local log_file="${VLOCITY_REPORTS_DIR}/${cmd}.log"

  if [ -z "$sf_user" ]; then
    vlocity_log "ERROR: no Salesforce username resolved for vlocity ${cmd}"
    return 2
  fi
  if [ ! -f "$job_file" ]; then
    vlocity_log "ERROR: vlocity job file not found: ${job_file}"
    return 2
  fi

  vlocity_log "Running: vlocity -sfdx.username '${sf_user}' -job ${job_file} ${cmd} --verbose true --simpleLogging true $*"

  set +e
  vlocity \
    -sfdx.username "$sf_user" \
    -job "$job_file" \
    "$cmd" \
    --verbose true \
    --simpleLogging true \
    "$@" \
    2>&1 | tee "$log_file"
  local rc=${PIPESTATUS[0]}
  set -e

  vlocity_log "vlocity ${cmd} exit=${rc} (log: ${log_file})"
  return "$rc"
}

# ------------------------------------------------------------------------------
# vlocity_deploy_with_retry <sf-username> [job-file]
# Implements the Jenkins flow:
#   1. packDeploy → if it fails…
#   2. packRetry  → if it also fails, return the failure exit code.
#
# Returns 0 on success, non-zero on permanent failure.
# ------------------------------------------------------------------------------
vlocity_deploy_with_retry() {
  local sf_user="${1:?sf-username required}"
  local job_file="${2:-$VLOCITY_JOB_FILE}"

  vlocity_log "STEP 1/2: packDeploy"
  if run_vlocity_pack packDeploy "$job_file" "$sf_user"; then
    vlocity_log "packDeploy succeeded ✅"
    return 0
  fi

  vlocity_log "packDeploy reported failures — attempting packRetry"
  vlocity_log "STEP 2/2: packRetry"
  if run_vlocity_pack packRetry "$job_file" "$sf_user"; then
    vlocity_log "packRetry succeeded ✅"
    return 0
  fi

  vlocity_log "packRetry ALSO failed ❌"
  return 1
}

# ------------------------------------------------------------------------------
# github_deployment_create <env-name>
# Creates a GitHub Deployment record so the PR / commit shows a "Deployments"
# pill next to it. Mirrors the Jenkins helper `jslGitHubDeploymentCreate`.
# Requires GITHUB_TOKEN + GITHUB_REPOSITORY env vars (provided by Actions).
#
# Echoes the deployment ID on stdout, "" on failure.
# ------------------------------------------------------------------------------
github_deployment_create() {
  local env_name="${1:-vlocity}"
  if [ -z "${GITHUB_TOKEN:-}" ] || [ -z "${GITHUB_REPOSITORY:-}" ]; then
    vlocity_log "GITHUB_TOKEN/REPOSITORY missing — skipping deployment record create"
    echo ""
    return 0
  fi

  local sha="${GITHUB_SHA:-HEAD}"
  local payload
  payload=$(jq -nc \
    --arg ref "$sha" \
    --arg env "$env_name" \
    '{ref:$ref, environment:$env, auto_merge:false, required_contexts:[], description:"Vlocity deploy", transient_environment:false, production_environment:false}')

  local resp
  resp=$(curl -sS -X POST \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -d "$payload" \
    "https://api.github.com/repos/${GITHUB_REPOSITORY}/deployments" || echo '{}')

  echo "$resp" | jq -r '.id // empty'
}

# ------------------------------------------------------------------------------
# github_deployment_set_status <deployment-id> <state> [log-url] [env-name]
# Updates a GitHub Deployment with one of: in_progress, success, failure,
# error, queued. Mirrors `jslGitHubDeploymentSetStatus`.
# ------------------------------------------------------------------------------
github_deployment_set_status() {
  local id="${1:-}"
  local state="${2:-in_progress}"
  local log_url="${3:-${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}}"
  local env_name="${4:-vlocity}"

  if [ -z "$id" ] || [ -z "${GITHUB_TOKEN:-}" ] || [ -z "${GITHUB_REPOSITORY:-}" ]; then
    return 0
  fi

  local payload
  payload=$(jq -nc \
    --arg state "$state" \
    --arg log "$log_url" \
    --arg env "$env_name" \
    '{state:$state, log_url:$log, environment:$env, description:"Vlocity \($state)"}')

  curl -sS -X POST \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -d "$payload" \
    "https://api.github.com/repos/${GITHUB_REPOSITORY}/deployments/${id}/statuses" >/dev/null || true
}

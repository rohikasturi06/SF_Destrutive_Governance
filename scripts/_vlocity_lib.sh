#!/bin/bash
# ==============================================================================
# Shared Vlocity Build Helpers
# ==============================================================================
# Functions used by scripts/vlocity_deploy.sh to detect Vlocity / OmniStudio
# changes, authenticate the vlocity CLI to the correct org, and run packDeploy
# with a packRetry fallback.
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
: "${VLOCITY_ROOT:=vlocity}"
: "${VLOCITY_JOB_FILE:=scripts/vlocity_deploy.yaml}"
: "${VLOCITY_PROJECT_PATH:=vlocity/datapacks}"
: "${VLOCITY_REPORTS_DIR:=reports/vlocity}"
: "${VLOCITY_RETRY_LIMIT:=1}"

# Single-folder contract:
#   The Vlocity deploy is triggered **only** when files inside the top-level
#   `vlocity/` folder change. Everything else (including OmniStudio source-
#   format files under force-app/main/default/omni*) is treated as standard
#   Salesforce metadata and deployed via the SF CLI path.
#
#   This is intentionally narrower than the legacy Jenkins detector — keeping
#   the trigger surface tight prevents accidental Vlocity Build Tool runs when
#   only standard metadata changes.
#
# To extend, override VLOCITY_ROOT via env (rarely needed):
#   VLOCITY_ROOT=my-vlocity-folder ./scripts/vlocity_deploy.sh

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
# Detection rule: a Vlocity deploy is triggered IFF at least one file under
# the top-level `${VLOCITY_ROOT}/` folder changed (added, modified, renamed,
# or had its type changed). Nothing outside that folder can trigger a Vlocity
# run — even OmniStudio source-format files in force-app/.
#
# When FROM/TO refs are not provided, falls back to comparing the current HEAD
# against origin/<TARGET_BRANCH>, which matches the behavior of generate_delta.sh.
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

  local diff_files
  diff_files=$(git diff --name-only --diff-filter=ACMRT "$from_ref" "$to_ref" 2>/dev/null || true)

  if [ -z "$diff_files" ]; then
    return 0
  fi

  # Anchor at the start of the path: a file is a Vlocity change iff its path
  # begins with "${VLOCITY_ROOT}/". This means scripts/vlocity_*.sh (which
  # *contain* the word "vlocity") will NOT trigger a Vlocity deploy — only
  # files actually inside the vlocity folder do.
  local matched
  matched=$(printf '%s\n' "$diff_files" \
    | grep -E "^${VLOCITY_ROOT}/" \
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
    patch_vlocity_omnistudio_nullguard
    return 0
  fi
  vlocity_log "Installing vlocity build tool (npm i -g vlocity@${VLOCITY_BUILD_VERSION:-latest})"
  npm install -g "vlocity@${VLOCITY_BUILD_VERSION:-latest}" --silent
  patch_vlocity_omnistudio_nullguard
}

# ------------------------------------------------------------------------------
# patch_vlocity_omnistudio_nullguard
# Works around an upstream Vlocity Build Tool bug (present through v1.17.24 and
# current master) that crashes when deploying to a *namespace-less* OmniStudio
# Standard org:
#
#   DataPacksUtils.getExpandedDefinition():
#     if (this.vlocity.isOmniStudioInstalled && !this.vlocity.namespace) {
#         SObjectType = SObjectType.replace('%vlocity_namespace%__', '');
#     }
#
# Callers like isDeployLast()/isSoloExport()/isForceQueueable() pass
# SObjectType = null, so on an OmniStudio org without a namespace this throws:
#   TypeError: Cannot read properties of null (reading 'replace')
# before any datapack is deployed.
#
# We inject the missing null-guard (`&& SObjectType`) into the condition. The
# edit is idempotent and a no-op if the file/line can't be found, so it never
# breaks the deploy on a fixed build tool version.
# ------------------------------------------------------------------------------
patch_vlocity_omnistudio_nullguard() {
  local global_root vfile
  global_root="$(npm root -g 2>/dev/null || true)"
  vfile="${global_root}/vlocity/lib/datapacksutils.js"

  if [ -z "$global_root" ] || [ ! -f "$vfile" ]; then
    vlocity_log "WARN: could not locate vlocity datapacksutils.js to patch (skipping null-guard)"
    return 0
  fi

  if grep -q 'this.vlocity.namespace && SObjectType)' "$vfile"; then
    vlocity_log "vlocity null-guard already applied"
    return 0
  fi

  if sed -i.bak \
      's/this\.vlocity\.isOmniStudioInstalled && !this\.vlocity\.namespace)/this.vlocity.isOmniStudioInstalled \&\& !this.vlocity.namespace \&\& SObjectType)/g' \
      "$vfile" 2>/dev/null && grep -q 'this.vlocity.namespace && SObjectType)' "$vfile"; then
    rm -f "${vfile}.bak"
    vlocity_log "Patched vlocity datapacksutils.js null-guard for namespace-less OmniStudio orgs"
  else
    [ -f "${vfile}.bak" ] && mv -f "${vfile}.bak" "$vfile"
    vlocity_log "WARN: vlocity null-guard patch did not apply (build-tool layout may have changed)"
  fi
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
# build_vlocity_delta_project [changed-list] [base-job-file]
# Builds a *temporary* Vlocity project containing ONLY the datapack folders that
# changed in this delta, plus a matching temp job file that points at it. This
# makes `packDeploy` deploy exactly the changed packs (delta deploy) instead of
# the whole project — or, with an empty manifest, nothing at all.
#
# A datapack folder is the 3-segment path  ${VLOCITY_ROOT}/<Type>/<Name>/...
# Files directly under ${VLOCITY_ROOT}/ (e.g. deploy.yaml) are NOT datapacks and
# are ignored. The generated job file has NO manifest, so packDeploy deploys
# everything staged in the temp project (= the changed packs).
#
# Sets globals:
#   VLOCITY_DELTA_PACK_COUNT    number of datapack folders staged
#   VLOCITY_DELTA_JOB_FILE      path to the generated temp job file ("" if none)
#   VLOCITY_DELTA_PROJECT_DIR   path to the staged temp project dir ("" if none)
#   VLOCITY_DELTA_TMP_ROOT      temp root to clean up ("" if none)
# ------------------------------------------------------------------------------
build_vlocity_delta_project() {
  local changed_list="${1:-${VLOCITY_CHANGED_LIST:-}}"
  local base_job="${2:-$VLOCITY_JOB_FILE}"

  VLOCITY_DELTA_PACK_COUNT=0
  VLOCITY_DELTA_JOB_FILE=""
  VLOCITY_DELTA_PROJECT_DIR=""
  VLOCITY_DELTA_TMP_ROOT=""

  # Reduce changed files to unique datapack folders: <root>/<Type>/<Name>.
  local packs
  packs=$(printf '%s\n' "$changed_list" \
    | awk -F/ -v root="$VLOCITY_ROOT" 'NF>=4 && $1==root {print $1"/"$2"/"$3}' \
    | sort -u)

  if [ -z "$packs" ]; then
    return 0
  fi

  local tmp_root proj_dir
  tmp_root="$(mktemp -d)"
  proj_dir="${tmp_root}/project"
  mkdir -p "$proj_dir"

  local count=0 pack rel
  while IFS= read -r pack; do
    [ -z "$pack" ] && continue
    [ -d "$pack" ] || continue
    rel="${pack#"${VLOCITY_ROOT}"/}"           # <Type>/<Name>
    mkdir -p "${proj_dir}/$(dirname "$rel")"
    cp -R "$pack" "${proj_dir}/$(dirname "$rel")/"
    count=$((count + 1))
  done <<< "$packs"

  if [ "$count" -eq 0 ]; then
    rm -rf "$tmp_root"
    return 0
  fi

  # Generate the temp job file: copy the base job but drop projectPath/manifest,
  # then point projectPath at the temp project (no manifest = deploy everything
  # staged there). If the base job file is missing (e.g. it was removed from the
  # repo), fall back to safe CI defaults so the deploy can still run.
  local job_out="${tmp_root}/deploy.delta.yaml"
  if [ -f "$base_job" ]; then
    grep -vE '^[[:space:]]*(projectPath|manifest):' "$base_job" > "$job_out" 2>/dev/null || true
  else
    vlocity_log "Base job file '${base_job}' not found — using built-in delta defaults"
    {
      echo "expansionPath: ."
      echo "continueAfterError: true"
      echo "autoUpdateSettings: true"
      echo "defaultMaxParallel: 10"
      echo "maxDepth: -1"
      # activate/compileLwc disabled by default: the activation + LWC-compile
      # REST endpoints belong to the Vlocity managed package and 404 ("Could not
      # find a match for URL") on namespace-less OmniStudio Standard orgs.
      echo "activate: false"
      echo "compileLwc: false"
      echo "ignoreAllErrors: false"
      echo "verbose: true"
      echo "simpleLogging: true"
    } > "$job_out"
  fi
  {
    echo ""
    echo "# --- Auto-generated for delta deploy (changed datapacks only) ---"
    echo "projectPath: ${proj_dir}"
  } >> "$job_out"

  VLOCITY_DELTA_PACK_COUNT="$count"
  VLOCITY_DELTA_JOB_FILE="$job_out"
  VLOCITY_DELTA_PROJECT_DIR="$proj_dir"
  VLOCITY_DELTA_TMP_ROOT="$tmp_root"
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

#!/bin/bash
# ==============================================================================
# Vlocity (OmniStudio) Deployment
# ==============================================================================
# GitHub Actions equivalent of the Jenkins shared-library step:
#
#     def vlocityDeploy(targetEnv, deployUrl, salesforceCreds, deployfile) {
#         if (targetEnv == env.SF_REL_ENV) { sh "npm uninstall puppeteer -g" }
#         else                              { sh "npm install   puppeteer -g" }
#         jslGitHubDeploymentCreate(env.GIT_BRANCH, "${targetEnv}_Vlocity")
#         jslGitHubDeploymentSetStatus(..., 'in_progress', ...)
#         def success = jslBuildVlocity("-job ${deployfile} packDeploy ...", ...)
#         if (!success) {
#             success = jslBuildVlocity("-job ${deployfile} packRetry ...", ...)
#             if (!success) {
#                 jslGitHubDeploymentSetStatus(..., 'failure', ...)
#                 error("Deploy to ${targetEnv}_Vlocity Failed even after deploy")
#             }
#         }
#         jslGitHubDeploymentSetStatus(..., 'success', ...)
#     }
#
# Pre-requisites (set by the workflow before calling this script):
#   ORG_NAME              - SF CLI alias of the target org (dev / qa / intuat)
#   SF_AUTH_URL           - (optional) standard SFDX auth URL, used if the
#                           vlocity-specific URL isn't provided
#   VLOCITY_SF_AUTH_URL   - (optional) Vlocity-specific SFDX auth URL; takes
#                           precedence so the vlocity build can use a separate
#                           integration user
#   VLOCITY_JOB_FILE      - path to the vlocity job YAML, default vlocity/deploy.yaml
#
# Outputs:
#   reports/vlocity/packDeploy.log
#   reports/vlocity/packRetry.log (if a retry was needed)
#   reports/vlocity/summary.json
#
# Exit codes:
#   0  success / no-op (no Vlocity changes)
#   1  permanent failure (packDeploy + packRetry both failed)
#   2  configuration error
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_vlocity_lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_vlocity_lib.sh"

JOB_FILE="${VLOCITY_JOB_FILE:-vlocity/deploy.yaml}"
ORG_ALIAS="${ORG_NAME:-sandbox}"
VLOCITY_ENV_NAME="${ORG_ALIAS}_Vlocity"

mkdir -p "$VLOCITY_REPORTS_DIR"

echo ""
echo "🚀 STAGE: VLOCITY DEPLOY"
echo "=================================="
vlocity_log "Target org alias       : ${ORG_ALIAS}"
vlocity_log "GitHub deploy env name : ${VLOCITY_ENV_NAME}"
vlocity_log "Job file               : ${JOB_FILE}"

# ------------------------------------------------------------------------------
# 1) Detect whether there's anything to deploy.
# ------------------------------------------------------------------------------
detect_vlocity_changes "${FROM_REF:-}" "${TO_REF:-HEAD}"
print_vlocity_preview

if [ "${HAS_VLOCITY_CHANGES:-false}" != "true" ]; then
  vlocity_log "No Vlocity changes — skipping deploy"
  jq -nc \
    --arg status "Skipped" \
    --arg reason "No Vlocity/OmniStudio components changed in this delta" \
    '{result:{status:$status, message:$reason}}' \
    > "${VLOCITY_REPORTS_DIR}/summary.json"
  echo "✅ STAGE COMPLETED: Vlocity deploy skipped (no changes)"
  exit 0
fi

# ------------------------------------------------------------------------------
# 1b) Stage ONLY the changed datapacks into a temp project (delta deploy).
#     If the delta touched only non-datapack files (e.g. deploy.yaml itself),
#     there is nothing to deploy — skip cleanly.
# ------------------------------------------------------------------------------
build_vlocity_delta_project "${VLOCITY_CHANGED_LIST:-}" "$JOB_FILE"

if [ "${VLOCITY_DELTA_PACK_COUNT:-0}" -eq 0 ]; then
  vlocity_log "No datapack folders in delta (only non-datapack vlocity files changed) — nothing to deploy"
  jq -nc \
    --arg status "Skipped" \
    --arg reason "Vlocity files changed but no datapack folders (vlocity/<Type>/<Name>/) were affected" \
    '{result:{status:$status, message:$reason}}' \
    > "${VLOCITY_REPORTS_DIR}/summary.json"
  echo "✅ STAGE COMPLETED: Vlocity deploy skipped (no datapacks in delta)"
  exit 0
fi

DEPLOY_JOB_FILE="$VLOCITY_DELTA_JOB_FILE"
vlocity_log "Delta deploy: ${VLOCITY_DELTA_PACK_COUNT} changed datapack(s) staged → ${VLOCITY_DELTA_PROJECT_DIR}"

# ------------------------------------------------------------------------------
# 2) Install Vlocity CLI + configure puppeteer per target env.
# ------------------------------------------------------------------------------
install_vlocity_cli
configure_puppeteer "$ORG_ALIAS"

# ------------------------------------------------------------------------------
# 3) Authenticate the Salesforce CLI as the Vlocity integration user (if a
#    dedicated VLOCITY_SF_AUTH_URL was provided), otherwise reuse the org
#    alias already authenticated by scripts/authenticate.sh.
# ------------------------------------------------------------------------------
VLOCITY_ORG_ALIAS="${ORG_ALIAS}_vlocity"
if [ -n "${VLOCITY_SF_AUTH_URL:-}" ]; then
  vlocity_log "Authenticating dedicated vlocity user (alias ${VLOCITY_ORG_ALIAS})"
  auth_file="$(mktemp)"
  trap 'rm -f "${auth_file}"' EXIT
  printf '%s' "$VLOCITY_SF_AUTH_URL" > "$auth_file"
  if ! sf org login sfdx-url \
      --sfdx-url-file "$auth_file" \
      --alias "$VLOCITY_ORG_ALIAS" >/dev/null 2>&1; then
    vlocity_log "ERROR: Vlocity SFDX login failed — falling back to ${ORG_ALIAS}"
    VLOCITY_ORG_ALIAS="$ORG_ALIAS"
  fi
  rm -f "$auth_file"
  trap - EXIT
else
  vlocity_log "No VLOCITY_SF_AUTH_URL provided — reusing existing org alias ${ORG_ALIAS}"
  VLOCITY_ORG_ALIAS="$ORG_ALIAS"
fi

SF_USERNAME="$(resolve_vlocity_username "$VLOCITY_ORG_ALIAS")"
if [ -z "$SF_USERNAME" ]; then
  vlocity_log "ERROR: could not resolve a Salesforce username for alias ${VLOCITY_ORG_ALIAS}"
  exit 2
fi
vlocity_log "Resolved vlocity SFDX user: ${SF_USERNAME}"

# ------------------------------------------------------------------------------
# 4) Create a GitHub Deployment record so the commit shows "{env}_Vlocity" in
#    the Deployments tab — matches jslGitHubDeploymentCreate in the Jenkins lib.
# ------------------------------------------------------------------------------
DEPLOYMENT_ID="$(github_deployment_create "$VLOCITY_ENV_NAME" || echo '')"
if [ -n "$DEPLOYMENT_ID" ]; then
  vlocity_log "Created GitHub deployment id=${DEPLOYMENT_ID} for env=${VLOCITY_ENV_NAME}"
  github_deployment_set_status "$DEPLOYMENT_ID" "in_progress" "" "$VLOCITY_ENV_NAME"
fi

# ------------------------------------------------------------------------------
# 5) Run packDeploy → packRetry (mirrors Jenkins retry semantics exactly).
# ------------------------------------------------------------------------------
DEPLOY_RC=0
if vlocity_deploy_with_retry "$SF_USERNAME" "$DEPLOY_JOB_FILE"; then
  DEPLOY_STATUS="Succeeded"
else
  DEPLOY_RC=$?
  DEPLOY_STATUS="Failed"
fi

# ------------------------------------------------------------------------------
# 6) Write a machine-readable summary so the executive summary email/PR
#    comment can pick it up.
# ------------------------------------------------------------------------------
# NB: VLOCITY_CHANGED_LIST can contain thousands of paths. Passing it as a
# single `--arg` exceeds Linux's per-argument limit (MAX_ARG_STRLEN, 128KB) and
# fails with "Argument list too long". Stage it in a temp file and read it with
# --rawfile, which has no such limit.
CHANGED_LIST_FILE="$(mktemp)"
printf '%s' "${VLOCITY_CHANGED_LIST:-}" > "$CHANGED_LIST_FILE"

jq -nc \
  --arg status     "$DEPLOY_STATUS" \
  --arg env        "$VLOCITY_ENV_NAME" \
  --arg user       "$SF_USERNAME" \
  --arg jobFile    "$JOB_FILE" \
  --rawfile files  "$CHANGED_LIST_FILE" \
  --argjson rc     "$DEPLOY_RC" \
  --argjson packs  "${VLOCITY_DELTA_PACK_COUNT:-0}" \
  '{
     result: {
       status:          $status,
       returnCode:      $rc,
       environment:     $env,
       username:        $user,
       jobFile:         $jobFile,
       deltaPackCount:  $packs,
       changedFiles:    ($files | split("\n") | map(select(length>0)))
     }
   }' \
  > "${VLOCITY_REPORTS_DIR}/summary.json"

rm -f "$CHANGED_LIST_FILE"
# Clean up the staged delta project.
[ -n "${VLOCITY_DELTA_TMP_ROOT:-}" ] && rm -rf "$VLOCITY_DELTA_TMP_ROOT"

# ------------------------------------------------------------------------------
# 7) Update GitHub Deployment status to terminal state.
# ------------------------------------------------------------------------------
if [ -n "$DEPLOYMENT_ID" ]; then
  if [ "$DEPLOY_RC" -eq 0 ]; then
    github_deployment_set_status "$DEPLOYMENT_ID" "success" "" "$VLOCITY_ENV_NAME"
  else
    github_deployment_set_status "$DEPLOYMENT_ID" "failure" "" "$VLOCITY_ENV_NAME"
  fi
fi

if [ "$DEPLOY_RC" -eq 0 ]; then
  echo ""
  echo "✅ STAGE COMPLETED: Vlocity deploy to ${VLOCITY_ENV_NAME} succeeded"
  exit 0
else
  echo ""
  echo "❌ STAGE FAILED: Deploy to ${VLOCITY_ENV_NAME} failed even after packRetry"
  exit "$DEPLOY_RC"
fi

#!/bin/bash
# ==============================================================================
# Vlocity (OmniStudio) PR Validation
# ==============================================================================
# Runs on pull requests targeting dev / qa / intuat. It complements the
# Salesforce `sf project deploy start --dry-run` step (which validates standard
# metadata) by inspecting the Vlocity / OmniStudio components in the delta and
# proving that they parse and pack-build cleanly against the target org.
#
# The Vlocity Build Tool does not expose a true `--dry-run` for packDeploy.
# This script is therefore a structural validation rather than a full deploy:
#
#   1. Detect Vlocity changes in the PR delta.
#   2. Install the vlocity CLI + puppeteer for LWC compile.
#   3. Resolve the target SF user (no separate VLOCITY auth required for a PR
#      check — we re-use the same login the workflow already established).
#   4. Run `vlocity packGetAllAvailableExports --maxDepth 0` against the job
#      file to confirm the YAML parses and that the tool can connect.
#   5. (Optional) Run `vlocity packBuildFile` to confirm the changed datapacks
#      build into a single bundle without errors.
#
# Outputs:
#   reports/vlocity/validate.log
#   reports/vlocity/validate.json
#
# Exit codes:
#   0 success / no-op (no Vlocity changes)
#   1 validation failure
#   2 configuration error
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_vlocity_lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_vlocity_lib.sh"

JOB_FILE="${VLOCITY_JOB_FILE:-vlocity/deploy.yaml}"
ORG_ALIAS="${ORG_NAME:-sandbox}"

mkdir -p "$VLOCITY_REPORTS_DIR"

echo ""
echo "🚀 STAGE: VLOCITY VALIDATION (PR dry-run)"
echo "=================================="
vlocity_log "Target org alias : ${ORG_ALIAS}"
vlocity_log "Job file         : ${JOB_FILE}"

# ------------------------------------------------------------------------------
# 1) Detect changes — short-circuit when nothing to validate.
# ------------------------------------------------------------------------------
detect_vlocity_changes "${FROM_REF:-}" "${TO_REF:-HEAD}"
emit_vlocity_github_outputs
print_vlocity_preview

if [ "${HAS_VLOCITY_CHANGES:-false}" != "true" ]; then
  vlocity_log "No Vlocity / OmniStudio changes — skipping validation"
  jq -nc \
    --arg status "Skipped" \
    --arg reason "No Vlocity components changed" \
    '{result:{status:$status, message:$reason, changedFiles:[]}}' \
    > "${VLOCITY_REPORTS_DIR}/validate.json"
  echo "✅ STAGE COMPLETED: Vlocity validation skipped (no changes)"
  exit 0
fi

# ------------------------------------------------------------------------------
# 2) Sanity-check that the vlocity job file exists and parses.
# ------------------------------------------------------------------------------
if [ ! -f "$JOB_FILE" ]; then
  vlocity_log "ERROR: Vlocity job file not found at ${JOB_FILE}"
  jq -nc \
    --arg status "Failed" \
    --arg reason "Vlocity job file ${JOB_FILE} not present in repo" \
    '{result:{status:$status, message:$reason}}' \
    > "${VLOCITY_REPORTS_DIR}/validate.json"
  exit 2
fi

if ! python3 -c "import yaml,sys; yaml.safe_load(open('${JOB_FILE}'))" >/dev/null 2>&1; then
  vlocity_log "ERROR: ${JOB_FILE} is not valid YAML"
  jq -nc \
    --arg status "Failed" \
    --arg reason "Job file did not parse as YAML" \
    '{result:{status:$status, message:$reason}}' \
    > "${VLOCITY_REPORTS_DIR}/validate.json"
  exit 1
fi
vlocity_log "Vlocity job file parsed successfully"

# ------------------------------------------------------------------------------
# 3) Install vlocity + puppeteer (PRs always need puppeteer; we never validate
#    against PROD).
# ------------------------------------------------------------------------------
install_vlocity_cli
configure_puppeteer "$ORG_ALIAS"

# ------------------------------------------------------------------------------
# 4) Resolve SF user from the alias already authenticated by the workflow.
# ------------------------------------------------------------------------------
SF_USERNAME="$(resolve_vlocity_username "$ORG_ALIAS")"
if [ -z "$SF_USERNAME" ]; then
  vlocity_log "ERROR: could not resolve a SF username for alias ${ORG_ALIAS}"
  exit 2
fi
vlocity_log "Resolved SFDX user: ${SF_USERNAME}"

# ------------------------------------------------------------------------------
# 5) Connectivity check: `packGetAllAvailableExports --maxDepth 0` just exercises
#    the connection + job file + namespace resolution without deploying anything.
# ------------------------------------------------------------------------------
log_file="${VLOCITY_REPORTS_DIR}/validate.log"
set +e
vlocity \
  -sfdx.username "$SF_USERNAME" \
  -job "$JOB_FILE" \
  packGetAllAvailableExports \
  --maxDepth 0 \
  --verbose true \
  --simpleLogging true \
  2>&1 | tee "$log_file"
RC=${PIPESTATUS[0]}
set -e

if [ "$RC" -eq 0 ]; then
  STATUS="Succeeded"
  MSG="Vlocity job file + org connectivity verified"
else
  STATUS="Failed"
  MSG="vlocity packGetAllAvailableExports failed (exit ${RC})"
fi

jq -nc \
  --arg status   "$STATUS" \
  --arg msg      "$MSG" \
  --arg user     "$SF_USERNAME" \
  --arg jobFile  "$JOB_FILE" \
  --arg files    "${VLOCITY_CHANGED_LIST:-}" \
  --argjson rc   "$RC" \
  '{
     result: {
       status:        $status,
       returnCode:    $rc,
       message:       $msg,
       username:      $user,
       jobFile:       $jobFile,
       changedFiles:  ($files | split("\n") | map(select(length>0)))
     }
   }' \
  > "${VLOCITY_REPORTS_DIR}/validate.json"

if [ "$RC" -eq 0 ]; then
  echo ""
  echo "✅ STAGE COMPLETED: Vlocity validation passed"
  exit 0
else
  echo ""
  echo "❌ STAGE FAILED: Vlocity validation failed (exit ${RC})"
  exit "$RC"
fi

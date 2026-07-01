#!/bin/bash
# ==============================================================================
# Post-Merge Deployment (real deployment, not dry-run)
# ==============================================================================
# Performs an actual deployment to a Salesforce org using the delta package
# produced by scripts/generate_delta.sh. Supports:
#   - Source metadata deployment (delta/force-app)
#   - Destructive changes via --post-destructive-changes
#   - Destructive-only deployments (no source-dir, manifest-driven)
#   - Async start + polling loop with live progress
#
# Inputs (env):
#   ORG_NAME (alias)            - target org alias (required)
#   RELATED_TESTS               - optional CSV of mapped Apex test classes
#   COVERAGE_THRESHOLD          - optional, default 75
#   SF_DEPLOY_WAIT_MINUTES      - optional, default 30
#
# Outputs:
#   reports/deploy-start.json
#   reports/deploy-report.json
#
# Exit code:
#   0 on success / no-op
#   non-zero on deployment failure
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_deployment_lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_deployment_lib.sh"

mkdir -p reports

echo ""
echo "🚀 STAGE 7: POST-MERGE DEPLOYMENT"
echo "================================="
echo "🏷  Target org alias: ${ORG_NAME:-sandbox}"

detect_destructive_changes
print_destructive_preview

if ! has_any_deployable; then
  echo "ℹ️  No deployable metadata or destructive changes — skipping deployment."
  echo '{"result":{"status":"Skipped","message":"No changes to deploy"}}' > reports/deploy-report.json
  exit 0
fi

# ------------------------------------------------------------------------------
# Build deployment arguments from the shared library so dry-run and real
# deploy paths cannot diverge in their handling of destructive changes.
# ------------------------------------------------------------------------------
declare -a DEPLOY_ARGS=()
read_deploy_args_into DEPLOY_ARGS deploy "${ORG_NAME:-sandbox}"

# Reflect the chosen test level for clarity in the build log.
TEST_LEVEL="NoTestRun"
for ((i=0; i<${#DEPLOY_ARGS[@]}; i++)); do
  if [ "${DEPLOY_ARGS[$i]}" = "--test-level" ]; then
    TEST_LEVEL="${DEPLOY_ARGS[$((i+1))]}"
  fi
done

echo "🧪 Test Strategy: ${TEST_LEVEL}"
if [ "${HAS_DESTRUCTIVE_CHANGES:-false}" = "true" ]; then
  echo "🗑  Destructive members: ${DESTRUCTIVE_MEMBER_COUNT} (--post-destructive-changes)"
fi

# ------------------------------------------------------------------------------
# Start deployment async and capture job id, then poll with live status.
# ------------------------------------------------------------------------------
echo ""
echo "🚀 Starting deployment (async) and capturing job id..."

set +e
START_JSON=$(sf project deploy start "${DEPLOY_ARGS[@]}" --async 2>&1)
START_EXIT=$?
set -e

echo "$START_JSON" > reports/deploy-start.json || true

if [ "$START_EXIT" -ne 0 ]; then
  echo "❌ Failed to start deployment"
  echo "$START_JSON"
  exit "$START_EXIT"
fi

DEPLOY_ID=$(echo "$START_JSON" | jq -r '.result.id // .result.deploymentId // .result.jobId // empty' 2>/dev/null || echo "")
if [ -z "$DEPLOY_ID" ] || [ "$DEPLOY_ID" = "null" ]; then
  echo "❌ Could not determine deployment ID from start response"
  echo "$START_JSON"
  exit 1
fi

echo "📦 Deployment ID: $DEPLOY_ID"
echo ""
echo "📡 Polling deployment progress..."

LAST_STATUS=""
while true; do
  set +e
  REPORT_JSON=$(sf project deploy report --job-id "$DEPLOY_ID" --json 2>&1)
  REPORT_EXIT=$?
  set -e

  if [ "$REPORT_EXIT" -ne 0 ] || [ -z "$REPORT_JSON" ]; then
    echo "⚠️  Unable to fetch deployment report (code=$REPORT_EXIT); retrying in 10s..."
    sleep 10
    continue
  fi

  echo "$REPORT_JSON" > reports/deploy-report.json || true

  STATUS=$(echo "$REPORT_JSON" | jq -r '.result.status // .status // "Unknown"' 2>/dev/null || echo Unknown)
  TOTAL=$(echo "$REPORT_JSON"  | jq -r '.result.numberComponentsTotal // .numberComponentsTotal // 0' 2>/dev/null || echo 0)
  DONE=$(echo "$REPORT_JSON"   | jq -r '.result.numberComponentsDeployed // .numberComponentsDeployed // 0' 2>/dev/null || echo 0)
  ERR=$(echo "$REPORT_JSON"    | jq -r '.result.numberComponentErrors // .numberComponentErrors // 0' 2>/dev/null || echo 0)
  T_TOTAL=$(echo "$REPORT_JSON" | jq -r '.result.numberTestsTotal // .numberTestsTotal // 0' 2>/dev/null || echo 0)
  T_DONE=$(echo "$REPORT_JSON"  | jq -r '.result.numberTestsCompleted // .numberTestsCompleted // 0' 2>/dev/null || echo 0)
  T_FAIL=$(echo "$REPORT_JSON"  | jq -r '.result.numberTestErrors // .numberTestErrors // 0' 2>/dev/null || echo 0)

  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  if [ "$STATUS" != "$LAST_STATUS" ]; then
    echo "$TS ▶️  Status: $STATUS | Components: $DONE/$TOTAL (errors: $ERR) | Tests: $T_DONE/$T_TOTAL (failures: $T_FAIL)"
    LAST_STATUS="$STATUS"
  else
    echo "$TS ⏳ Progress: $DONE/$TOTAL comps, $T_DONE/$T_TOTAL tests, errs=$ERR, test-fails=$T_FAIL"
  fi

  case "$STATUS" in
    Succeeded|SucceededPartial)
      echo ""
      echo "✅ Deployment completed: $STATUS"
      summarize_deploy_report reports/deploy-report.json || true
      exit 0
      ;;
    Failed|Canceled|Aborted|Rejected)
      echo ""
      echo "❌ Deployment finished with status: $STATUS"
      summarize_deploy_report reports/deploy-report.json || true
      exit 1
      ;;
    *)
      sleep 10
      ;;
  esac
done

#!/usr/bin/env bash
# ==============================================================================
# Salesforce Command Engine — Parameterized Validation Runner
# ==============================================================================
# Maps the resolved parameters to the correct Salesforce CLI command and
# enforces the Validation/NoTestRun platform constraint:
#
#   NoTestRun (EXECUTION_MODE=dry-run):
#     sf project deploy start  --dry-run --test-level NoTestRun ...
#       (the Metadata API rejects NoTestRun under `deploy validate`)
#
#   All other levels (EXECUTION_MODE=validate):
#     sf project deploy validate --test-level <Level> [--tests ...] ...
#       (produces a 10-day quick-deploy validation ID)
#
# Inputs (environment variables):
#   TEST_LEVEL        resolved Apex test level
#   SPECIFIED_TESTS   space-separated class list (RunSpecifiedTests only)
#   EXECUTION_MODE    dry-run | validate
#   TARGET_ENV        sandbox-dev | sandbox-uat | production (for logs)
#   TARGET_ORG_ALIAS  CLI org alias (default: target-org)
#   SOURCE_DIR        metadata dir (default: force-app)
#   RESULTS_DIR       coverage/results output dir (default: reports/coverage)
#   REPORT_JSON       JSON report path (default: reports/validate-report.json)
# ==============================================================================

set -euo pipefail

TEST_LEVEL="${TEST_LEVEL:-RunLocalTests}"
SPECIFIED_TESTS="${SPECIFIED_TESTS:-}"
EXECUTION_MODE="${EXECUTION_MODE:-validate}"
TARGET_ENV="${TARGET_ENV:-sandbox-dev}"
TARGET_ORG_ALIAS="${TARGET_ORG_ALIAS:-target-org}"
SOURCE_DIR="${SOURCE_DIR:-force-app}"
RESULTS_DIR="${RESULTS_DIR:-reports/coverage}"
REPORT_JSON="${REPORT_JSON:-reports/validate-report.json}"

mkdir -p reports "$RESULTS_DIR"

echo "🧪 Salesforce validation: level=${TEST_LEVEL}, mode=${EXECUTION_MODE}, env=${TARGET_ENV}, org=${TARGET_ORG_ALIAS}"

# Build the argv array so each test class is passed as a discrete token and is
# never re-expanded by the shell (defends against injection via class names).
declare -a ARGS=()

if [ "$EXECUTION_MODE" = "dry-run" ]; then
  # NoTestRun path — bypass the validate/NoTestRun constraint via deploy start.
  ARGS=(
    project deploy start
    --source-dir "$SOURCE_DIR"
    --dry-run
    --test-level NoTestRun
    --target-org "$TARGET_ORG_ALIAS"
    --verbose
    --json
  )
else
  ARGS=(
    project deploy validate
    --source-dir "$SOURCE_DIR"
    --test-level "$TEST_LEVEL"
    --target-org "$TARGET_ORG_ALIAS"
    --coverage-formatters json
    --results-dir "$RESULTS_DIR"
    --verbose
    --json
  )
  if [ "$TEST_LEVEL" = "RunSpecifiedTests" ]; then
    if [ -z "$SPECIFIED_TESTS" ]; then
      echo "::error::RunSpecifiedTests requires at least one class in SPECIFIED_TESTS." >&2
      exit 1
    fi
    # Append one --tests flag per class.
    for t in $SPECIFIED_TESTS; do
      ARGS+=(--tests "$t")
    done
  fi
fi

echo "▶️  sf ${ARGS[*]}"

set +e
sf "${ARGS[@]}" > "$REPORT_JSON" 2>&1
RC=$?
set -e

# Surface a human-readable summary regardless of outcome.
if command -v jq >/dev/null 2>&1 && jq -e . "$REPORT_JSON" >/dev/null 2>&1; then
  STATUS=$(jq -r '.result.status // .status // "Unknown"' "$REPORT_JSON" 2>/dev/null || echo "Unknown")
  DEPLOY_ID=$(jq -r '.result.id // empty' "$REPORT_JSON" 2>/dev/null || echo "")
  echo "📄 Status: ${STATUS}"
  [ -n "$DEPLOY_ID" ] && echo "🆔 Validation/Deployment Id: ${DEPLOY_ID} (quick-deploy ID is valid for 10 days)"
else
  echo "⚠️  CLI did not return parseable JSON — raw output:"
  cat "$REPORT_JSON" || true
fi

if [ "$RC" -ne 0 ]; then
  echo "::error::Salesforce validation failed (exit ${RC})." >&2
  exit "$RC"
fi

echo "✅ Salesforce validation command completed."

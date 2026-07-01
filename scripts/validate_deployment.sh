#!/bin/bash
# ==============================================================================
# Deployment Dry-Run Validation
# ==============================================================================
# Executes a dry-run (check-only) deployment validation to Salesforce.
# Tests deployment without actually deploying to ensure quality.
#
# Capabilities:
#   - Source metadata validation (delta/force-app)
#   - Destructive change validation (delta/destructiveChanges/destructiveChanges.xml)
#   - Destructive-only PRs (no source metadata, only deletions)
#   - Test selection honors the resolved/selected level (no RunLocalTests fallback)
#   - NoTestRun for metadata-only and destructive-only changes
#
# Output:
#   - reports/deploy-report.json
#   - reports/validation-summary.txt
# ==============================================================================

set -euo pipefail

# Load shared deployment helpers (destructive detection, deploy args, summary).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_deployment_lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_deployment_lib.sh"

echo ""
echo "🚀 STAGE 6: DRY-RUN VALIDATION & QUALITY GATES SUMMARY"
echo "======================================================"
echo "🔍 Validating deployment with check-only mode (no actual deployment)..."

mkdir -p reports
echo '{"result":{"status":"Failed","message":"No deploy run performed"}}' > reports/deploy-report.json
echo "" > reports/validation-summary.txt

# PR validation is STRICT about Apex tests: if Apex changed and no test class can
# be found/mapped, the run must fail (not silently fall back to RunLocalTests).
# select_test_args() reads this. Post-merge deploy.sh does NOT set it, so its
# behavior is unchanged.
export REQUIRE_APEX_TESTS="true"

# Effective test level actually used for this run, surfaced to the executive
# summary (reports/test-level.txt). Overwritten below once resolved.
echo "NoTestRun" > reports/test-level.txt

# Single source of truth for downstream steps. We default to "failure" so that
# any unexpected `set -e` exit, killed subshell, or early crash is faithfully
# reported instead of triggering a confusing "validation_result.txt missing"
# fallback in the workflow YAML. Each clean exit path below overrides this.
echo "failure" > validation_result.txt
record_result() {
  case "${1:-failure}" in
    success) echo "success" > validation_result.txt ;;
    *)       echo "failure" > validation_result.txt ;;
  esac
}

summary() {
  echo "$1" | tee -a reports/validation-summary.txt
}

# ------------------------------------------------------------------------------
# Detect what's actually deployable (source and/or destructive)
# ------------------------------------------------------------------------------
detect_destructive_changes
print_destructive_preview

NON_APEX_DEPLOYMENT="false"

if has_any_deployable; then
  summary "📦 Deployable changes detected"
  if [ "${HAS_DESTRUCTIVE_CHANGES:-false}" = "true" ]; then
    summary "🗑️  Destructive members: ${DESTRUCTIVE_MEMBER_COUNT}"
  fi
  if has_source_metadata; then
    SOURCE_FILE_COUNT=$(find "$DELTA_SOURCE_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
    summary "📁 Source files: ${SOURCE_FILE_COUNT}"
  else
    summary "📁 Source files: 0 (destructive-only run)"
  fi

  # Apex detection drives both test strategy and the coverage gate.
  HAS_APEX_IN_DELTA="false"
  if has_source_metadata && find "$DELTA_SOURCE_DIR" \( -name '*.cls' -o -name '*.trigger' \) 2>/dev/null | grep -q .; then
    HAS_APEX_IN_DELTA="true"
  fi

  if [ "$HAS_APEX_IN_DELTA" = "false" ]; then
    NON_APEX_DEPLOYMENT="true"
  fi

  # ----------------------------------------------------------------------------
  # Build primary deploy arguments (test selection lives inside the lib).
  # ----------------------------------------------------------------------------
  declare -a PRIMARY_ARGS=()
  read_deploy_args_into PRIMARY_ARGS validate "${ORG_NAME:-sandbox}"

  # Reflect the chosen test level in the summary.
  PRIMARY_TEST_LEVEL="NoTestRun"
  for ((i=0; i<${#PRIMARY_ARGS[@]}; i++)); do
    if [ "${PRIMARY_ARGS[$i]}" = "--test-level" ]; then
      PRIMARY_TEST_LEVEL="${PRIMARY_ARGS[$((i+1))]}"
    fi
  done
  summary "🧪 Test Strategy: ${PRIMARY_TEST_LEVEL}"
  echo "$PRIMARY_TEST_LEVEL" > reports/test-level.txt

  # Is there an explicit --tests list in the resolved plan?
  PRIMARY_HAS_TESTS="false"
  for ((i=0; i<${#PRIMARY_ARGS[@]}; i++)); do
    if [ "${PRIMARY_ARGS[$i]}" = "--tests" ]; then
      PRIMARY_HAS_TESTS="true"
      break
    fi
  done

  # HARD GATE: Apex changed but no test class could be found/mapped. RunSpecifiedTests
  # with an empty --tests list is an invalid, wasteful run — fail fast with an
  # actionable message instead of shipping untested Apex.
  if [ "$PRIMARY_TEST_LEVEL" = "RunSpecifiedTests" ] && [ "$PRIMARY_HAS_TESTS" = "false" ]; then
    echo "NO_TEST_FOUND" > reports/test-level.txt
    summary "❌ Apex changes detected, but NO Apex test class could be found or mapped to them."
    echo "::error::Apex was modified but no test class covers it. Add a *Test class that exercises the changed class(es) (or explicitly choose RunLocalTests / RunAllTestsInOrg in the PR), then re-run."
    record_result failure
    exit 1
  fi

  if [ "$PRIMARY_TEST_LEVEL" = "RunSpecifiedTests" ]; then
    summary "   Tests: $(printf '%s ' "${PRIMARY_ARGS[@]}" | tr ' ' '\n' | awk '/^--tests$/{getline; print}' | paste -sd, - || echo "")"
  fi

  echo ""
  echo "⚙️  EXECUTING DRY-RUN VALIDATION"
  echo "================================"
  echo "📋 Validation Details:"
  echo "  • Mode: Dry-run (check-only - no actual deployment)"
  echo "  • Test Level: ${PRIMARY_TEST_LEVEL}"
  echo "  • Environment: ${ORG_NAME:-sandbox}"
  if [ "${HAS_DESTRUCTIVE_CHANGES:-false}" = "true" ]; then
    echo "  • Destructive: ${DESTRUCTIVE_MEMBER_COUNT} member(s) via --post-destructive-changes"
  fi
  echo ""

  summary "🔄 Running validation..."
  if sf project deploy start "${PRIMARY_ARGS[@]}" > reports/deploy-report.json 2>&1; then
    summary "✅ Validation passed (${PRIMARY_TEST_LEVEL})"
  else
    summary "⚠️  Validation failed with primary strategy"
  fi

  # Compute coverage from primary attempt
  COVERAGE=0
  if jq -e '.result.details.runTestResult.codeCoverage' reports/deploy-report.json >/dev/null 2>&1; then
    COVERAGE=$(jq -r '[.result.details.runTestResult.codeCoverage[]? | (.coveredPercent // 0)] | (if length>0 then (add/length) else 0 end)' reports/deploy-report.json 2>/dev/null || echo "0")
    COVERAGE=${COVERAGE%.*}
  fi
  summary "📊 Coverage: ${COVERAGE}%"

  # ----------------------------------------------------------------------------
  # NOTE: The automatic "RunLocalTests fallback" was intentionally REMOVED.
  # Previously, when the primary strategy was RunSpecifiedTests and coverage was
  # below threshold, the script fired a SECOND `sf project deploy start` with
  # RunLocalTests — producing a second validation in the org and overwriting the
  # first report. We now run EXACTLY ONE validation with the selected test level;
  # there is no second org validation.
  # ----------------------------------------------------------------------------

  # ----------------------------------------------------------------------------
  # Direct link to the org's Deployment Status page for fast triage.
  # ----------------------------------------------------------------------------
  if command -v jq >/dev/null 2>&1; then
    ORG_URL=$(sf org display --target-org "${ORG_NAME:-sandbox}" --json 2>/dev/null | jq -r '.result.instanceUrl // empty' || true)
    DEPLOY_ID=$(jq -r '.result.id // empty' reports/deploy-report.json 2>/dev/null || echo "")
    if [ -n "$ORG_URL" ]; then
      echo "🔗 View in org: ${ORG_URL}/lightning/setup/DeployStatus/home"
      if [ -n "$DEPLOY_ID" ]; then
        echo "🆔 Deployment Id: $DEPLOY_ID"
      fi
    fi
  fi

  # ----------------------------------------------------------------------------
  # Echo all changed files for the PR comment / log preview.
  # ----------------------------------------------------------------------------
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📝 ALL FILES MODIFIED IN THIS CHANGE"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  ALL_MODIFIED=$(git diff --name-only "origin/${TARGET_BRANCH:-main}" HEAD 2>/dev/null | head -30 || true)

  if [ -n "$ALL_MODIFIED" ]; then
    METADATA_FILES=$(echo "$ALL_MODIFIED" | grep -E '^force-app/' || true)
    SCRIPT_FILES=$(echo "$ALL_MODIFIED" | grep -E '\.(sh|yml|yaml)$' || true)
    CONFIG_FILES=$(echo "$ALL_MODIFIED" | grep -E '\.(json|md|xml)$' | grep -v '^force-app/' || true)
    DELETED_FILES=$(git diff --name-only --diff-filter=D "origin/${TARGET_BRANCH:-main}" HEAD 2>/dev/null || true)

    if [ -n "$METADATA_FILES" ]; then
      echo ""
      echo "📦 Salesforce Metadata:"
      echo "$METADATA_FILES" | sed 's/^/  /'
    fi
    if [ -n "$DELETED_FILES" ]; then
      echo ""
      echo "🗑️  Deleted Files (drives destructiveChanges.xml):"
      echo "$DELETED_FILES" | sed 's/^/  /'
    fi
    if [ -n "$SCRIPT_FILES" ]; then
      echo ""
      echo "🔧 Pipeline Scripts:"
      echo "$SCRIPT_FILES" | sed 's/^/  /'
    fi
    if [ -n "$CONFIG_FILES" ]; then
      echo ""
      echo "⚙️  Configuration Files:"
      echo "$CONFIG_FILES" | sed 's/^/  /'
    fi
  else
    echo "  (unable to determine changed files)"
  fi
  echo ""

else
  summary "ℹ️  No deployable metadata or destructive changes - skipping validation"
  echo '{"result":{"status":"Skipped","message":"No changes to deploy"}}' > reports/deploy-report.json

  echo ""
  echo "📝 Files Modified in This Change:"
  git diff --name-only "origin/${TARGET_BRANCH:-main}" HEAD 2>/dev/null | head -20 || echo "  (unable to determine changed files)"
  echo ""
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 DRY-RUN VALIDATION & QUALITY GATES SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Code Analyzer results
APEX_VIOLATIONS=0
LWC_VIOLATIONS=0
if [ -f reports/apex.json ]; then
  APEX_VIOLATIONS=$(jq '.violations | length' reports/apex.json 2>/dev/null || echo "0")
fi
if [ -f reports/lwc.json ]; then
  LWC_VIOLATIONS=$(jq '.violations | length' reports/lwc.json 2>/dev/null || echo "0")
fi
TOTAL_VIOLATIONS=$((APEX_VIOLATIONS + LWC_VIOLATIONS))

# Deployment validation metrics
STATUS="Failed"
COMPONENT_FAIL_COUNT=0
TEST_FAIL_COUNT=0
COVERAGE=${COVERAGE:-0}

if [ -f reports/deploy-report.json ]; then
  STATUS=$(jq -r '.result.status // "Failed"' reports/deploy-report.json 2>/dev/null || echo "Failed")

  if jq -e '.result.details.componentFailures' reports/deploy-report.json >/dev/null 2>&1; then
    COMPONENT_FAIL_COUNT=$(jq '.result.details.componentFailures | length' reports/deploy-report.json 2>/dev/null || echo "0")
  fi

  if jq -e '.result.details.runTestResult.failures' reports/deploy-report.json >/dev/null 2>&1; then
    TEST_FAIL_COUNT=$(jq '.result.details.runTestResult.failures | length' reports/deploy-report.json 2>/dev/null || echo "0")
  fi

  if jq -e '.result.details.runTestResult.codeCoverage' reports/deploy-report.json >/dev/null 2>&1; then
    COVERAGE=$(jq -r '[.result.details.runTestResult.codeCoverage[]? | (.coveredPercent // 0)] | (if length>0 then (add/length) else 0 end)' reports/deploy-report.json 2>/dev/null || echo "0")
    COVERAGE=${COVERAGE%.*}
  fi
fi

echo ""
echo "🔍 Code Quality Analysis:"
echo "  • Total Code Violations: $TOTAL_VIOLATIONS (Apex: $APEX_VIOLATIONS, LWC: $LWC_VIOLATIONS)"

# Vlocity summary — gate on directory existence to keep `set -euo pipefail`
# happy when the delta workspace is empty (no deploy run).
VLOCITY_COMPONENTS=0
if [ -d delta/force-app ]; then
  VLOCITY_COMPONENTS=$(find delta/force-app \( -name '*.rpt-meta.xml' -o -name '*.oip-meta.xml' -o -name '*.omniscript-meta.xml' \) 2>/dev/null | wc -l | tr -d ' ')
fi
if [ "$VLOCITY_COMPONENTS" -gt 0 ]; then
  echo ""
  echo "🧩 Vlocity Components Detected:"
  OMNI_DATA_TRANSFORMS=$(find delta/force-app -name "*.rpt-meta.xml" 2>/dev/null | wc -l | tr -d ' ')
  OMNI_INTEGRATION_PROCEDURES=$(find delta/force-app -name "*.oip-meta.xml" 2>/dev/null | wc -l | tr -d ' ')
  OMNI_SCRIPTS=$(find delta/force-app -name "*.omniscript-meta.xml" 2>/dev/null | wc -l | tr -d ' ')
  echo "  • Total Vlocity Components: $VLOCITY_COMPONENTS"
  [ "$OMNI_DATA_TRANSFORMS" -gt 0 ] && echo "  • OmniDataTransform: $OMNI_DATA_TRANSFORMS"
  [ "$OMNI_INTEGRATION_PROCEDURES" -gt 0 ] && echo "  • OmniIntegrationProcedure: $OMNI_INTEGRATION_PROCEDURES"
  [ "$OMNI_SCRIPTS" -gt 0 ] && echo "  • OmniScript: $OMNI_SCRIPTS"
  echo "  • XML Validation: ✅ Validated during deployment"
fi

if [ "${HAS_DESTRUCTIVE_CHANGES:-false}" = "true" ]; then
  echo ""
  echo "🗑️  Destructive Changes Validated:"
  echo "  • Members: ${DESTRUCTIVE_MEMBER_COUNT}"
  echo "  • Mode: --post-destructive-changes (delete after source deploy)"
fi

echo ""
echo "🧪 Deployment Validation:"
echo "  • Validation Status: ${STATUS}"
echo "  • Component Failures: ${COMPONENT_FAIL_COUNT}"
echo "  • Test Failures: ${TEST_FAIL_COUNT}"
echo "  • Code Coverage: ${COVERAGE}% (threshold: ${COVERAGE_THRESHOLD:-75}%)"
echo ""

# Detailed failure information
if [ "${COMPONENT_FAIL_COUNT}" -gt 0 ] || [ "${TEST_FAIL_COUNT}" -gt 0 ] || [ "$STATUS" = "Failed" ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "⚠️  ISSUES DETECTED"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if [ "${TEST_FAIL_COUNT}" -gt 0 ]; then
    echo ""
    echo "🧪 Test Failures:"
    jq -r '.result.details.runTestResult.failures[]? |
      "  ❌ \(.name).\(.methodName // "unknown")\n     \(.message // "" )" ' reports/deploy-report.json 2>/dev/null \
      | sed -e "s/<br>/\\n/g" -e "s/<[^>]*>//g" \
      | head -20 || true
  fi

  if [ "${COMPONENT_FAIL_COUNT}" -gt 0 ]; then
    echo ""
    echo "🔧 Component Failures:"
    jq -r '.result.details.componentFailures[]? | "  ❌ " + (.fileName // .name) + ": " + (.problem // "Unknown")' reports/deploy-report.json 2>/dev/null | head -10 || true
  fi

  if [ "${COMPONENT_FAIL_COUNT}" -eq 0 ] && [ "${TEST_FAIL_COUNT}" -eq 0 ] && [ "$STATUS" = "Failed" ]; then
    echo ""
    echo "🔧 Deployment Errors:"
    if [ -f reports/deploy-report.json ]; then
      echo "📄 Full deployment report:"
      jq -r '.result // .' reports/deploy-report.json 2>/dev/null | head -50 || true
    fi
  fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 QUALITY GATE VERDICT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# One verdict, one line of action. Detailed metrics already printed above.
if [ "$STATUS" = "Succeeded" ]; then
  echo "✅ PASSED — deployment validated successfully."
  record_result success
  exit 0

elif [ "$STATUS" = "Skipped" ] && [ "${COMPONENT_FAIL_COUNT}" -eq 0 ] && [ "${TEST_FAIL_COUNT}" -eq 0 ]; then
  echo "✅ PASSED — no Salesforce changes to validate."
  record_result success
  exit 0

elif [ "${COMPONENT_FAIL_COUNT}" -gt 0 ] || [ "${TEST_FAIL_COUNT}" -gt 0 ]; then
  echo "❌ FAILED — ${COMPONENT_FAIL_COUNT} component error(s), ${TEST_FAIL_COUNT} test failure(s)."
  echo "👉 ACTION: fix the issues listed under '⚠️  ISSUES DETECTED' above, commit, re-push."
  record_result failure
  exit 1

elif [ "$STATUS" != "Succeeded" ] \
     && [ "$STATUS" != "Skipped" ] \
     && [ "${NON_APEX_DEPLOYMENT:-false}" != "true" ] \
     && [ "$COVERAGE" -lt "${COVERAGE_THRESHOLD:-75}" ]; then
  echo "❌ FAILED — code coverage ${COVERAGE}% is below the ${COVERAGE_THRESHOLD:-75}% threshold."
  echo "👉 ACTION: add or fix Apex tests for the changed classes."
  record_result failure
  exit 1

else
  echo "❌ FAILED — deployment validation status: ${STATUS}."
  echo "👉 ACTION: review the error block above (or open the deploy report link if printed)."
  record_result failure
  exit 1
fi

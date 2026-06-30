#!/usr/bin/env bash
# ==============================================================================
# Code Coverage Validation  (parity with Jenkinsfile validate())
# ==============================================================================
# Mirrors the test-coverage validation logic of the reference Jenkins pipeline
# (Jenkinsfile -> def validate()). Reads the Salesforce CLI --json validation
# report and reproduces the same behavior:
#
#   - Per-class coverage = (numLocations - numLocationsNotCovered) / numLocations
#     * 100, formatted to 2 decimals. Classes with numLocations == 0 are skipped
#     with the same diagnostic message.
#   - Overall coverage is computed and printed inside a
#     "Code Coverage Results Start ... End" block.
#   - Threshold is 95%, but overall < 95% is only a WARNING (the per-class fail
#     was intentionally commented out in the reference).
#   - HARD FAILURES (build-breaking), exactly as in the reference:
#       * non-empty .result.details.runTestResult.codeCoverageWarnings  -> fail
#       * non-empty .result.details.runTestResult.failures              -> fail
#   - Coverage gating only applies when Apex (.cls/.trigger) is present
#     (CONTAINS_COVERAGE_CHECK_FILES).
#
# Inputs (environment variables):
#   REPORT_JSON          validation JSON report (default: reports/validate-report.json)
#   COVERAGE_THRESHOLD   warning threshold percent (default: 95, matches reference)
#   TEST_LEVEL           NoTestRun short-circuits (no tests were executed)
#   COVERAGE_SCAN_DIR    dir scanned for *.cls/*.trigger (default: force-app)
# ==============================================================================

set -euo pipefail

REPORT_JSON="${REPORT_JSON:-reports/validate-report.json}"
COVERAGE_THRESHOLD="${COVERAGE_THRESHOLD:-95}"   # reference Jenkinsfile uses 95
TEST_LEVEL="${TEST_LEVEL:-}"
COVERAGE_SCAN_DIR="${COVERAGE_SCAN_DIR:-force-app}"

echo "📊 Code Coverage Validation (warning threshold: ${COVERAGE_THRESHOLD}%, parity with Jenkins validate())"

if [ "$TEST_LEVEL" = "NoTestRun" ]; then
  echo "No code coverage data available."
  echo "ℹ️  TEST_LEVEL=NoTestRun — no tests executed."
  exit 0
fi

if [ ! -f "$REPORT_JSON" ]; then
  echo "::warning::Coverage report '$REPORT_JSON' not found — skipping coverage validation."
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "::warning::jq not available — skipping coverage validation."
  exit 0
fi

# CONTAINS_COVERAGE_CHECK_FILES: only enforce coverage when Apex is in scope.
CONTAINS_COVERAGE_CHECK_FILES=false
for ext in cls trigger; do
  if find "$COVERAGE_SCAN_DIR" -type f -name "*.$ext" 2>/dev/null | grep -q .; then
    CONTAINS_COVERAGE_CHECK_FILES=true
    break
  fi
done
echo "CONTAINS_COVERAGE_CHECK_FILES : ${CONTAINS_COVERAGE_CHECK_FILES}"

# ------------------------------------------------------------------------------
# Per-class + overall coverage (identical math to the reference)
# ------------------------------------------------------------------------------
hasCoverage="false"
if jq -e 'try .result.details.runTestResult.codeCoverage[] catch false' "$REPORT_JSON" >/dev/null 2>&1; then
  hasCoverage="true"
fi

formattedOverallCoverage=""
if [ "$hasCoverage" = "true" ]; then
  totalCoveredLocations=0
  totalLocationsProcessed=0
  classCoverages=()

  while IFS=$'\t' read -r name totalLocations uncoveredLocations; do
    [ -z "$name" ] && continue
    totalLocations="${totalLocations:-0}"
    uncoveredLocations="${uncoveredLocations:-0}"
    if [ "$totalLocations" -gt 0 ]; then
      covered=$(( totalLocations - uncoveredLocations ))
      formattedCoverage=$(awk "BEGIN{printf \"%.2f\", ($covered/$totalLocations)*100}")
      classCoverages+=("${name}: ${formattedCoverage}%")
      totalCoveredLocations=$(( totalCoveredLocations + covered ))
      totalLocationsProcessed=$(( totalLocationsProcessed + totalLocations ))
    else
      echo "Skipping ${name}: numLocations or numLocationsNotCovered missing or invalid."
    fi
  done < <(jq -r '.result.details.runTestResult.codeCoverage[]?
                  | [ (.name // ""),
                      ((.numLocations // 0) | tostring),
                      ((.numLocationsNotCovered // 0) | tostring) ]
                  | @tsv' "$REPORT_JSON")

  if [ "$totalLocationsProcessed" -gt 0 ]; then
    formattedOverallCoverage=$(awk "BEGIN{printf \"%.2f\", ($totalCoveredLocations/$totalLocationsProcessed)*100}")
    echo "Code Coverage Results Start"
    echo "Overall Code Coverage: ${formattedOverallCoverage}%"
    for line in "${classCoverages[@]}"; do echo "$line"; done
    echo "Code Coverage Results End"
  else
    echo "No valid coverage data found."
  fi
else
  echo "No code coverage data available."
fi

# Overall < threshold is only a WARNING (matches reference behavior).
if [ -n "$formattedOverallCoverage" ] && [ "$CONTAINS_COVERAGE_CHECK_FILES" = "true" ]; then
  if awk "BEGIN{exit !($formattedOverallCoverage < $COVERAGE_THRESHOLD)}"; then
    echo "⚠️ Warning: Overall Code Coverage is less than ${COVERAGE_THRESHOLD}%. Please improve coverage."
  fi
fi

# ------------------------------------------------------------------------------
# Hard gates (build-breaking), exactly as the reference validate()
# ------------------------------------------------------------------------------
echo "Extracting Test Coverage Warnings..."
testCoverageWarnings=$(jq -r 'try .result.details.runTestResult.codeCoverageWarnings[] catch empty
                              | "\nClass: \(.name), Message: \(.message)\n"' "$REPORT_JSON" 2>/dev/null || echo "")

testfailures=$(jq -r 'try .result.details.runTestResult.failures[] catch empty
                      | "\nClass: \(.name), Message: \(.message)\n"' "$REPORT_JSON" 2>/dev/null || echo "")

if [ -n "$(printf '%s' "$testCoverageWarnings" | tr -d '[:space:]')" ]; then
  echo "Test Coverage Warnings Found:"
  echo "${testCoverageWarnings}"
  echo "::error::Deployment failed due to insufficient test coverage warning found. Please improve coverage and retry."
  exit 1
else
  echo "No Test Coverage Warnings Found."
fi

if [ -n "$(printf '%s' "$testfailures" | tr -d '[:space:]')" ]; then
  echo "Test Class failures Found:"
  echo "${testfailures}"
  echo "::error::Deployment failed due to test classes failing. Please check the error."
  exit 1
else
  echo "No Test Failures Found."
fi

echo "✅ Coverage validation passed (no coverage warnings, no test failures)."

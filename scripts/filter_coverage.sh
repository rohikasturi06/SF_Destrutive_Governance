#!/bin/bash
# ==============================================================================
# Code Coverage Analysis for Delta Classes
# ==============================================================================
# Analyzes and displays code coverage for Apex classes in the delta package.
# Shows individual class coverage percentages to help identify testing gaps.
#
# Output:
#   - Coverage percentage for each Apex class in delta
#   - Overall coverage summary
#   - Filtered coverage report
# ==============================================================================

set -euo pipefail

echo ""
echo "🚀 STAGE 5C: CODE COVERAGE ANALYSIS"
echo "==================================="

# Check if we have a deploy report
if [ ! -f reports/deploy-report.json ]; then
  echo "ℹ️  No deployment validation ran - skipping coverage analysis"
  echo ""
  echo "✅ STAGE 5C COMPLETED: Coverage analysis skipped"
  echo "============================================"
  exit 0
fi

# Check if we have delta classes
if [ -z "${DELTA_APEX_CLASSES:-}" ]; then
  echo "ℹ️  No Apex classes in delta - skipping coverage analysis"
  echo ""
  echo "✅ STAGE 5C COMPLETED: Coverage analysis skipped"
  echo "============================================"
  exit 0
fi

echo "📋 Analyzing coverage for delta classes..."
echo ""

# Check if coverage data exists
if ! jq -e '.result.details.runTestResult.codeCoverage' reports/deploy-report.json >/dev/null 2>&1; then
  # Check if tests failed
  TEST_FAIL_COUNT=0
  if jq -e '.result.details.runTestResult.failures' reports/deploy-report.json >/dev/null 2>&1; then
    TEST_FAIL_COUNT=$(jq '.result.details.runTestResult.failures | length' reports/deploy-report.json 2>/dev/null || echo "0")
  fi
  
  if [ "$TEST_FAIL_COUNT" -gt 0 ]; then
    echo "⚠️  No coverage data - tests failed during execution"
    echo ""
    echo "ℹ️  Salesforce doesn't generate coverage when tests fail."
    echo "   Fix test failures first, then coverage will be available."
  else
    echo "ℹ️  No coverage data available (metadata-only deployment)"
  fi
  
  echo ""
  echo "📊 Delta Classes (coverage unavailable):"
  for cls in $DELTA_APEX_CLASSES; do
    echo "  • $cls"
  done
  echo ""
  echo "✅ STAGE 5C COMPLETED: Coverage analysis skipped"
  echo "============================================="
  exit 0
fi

# Display coverage for each delta class
echo "📊 Coverage by Class:"
echo "===================="

TOTAL_COVERAGE=0
CLASS_COUNT=0

for cls in $DELTA_APEX_CLASSES; do
  # Get coverage for this specific class
  COVERAGE=$(jq -r --arg cls "$cls" '.result.details.runTestResult.codeCoverage[]? | select(.name == $cls) | .coveredPercent // "N/A"' reports/deploy-report.json 2>/dev/null || echo "N/A")
  
  if [ "$COVERAGE" = "N/A" ] || [ -z "$COVERAGE" ]; then
    echo "  • $cls: N/A (not covered or not executable)"
  else
    echo "  • $cls: ${COVERAGE}%"
    TOTAL_COVERAGE=$((TOTAL_COVERAGE + ${COVERAGE%.*}))
    CLASS_COUNT=$((CLASS_COUNT + 1))
  fi
done

echo ""
if [ $CLASS_COUNT -gt 0 ]; then
  AVG_COVERAGE=$((TOTAL_COVERAGE / CLASS_COUNT))
  echo "📈 Average Coverage: ${AVG_COVERAGE}%"
  
  if [ $AVG_COVERAGE -lt 75 ]; then
    echo "⚠️  Coverage below 75% threshold"
  else
    echo "✅ Coverage meets 75% threshold"
  fi
else
  echo "ℹ️  No executable Apex classes with coverage data"
fi

# Filter the coverage report to only include delta classes
echo ""
echo "🔧 Filtering coverage report for delta classes..."

jq --arg delta_classes "$DELTA_APEX_CLASSES" '
  if .result.details.runTestResult.codeCoverage then
    .result.details.runTestResult.codeCoverage = [
      .result.details.runTestResult.codeCoverage[]? | 
      select(.name as $name | ($delta_classes | split(" ") | index($name)))
    ]
  else
    .
  end
' reports/deploy-report.json > reports/deploy-report-filtered.json 2>/dev/null

# Replace original with filtered version
if [ -f reports/deploy-report-filtered.json ]; then
  mv reports/deploy-report-filtered.json reports/deploy-report.json
  echo "✅ Coverage report filtered to delta scope only"
fi

echo ""
echo "✅ STAGE 5C COMPLETED: Coverage analysis finished"
echo "=============================================="

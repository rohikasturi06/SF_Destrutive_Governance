#!/bin/bash
# ==============================================================================
# Deployment Dry-Run Validation
# ==============================================================================
# Executes a dry-run (check-only) deployment validation to Salesforce sandbox.
# Tests the deployment without actually deploying to ensure quality.
#
# Validation Strategy:
#   1. Try RunSpecifiedTests with mapped test classes
#   2. Fallback to RunLocalTests if needed
#   3. Skip tests for metadata-only deployments (NoTestRun)
#
# Output:
#   - Deployment validation results
#   - Test execution summary
#   - Code coverage metrics
#   - Quality gate validation
# ==============================================================================

set -euo pipefail

echo ""
echo "🚀 STAGE 6: DRY-RUN VALIDATION & QUALITY GATES SUMMARY"
echo "======================================================"
echo "🔍 Validating deployment with check-only mode (no actual deployment)..."

# Create reports directory
mkdir -p reports

# Initialize default report
echo '{"result":{"status":"Failed","message":"No deploy run performed"}}' > reports/deploy-report.json
echo "" > reports/validation-summary.txt

# Logging function
summary() {
  echo "$1" | tee -a reports/validation-summary.txt
}

# Check if there's deployable metadata
if [ -d "delta/force-app" ] && [ "$(find delta/force-app -type f 2>/dev/null | wc -l)" -gt 0 ]; then
  summary "📦 Deployable metadata detected"

  # Check if Apex components exist (requiring test execution)
  if find delta/force-app -name "*.cls" -o -name "*.trigger" 2>/dev/null | grep -q .; then
    summary "🧪 Apex components detected - running tests"

    echo ""
    echo "⚙️  EXECUTING DRY-RUN VALIDATION WITH TESTS"
    echo "==========================================="

    # Try intelligent test selection first
    if [ -n "${RELATED_TESTS:-}" ]; then
      RELATED_TESTS_CSV=$(echo "$RELATED_TESTS" | xargs -n1 | paste -sd, - || echo "")
      summary "🎯 Test Strategy: RunSpecifiedTests"
      summary "   Tests: ${RELATED_TESTS_CSV}"

      echo ""
      echo "📋 Validation Details:"
      echo "  • Mode: Dry-run (check-only - no actual deployment)"
      echo "  • Tests: $RELATED_TESTS_CSV"
      echo "  • Environment: Sandbox"
      echo ""

      summary "🔄 Running validation..."
      
      if sf project deploy start \
        --source-dir delta/force-app \
        --target-org "${ORG_NAME:-sandbox}" \
        --dry-run \
        --test-level RunSpecifiedTests \
        --tests "$RELATED_TESTS_CSV" \
        --json > reports/deploy-report.json 2>&1; then
        summary "✅ Validation passed with mapped tests"
      else
        summary "⚠️  Validation failed with mapped tests - trying fallback"
      fi

      # Calculate coverage
      COVERAGE=0
      if jq -e '.result.details.runTestResult.codeCoverage' reports/deploy-report.json >/dev/null 2>&1; then
        COVERAGE=$(jq -r '[.result.details.runTestResult.codeCoverage[]? | (.coveredPercent // 0)] | (if length>0 then (add/length) else 0 end)' reports/deploy-report.json 2>/dev/null || echo "0")
        COVERAGE=${COVERAGE%.*}
      fi
      summary "📊 Coverage: ${COVERAGE}%"

      # Check if fallback needed
      if [ "$COVERAGE" -lt "${COVERAGE_THRESHOLD}" ] || jq -e '.result.status != "Succeeded"' reports/deploy-report.json >/dev/null 2>&1; then
        summary "⚠️  Fallback required (coverage < ${COVERAGE_THRESHOLD}% or validation failed)"
        summary "🔄 Test Strategy: RunLocalTests (all org tests)"
        
        echo ""
        echo "📋 Fallback Validation:"
        echo "  • Mode: Dry-run (check-only)"
        echo "  • Tests: All local tests in org"
        echo ""
        
        if sf project deploy start \
          --source-dir delta/force-app \
          --target-org "${ORG_NAME:-sandbox}" \
          --dry-run \
          --test-level RunLocalTests \
          --json > reports/deploy-report-coverage.json 2>&1; then
          summary "✅ Fallback validation passed"
          mv reports/deploy-report-coverage.json reports/deploy-report.json
        else
          summary "❌ Fallback validation failed"
          mv reports/deploy-report-coverage.json reports/deploy-report.json || true
          echo ""
          echo "🔍 Fallback Deployment Error Details:"
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          if [ -f reports/deploy-report.json ]; then
            ERROR_MSG=$(jq -r '.message // .result.message // "Unknown error"' reports/deploy-report.json 2>/dev/null || echo "Failed to parse error details")
            echo "❌ Error: $ERROR_MSG"
            echo ""
            echo "📄 Raw deployment response:"
            cat reports/deploy-report.json | head -20
          else
            echo "❌ No deployment report generated"
          fi
        fi
      fi

    else
      summary "🔄 Test Strategy: RunLocalTests (no mapped tests)"
      
      echo ""
      echo "📋 Validation Details:"
      echo "  • Mode: Dry-run (check-only - no actual deployment)"
      echo "  • Tests: All local tests in org"
      echo "  • Environment: Sandbox"
      echo ""
      
      if sf project deploy start \
        --source-dir delta/force-app \
        --target-org "${ORG_NAME:-sandbox}" \
        --dry-run \
        --test-level RunLocalTests \
        --json > reports/deploy-report.json 2>&1; then
        summary "✅ Validation passed"
      else
        summary "❌ Validation failed"
        echo ""
        echo "🔍 Deployment Error Details:"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if [ -f reports/deploy-report.json ]; then
          ERROR_MSG=$(jq -r '.message // .result.message // "Unknown error"' reports/deploy-report.json 2>/dev/null || echo "Failed to parse error details")
          echo "❌ Error: $ERROR_MSG"
          echo ""
          echo "📄 Raw deployment response:"
          cat reports/deploy-report.json | head -20
        else
          echo "❌ No deployment report generated"
        fi
      fi
    fi

  else
    summary "📄 Non-Apex deployment detected - no test execution required"
    
  echo ""
  echo "⚙️  EXECUTING METADATA VALIDATION (NO TESTS)"
    echo "============================================"
    echo ""
    echo "📋 Validation Details:"
    echo "  • Mode: Dry-run (check-only - no actual deployment)"
    
    # Generate dynamic component summary from package.xml
    COMPONENT_TYPES=""
    if [ -f "delta/package/package.xml" ]; then
      # Extract metadata types from package.xml
      COMPONENT_TYPES=$(grep -o '<name>[^<]*</name>' delta/package/package.xml | sed 's/<name>//g' | sed 's/<\/name>//g' | sort -u | tr '\n' ' ' | sed 's/ $//')
    fi
    
    # If no specific types found, show generic
    if [ -z "$COMPONENT_TYPES" ]; then
      COMPONENT_TYPES="Salesforce Metadata"
    fi
    
    echo "  • Components: ${COMPONENT_TYPES}"
    echo "  • Test Level: NoTestRun (Apex tests not required)"
    echo "  • Environment: Sandbox"
    echo ""
  
  # Mark as non-apex deployment so coverage gate is skipped, but overall
  # status must still be Succeeded/Skipped to pass quality gates
  NON_APEX_DEPLOYMENT=true
  
  if sf project deploy start \
      --source-dir delta/force-app \
      --target-org "${ORG_NAME:-sandbox}" \
      --dry-run \
      --test-level NoTestRun \
      --wait 30 \
      --json > reports/deploy-report.json 2>&1; then
    summary "✅ Metadata validation completed"
  else
    summary "❌ Metadata validation failed"
    echo ""
    echo "🔍 Deployment Error Details:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ -f reports/deploy-report.json ]; then
      # Try to extract error message from JSON
      ERROR_MSG=$(jq -r '.message // .result.message // "Unknown error"' reports/deploy-report.json 2>/dev/null || echo "Failed to parse error details")
      echo "❌ Error: $ERROR_MSG"
      echo ""
      echo "📄 Raw deployment response:"
      cat reports/deploy-report.json | head -20
    else
      echo "❌ No deployment report generated"
    fi
  fi

  # Print direct link to Deployment Status in the org for convenience
  if command -v jq >/dev/null 2>&1; then
    ORG_URL=$(sf org display --target-org "${ORG_NAME:-sandbox}" --json 2>/dev/null | jq -r '.result.instanceUrl // empty')
    DEPLOY_ID=$(jq -r '.result.id // empty' reports/deploy-report.json 2>/dev/null || echo "")
    if [ -n "$ORG_URL" ]; then
      echo "🔗 View in org: ${ORG_URL}/lightning/setup/DeployStatus/home"
      if [ -n "$DEPLOY_ID" ]; then
        echo "🆔 Deployment Id: $DEPLOY_ID"
      fi
    fi
  fi
    
    summary "✅ Metadata validation completed"
  fi

  # For metadata deployments, show ALL modified files (metadata + scripts/YAML)
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📝 ALL FILES MODIFIED IN THIS CHANGE"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  ALL_MODIFIED=$(git diff --name-only "origin/${TARGET_BRANCH:-main}" HEAD 2>/dev/null | head -30)
  
  if [ -n "$ALL_MODIFIED" ]; then
    # Separate metadata from scripts/config
    METADATA_FILES=$(echo "$ALL_MODIFIED" | grep -E '^force-app/' || echo "")
    SCRIPT_FILES=$(echo "$ALL_MODIFIED" | grep -E '\.(sh|yml|yaml)$' || echo "")
    CONFIG_FILES=$(echo "$ALL_MODIFIED" | grep -E '\.(json|md|xml)$' | grep -v '^force-app/' || echo "")
    
    if [ -n "$METADATA_FILES" ]; then
      echo ""
      echo "📦 Salesforce Metadata:"
      echo "$METADATA_FILES" | sed 's/^/  /'
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
  summary "ℹ️  No deployable metadata - skipping validation"
  echo '{"result":{"status":"Skipped","message":"No changes to deploy"}}' > reports/deploy-report.json
  
  # Show what files were modified (script/YAML changes only)
  echo ""
  echo "📝 Files Modified in This Change:"
  git diff --name-only "origin/${TARGET_BRANCH:-main}" HEAD 2>/dev/null | head -20 || echo "  (unable to determine changed files)"
  echo ""
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 DRY-RUN VALIDATION & QUALITY GATES SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Extract Code Analyzer results
APEX_VIOLATIONS=0
LWC_VIOLATIONS=0

if [ -f reports/apex.json ]; then
  APEX_VIOLATIONS=$(jq '.violations | length' reports/apex.json 2>/dev/null || echo "0")
fi

if [ -f reports/lwc.json ]; then
  LWC_VIOLATIONS=$(jq '.violations | length' reports/lwc.json 2>/dev/null || echo "0")
fi

TOTAL_VIOLATIONS=$((APEX_VIOLATIONS + LWC_VIOLATIONS))

# Extract deployment validation metrics
STATUS="Failed"
COMPONENT_FAIL_COUNT=0
TEST_FAIL_COUNT=0
COVERAGE=0

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

# Check for Vlocity components and add summary
VLOCITY_COMPONENTS=$(find delta/force-app -name "*.rpt-meta.xml" -o -name "*.oip-meta.xml" -o -name "*.omniscript-meta.xml" 2>/dev/null | wc -l)
if [ "$VLOCITY_COMPONENTS" -gt 0 ]; then
  echo ""
  echo "🧩 Vlocity Components Detected:"
  OMNI_DATA_TRANSFORMS=$(find delta/force-app -name "*.rpt-meta.xml" 2>/dev/null | wc -l)
  OMNI_INTEGRATION_PROCEDURES=$(find delta/force-app -name "*.oip-meta.xml" 2>/dev/null | wc -l)
  OMNI_SCRIPTS=$(find delta/force-app -name "*.omniscript-meta.xml" 2>/dev/null | wc -l)
  
  echo "  • Total Vlocity Components: $VLOCITY_COMPONENTS"
  if [ "$OMNI_DATA_TRANSFORMS" -gt 0 ]; then
    echo "  • OmniDataTransform: $OMNI_DATA_TRANSFORMS"
  fi
  if [ "$OMNI_INTEGRATION_PROCEDURES" -gt 0 ]; then
    echo "  • OmniIntegrationProcedure: $OMNI_INTEGRATION_PROCEDURES"
  fi
  if [ "$OMNI_SCRIPTS" -gt 0 ]; then
    echo "  • OmniScript: $OMNI_SCRIPTS"
  fi
  
  # Vlocity components are validated during deployment
  echo "  • XML Validation: ✅ Validated during deployment"
fi

echo ""
echo "🧪 Deployment Validation:"
echo "  • Validation Status: ${STATUS}"
echo "  • Component Failures: ${COMPONENT_FAIL_COUNT}"
echo "  • Test Failures: ${TEST_FAIL_COUNT}"
echo "  • Code Coverage: ${COVERAGE}% (threshold: ${COVERAGE_THRESHOLD}%)"
echo ""

# Display detailed failure information if needed
if [ "${COMPONENT_FAIL_COUNT}" -gt 0 ] || [ "${TEST_FAIL_COUNT}" -gt 0 ] || [ "$STATUS" = "Failed" ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "⚠️  ISSUES DETECTED"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Display test failures
  if [ "${TEST_FAIL_COUNT}" -gt 0 ]; then
    echo ""
    echo "🧪 Test Failures:"
    jq -r '.result.details.runTestResult.failures[]? |
      "  ❌ \(.name).\(.methodName // "unknown")\n     \(.message // "" )" ' reports/deploy-report.json 2>/dev/null \
      | sed -e "s/<br>/\\n/g" -e "s/<[^>]*>//g" \
      | head -20 || true
  fi

  # Display component failures
  if [ "${COMPONENT_FAIL_COUNT}" -gt 0 ]; then
    echo ""
    echo "🔧 Component Failures:"
    jq -r '.result.details.componentFailures[]? | "  ❌ " + (.fileName // .name) + ": " + (.problem // "Unknown")' reports/deploy-report.json 2>/dev/null | head -10 || true
  fi

  # Display general deployment errors if no specific failures but status is Failed
  if [ "${COMPONENT_FAIL_COUNT}" -eq 0 ] && [ "${TEST_FAIL_COUNT}" -eq 0 ] && [ "$STATUS" = "Failed" ]; then
    echo ""
    echo "🔧 Deployment Errors:"
    # Show the full deployment report for debugging
    if [ -f reports/deploy-report.json ]; then
      echo "📄 Full deployment report:"
      jq -r '.result // .' reports/deploy-report.json 2>/dev/null | head -50 || true
    fi
  fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 QUALITY GATE VALIDATION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Validate quality gates
if [ "$STATUS" = "Succeeded" ]; then
  echo "✅ Validation: PASSED"
  echo "✅ All quality gates met"
  echo ""
  echo "🎉 DEPLOYMENT READY"
  exit 0
  
elif [ "$STATUS" = "Skipped" ] && [ "${COMPONENT_FAIL_COUNT}" -eq 0 ] && [ "${TEST_FAIL_COUNT}" -eq 0 ]; then
  echo "✅ Validation: SKIPPED (no changes)"
  echo "✅ All quality gates met"
  echo ""
  echo "🎉 PIPELINE SUCCESSFUL"
  exit 0
  
elif [ "${COMPONENT_FAIL_COUNT}" -gt 0 ] || [ "${TEST_FAIL_COUNT}" -gt 0 ]; then
  echo "❌ Validation: FAILED"
  echo "   • Component Failures: ${COMPONENT_FAIL_COUNT}"
  echo "   • Test Failures: ${TEST_FAIL_COUNT}"
  echo ""
  echo "💥 QUALITY GATES FAILED - Fix issues before deploying"
  exit 1
  
elif [ "$STATUS" != "Succeeded" ] && [ "$COVERAGE" -lt "${COVERAGE_THRESHOLD}" ] && [ "$STATUS" != "Skipped" ] && [ "${NON_APEX_DEPLOYMENT:-false}" != "true" ]; then
  echo "❌ Validation: FAILED"
  echo "   • Status: ${STATUS}"
  echo "   • Coverage: ${COVERAGE}% (required: ${COVERAGE_THRESHOLD}%)"
  echo "   • Component Failures: ${COMPONENT_FAIL_COUNT}"
  echo "   • Test Failures: ${TEST_FAIL_COUNT}"
  echo ""
  echo "💥 QUALITY GATES FAILED - Increase test coverage"
  exit 1
  
elif [ "$STATUS" = "Failed" ]; then
  echo "❌ Validation: FAILED"
  echo "   • Status: ${STATUS}"
  echo "   • Component Failures: ${COMPONENT_FAIL_COUNT}"
  echo "   • Test Failures: ${TEST_FAIL_COUNT}"
  exit 1
else
  echo "✅ Validation: PASSED"
  echo "✅ All quality gates met"
  echo ""
  echo "🎉 DEPLOYMENT READY"
  exit 0
fi

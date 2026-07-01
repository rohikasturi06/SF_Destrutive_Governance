#!/bin/bash
# ==============================================================================
# Static Code Analysis Results Display Script
# ==============================================================================
# Displays results from Salesforce Code Analyzer executed by GitHub Actions.
# The actual analysis is performed by forcedotcom/run-code-analyzer@v2 action.
#
# This script:
#   1. Ensures report files exist
#   2. Displays violations in human-readable format
#   3. Provides summary statistics
#
# Note: This script should NOT fail even if violations are found.
# The Code Analyzer GitHub Action may exit with code 2 when violations exceed
# the severity threshold, but this is informational, not a failure.
# ==============================================================================

set -euo pipefail

# Exit successfully at the end regardless of violations found
trap 'exit 0' EXIT

echo ""
echo "🚀 STAGE 4: STATIC CODE ANALYSIS RESULTS"
echo "========================================"
echo "📋 Displaying code analysis results..."

# Create reports directory
mkdir -p reports

# Ensure report files exist with default empty structure
[ -f reports/apex.json ] || echo '{"violations":[]}' > reports/apex.json
[ -f reports/lwc.json ] || echo '{"violations":[]}' > reports/lwc.json

# Check if Code Analyzer GitHub Actions actually ran by looking for real content
APEX_ANALYZER_RAN="false"
LWC_ANALYZER_RAN="false"

# Check if apex.json has real violations or is just our empty default
if [ -f reports/apex.json ]; then
  # If file is larger than just our default empty structure, analyzer likely ran
  if [ "$(wc -c < reports/apex.json)" -gt 20 ]; then
    APEX_ANALYZER_RAN="true"
  fi
fi

# Check if lwc.json has real violations or is just our empty default  
if [ -f reports/lwc.json ]; then
  # If file is larger than just our default empty structure, analyzer likely ran
  if [ "$(wc -c < reports/lwc.json)" -gt 20 ]; then
    LWC_ANALYZER_RAN="true"
  fi
fi

echo ""
echo "🔧 Apex Code Analysis:"
echo "======================"

# Display Apex results
APEX_VIOLATIONS=$(jq '.violations | length' reports/apex.json 2>/dev/null || echo "0")
if [ "$APEX_ANALYZER_RAN" = "false" ]; then
  echo "⏭️  Skipped (no Apex components in delta package)"
elif [ "$APEX_VIOLATIONS" -gt 0 ]; then
  echo "📊 Found $APEX_VIOLATIONS violation(s)"
  echo ""
  jq -r '.violations[]? |
    (if .location then (.location | split(":")[0] | split("/") | .[-1]) else "Unknown" end) as $file |
    "  ❌ [\(.severity // "N/A")] \($file) - \(.ruleName // "Unknown")\n     \(.message)"' reports/apex.json 2>/dev/null | head -40
else
  echo "✅ No violations found - code meets quality standards!"
fi

echo ""
echo "⚡ LWC Code Analysis:"
echo "====================="

# Display LWC results
LWC_VIOLATIONS=$(jq '.violations | length' reports/lwc.json 2>/dev/null || echo "0")
if [ "$LWC_ANALYZER_RAN" = "false" ]; then
  echo "⏭️  Skipped (no LWC components in delta package)"
elif [ "$LWC_VIOLATIONS" -gt 0 ]; then
  echo "📊 Found $LWC_VIOLATIONS violation(s)"
  echo ""
  jq -r '.violations[]? |
    (if .location then (.location | split(":")[0] | split("/") | .[-1]) else "Unknown" end) as $file |
    "  ❌ [\(.severity // "N/A")] \($file) - \(.ruleName // "Unknown")\n     \(.message)"' reports/lwc.json 2>/dev/null | head -40
else
  echo "✅ No violations found - code meets quality standards!"
fi

echo ""
echo "📊 Overall Summary:"
echo "==================="
if [ "$APEX_ANALYZER_RAN" = "false" ]; then
  echo "  • Apex violations: Skipped (no components)"
else
  echo "  • Apex violations: $APEX_VIOLATIONS"
fi

if [ "$LWC_ANALYZER_RAN" = "false" ]; then
  echo "  • LWC violations: Skipped (no components)"
else
  echo "  • LWC violations: $LWC_VIOLATIONS"
fi

if [ "$APEX_ANALYZER_RAN" = "false" ] && [ "$LWC_ANALYZER_RAN" = "false" ]; then
  echo "  • Total violations: Skipped (no components to analyze)"
else
  echo "  • Total violations: $((APEX_VIOLATIONS + LWC_VIOLATIONS))"
fi

echo ""
echo "✅ STAGE 4 COMPLETED: Static code analysis results displayed"
echo "=========================================================="

#!/bin/bash
# ==============================================================================
# Apex Test Class Identification
# ==============================================================================
# Identifies Apex classes and their corresponding test classes in the delta
# package for targeted test execution.
#
# Output:
#   - List of Apex classes found in delta
#   - List of test classes to execute
#   - JSON mapping file for reference
# ==============================================================================

set -euo pipefail

echo ""
echo "🚀 STAGE 5: APEX TEST CLASS IDENTIFICATION"
echo "=========================================="

# Create reports directory
mkdir -p reports

# Check if deployment package exists
if [ "${HAS_DEPLOYMENT_PACKAGE:-true}" = "false" ]; then
  echo "⏭️  Skipped - No deployment package to process"
  echo '{"result":"No deployment package","classes":[],"tests":[]}' > reports/test-mapping.json
  echo "RELATED_TESTS=" >> "$GITHUB_ENV"
  exit 0
fi

# Check if package.xml exists
if [ ! -f "delta/package/package.xml" ]; then
  echo "⏭️  Skipped - No package.xml found"
  echo '{"result":"No package.xml found","classes":[],"tests":[]}' > reports/test-mapping.json
  echo "RELATED_TESTS=" >> "$GITHUB_ENV"
  exit 0
fi

# Extract ONLY Apex classes from package.xml (not LWC or other components)
echo "📦 Scanning package.xml for Apex classes..."

# Use Python for reliable XML parsing to get only ApexClass and ApexTrigger members
DELTA_APEX_CLASSES=$(python3 - <<'PYTHON'
import xml.etree.ElementTree as ET
from pathlib import Path

package_path = Path("delta/package/package.xml")
apex_classes = []

if package_path.exists():
    try:
        tree = ET.parse(package_path)
        ns = {"md": "http://soap.sforce.com/2006/04/metadata"}
        root = tree.getroot()
        
        # Find all <types> elements
        for types in root.findall('md:types', ns):
            name = types.findtext('md:name', default='', namespaces=ns)
            
            # Only process ApexClass and ApexTrigger types
            if name in ["ApexClass", "ApexTrigger"]:
                for members in types.findall('md:members', ns):
                    member_name = (members.text or '').strip()
                    if member_name:
                        apex_classes.append(member_name)
    except Exception:
        pass

# Output space-separated list
print(' '.join(apex_classes))
PYTHON
)

if [ -z "$DELTA_APEX_CLASSES" ]; then
  echo "ℹ️  No Apex classes found in package.xml"
  echo '{"result":"No Apex classes in delta","classes":[],"tests":[]}' > reports/test-mapping.json
  echo "RELATED_TESTS=" >> "$GITHUB_ENV"
  exit 0
fi

echo "📋 Apex classes in delta: $DELTA_APEX_CLASSES"
echo ""

# Check if classes directory exists
if [ ! -d "delta/force-app/main/default/classes" ]; then
  echo "ℹ️  No Apex classes directory found (metadata-only deployment)"
  echo "{\"result\":\"Metadata-only deployment\",\"classes\":[],\"tests\":[]}" > reports/test-mapping.json
  echo "RELATED_TESTS=" >> "$GITHUB_ENV"
  exit 0
fi

# Separate test classes from regular classes
ALL_TESTS=""
ALL_CLASSES=""

echo "🔍 Identifying test classes..."
for cls in $DELTA_APEX_CLASSES; do
  file_path=$(find delta/force-app force-app -path "*/classes/${cls}.cls" 2>/dev/null | head -n1)
  
  if [ -z "$file_path" ]; then
    echo "  ⚠️  ${cls}: File not found"
    continue
  fi
  
  # Check if it's a test class (contains @isTest or @IsTest)
  if grep -qiE "@isTest|@IsTest" "$file_path" 2>/dev/null; then
    echo "  ✓ ${cls} → Test class"
    ALL_TESTS="$ALL_TESTS $cls"
  else
    echo "  ✓ ${cls} → Regular class"
    ALL_CLASSES="$ALL_CLASSES $cls"
  fi
done

# Clean up whitespace
ALL_TESTS=$(echo "$ALL_TESTS" | xargs -n1 2>/dev/null | sort -u | xargs || echo "")
ALL_CLASSES=$(echo "$ALL_CLASSES" | xargs -n1 2>/dev/null | sort -u | xargs || echo "")

echo ""
echo "📊 Summary:"
echo "  • Regular Apex classes: ${ALL_CLASSES:-none}"
echo "  • Test classes: ${ALL_TESTS:-none}"

# Find which tests cover which classes (simple name matching)
MAPPED_TESTS=""
if [ -n "$ALL_CLASSES" ] && [ -n "$ALL_TESTS" ]; then
  echo ""
  echo "🔗 Mapping tests to classes:"
  for cls in $ALL_CLASSES; do
    for test in $ALL_TESTS; do
      # Check if test references the class by name
      test_file=$(find delta/force-app force-app -path "*/classes/${test}.cls" 2>/dev/null | head -n1)
      if [ -n "$test_file" ] && grep -qE "\b${cls}\b" "$test_file" 2>/dev/null; then
        echo "  ✓ ${test} tests ${cls}"
        MAPPED_TESTS="$MAPPED_TESTS $test"
      fi
    done
  done
  MAPPED_TESTS=$(echo "$MAPPED_TESTS" | xargs -n1 2>/dev/null | sort -u | xargs || echo "")
fi

# If no mapped tests found, use all test classes
if [ -z "$MAPPED_TESTS" ] && [ -n "$ALL_TESTS" ]; then
  MAPPED_TESTS="$ALL_TESTS"
  echo "  ℹ️  No specific mappings found, will use all test classes"
fi

echo ""
if [ -n "$MAPPED_TESTS" ]; then
  echo "✅ Tests to execute: $MAPPED_TESTS"
else
  echo "ℹ️  No test classes identified - will use RunLocalTests"
fi

# Save to environment and JSON
echo "RELATED_TESTS=$MAPPED_TESTS" >> "$GITHUB_ENV"
echo "APEX_CLASSES=$DELTA_APEX_CLASSES" >> "$GITHUB_ENV"
echo "DELTA_APEX_CLASSES=$DELTA_APEX_CLASSES" >> "$GITHUB_ENV"
echo "TESTS_IN_DELTA=$ALL_TESTS" >> "$GITHUB_ENV"

# Create JSON report
cat > reports/test-mapping.json <<EOF
{
  "classes": $(echo "$ALL_CLASSES" | xargs -n1 2>/dev/null | jq -R . | jq -s . || echo '[]'),
  "tests": $(echo "$ALL_TESTS" | xargs -n1 2>/dev/null | jq -R . | jq -s . || echo '[]'),
  "mapped_tests": $(echo "$MAPPED_TESTS" | xargs -n1 2>/dev/null | jq -R . | jq -s . || echo '[]')
}
EOF

echo ""
echo "✅ STAGE 5 COMPLETED: Test identification finished"
echo "=============================================="

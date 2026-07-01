#!/bin/bash
# ==============================================================================
# Apex Test Resolution (developer-maintained test map)
# ==============================================================================
# Resolves which Apex tests to run for the changed classes by reading an
# explicit, reviewable mapping file: config/test-map.yaml.
#
#   <RegularClassOrTrigger>:
#     - <TestClass1>
#     - <TestClass2>
#
# Rules:
#   - Every regular Apex class/trigger that can change MUST have an entry.
#   - A changed class that is NOT in the map (and is not itself a mapped test
#     class) is reported in UNMAPPED_CLASSES so the validation step can block the
#     PR — the developer must commit the test class and register it in the map.
#
# NOTE: automatic test-class recognition (repo-wide @isTest grep) was removed on
# purpose; this explicit map is the single source of truth.
#
# Outputs (GITHUB_ENV): RELATED_TESTS, UNMAPPED_CLASSES, DELTA_APEX_CLASSES,
#                       APEX_CLASSES, TESTS_IN_DELTA
# ==============================================================================

set -euo pipefail

echo ""
echo "🚀 STAGE 5: APEX TEST RESOLUTION (test-map)"
echo "=========================================="

mkdir -p reports

if [ "${HAS_DEPLOYMENT_PACKAGE:-true}" = "false" ]; then
  echo "⏭️  Skipped - No deployment package to process"
  echo '{"result":"No deployment package","related_tests":[],"unmapped_classes":[]}' > reports/test-mapping.json
  echo "RELATED_TESTS=" >> "$GITHUB_ENV"
  echo "UNMAPPED_CLASSES=" >> "$GITHUB_ENV"
  exit 0
fi

if [ ! -f "delta/package/package.xml" ]; then
  echo "⏭️  Skipped - No package.xml found"
  echo '{"result":"No package.xml found","related_tests":[],"unmapped_classes":[]}' > reports/test-mapping.json
  echo "RELATED_TESTS=" >> "$GITHUB_ENV"
  echo "UNMAPPED_CLASSES=" >> "$GITHUB_ENV"
  exit 0
fi

echo "📦 Scanning package.xml for Apex classes/triggers..."
DELTA_APEX_CLASSES=$(python3 - <<'PYTHON'
import xml.etree.ElementTree as ET
from pathlib import Path

package_path = Path("delta/package/package.xml")
apex = []
if package_path.exists():
    try:
        root = ET.parse(package_path).getroot()
        ns = {"md": "http://soap.sforce.com/2006/04/metadata"}
        for types in root.findall('md:types', ns):
            name = types.findtext('md:name', default='', namespaces=ns)
            if name in ["ApexClass", "ApexTrigger"]:
                for m in types.findall('md:members', ns):
                    v = (m.text or '').strip()
                    if v:
                        apex.append(v)
    except Exception:
        pass
print(' '.join(apex))
PYTHON
)

if [ -z "$DELTA_APEX_CLASSES" ]; then
  echo "ℹ️  No Apex classes/triggers in delta"
  echo '{"result":"No Apex in delta","related_tests":[],"unmapped_classes":[]}' > reports/test-mapping.json
  echo "RELATED_TESTS=" >> "$GITHUB_ENV"
  echo "UNMAPPED_CLASSES=" >> "$GITHUB_ENV"
  exit 0
fi

echo "📋 Apex in delta: $DELTA_APEX_CLASSES"
echo ""

# ------------------------------------------------------------------------------
# Read the developer-maintained test map.
# ------------------------------------------------------------------------------
TEST_MAP_FILE="${TEST_MAP_FILE:-config/test-map.yaml}"

if [ ! -f "$TEST_MAP_FILE" ]; then
  echo "::error::Test map '$TEST_MAP_FILE' is missing. Create it and map each Apex class to its test class(es)."
  echo "RELATED_TESTS=" >> "$GITHUB_ENV"
  echo "UNMAPPED_CLASSES=$DELTA_APEX_CLASSES" >> "$GITHUB_ENV"
  echo "DELTA_APEX_CLASSES=$DELTA_APEX_CLASSES" >> "$GITHUB_ENV"
  exit 0
fi

# Test class(es) mapped to a given key (class/trigger), one per line.
tests_for_class() {
  awk -v key="$1" '
    /^[[:space:]]*#/ { next }
    /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:/ {
      k=$0; sub(/[[:space:]]*:.*/,"",k); gsub(/[[:space:]]/,"",k); incls=(k==key); next
    }
    incls && /^[[:space:]]*-[[:space:]]*/ {
      v=$0; sub(/^[[:space:]]*-[[:space:]]*/,"",v); sub(/#.*/,"",v); gsub(/[[:space:]]/,"",v)
      if (v != "") print v
    }
  ' "$TEST_MAP_FILE"
}

# Every test class referenced anywhere in the map (its values).
KNOWN_TEST_CLASSES=$(awk '
  /^[[:space:]]*#/ { next }
  /^[[:space:]]*-[[:space:]]*/ {
    v=$0; sub(/^[[:space:]]*-[[:space:]]*/,"",v); sub(/#.*/,"",v); gsub(/[[:space:]]/,"",v)
    if (v != "") print v
  }
' "$TEST_MAP_FILE" | sort -u)

RELATED_TESTS=""
UNMAPPED_CLASSES=""
TESTS_IN_DELTA=""

echo "🔗 Resolving changed Apex via $TEST_MAP_FILE:"
for cls in $DELTA_APEX_CLASSES; do
  mapped=$(tests_for_class "$cls" | tr '\n' ' ')
  if [ -n "$(printf '%s' "$mapped" | tr -d '[:space:]')" ]; then
    echo "  ✓ ${cls} → ${mapped}"
    RELATED_TESTS="$RELATED_TESTS $mapped"
  elif printf '%s\n' "$KNOWN_TEST_CLASSES" | grep -qx "$cls"; then
    echo "  ✓ ${cls} → is a mapped test class (will run)"
    RELATED_TESTS="$RELATED_TESTS $cls"
    TESTS_IN_DELTA="$TESTS_IN_DELTA $cls"
  else
    echo "  ✗ ${cls} → NOT in test map"
    UNMAPPED_CLASSES="$UNMAPPED_CLASSES $cls"
  fi
done

# Normalize (space-separated, unique) without relying on xargs.
norm() { printf '%s' "$1" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ *$//'; }
RELATED_TESTS=$(norm "$RELATED_TESTS")
UNMAPPED_CLASSES=$(norm "$UNMAPPED_CLASSES")
TESTS_IN_DELTA=$(norm "$TESTS_IN_DELTA")

echo ""
echo "📊 Summary:"
echo "  • Mapped tests to run : ${RELATED_TESTS:-none}"
echo "  • Unmapped classes    : ${UNMAPPED_CLASSES:-none}"

{
  echo "RELATED_TESTS=$RELATED_TESTS"
  echo "UNMAPPED_CLASSES=$UNMAPPED_CLASSES"
  echo "DELTA_APEX_CLASSES=$DELTA_APEX_CLASSES"
  echo "APEX_CLASSES=$DELTA_APEX_CLASSES"
  echo "TESTS_IN_DELTA=$TESTS_IN_DELTA"
} >> "$GITHUB_ENV"

cat > reports/test-mapping.json <<JSON
{
  "delta_classes": $(printf '%s' "$DELTA_APEX_CLASSES" | tr ' ' '\n' | sed '/^$/d' | jq -R . | jq -s . 2>/dev/null || echo '[]'),
  "related_tests": $(printf '%s' "$RELATED_TESTS" | tr ' ' '\n' | sed '/^$/d' | jq -R . | jq -s . 2>/dev/null || echo '[]'),
  "unmapped_classes": $(printf '%s' "$UNMAPPED_CLASSES" | tr ' ' '\n' | sed '/^$/d' | jq -R . | jq -s . 2>/dev/null || echo '[]')
}
JSON

echo ""
echo "✅ STAGE 5 COMPLETED: Test map resolution finished"
echo "=============================================="

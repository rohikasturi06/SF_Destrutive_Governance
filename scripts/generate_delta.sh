#!/bin/bash
# ==============================================================================
# Delta Package Generation Script
# ==============================================================================
# Generates deployment delta package using sfdx-git-delta plugin to identify
# changes between source and target branches for incremental deployments.
#
# Process Flow:
#   1. Configure git workspace safety settings
#   2. Fetch target branch for comparison baseline
#   3. Generate delta package with changed metadata
#   4. Validate delta package structure and contents
#
# Output Artifacts:
#   - delta/package.xml: Primary deployment manifest
#   - delta/force-app/: Source metadata for deployment
#   - Destructive changes manifest (if applicable)
# ==============================================================================

set -euo pipefail

# Load shared deployment helpers (destructive detection, deploy args, summary).
# shellcheck source=./_deployment_lib.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_deployment_lib.sh"

echo ""
echo "🚀 STAGE 3: DELTA PACKAGE GENERATION"
echo "======================================"
echo "🔄 Generating deployment delta package..."

# Ensure output directories exist
echo "📁 Creating output directories..."
mkdir -p delta reports

# Configure git safety for workspace operations
echo "🔧 Configuring git workspace safety..."
git config --global --add safe.directory "$GITHUB_WORKSPACE"

# Resolve comparison range for delta generation
# Prefer explicit FROM_REF/TO_REF (e.g., push: before/after),
# otherwise fall back to branch-based comparison
RAW_FROM_REF="${FROM_REF:-}"
RAW_TO_REF="${TO_REF:-}"

# Resolve target branch for branch-based fallback
RAW_TARGET_BRANCH="${TARGET_BRANCH:-}"

# Normalize empty or explicit "null" values coming from GitHub context
if [ -z "$RAW_TARGET_BRANCH" ] || [ "$RAW_TARGET_BRANCH" = "null" ]; then
  if [ -n "${GITHUB_BASE_REF:-}" ] && [ "${GITHUB_BASE_REF}" != "null" ]; then
    RAW_TARGET_BRANCH="$GITHUB_BASE_REF"
  elif [ -n "${GITHUB_REF_NAME:-}" ] && [ "${GITHUB_REF_NAME}" != "null" ]; then
    RAW_TARGET_BRANCH="$GITHUB_REF_NAME"
  else
    RAW_TARGET_BRANCH="main"
  fi
fi

TARGET_BRANCH="$RAW_TARGET_BRANCH"
echo "🧭 Current org alias for this run: ${ORG_NAME:-sandbox}"

# Determine comparison endpoints
if [ -n "$RAW_FROM_REF" ] && [ -n "$RAW_TO_REF" ] && [ "$RAW_FROM_REF" != "null" ] && [ "$RAW_TO_REF" != "null" ]; then
  FROM_REF="$RAW_FROM_REF"
  TO_REF="$RAW_TO_REF"
  echo "📊 Generating delta from $FROM_REF to $TO_REF"
else
  echo "📥 Fetching target branch: $TARGET_BRANCH"
  if ! git fetch origin "$TARGET_BRANCH" --quiet; then
    echo "⚠️  Unable to fetch origin/$TARGET_BRANCH - falling back to origin/main"
    TARGET_BRANCH_FALLBACK="main"
    git fetch origin "$TARGET_BRANCH_FALLBACK" --quiet
    TARGET_BRANCH="$TARGET_BRANCH_FALLBACK"
  fi
  FROM_REF="origin/$TARGET_BRANCH"
  TO_REF="HEAD"
  echo "📊 Generating delta from $FROM_REF to $TO_REF"
fi

# Generate delta package using sfdx-git-delta plugin
echo "⚙️  Executing sfdx-git-delta plugin..."
DELTA_EXIT_CODE=0
if ! sf sgd source delta \
  --to "$TO_REF" \
  --from "$FROM_REF" \
  --output delta \
  --generate-delta >/dev/null 2>&1; then

  echo "⚠️  Delta generation completed with warnings (no changes detected)"
  echo "  • This is normal for script-only changes or when no differences exist"
  DELTA_EXIT_CODE=1
else
  echo "✅ Delta generation completed successfully"
fi

# Validate and display delta package analysis
echo ""
echo "📋 Delta Package Analysis:"
echo "=========================="

# Check for delta files and deployment package
DELTA_COUNT=$(find delta -type f | wc -l)
echo "📁 Total files in delta: $DELTA_COUNT"

if [ -f delta/package/package.xml ]; then
  # Check if package.xml has actual content (not just the basic structure)
  PACKAGE_MEMBERS=$(python3 - <<'PY'
from pathlib import Path
import xml.etree.ElementTree as ET

package_path = Path("delta/package/package.xml")
count = 0
if package_path.exists():
    try:
        tree = ET.parse(package_path)
        ns = {"md": "http://soap.sforce.com/2006/04/metadata"}
        root = tree.getroot()
        # Count all non-empty <members> entries within <types>
        for types in root.findall('md:types', ns):
            name = types.findtext('md:name', default='', namespaces=ns)
            if name in {"ApexClass", "ApexTrigger", "LightningComponentBundle",
                        "ApexPage", "ApexComponent", "StaticResource",
                        "AuraDefinitionBundle", "CustomObject", "CustomField"}:
                for members in types.findall('md:members', ns):
                    if (members.text or '').strip():
                        count += 1
            else:
                for members in types.findall('md:members', ns):
                    if (members.text or '').strip():
                        count += 1
    except ET.ParseError:
        # Fallback: treat as empty package if parsing fails
        count = 0
print(count)
PY
)

  # ----------------------------------------------------------------------------
  # Destructive change detection (single source of truth: _deployment_lib.sh)
  # ----------------------------------------------------------------------------
  detect_destructive_changes
  print_destructive_preview

  if [ "${PACKAGE_MEMBERS:-0}" -gt 0 ] || [ "${HAS_DESTRUCTIVE_CHANGES:-false}" = "true" ]; then
    echo ""
    echo "📦 Package.xml Preview (first 20 lines):"
    sed -n '1,20p' delta/package/package.xml || true

    # Component-type detection feeds downstream gates (Code Analyzer, etc.)
    HAS_APEX="false"
    HAS_LWC="false"
    HAS_VLOCITY="false"

    if grep -q "<name>ApexClass</name>" delta/package/package.xml 2>/dev/null || \
       grep -q "<name>ApexTrigger</name>" delta/package/package.xml 2>/dev/null; then
      HAS_APEX="true"
    fi

    if grep -q "<name>LightningComponentBundle</name>" delta/package/package.xml 2>/dev/null; then
      HAS_LWC="true"
    fi

    if find delta/force-app -name "*.rpt-meta.xml" -o -name "*.oip-meta.xml" -o -name "*.omniscript-meta.xml" 2>/dev/null | grep -q .; then
      HAS_VLOCITY="true"
    fi

    # Reasoning for HAS_DEPLOYMENT_PACKAGE:
    #   Either source metadata is present OR destructive changes have members.
    #   This ensures pure-deletion PRs (no force-app changes) still trigger
    #   downstream validate/deploy stages.
    {
      echo "HAS_DEPLOYMENT_PACKAGE=true"
    } >> "$GITHUB_ENV"

    {
      echo "has-deployment-package=true"
      echo "has-apex=$HAS_APEX"
      echo "has-lwc=$HAS_LWC"
      echo "has-vlocity=$HAS_VLOCITY"
    } >> "$GITHUB_OUTPUT"

    # Persist destructive-change state for downstream steps.
    emit_github_env_outputs

    if [ "${PACKAGE_MEMBERS:-0}" -eq 0 ] && [ "${HAS_DESTRUCTIVE_CHANGES:-false}" = "true" ]; then
      echo ""
      echo "ℹ️  Destructive-only delta detected — pipeline will run as a"
      echo "   deletion-focused deployment (no source-dir, manifest-driven)."
    fi
  else
    echo ""
    echo "📋 Empty Package.xml Found:"
    echo "  • Package.xml exists but contains no metadata components"
    echo "  • No destructive changes detected"
    echo "  • This indicates only script/YAML changes (no deployment needed)"
    echo ""
    echo "📄 Package.xml Contents:"
    cat delta/package/package.xml
    echo ""

    echo "📝 Files Modified in This Change:"
    git diff --name-only "origin/$TARGET_BRANCH" HEAD | head -20 || echo "  (unable to determine changed files)"

    {
      echo "HAS_DEPLOYMENT_PACKAGE=false"
    } >> "$GITHUB_ENV"

    {
      echo "has-deployment-package=false"
      echo "has-apex=false"
      echo "has-lwc=false"
      echo "has-vlocity=false"
    } >> "$GITHUB_OUTPUT"

    emit_github_env_outputs
  fi

else
  # No package.xml at all — still check for destructive changes (sgd quirk).
  detect_destructive_changes
  print_destructive_preview

  if [ "${HAS_DESTRUCTIVE_CHANGES:-false}" = "true" ]; then
    echo ""
    echo "ℹ️  No package.xml but destructive changes present — destructive-only run."
    {
      echo "HAS_DEPLOYMENT_PACKAGE=true"
    } >> "$GITHUB_ENV"
    {
      echo "has-deployment-package=true"
      echo "has-apex=false"
      echo "has-lwc=false"
      echo "has-vlocity=false"
    } >> "$GITHUB_OUTPUT"
  else
    echo ""
    echo "📋 No Package.xml Found:"
    echo "  • No deployment package generated"
    echo "  • No destructive changes detected"
    echo "  • This indicates only script/YAML changes or no changes to deploy"
    echo ""

    echo "📝 Files Modified in This Change:"
    git diff --name-only "origin/$TARGET_BRANCH" HEAD | head -20 || echo "  (unable to determine changed files)"

    {
      echo "HAS_DEPLOYMENT_PACKAGE=false"
    } >> "$GITHUB_ENV"
    {
      echo "has-deployment-package=false"
      echo "has-apex=false"
      echo "has-lwc=false"
      echo "has-vlocity=false"
    } >> "$GITHUB_OUTPUT"
  fi

  emit_github_env_outputs
fi

echo ""
echo "📊 Delta generation summary:"
ls -la delta || echo "No delta directory found"

# Exit with appropriate code based on delta generation result
if [ "$DELTA_EXIT_CODE" -eq 0 ]; then
  echo ""
  echo "✅ STAGE 3 COMPLETED: Delta package generated successfully"
  echo "=================================================="
  exit 0
else
  echo ""
  echo "✅ STAGE 3 COMPLETED: Delta analysis completed (no deployment changes)"
  echo "=================================================================="
  # Don't exit with error code for normal "no changes" scenario
  exit 0
fi

# Ensure script always exits successfully
exit 0

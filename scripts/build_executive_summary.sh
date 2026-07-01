#!/bin/bash
# ==============================================================================
# Executive Deployment Summary (Markdown)
# ==============================================================================
# Builds a business-readable Markdown summary intended for:
#   - GITHUB_STEP_SUMMARY (renders on the Actions run page)
#   - A sticky PR comment via marocchino/sticky-pull-request-comment
#   - Optionally, an HTML/text email body
#
# Inputs (env):
#   PR_NUMBER, PR_TITLE, PR_AUTHOR, PR_URL  - PR metadata
#   TARGET_ENV                              - dev | qa | intuat | prod
#   TARGET_BRANCH                           - PR base branch (e.g. dev)
#   WORKFLOW_RUN_URL                        - link to the workflow run
#   COVERAGE_THRESHOLD                      - default 75
#
# Reads:
#   delta/package/package.xml
#   delta/destructiveChanges/destructiveChanges.xml
#   reports/deploy-report.json
#   reports/apex.json, reports/lwc.json
#
# Writes:
#   $1 (default reports/executive-summary.md)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_deployment_lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_deployment_lib.sh"

OUTPUT_FILE="${1:-reports/executive-summary.md}"
mkdir -p "$(dirname "$OUTPUT_FILE")"
: > "$OUTPUT_FILE"

# ------------------------------------------------------------------------------
# Inputs
# ------------------------------------------------------------------------------
PR_NUMBER="${PR_NUMBER:-}"
PR_TITLE="${PR_TITLE:-}"
PR_AUTHOR="${PR_AUTHOR:-}"
PR_URL="${PR_URL:-}"
TARGET_ENV="${TARGET_ENV:-dev}"
TARGET_BRANCH="${TARGET_BRANCH:-${TARGET_ENV}}"
WORKFLOW_RUN_URL="${WORKFLOW_RUN_URL:-}"
COVERAGE_THRESHOLD="${COVERAGE_THRESHOLD:-75}"

TARGET_ENV_UPPER=$(echo "$TARGET_ENV" | tr '[:lower:]' '[:upper:]')

# Detect Vlocity changes for header context.
#
# IMPORTANT baseline choice: use the merge-base (three-dot) diff
# "origin/<base>...HEAD" so we report only the changes THIS PR introduced, not
# every file that happens to differ between the branch tips. We also report the
# count of changed *datapacks* (unique vlocity/<Type>/<Name> folders) — the same
# unit the post-merge deploy uses ("N changed datapack(s)") — so the summary and
# the deploy preview speak the same language instead of disagreeing (a raw file
# count balloons to thousands whenever the whole folder is regenerated/moved).
VLOCITY_CHANGED_LIST=""
VLOCITY_CHANGED_FILE_COUNT=0
VLOCITY_CHANGED_COUNT=0
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # Prefer merge-base diff; fall back to tip diff if the merge base is unavailable.
  VLOCITY_CHANGED_LIST=$(git diff --name-only "origin/${TARGET_BRANCH}...HEAD" 2>/dev/null | grep -E '^vlocity/' || true)
  if [ -z "$VLOCITY_CHANGED_LIST" ]; then
    VLOCITY_CHANGED_LIST=$(git diff --name-only "origin/${TARGET_BRANCH}" HEAD 2>/dev/null | grep -E '^vlocity/' || true)
  fi
  if [ -n "$VLOCITY_CHANGED_LIST" ]; then
    VLOCITY_CHANGED_FILE_COUNT=$(printf '%s\n' "$VLOCITY_CHANGED_LIST" | grep -c . || true)
    # Collapse to unique datapack folders: vlocity/<Type>/<Name>.
    VLOCITY_CHANGED_COUNT=$(printf '%s\n' "$VLOCITY_CHANGED_LIST" \
      | awk -F/ 'NF>=3 && $1=="vlocity" {print $1"/"$2"/"$3}' \
      | sort -u | grep -c . || true)
  fi
fi

# ------------------------------------------------------------------------------
# Extract Jira/ticket id from PR title (e.g. "[PROJ-123] Clean up...").
# ------------------------------------------------------------------------------
TICKET_ID=""
TICKET_TITLE=""
if [ -n "$PR_TITLE" ]; then
  if [[ "$PR_TITLE" =~ \[([A-Z][A-Z0-9]+-[0-9]+)\] ]]; then
    TICKET_ID="${BASH_REMATCH[1]}"
    TICKET_TITLE="${PR_TITLE#*]}"
    TICKET_TITLE="${TICKET_TITLE# }"
  fi
fi

# ------------------------------------------------------------------------------
# Detect destructive changes (sets HAS_DESTRUCTIVE_CHANGES, etc.).
# ------------------------------------------------------------------------------
detect_destructive_changes

# ------------------------------------------------------------------------------
# Pre-flight orphaned-dependency report.
#
# scripts/scan_dependencies.sh writes reports/dependency-errors.md when it
# finds blocking references. If that file exists and is non-empty, we promote
# it to the very top of the executive summary so the PO sees the cleanup
# checklist before anything else.
# ------------------------------------------------------------------------------
DEPENDENCY_ERRORS_PRESENT="false"
DEPENDENCY_ERRORS_FILE="reports/dependency-errors.md"
if [ -s "$DEPENDENCY_ERRORS_FILE" ]; then
  DEPENDENCY_ERRORS_PRESENT="true"
fi

# ------------------------------------------------------------------------------
# Pull metrics from reports/
# ------------------------------------------------------------------------------
DEPLOY_STATUS="Unknown"
COMPONENT_FAILURES=0
TEST_FAILURES=0
COVERAGE=0
# Distinguish "coverage measured as 0%" from "no coverage data was reported at
# all" (e.g. NoTestRun, or Salesforce ran no tests that touch the changed
# classes). Only the former should ever render red — the latter is N/A.
HAS_COVERAGE_DATA="false"

if [ -f reports/deploy-report.json ]; then
  DEPLOY_STATUS=$(jq -r '.result.status // "Unknown"' reports/deploy-report.json 2>/dev/null || echo Unknown)
  if jq -e '.result.details.componentFailures' reports/deploy-report.json >/dev/null 2>&1; then
    COMPONENT_FAILURES=$(jq '.result.details.componentFailures | length' reports/deploy-report.json 2>/dev/null || echo 0)
  fi
  if jq -e '.result.details.runTestResult.failures' reports/deploy-report.json >/dev/null 2>&1; then
    TEST_FAILURES=$(jq '.result.details.runTestResult.failures | length' reports/deploy-report.json 2>/dev/null || echo 0)
  fi
  # Coverage data only counts if the codeCoverage array is actually non-empty.
  if jq -e '(.result.details.runTestResult.codeCoverage // []) | length > 0' reports/deploy-report.json >/dev/null 2>&1; then
    HAS_COVERAGE_DATA="true"
    COVERAGE=$(jq -r '[.result.details.runTestResult.codeCoverage[]? | (.coveredPercent // 0)] | (if length>0 then (add/length|floor) else 0 end)' reports/deploy-report.json 2>/dev/null || echo 0)
  fi
fi

APEX_VIOLATIONS=0
LWC_VIOLATIONS=0
[ -f reports/apex.json ] && APEX_VIOLATIONS=$(jq '.violations | length' reports/apex.json 2>/dev/null || echo 0)
[ -f reports/lwc.json ]  && LWC_VIOLATIONS=$(jq '.violations | length'  reports/lwc.json  2>/dev/null || echo 0)
TOTAL_VIOLATIONS=$((APEX_VIOLATIONS + LWC_VIOLATIONS))

HAS_APEX_CHANGES="false"
if has_source_metadata && find "$DELTA_SOURCE_DIR" \( -name '*.cls' -o -name '*.trigger' \) 2>/dev/null | grep -q .; then
  HAS_APEX_CHANGES="true"
fi

# ------------------------------------------------------------------------------
# Health & Safety derivations
# ------------------------------------------------------------------------------
case "$DEPLOY_STATUS" in
  Succeeded)
    OVERALL="🟢 PASSED"
    OVERALL_NOTE="Safe to merge"
    DR_STATUS="🟢 SUCCESS"
    DR_NOTE="No errors detected in Salesforce validation"
    ;;
  Skipped)
    OVERALL="🟢 SKIPPED"
    OVERALL_NOTE="No deployable changes"
    DR_STATUS="🟢 SKIPPED"
    DR_NOTE="No source or destructive changes to validate"
    ;;
  *)
    OVERALL="🔴 FAILED"
    OVERALL_NOTE="Resolve failures before merge"
    DR_STATUS="🔴 ${DEPLOY_STATUS}"
    DR_NOTE="${COMPONENT_FAILURES} component error(s), ${TEST_FAILURES} test failure(s)"
    ;;
esac

# A PR that touches only pipeline/config/Vlocity files produces no Salesforce
# deploy report, so DEPLOY_STATUS stays "Unknown". That is NOT a failure — there
# was simply no SF metadata to dry-run. Report it green so the gate verdict
# (which already passes) and this summary agree.
if [ "$DEPLOY_STATUS" = "Unknown" ] && ! has_source_metadata && [ "${HAS_DESTRUCTIVE_CHANGES:-false}" != "true" ]; then
  OVERALL="🟢 PASSED"
  OVERALL_NOTE="No Salesforce metadata to validate"
  DR_STATUS="🟢 N/A"
  DR_NOTE="No Salesforce components changed in this PR"
fi

# Pre-flight scanner outranks deploy status — if it flagged orphaned refs the
# Salesforce dry-run never got to run, and the merge must be blocked.
if [ "$DEPENDENCY_ERRORS_PRESENT" = "true" ]; then
  OVERALL="🛑 BLOCKED"
  OVERALL_NOTE="Orphaned references — clean up referenced files first"
  DR_STATUS="⏭️ NOT RUN"
  DR_NOTE="Pre-flight dependency scan blocked the deployment validation"
fi

if [ "$TOTAL_VIOLATIONS" -eq 0 ]; then
  CQ_STATUS="🟢 100%"
  CQ_NOTE="0 violations found"
else
  CQ_STATUS="🟠 ${TOTAL_VIOLATIONS} issue(s)"
  CQ_NOTE="Apex: ${APEX_VIOLATIONS}, LWC: ${LWC_VIOLATIONS}"
fi

if [ "$HAS_APEX_CHANGES" = "true" ]; then
  if [ "$HAS_COVERAGE_DATA" = "true" ]; then
    if [ "${COVERAGE:-0}" -ge "$COVERAGE_THRESHOLD" ]; then
      COV_STATUS="🟢 ${COVERAGE}%"
      COV_NOTE="≥ ${COVERAGE_THRESHOLD}% threshold"
    else
      COV_STATUS="🔴 ${COVERAGE}%"
      COV_NOTE="< ${COVERAGE_THRESHOLD}% threshold"
    fi
  else
    # Apex changed but Salesforce reported no coverage figures. This is NOT a
    # measured 0% — it means no test exercised the changed classes in this run.
    # Show it as neutral so it never contradicts a PASSED dry-run.
    COV_STATUS="⚪ N/A"
    COV_NOTE="No coverage data reported — no Apex tests ran against the changed classes"
  fi
else
  COV_STATUS="🟢 N/A"
  COV_NOTE="No custom code (Apex) was modified"
fi

# ------------------------------------------------------------------------------
# Header
# ------------------------------------------------------------------------------
{
  if [ "${VLOCITY_CHANGED_COUNT}" -gt 0 ]; then
    echo "# 🎯 Executive Deployment Summary — Vlocity Changes"
  else
    echo "# 🎯 Executive Deployment Summary"
  fi
  echo ""
  if [ -n "$TICKET_ID" ]; then
    echo "**User Story:** \`${TICKET_ID}\` ${TICKET_TITLE}"
  elif [ -n "$PR_TITLE" ]; then
    echo "**Title:** ${PR_TITLE}"
  fi
  printf '**Author:** `%s` &nbsp;&nbsp;|&nbsp;&nbsp; **Target Environment:** `%s`' "${PR_AUTHOR:-unknown}" "${TARGET_ENV_UPPER}"
  if [ -n "$PR_NUMBER" ]; then
    printf ' &nbsp;&nbsp;|&nbsp;&nbsp; **PR:** #%s' "$PR_NUMBER"
  fi
  echo ""
  if [ "${VLOCITY_CHANGED_COUNT}" -gt 0 ]; then
    printf '**Vlocity Scope:** `%s datapack(s)` changed (`%s` file(s) under `vlocity/`, vs `%s`)' \
      "$VLOCITY_CHANGED_COUNT" "$VLOCITY_CHANGED_FILE_COUNT" "$TARGET_BRANCH"
    echo ""
  fi
  echo ""
  echo "### 🚦 Health & Safety Check"
  echo ""
  echo "| Metric | Status | Note |"
  echo "| :--- | :--- | :--- |"
  echo "| **Overall Status** | ${OVERALL} | ${OVERALL_NOTE} |"
  echo "| **Code Quality** | ${CQ_STATUS} | ${CQ_NOTE} |"
  echo "| **Test Coverage** | ${COV_STATUS} | ${COV_NOTE} |"
  echo "| **Dry-Run Deploy** | ${DR_STATUS} | ${DR_NOTE} |"
  echo ""
} >> "$OUTPUT_FILE"

# ------------------------------------------------------------------------------
# Orphaned dependency block (always at the very top of the body so it's the
# first concrete content the PO/developer sees).
# ------------------------------------------------------------------------------
if [ "$DEPENDENCY_ERRORS_PRESENT" = "true" ]; then
  cat "$DEPENDENCY_ERRORS_FILE" >> "$OUTPUT_FILE"
  echo "" >> "$OUTPUT_FILE"
fi

# ------------------------------------------------------------------------------
# Destructive Changes — high-alert section, business terms
# ------------------------------------------------------------------------------
if [ "${HAS_DESTRUCTIVE_CHANGES:-false}" = "true" ]; then
  {
    echo "### ⚠️ DESTRUCTIVE CHANGES (Deletions)"
    echo ""
    echo "_The following items will be **permanently deleted** from \`${TARGET_ENV_UPPER}\`. Please confirm data loss is acceptable._"
    echo ""
    python3 - "$DESTRUCTIVE_CHANGES_FILE" <<'PY'
import sys, xml.etree.ElementTree as ET
from pathlib import Path

p = Path(sys.argv[1])
ns = {"md": "http://soap.sforce.com/2006/04/metadata"}

# Salesforce metadata type → human-readable business label.
LABELS = {
    "CustomObject":            "🗑️ Database Object",
    "CustomField":             "🗑️ Database Field",
    "RecordType":              "🗑️ Record Type",
    "ValidationRule":          "🗑️ Data Quality Rule",
    "ListView":                "🗑️ List View",
    "Flow":                    "🗑️ Automation (Flow)",
    "FlowDefinition":          "🗑️ Automation (Flow Definition)",
    "Workflow":                "🗑️ Automation (Workflow)",
    "WorkflowAlert":           "🗑️ Automation (Email Alert)",
    "WorkflowFieldUpdate":     "🗑️ Automation (Field Update)",
    "WorkflowRule":            "🗑️ Automation (Workflow Rule)",
    "ApprovalProcess":         "🗑️ Automation (Approval Process)",
    "ApexClass":               "🗑️ Custom Backend Code (Apex Class)",
    "ApexTrigger":             "🗑️ Custom Backend Code (Apex Trigger)",
    "ApexComponent":           "🗑️ Custom Backend Code (Visualforce Component)",
    "ApexPage":                "🗑️ User Interface (Visualforce Page)",
    "LightningComponentBundle":"🗑️ User Interface (Lightning Web Component)",
    "AuraDefinitionBundle":    "🗑️ User Interface (Aura Component)",
    "FlexiPage":               "🗑️ User Interface (Lightning Page)",
    "Layout":                  "🗑️ User Interface (Page Layout)",
    "CustomTab":               "🗑️ User Interface (Tab)",
    "Profile":                 "🗑️ Security & Access (Profile)",
    "PermissionSet":           "🗑️ Security & Access (Permission Set)",
    "PermissionSetGroup":      "🗑️ Security & Access (Permission Set Group)",
    "Role":                    "🗑️ Security & Access (Role)",
    "Report":                  "🗑️ Report",
    "Dashboard":               "🗑️ Dashboard",
    "EmailTemplate":           "🗑️ Email Template",
    "StaticResource":          "🗑️ Static Resource",
    "OmniDataTransform":       "🗑️ OmniStudio Data Transform",
    "OmniIntegrationProcedure":"🗑️ OmniStudio Integration Procedure",
    "OmniScript":              "🗑️ OmniStudio Script",
}

try:
    root = ET.parse(p).getroot()
    for t in root.findall('md:types', ns):
        name = (t.findtext('md:name', default='', namespaces=ns) or '').strip()
        members = [(m.text or '').strip() for m in t.findall('md:members', ns) if (m.text or '').strip()]
        if not members:
            continue
        label = LABELS.get(name, f"🗑️ {name}")
        for m in members:
            print(f"* **{label}:** `{m}`")
except Exception as e:
    print(f"_Unable to parse destructive changes: {e}_")
PY
    echo ""
  } >> "$OUTPUT_FILE"
fi

# ------------------------------------------------------------------------------
# Added or Modified Components — grouped by business category
# ------------------------------------------------------------------------------
if has_source_metadata && [ -f delta/package/package.xml ]; then
  {
    echo "### 📦 ADDED OR MODIFIED COMPONENTS"
    echo ""
    python3 - delta/package/package.xml <<'PY'
import sys, xml.etree.ElementTree as ET
from pathlib import Path
from collections import OrderedDict, defaultdict

p = Path(sys.argv[1])
ns = {"md": "http://soap.sforce.com/2006/04/metadata"}

# Business category → set of metadata type names that belong to it.
# Order here determines the order in the rendered summary.
CATEGORIES = OrderedDict([
    ("**🗄️ Database & Schema**", {
        "CustomObject", "CustomField", "RecordType", "ValidationRule",
        "ListView", "BusinessProcess", "CompactLayout", "FieldSet"
    }),
    ("**⚙️ Automations & Processes**", {
        "Flow", "FlowDefinition", "Workflow", "WorkflowAlert",
        "WorkflowFieldUpdate", "WorkflowTask", "WorkflowRule",
        "ApprovalProcess", "AssignmentRule", "AutoResponseRule",
    }),
    ("**🧠 Custom Backend Code**", {
        "ApexClass", "ApexTrigger", "ApexComponent", "ApexTestSuite"
    }),
    ("**🎨 User Interface**", {
        "LightningComponentBundle", "AuraDefinitionBundle", "ApexPage",
        "FlexiPage", "Layout", "CustomTab", "HomePageComponent",
        "HomePageLayout", "AppMenu", "CustomApplication"
    }),
    ("**🛡️ Security & Access**", {
        "Profile", "PermissionSet", "PermissionSetGroup", "Role",
        "SharingRules", "SharingSet", "MutingPermissionSet"
    }),
    ("**📊 Reports & Dashboards**", {
        "Report", "Dashboard", "ReportType", "AnalyticSnapshot"
    }),
    ("**✉️ Communications & Templates**", {
        "EmailTemplate", "Letterhead", "EmailServicesFunction"
    }),
    ("**🧩 OmniStudio / Vlocity**", {
        "OmniDataTransform", "OmniIntegrationProcedure", "OmniScript",
        "OmniDataPack", "OmniUiCard"
    }),
    ("**📁 Static Resources & Documents**", {
        "StaticResource", "Document", "ContentAsset"
    }),
])

# Pretty member-type sub-label (singular/plural awareness via type name suffix).
TYPE_LABELS = {
    "CustomObject":            "Object",
    "CustomField":             "Field",
    "RecordType":              "Record Type",
    "ValidationRule":          "Validation Rule",
    "ListView":                "List View",
    "Flow":                    "Flow",
    "Workflow":                "Workflow",
    "WorkflowAlert":           "Workflow Alert",
    "WorkflowFieldUpdate":     "Workflow Field Update",
    "WorkflowRule":            "Workflow Rule",
    "ApprovalProcess":         "Approval Process",
    "ApexClass":               "Apex Class",
    "ApexTrigger":             "Apex Trigger",
    "LightningComponentBundle":"Lightning Web Component",
    "AuraDefinitionBundle":    "Aura Component",
    "ApexPage":                "Visualforce Page",
    "FlexiPage":               "Lightning Page",
    "Layout":                  "Page Layout",
    "CustomTab":               "Tab",
    "Profile":                 "Profile",
    "PermissionSet":           "Permission Set",
    "PermissionSetGroup":      "Permission Set Group",
    "Report":                  "Report",
    "Dashboard":               "Dashboard",
    "EmailTemplate":           "Email Template",
    "StaticResource":          "Static Resource",
    "OmniDataTransform":       "OmniStudio Data Transform",
    "OmniIntegrationProcedure":"OmniStudio Integration Procedure",
    "OmniScript":              "OmniStudio Script",
}

groups = defaultdict(list)
other = defaultdict(list)
seen_any = False

try:
    root = ET.parse(p).getroot()
    for t in root.findall('md:types', ns):
        name = (t.findtext('md:name', default='', namespaces=ns) or '').strip()
        members = [(m.text or '').strip() for m in t.findall('md:members', ns) if (m.text or '').strip()]
        if not members:
            continue
        seen_any = True
        placed = False
        for cat, types in CATEGORIES.items():
            if name in types:
                groups[cat].append((name, members))
                placed = True
                break
        if not placed:
            other["**🔧 Other Salesforce Metadata**"].append((name, members))
except Exception as e:
    print(f"_Unable to parse package.xml: {e}_")
    sys.exit(0)

if not seen_any:
    print("_No source metadata in this PR (destructive-only or pipeline-only changes)._")
    sys.exit(0)

def emit_group(cat, items):
    print(cat)
    print()
    for name, members in items:
        label = TYPE_LABELS.get(name, name)
        for m in members:
            print(f"* ➕ {label}: `{m}`")
    print()

for cat in CATEGORIES:
    if cat in groups:
        emit_group(cat, groups[cat])
for cat, items in other.items():
    emit_group(cat, items)
PY
    echo ""
  } >> "$OUTPUT_FILE"
elif [ "${HAS_DESTRUCTIVE_CHANGES:-false}" != "true" ]; then
  {
    echo "### 📝 No Salesforce Components Modified"
    echo ""
    echo "_Only pipeline / configuration files changed in this PR. No Salesforce metadata was added, modified, or deleted._"
    if [ "${VLOCITY_CHANGED_COUNT}" -gt 0 ]; then
      echo ""
      echo "_Vlocity files were detected in this PR and are deployed post-merge via the Vlocity deployment stage._"
    fi
    echo ""
  } >> "$OUTPUT_FILE"
fi

# ------------------------------------------------------------------------------
# Pipeline / config files — collapsed for PO clarity
# ------------------------------------------------------------------------------
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  CHANGED_PIPELINE=$(git diff --name-only "origin/${TARGET_BRANCH}" HEAD 2>/dev/null \
                       | grep -E '\.(sh|yml|yaml)$|^\.github/' || true)
  PIPELINE_COUNT=$(printf '%s\n' "$CHANGED_PIPELINE" | grep -c . || true)

  # Keep this section explicitly visible for Vlocity-only PRs, since reviewers
  # rely on it as confirmation that the change set is pipeline/config oriented.
  if [ "${VLOCITY_CHANGED_COUNT}" -gt 0 ]; then
    {
      echo "### 🔧 Scripts & Pipeline Configurations (Developer Only) — ${PIPELINE_COUNT} file(s)"
      echo ""
    } >> "$OUTPUT_FILE"
  fi

  if [ -n "$CHANGED_PIPELINE" ]; then
    {
      echo "<details>"
      echo "<summary><strong>🔧 Scripts &amp; Pipeline Configurations (Developer Only)</strong> — ${PIPELINE_COUNT} file(s)</summary>"
      echo ""
      printf '%s\n' "$CHANGED_PIPELINE" | sed 's/^/* `/' | sed 's/$/`/'
      echo ""
      echo "</details>"
      echo ""
    } >> "$OUTPUT_FILE"
  fi
fi

# ------------------------------------------------------------------------------
# Failure details (collapsed)
# ------------------------------------------------------------------------------
if { [ "${COMPONENT_FAILURES:-0}" -gt 0 ] || [ "${TEST_FAILURES:-0}" -gt 0 ]; } && [ -f reports/deploy-report.json ]; then
  {
    echo "<details open>"
    echo "<summary><strong>❌ Failure Details</strong></summary>"
    echo ""
    if jq -e '.result.details.componentFailures | length > 0' reports/deploy-report.json >/dev/null 2>&1; then
      echo "**Component Errors:**"
      echo ""
      jq -r '.result.details.componentFailures[]? |
              "* `" + ((.fileName // .fullName // "unknown") | tostring) + "` — " + ((.problem // "Unknown error") | tostring)' \
        reports/deploy-report.json | head -20
      echo ""
    fi
    if jq -e '.result.details.runTestResult.failures | length > 0' reports/deploy-report.json >/dev/null 2>&1; then
      echo "**Test Failures:**"
      echo ""
      jq -r '.result.details.runTestResult.failures[]? |
              "* `" + ((.name // "Unknown") | tostring) + "." + ((.methodName // "unknown") | tostring) + "` — " + ((.message // "No message") | tostring)' \
        reports/deploy-report.json | head -20
      echo ""
    fi
    echo "</details>"
    echo ""
  } >> "$OUTPUT_FILE"
fi

# ------------------------------------------------------------------------------
# Footer
# ------------------------------------------------------------------------------
{
  echo "---"
  echo ""
  if [ -n "$WORKFLOW_RUN_URL" ]; then
    echo "🔗 [View full workflow run](${WORKFLOW_RUN_URL})"
  fi
  if [ -n "$PR_URL" ]; then
    echo "🔗 [View Pull Request](${PR_URL})"
  fi
  echo ""
  echo "<sub>This summary was generated by the Salesforce CI/CD pipeline. Re-pushing to this branch will update the comment in place.</sub>"
} >> "$OUTPUT_FILE"

echo "✅ Executive summary written to: $OUTPUT_FILE"

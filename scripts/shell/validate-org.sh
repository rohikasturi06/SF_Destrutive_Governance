#!/usr/bin/env bash
set -euo pipefail

mkdir -p reports

echo "[VALIDATION] Starting check-only validation against target org"
echo "[VALIDATION] Org alias: ${SF_ALIAS:-ci-org}"
echo "[VALIDATION] Source dir: src/salesforce/force-app"
echo "[VALIDATION] Preparing executive summary and change log"

summarize_manifest() {
  local file_path="$1"
  local title="$2"
  {
    echo "## ${title}"
    echo ""
    echo "- File: \`${file_path}\`"
  } >> reports/executive-summary.md

  if [[ ! -f "$file_path" ]]; then
    echo "- Status: not found" >> reports/executive-summary.md
    echo "" >> reports/executive-summary.md
    return
  fi

  local type_count member_count
  type_count=$(grep -c "<types>" "$file_path" 2>/dev/null || true)
  member_count=$(grep -c "<members>" "$file_path" 2>/dev/null || true)

  echo "- Status: found" >> reports/executive-summary.md
  echo "- Metadata types: ${type_count}" >> reports/executive-summary.md
  echo "- Members: ${member_count}" >> reports/executive-summary.md
  echo "" >> reports/executive-summary.md
  echo "| Type | Members |" >> reports/executive-summary.md
  echo "|---|---:|" >> reports/executive-summary.md

  awk '
    /<types>/ { in_types=1; type=""; members=0; next }
    /<\/types>/ { if (type != "") print type "|" members; in_types=0; next }
    in_types && /<name>/ {
      gsub(/.*<name>/, ""); gsub(/<\/name>.*/, ""); type=$0; next
    }
    in_types && /<members>/ { members++; next }
  ' "$file_path" 2>/dev/null | while IFS='|' read -r t m; do
    if [[ -n "${t}" ]]; then
      echo "| ${t} | ${m} |" >> reports/executive-summary.md
    fi
  done
  echo "" >> reports/executive-summary.md
}

{
  echo "# Validation Executive Summary"
  echo ""
  echo "- Repository: ${GITHUB_REPOSITORY:-local-run}"
  echo "- Run ID: ${GITHUB_RUN_ID:-local-run}"
  echo "- Branch/Ref: ${GITHUB_REF_NAME:-local}"
  echo "- Base SHA: ${BASE_SHA:-n/a}"
  echo "- Head SHA: ${HEAD_SHA:-n/a}"
  echo ""
} > reports/executive-summary.md

{
  echo "## Validations Executed"
  echo ""
  echo "- Salesforce authentication/session verification"
  echo "- SGD delta generation from git diff"
  echo "- Manifest inspection (package.xml + destructiveChanges.xml)"
  echo "- Check-only deployment validation against target org"
  echo ""
} >> reports/executive-summary.md

{
  echo "## Git Delta Changed Files"
  echo ""
  echo "| File |"
  echo "|---|"
} >> reports/executive-summary.md

if [[ -n "${BASE_SHA:-}" && -n "${HEAD_SHA:-}" ]]; then
  git diff --name-only "${BASE_SHA}" "${HEAD_SHA}" | head -200 | while IFS= read -r file; do
    [[ -n "$file" ]] && echo "| ${file} |" >> reports/executive-summary.md
  done
else
  echo "| Base/head SHA not supplied |" >> reports/executive-summary.md
fi
echo "" >> reports/executive-summary.md

summarize_manifest "manifest/package.xml" "Package Manifest"
summarize_manifest "manifest/destructiveChanges.xml" "Destructive Manifest"

DEPLOY_CMD=(sf project deploy start --target-org "${SF_ALIAS:-ci-org}" --dry-run --test-level NoTestRun --wait 30 --verbose --json)

if [[ -f "manifest/package.xml" ]]; then
  DEPLOY_CMD+=(--manifest manifest/package.xml)
  if [[ -f "manifest/destructiveChanges.xml" ]]; then
    DEPLOY_CMD+=(--post-destructive-changes manifest/destructiveChanges.xml)
  fi
  echo "[VALIDATION] Running manifest-based check-only deploy"
else
  DEPLOY_CMD+=(--source-dir src/salesforce/force-app)
  echo "[VALIDATION] Running source-dir check-only deploy"
fi

"${DEPLOY_CMD[@]}" | tee reports/org-validation-result.json

STATUS=$(jq -r '.result.status // "Unknown"' reports/org-validation-result.json)
DEPLOY_ID=$(jq -r '.result.id // "n/a"' reports/org-validation-result.json)
ORG_URL=$(sf org display --target-org "${SF_ALIAS:-ci-org}" --json | jq -r '.result.instanceUrl // ""')

# Non-blocking case: destructive check-only warning for already-missing metadata.
if [[ "$STATUS" == "Failed" ]]; then
  ONLY_MISSING_WARNINGS=$(jq -r '
    [
      (.result.details.componentFailures // [])[]?.problem
      | select(type=="string")
      | test("^No [A-Za-z0-9_]+ named:")
    ] | length
  ' reports/org-validation-result.json 2>/dev/null || echo "0")

  TOTAL_FAILURES=$(jq -r '(.result.details.componentFailures // []) | length' reports/org-validation-result.json 2>/dev/null || echo "0")

  if [[ "$TOTAL_FAILURES" -gt 0 && "$ONLY_MISSING_WARNINGS" -eq "$TOTAL_FAILURES" ]]; then
    echo "[VALIDATION] Only missing-metadata warnings detected in destructive check. Treating as non-blocking."
    STATUS="SucceededWithWarnings"
  fi
fi

echo "[VALIDATION] Deployment status: ${STATUS}"
echo "[VALIDATION] Deployment id: ${DEPLOY_ID}"
if [[ -n "$ORG_URL" ]]; then
  echo "[VALIDATION] Org deploy status page: ${ORG_URL}/lightning/setup/DeployStatus/home"
fi

{
  echo "## Deployment Result"
  echo ""
  echo "- Status: ${STATUS}"
  echo "- Deployment ID: ${DEPLOY_ID}"
  if [[ -n "$ORG_URL" ]]; then
    echo "- Deploy Status URL: ${ORG_URL}/lightning/setup/DeployStatus/home"
  fi
  echo ""
} >> reports/executive-summary.md

echo "[VALIDATION] Executive summary generated: reports/executive-summary.md"

if [[ "$STATUS" != "Succeeded" && "$STATUS" != "SucceededPartial" ]]; then
  echo "[VALIDATION] Validation failed. Inspect reports/org-validation-result.json"
  exit 1
fi

echo "[VALIDATION] Check-only validation passed"

#!/usr/bin/env bash
set -euo pipefail

mkdir -p reports

echo "[VALIDATION] Starting check-only validation against target org"
echo "[VALIDATION] Org alias: ${SF_ALIAS:-ci-org}"
echo "[VALIDATION] Source dir: src/salesforce/force-app"

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
  echo ""
} > reports/executive-summary.md

summarize_manifest "manifest/package.xml" "Package Manifest"
summarize_manifest "manifest/destructiveChanges.xml" "Destructive Manifest"

sf project deploy start \
  --source-dir src/salesforce/force-app \
  --target-org "${SF_ALIAS:-ci-org}" \
  --dry-run \
  --test-level NoTestRun \
  --wait 30 \
  --verbose \
  --json | tee reports/org-validation-result.json

STATUS=$(jq -r '.result.status // "Unknown"' reports/org-validation-result.json)
DEPLOY_ID=$(jq -r '.result.id // "n/a"' reports/org-validation-result.json)
ORG_URL=$(sf org display --target-org "${SF_ALIAS:-ci-org}" --json | jq -r '.result.instanceUrl // ""')

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

#!/usr/bin/env bash
set -euo pipefail

mkdir -p reports

echo "[VALIDATION] Starting check-only validation against target org"
echo "[VALIDATION] Org alias: ${SF_ALIAS:-ci-org}"
echo "[VALIDATION] Source dir: src/salesforce/force-app"

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

if [[ "$STATUS" != "Succeeded" && "$STATUS" != "SucceededPartial" ]]; then
  echo "[VALIDATION] Validation failed. Inspect reports/org-validation-result.json"
  exit 1
fi

echo "[VALIDATION] Check-only validation passed"

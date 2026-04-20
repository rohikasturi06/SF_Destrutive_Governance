#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${SF_AUTH_URL:-}" || -z "${SF_ALIAS:-}" ]]; then
  echo "[AUTH] Missing required environment variables: SF_AUTH_URL and/or SF_ALIAS."
  exit 2
fi

attempt=1
max_attempts=3
until [[ $attempt -gt $max_attempts ]]; do
  echo "[AUTH] Auth URL login attempt ${attempt}/${max_attempts}"
  if sf org login sfdx-url \
      --sfdx-url-file sfdx_auth_url.txt \
      --alias "$SF_ALIAS" \
      --set-default >/dev/null 2>&1; then
    echo "[AUTH] Salesforce authentication successful."
    sf org display --target-org "$SF_ALIAS" >/dev/null 2>&1
    echo "[AUTH] Org session verification successful."
    exit 0
  fi

  if [[ $attempt -eq $max_attempts ]]; then
    echo "[AUTH] Salesforce authentication failed after retries."
    exit 1
  fi

  echo "[AUTH] Retry after backoff..."
  sleep $((attempt * 5))
  attempt=$((attempt + 1))
done

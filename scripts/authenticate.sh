#!/bin/bash
# ==============================================================================
# Salesforce Authentication Script
# ==============================================================================
# Establishes secure authenticated session with Salesforce sandbox environment
# for deployment validation operations.
#
# Security Measures:
#   - Validates required authentication credentials
#   - Uses temporary files for credential handling
#   - Implements secure cleanup of sensitive data
#   - Sets authenticated org as default for subsequent operations
#
# Environment Requirements:
#   - SF_AUTH_URL: Salesforce authentication URL (stored as GitHub secret)
# ==============================================================================

set -euo pipefail

echo ""
echo "🚀 STAGE 2: SALESFORCE AUTHENTICATION"
echo "===================================="
echo "🔐 Establishing Salesforce environment authentication..."

# Validate required environment variable
echo "🔍 Validating authentication credentials..."
if [ -z "${SF_AUTH_URL:-}" ]; then
  echo "❌ Error: SF_AUTH_URL environment variable is not configured"
  echo "💡 Ensure SF_AUTH_URL secret is properly configured in repository settings"
  exit 1
fi

# Write authentication URL to temporary file for security.
# Use printf (not echo) so we don't append a trailing newline or alter quoting.
echo "🔒 Preparing secure authentication file..."
AUTH_FILE="$(mktemp)"
printf '%s' "$SF_AUTH_URL" > "$AUTH_FILE"

ALIAS="${ORG_NAME:-sandbox}"

# Validate the shape WITHOUT printing the secret. A valid SFDX auth URL always
# starts with 'force://'. NOTE: recent Salesforce CLI security changes REDACT
# sfdxAuthUrl from `sf org display --json`; regenerate the secret with
# `sf org auth show-sfdx-auth-url --target-org <org>` instead.
if ! grep -q '^force://' "$AUTH_FILE"; then
  echo "❌ SF_AUTH_URL is not a valid SFDX auth URL (must start with 'force://')."
  echo "💡 The secret likely holds 'null', an access token, or quotes/whitespace."
  echo "   Regenerate it with: sf org auth show-sfdx-auth-url --target-org <org>"
  rm -f "$AUTH_FILE"
  exit 1
fi

# Authenticate using SFDX URL and configure as default org. Capture the CLI's
# real error (printed to stdout as JSON) instead of discarding it with
# '>/dev/null 2>&1', which previously hid the actual reason for failures.
echo "🔗 Connecting to Salesforce sandbox environment (alias: $ALIAS)..."
set +e
LOGIN_OUT="$(sf org login sfdx-url --sfdx-url-file "$AUTH_FILE" --alias "$ALIAS" --set-default --json 2>&1)"
LOGIN_RC=$?
set -e
if [ "$LOGIN_RC" -eq 0 ]; then

  echo "✅ Authentication successful - sandbox environment ready"
  # Secure cleanup of temporary authentication file
  rm -f "$AUTH_FILE"

  # Display which org we authenticated to for transparency
  echo ""
  echo "🔎 Authenticated Org Details:"
  sf org display --target-org "$ALIAS" --verbose --json 2>/dev/null | jq -r '
    "  • Alias: " + ( .result.alias // "n/a" ) + "\n" +
    "  • Username: " + ( .result.username // "n/a" ) + "\n" +
    "  • Instance Url: " + ( .result.instanceUrl // "n/a" ) + "\n" +
    "  • Org Id: " + ( .result.id // "n/a" )
  ' || true
else
  echo "❌ Authentication failed (exit ${LOGIN_RC}). Reason reported by Salesforce CLI:"
  echo "$LOGIN_OUT" | jq -r '.message // .name // empty' 2>/dev/null | sed 's/^/   /' || true
  echo "💡 If sfdxAuthUrl came back redacted/null, regenerate with:"
  echo "   sf org auth show-sfdx-auth-url --target-org <org>"
  rm -f "$AUTH_FILE"
  exit 1
fi

echo ""
echo "✅ STAGE 2 COMPLETED: Salesforce authentication established"
echo "======================================================="

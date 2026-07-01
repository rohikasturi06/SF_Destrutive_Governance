#!/usr/bin/env bash
# ==============================================================================
# Enforce Branch Protection  (Phase 1.3)
# ==============================================================================
# Protects the target branches (main and release/**) by creating/updating a
# GitHub repository RULESET that requires pull request reviews and a passing
# status check before merge, and blocks force-pushes and deletions.
#
# A ruleset (not classic branch protection) is used because classic protection
# cannot target a glob like release/** in a single rule.
#
# Requirements:
#   - GitHub CLI `gh` authenticated with admin rights on the repo
#     (run `gh auth login` first, or set GH_TOKEN with repo admin scope).
#
# Configuration (environment variables):
#   REPO              owner/name (default: auto-detected via gh)
#   RULESET_NAME      ruleset display name (default: "SF Quality Gate Protection")
#   REQUIRED_REVIEWS  approving reviews required (default: 1)
#   STATUS_CHECK      required check context (default: "Execute Validation")
#                     set to empty to skip the status-check rule (useful while
#                     the path-filtered pipeline may not run on every PR).
# ==============================================================================

set -euo pipefail

REPO="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
RULESET_NAME="${RULESET_NAME:-SF Quality Gate Protection}"
REQUIRED_REVIEWS="${REQUIRED_REVIEWS:-1}"
STATUS_CHECK="${STATUS_CHECK:-Execute Validation}"

echo "🔒 Enforcing branch protection ruleset on ${REPO}"
echo "   • Targets        : refs/heads/main, refs/heads/release/**"
echo "   • Required review : ${REQUIRED_REVIEWS}"
echo "   • Status check    : ${STATUS_CHECK:-<none>}"

# Build the rules array. The status-check rule is included only when STATUS_CHECK
# is non-empty so path-filtered runs don't permanently block unrelated PRs.
STATUS_RULE=""
if [ -n "$STATUS_CHECK" ]; then
  STATUS_RULE=$(cat <<JSON
    ,{
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "required_status_checks": [ { "context": "${STATUS_CHECK}" } ]
      }
    }
JSON
)
fi

PAYLOAD=$(cat <<JSON
{
  "name": "${RULESET_NAME}",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "include": ["refs/heads/main", "refs/heads/release/**"],
      "exclude": []
    }
  },
  "rules": [
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": ${REQUIRED_REVIEWS},
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false
      }
    },
    { "type": "deletion" },
    { "type": "non_fast_forward" }${STATUS_RULE}
  ]
}
JSON
)

# Idempotent: update the ruleset if one with the same name already exists.
EXISTING_ID=$(gh api "repos/${REPO}/rulesets" --jq ".[] | select(.name == \"${RULESET_NAME}\") | .id" 2>/dev/null | head -n1 || true)

if [ -n "${EXISTING_ID:-}" ]; then
  echo "♻️  Updating existing ruleset (id=${EXISTING_ID})"
  printf '%s' "$PAYLOAD" | gh api --method PUT "repos/${REPO}/rulesets/${EXISTING_ID}" --input - >/dev/null
else
  echo "✨ Creating new ruleset"
  printf '%s' "$PAYLOAD" | gh api --method POST "repos/${REPO}/rulesets" --input - >/dev/null
fi

echo "✅ Branch protection ruleset '${RULESET_NAME}' applied to ${REPO}."

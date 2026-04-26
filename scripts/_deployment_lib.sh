#!/bin/bash
# ==============================================================================
# Shared Deployment Helpers
# ==============================================================================
# Functions reused by validate_deployment.sh, deploy.sh and generate_delta.sh
# to keep destructive-change handling, deploy-arg construction, and run
# summarization consistent across the pipeline.
#
# Source this file from another script:
#     # shellcheck source=./_deployment_lib.sh
#     source "$(dirname "$0")/_deployment_lib.sh"
# ==============================================================================

# Idempotent guard so multiple `source` calls don't redefine functions.
if [ -n "${__SF_DEPLOYMENT_LIB_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
__SF_DEPLOYMENT_LIB_LOADED=1

# Defaults (callers may override via env)
: "${DELTA_DIR:=delta}"
: "${DELTA_SOURCE_DIR:=${DELTA_DIR}/force-app}"
: "${DELTA_PACKAGE_FILE:=${DELTA_DIR}/package/package.xml}"
: "${DELTA_DESTRUCTIVE_FILE:=${DELTA_DIR}/destructiveChanges/destructiveChanges.xml}"
: "${DELTA_DESTRUCTIVE_PACKAGE_FILE:=${DELTA_DIR}/destructiveChanges/package.xml}"

# ------------------------------------------------------------------------------
# count_destructive_members <path-to-destructiveChanges.xml>
# Echoes the number of non-empty <members> entries.
# ------------------------------------------------------------------------------
count_destructive_members() {
  local file="${1:-}"
  if [ -z "$file" ] || [ ! -f "$file" ]; then
    echo 0
    return 0
  fi
  python3 - "$file" <<'PY'
import sys, xml.etree.ElementTree as ET
from pathlib import Path
p = Path(sys.argv[1])
count = 0
try:
    root = ET.parse(p).getroot()
    ns = {"md": "http://soap.sforce.com/2006/04/metadata"}
    for t in root.findall('md:types', ns):
        for m in t.findall('md:members', ns):
            if (m.text or '').strip():
                count += 1
except Exception:
    count = 0
print(count)
PY
}

# ------------------------------------------------------------------------------
# count_package_members <path-to-package.xml>
# Echoes the number of non-empty <members> entries.
# ------------------------------------------------------------------------------
count_package_members() {
  local file="${1:-}"
  if [ -z "$file" ] || [ ! -f "$file" ]; then
    echo 0
    return 0
  fi
  python3 - "$file" <<'PY'
import sys, xml.etree.ElementTree as ET
from pathlib import Path
p = Path(sys.argv[1])
count = 0
try:
    root = ET.parse(p).getroot()
    ns = {"md": "http://soap.sforce.com/2006/04/metadata"}
    for t in root.findall('md:types', ns):
        for m in t.findall('md:members', ns):
            if (m.text or '').strip():
                count += 1
except Exception:
    count = 0
print(count)
PY
}

# ------------------------------------------------------------------------------
# detect_destructive_changes
# Sets globals: HAS_DESTRUCTIVE_CHANGES, DESTRUCTIVE_CHANGES_FILE,
#               DESTRUCTIVE_MEMBER_COUNT
# Returns 0 always; consult the variables for state.
# ------------------------------------------------------------------------------
detect_destructive_changes() {
  HAS_DESTRUCTIVE_CHANGES="false"
  DESTRUCTIVE_CHANGES_FILE=""
  DESTRUCTIVE_MEMBER_COUNT=0

  local candidate=""
  if [ -f "$DELTA_DESTRUCTIVE_FILE" ]; then
    candidate="$DELTA_DESTRUCTIVE_FILE"
  else
    # sgd has historically used a few output paths; pick the first match.
    candidate=$(find "$DELTA_DIR" -type f -name 'destructiveChanges*.xml' 2>/dev/null \
                  | grep -v '/destructiveChanges/package.xml' \
                  | head -n1 || true)
  fi

  if [ -z "$candidate" ] || [ ! -f "$candidate" ]; then
    return 0
  fi

  local members
  members=$(count_destructive_members "$candidate")
  if [ "${members:-0}" -gt 0 ]; then
    HAS_DESTRUCTIVE_CHANGES="true"
    DESTRUCTIVE_CHANGES_FILE="$candidate"
    DESTRUCTIVE_MEMBER_COUNT="$members"
  fi
  return 0
}

# ------------------------------------------------------------------------------
# has_source_metadata
# Returns 0 if delta/force-app contains at least one file.
# ------------------------------------------------------------------------------
has_source_metadata() {
  if [ -d "$DELTA_SOURCE_DIR" ] && [ "$(find "$DELTA_SOURCE_DIR" -type f 2>/dev/null | wc -l)" -gt 0 ]; then
    return 0
  fi
  return 1
}

# ------------------------------------------------------------------------------
# has_any_deployable
# Returns 0 if either source metadata OR destructive members exist.
# Side-effect: invokes detect_destructive_changes if not yet set.
# ------------------------------------------------------------------------------
has_any_deployable() {
  if has_source_metadata; then
    return 0
  fi
  if [ -z "${HAS_DESTRUCTIVE_CHANGES:-}" ]; then
    detect_destructive_changes
  fi
  if [ "${HAS_DESTRUCTIVE_CHANGES:-false}" = "true" ]; then
    return 0
  fi
  return 1
}

# ------------------------------------------------------------------------------
# print_destructive_preview
# Prints a human-readable summary of components scheduled for deletion.
# ------------------------------------------------------------------------------
print_destructive_preview() {
  if [ "${HAS_DESTRUCTIVE_CHANGES:-false}" != "true" ]; then
    return 0
  fi
  echo ""
  echo "🗑️  DESTRUCTIVE CHANGES PREVIEW"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  • File: $DESTRUCTIVE_CHANGES_FILE"
  echo "  • Members scheduled for deletion: ${DESTRUCTIVE_MEMBER_COUNT}"
  echo ""
  python3 - "$DESTRUCTIVE_CHANGES_FILE" <<'PY' || true
import sys, xml.etree.ElementTree as ET
from pathlib import Path
p = Path(sys.argv[1])
ns = {"md": "http://soap.sforce.com/2006/04/metadata"}
try:
    root = ET.parse(p).getroot()
    for t in root.findall('md:types', ns):
        name = t.findtext('md:name', default='', namespaces=ns).strip() or "(unknown)"
        members = [(m.text or '').strip() for m in t.findall('md:members', ns) if (m.text or '').strip()]
        if not members:
            continue
        print(f"  🔧 {name} ({len(members)})")
        for m in members:
            print(f"      • {m}")
except Exception as e:
    print(f"  ⚠️  Unable to parse destructive preview: {e}")
PY
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}

# ------------------------------------------------------------------------------
# select_test_args <out-array-name>
# Echoes test selection flags for `sf project deploy start`.
# Inputs (env): RELATED_TESTS, DELTA_SOURCE_DIR
# Behavior:
#   - If RELATED_TESTS is set, use RunSpecifiedTests with that CSV
#   - Else if delta has Apex (.cls/.trigger), use RunLocalTests
#   - Else NoTestRun (metadata-only, including destructive-only)
# ------------------------------------------------------------------------------
select_test_args() {
  local _csv
  if [ -n "${RELATED_TESTS:-}" ]; then
    _csv=$(echo "$RELATED_TESTS" | xargs -n1 | paste -sd, - || echo "")
  fi

  if [ -n "${_csv:-}" ]; then
    printf '%s\n' "--test-level" "RunSpecifiedTests" "--tests" "$_csv"
    return 0
  fi

  if has_source_metadata && find "$DELTA_SOURCE_DIR" \( -name '*.cls' -o -name '*.trigger' \) 2>/dev/null | grep -q .; then
    printf '%s\n' "--test-level" "RunLocalTests"
    return 0
  fi

  printf '%s\n' "--test-level" "NoTestRun"
}

# ------------------------------------------------------------------------------
# build_deploy_args_core <target-org>
# Emits the CORE argv (one per line) for `sf project deploy start`:
#   --source-dir | --manifest, --target-org,
#   --post-destructive-changes / --ignore-warnings (when destructive),
#   --test-level / --tests
# Execution-mode flags (--dry-run / --async / --wait / --json) are NOT added —
# callers append them based on whether they want validate, sync, or async.
# ------------------------------------------------------------------------------
build_deploy_args_core() {
  local org="${1:-${ORG_NAME:-sandbox}}"

  # Always run detection so HAS_DESTRUCTIVE_CHANGES is current.
  detect_destructive_changes

  local lines=()

  if has_source_metadata; then
    lines+=("--source-dir" "$DELTA_SOURCE_DIR")
  elif [ "${HAS_DESTRUCTIVE_CHANGES:-false}" = "true" ]; then
    # Destructive-only: still need a manifest. Prefer the destructive-changes
    # package wrapper, fall back to the empty top-level package.xml.
    if [ -f "$DELTA_DESTRUCTIVE_PACKAGE_FILE" ]; then
      lines+=("--manifest" "$DELTA_DESTRUCTIVE_PACKAGE_FILE")
    elif [ -f "$DELTA_PACKAGE_FILE" ]; then
      lines+=("--manifest" "$DELTA_PACKAGE_FILE")
    fi
  else
    # Nothing to do — caller should have short-circuited via has_any_deployable.
    return 0
  fi

  lines+=("--target-org" "$org")

  if [ "${HAS_DESTRUCTIVE_CHANGES:-false}" = "true" ]; then
    lines+=("--post-destructive-changes" "$DESTRUCTIVE_CHANGES_FILE")
    # Deletes commonly trigger warnings (e.g. references in unrelated profiles
    # the org already has). Real errors still fail the deployment.
    lines+=("--ignore-warnings")
  fi

  # Test selection
  while IFS= read -r flag; do
    [ -n "$flag" ] && lines+=("$flag")
  done < <(select_test_args)

  printf '%s\n' "${lines[@]}"
}

# ------------------------------------------------------------------------------
# build_deploy_args <mode> <target-org>
# Convenience wrapper around build_deploy_args_core that also emits
# execution-mode flags. Used by validate_deployment.sh and deploy.sh (sync).
# mode: "validate" → adds --dry-run --wait N --json
#       "deploy"   → adds              --wait N --json
# ------------------------------------------------------------------------------
build_deploy_args() {
  local mode="${1:-validate}"
  local org="${2:-${ORG_NAME:-sandbox}}"

  build_deploy_args_core "$org"

  if [ "$mode" = "validate" ]; then
    printf '%s\n' "--dry-run"
  fi
  printf '%s\n' "--wait" "${SF_DEPLOY_WAIT_MINUTES:-30}"
  printf '%s\n' "--json"
}

# ------------------------------------------------------------------------------
# read_deploy_args_into <array-name> <mode> <target-org>
# Fills a bash array (named via $1) with the result of build_deploy_args.
# Implemented with `printf %q` + eval for portability with bash 3.2 (macOS).
# Usage:
#   declare -a DEPLOY_ARGS
#   read_deploy_args_into DEPLOY_ARGS validate "$ORG_NAME"
# ------------------------------------------------------------------------------
read_deploy_args_into() {
  local __outname="$1"
  local mode="${2:-validate}"
  local org="${3:-${ORG_NAME:-sandbox}}"
  eval "$__outname=()"
  local __line __esc
  while IFS= read -r __line; do
    printf -v __esc '%q' "$__line"
    eval "$__outname+=($__esc)"
  done < <(build_deploy_args "$mode" "$org")
}

# ------------------------------------------------------------------------------
# read_deploy_args_core_into <array-name> <target-org>
# Same as read_deploy_args_into but emits CORE args only (no --dry-run/--wait/
# --json). Caller appends execution-mode flags. Used by deploy.yml inline.
# ------------------------------------------------------------------------------
read_deploy_args_core_into() {
  local __outname="$1"
  local org="${2:-${ORG_NAME:-sandbox}}"
  eval "$__outname=()"
  local __line __esc
  while IFS= read -r __line; do
    printf -v __esc '%q' "$__line"
    eval "$__outname+=($__esc)"
  done < <(build_deploy_args_core "$org")
}

# ------------------------------------------------------------------------------
# emit_github_env_outputs
# Writes destructive-change state to GITHUB_ENV (for downstream steps) and
# GITHUB_OUTPUT (for `if:` conditions). Safe in local runs (no-op).
# ------------------------------------------------------------------------------
emit_github_env_outputs() {
  if [ -n "${GITHUB_ENV:-}" ] && [ -w "${GITHUB_ENV}" ]; then
    {
      echo "HAS_DESTRUCTIVE_CHANGES=${HAS_DESTRUCTIVE_CHANGES:-false}"
      echo "DESTRUCTIVE_CHANGES_FILE=${DESTRUCTIVE_CHANGES_FILE:-}"
      echo "DESTRUCTIVE_MEMBER_COUNT=${DESTRUCTIVE_MEMBER_COUNT:-0}"
    } >> "$GITHUB_ENV"
  fi
  if [ -n "${GITHUB_OUTPUT:-}" ] && [ -w "${GITHUB_OUTPUT}" ]; then
    {
      echo "has-destructive-changes=${HAS_DESTRUCTIVE_CHANGES:-false}"
      echo "destructive-member-count=${DESTRUCTIVE_MEMBER_COUNT:-0}"
    } >> "$GITHUB_OUTPUT"
  fi
}

# ------------------------------------------------------------------------------
# summarize_deploy_report <path-to-json>
# Prints a concise component/test summary. Returns 0 on success, 1 if status
# indicates failure.
# ------------------------------------------------------------------------------
summarize_deploy_report() {
  local file="${1:-reports/deploy-report.json}"
  if [ ! -f "$file" ]; then
    echo "❌ No deploy report at $file"
    return 1
  fi

  local status total done_ errs t_total t_done t_fail
  status=$(jq -r '.result.status // .status // "Unknown"' "$file" 2>/dev/null || echo Unknown)
  total=$(jq -r '.result.numberComponentsTotal // 0' "$file" 2>/dev/null || echo 0)
  done_=$(jq -r '.result.numberComponentsDeployed // 0' "$file" 2>/dev/null || echo 0)
  errs=$(jq -r '.result.numberComponentErrors // 0' "$file" 2>/dev/null || echo 0)
  t_total=$(jq -r '.result.numberTestsTotal // 0' "$file" 2>/dev/null || echo 0)
  t_done=$(jq -r '.result.numberTestsCompleted // 0' "$file" 2>/dev/null || echo 0)
  t_fail=$(jq -r '.result.numberTestErrors // 0' "$file" 2>/dev/null || echo 0)

  echo ""
  echo "📊 Deploy Summary"
  echo "  • Status: $status"
  echo "  • Components: ${done_}/${total} (errors: ${errs})"
  echo "  • Tests: ${t_done}/${t_total} (failures: ${t_fail})"

  if jq -e '.result.details.componentFailures | length > 0' "$file" >/dev/null 2>&1; then
    echo ""
    echo "🔧 Component Failures:"
    jq -r '.result.details.componentFailures[]? | "  ❌ " + ((.fileName // .fullName // "unknown") | tostring) + ": " + ((.problem // "Unknown") | tostring)' "$file" 2>/dev/null | head -20 || true
  fi

  case "$status" in
    Succeeded|SucceededPartial|Skipped) return 0 ;;
    *) return 1 ;;
  esac
}

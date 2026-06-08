#!/bin/bash
# ==============================================================================
# Vlocity (OmniStudio) PR Validation
# ==============================================================================
# Runs on PRs targeting dev / qa / intuat. Complements the SF dry-run for
# standard metadata by validating the OmniStudio datapacks under vlocity/.
#
# Validation layers (in order, all run; failures accumulate):
#
#   STRUCTURAL (offline, no Salesforce org required)
#   ─────────────────────────────────────────────────
#     • Job file (vlocity/deploy.yaml) is valid YAML.
#     • For every changed *_DataPack.json under vlocity/datapacks/:
#         - is valid JSON
#         - has required fields:  VlocityDataPackType, VlocityRecordSObjectType
#         - folder name matches the pack identifier inside the JSON
#         - parent folder matches the declared VlocityDataPackType
#         - per-type required fields (DataRaptor, OmniScript, IntegrationProcedure)
#
#   BUILD (uses the Vlocity Build Tool, mostly offline)
#   ─────────────────────────────────────────────────────
#     • Run `vlocity packBuildAllFiles` against vlocity/datapacks/. This
#       assembles each pack's expanded files back into a single artifact.
#       It catches malformed expansions, missing companion files (e.g. a
#       DataRaptor with a *_DataPack.json but no Configuration body), and
#       references between packs that don't resolve.
#     • The build tool reads the connected org's namespace; if no org is
#       logged in we fall back to `-vlocity.namespace vlocity_cmt` which is
#       sufficient for source-form validation.
#
# What this script INTENTIONALLY does NOT do:
#   • Run `packGetAllAvailableExports` — that just enumerates everything the
#     org already has, and is hostile to vanilla orgs that don't ship every
#     Vlocity sObject (you get ~80 INVALID_TYPE stack traces in the log for
#     no useful signal). It tells you nothing about the PR.
#   • Run an actual `packDeploy` — that's reserved for the post-merge
#     workflow (scripts/vlocity_deploy.sh).
#
# Outputs:
#   reports/vlocity/validate.json   — machine-readable summary
#   reports/vlocity/validate.log    — combined human-readable log
#   reports/vlocity/build.log       — raw `packBuildAllFiles` output
#
# Exit codes:
#   0   success / no-op (no Vlocity changes)
#   1   validation failure (at least one error)
#   2   configuration error (missing job file, etc.)
# ==============================================================================

set -uo pipefail  # NOT -e — we want every check to run and accumulate findings.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_vlocity_lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_vlocity_lib.sh"

JOB_FILE="${VLOCITY_JOB_FILE:-vlocity/deploy.yaml}"
PROJECT_PATH="${VLOCITY_PROJECT_PATH:-vlocity/datapacks}"
ORG_ALIAS="${ORG_NAME:-sandbox}"
NAMESPACE_FALLBACK="${VLOCITY_NAMESPACE:-vlocity_cmt}"

mkdir -p "$VLOCITY_REPORTS_DIR"
SUMMARY_LOG="${VLOCITY_REPORTS_DIR}/validate.log"
BUILD_LOG="${VLOCITY_REPORTS_DIR}/build.log"
SUMMARY_JSON="${VLOCITY_REPORTS_DIR}/validate.json"
: > "$SUMMARY_LOG"
: > "$BUILD_LOG"

ERRORS=()
WARNINGS=()
PACK_RESULTS=()  # "status|file|message" rows for the JSON summary

record_error()   { ERRORS+=("$1");   echo "  ❌ $1" | tee -a "$SUMMARY_LOG"; }
record_warning() { WARNINGS+=("$1"); echo "  ⚠️  $1" | tee -a "$SUMMARY_LOG"; }
record_ok()      {                   echo "  ✅ $1" | tee -a "$SUMMARY_LOG"; }
section()        { printf '\n── %s ─────────────────────────────────────\n' "$1" | tee -a "$SUMMARY_LOG"; }

echo ""
echo "🚀 STAGE: VLOCITY PR VALIDATION (structural + build)"
echo "===================================================="
vlocity_log "Target org alias : ${ORG_ALIAS}"
vlocity_log "Job file         : ${JOB_FILE}"
vlocity_log "Project path     : ${PROJECT_PATH}"

# ------------------------------------------------------------------------------
# 1) Detect changes — short-circuit when nothing to validate.
# ------------------------------------------------------------------------------
detect_vlocity_changes "${FROM_REF:-}" "${TO_REF:-HEAD}"
emit_vlocity_github_outputs
print_vlocity_preview

if [ "${HAS_VLOCITY_CHANGES:-false}" != "true" ]; then
  vlocity_log "No Vlocity / OmniStudio changes — skipping validation"
  jq -nc \
    --arg status "Skipped" \
    --arg reason "No Vlocity components changed" \
    '{result:{status:$status, message:$reason, changedFiles:[], errors:[], warnings:[]}}' \
    > "$SUMMARY_JSON"
  echo "✅ STAGE COMPLETED: Vlocity validation skipped (no changes)"
  exit 0
fi

# ------------------------------------------------------------------------------
# 2) Job file sanity (exists + parses as YAML)
# ------------------------------------------------------------------------------
section "Job file sanity"
if [ ! -f "$JOB_FILE" ]; then
  record_error "Vlocity job file not found at ${JOB_FILE}"
else
  if python3 -c "import yaml; yaml.safe_load(open('${JOB_FILE}'))" >/dev/null 2>&1; then
    record_ok "${JOB_FILE} is valid YAML"
  else
    record_error "${JOB_FILE} is not valid YAML"
  fi
fi

# Fail fast on missing job file — nothing else makes sense without it.
if [ "${#ERRORS[@]}" -gt 0 ]; then
  jq -nc \
    --arg status "Failed" \
    --arg reason "Configuration error" \
    --argjson errors "$(printf '%s\n' "${ERRORS[@]}" | jq -R . | jq -s .)" \
    '{result:{status:$status, message:$reason, errors:$errors}}' \
    > "$SUMMARY_JSON"
  exit 2
fi

# ------------------------------------------------------------------------------
# 3) Per-file structural validation of changed datapack JSONs
#
#    Uses an embedded Python script so we can walk the JSON structure cleanly.
#    The Python prints one line per finding in the form:
#        STATUS|file|message
#    where STATUS ∈ {OK, ERROR, WARN}.
# ------------------------------------------------------------------------------
section "Structural validation of changed datapack files"

# Filter the changed list down to *_DataPack.json files we should validate.
mapfile -t DATAPACK_FILES < <(
  printf '%s\n' "${VLOCITY_CHANGED_LIST}" \
    | grep -E '_DataPack\.json$' \
    || true
)

if [ "${#DATAPACK_FILES[@]}" -eq 0 ]; then
  record_warning "No *_DataPack.json files in delta — only support files changed (still running build check)"
else
  vlocity_log "Validating ${#DATAPACK_FILES[@]} datapack file(s):"
  printf '%s\n' "${DATAPACK_FILES[@]}" | sed 's/^/    • /' | tee -a "$SUMMARY_LOG"

  # NB: we pass the file list on stdin to keep the bash↔python boundary tidy.
  STRUCTURAL_OUTPUT=$(printf '%s\n' "${DATAPACK_FILES[@]}" | python3 - <<'PY' 2>&1
import json
import os
import re
import sys
from pathlib import Path

# Minimum required top-level fields on a Vlocity datapack JSON.
REQUIRED_TOP = ["VlocityDataPackType", "VlocityRecordSObjectType"]

# Per-folder → expected datapack-type prefix. Validates the file lives under
# the right directory. Keys are the immediate parent of the pack folder, i.e.
# the segment after `vlocity/datapacks/`.
FOLDER_TYPE_MAP = {
    "DataRaptor":            ["DataRaptor", "SObject"],
    "OmniScript":            ["OmniScript"],
    "IntegrationProcedure":  ["IntegrationProcedure", "OmniScript"],
    "FlexCard":              ["FlexCard", "OmniUiCard"],
    "VlocityUITemplate":     ["VlocityUITemplate"],
    "VlocityUILayout":       ["VlocityUILayout"],
    "Attribute":             ["Attribute", "AttributeAssignmentRule",
                              "AttributeCategory"],
    "Product2":              ["Product2"],
    "PriceList":             ["PriceList"],
    "Promotion":             ["Promotion"],
    "Catalog":               ["Catalog"],
    "CalculationMatrix":     ["CalculationMatrix", "DecisionMatrix"],
    "CalculationProcedure":  ["CalculationProcedure", "ExpressionSet"],
    "ContextAction":         ["ContextAction"],
    "ContextDimension":      ["ContextDimension"],
    "ContextScope":          ["ContextScope"],
    "EntityFilter":          ["EntityFilter"],
    "ObjectClass":           ["ObjectClass"],
    "ObjectLayout":          ["ObjectLayout"],
    "Rule":                  ["Rule"],
}

# Per-type additional required fields (kept conservative; warn rather than
# error on the optional ones to avoid false positives across managed-package
# versions).
TYPE_REQUIRED = {
    "OmniScript": {
        "error": ["%vlocity_namespace%__Type__c",
                  "%vlocity_namespace%__SubType__c",
                  "%vlocity_namespace%__Language__c"],
        "warn":  [],
    },
    "IntegrationProcedure": {
        "error": ["%vlocity_namespace%__Type__c",
                  "%vlocity_namespace%__SubType__c"],
        "warn":  [],
    },
    "SObject": {  # DRBundle__c / DataRaptors
        "error": [],
        "warn":  ["%vlocity_namespace%__Type__c"],
    },
}

def emit(status, file, msg):
    # Pipe-delimited because messages may contain colons.
    print(f"{status}|{file}|{msg}")

for raw in sys.stdin:
    f = raw.strip()
    if not f:
        continue
    p = Path(f)
    file_had_error = False
    def fail(msg):
        global file_had_error
        file_had_error = True
        emit("ERROR", f, msg)
    if not p.exists():
        fail("file not present on disk")
        continue
    try:
        with open(p, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except json.JSONDecodeError as e:
        fail(f"invalid JSON: {e.msg} (line {e.lineno}, col {e.colno})")
        continue
    except Exception as e:
        fail(f"cannot read: {e}")
        continue

    # Required top-level fields
    missing_top = [k for k in REQUIRED_TOP if k not in data]
    if missing_top:
        fail(f"missing required field(s): {', '.join(missing_top)}")
        # Don't return — continue to surface as many findings as possible.

    dp_type = data.get("VlocityDataPackType", "")
    sobj    = data.get("VlocityRecordSObjectType", "")

    # Folder placement check: vlocity/datapacks/<TypeFolder>/<PackName>/*_DataPack.json
    try:
        parts = p.parts
        idx   = parts.index("datapacks")
        type_folder = parts[idx + 1] if len(parts) > idx + 1 else ""
        pack_folder = parts[idx + 2] if len(parts) > idx + 2 else ""
    except ValueError:
        type_folder = ""
        pack_folder = ""

    if type_folder and type_folder in FOLDER_TYPE_MAP:
        expected = FOLDER_TYPE_MAP[type_folder]
        if dp_type and dp_type not in expected:
            fail(
                f"VlocityDataPackType='{dp_type}' inconsistent with folder "
                f"'{type_folder}/' (expected one of: {', '.join(expected)})")

    # Folder ↔ identifier check
    # Try a few common identifier fields in priority order.
    identifier = (
        data.get("Name") or
        data.get("%vlocity_namespace%__GlobalKey__c") or
        data.get("Title") or
        ""
    )
    if pack_folder and identifier and identifier != pack_folder:
        # Skip the OmniScript case where the folder name is composite
        # (Type_SubType_Language) — that's expected.
        if dp_type in ("OmniScript", "IntegrationProcedure"):
            emit("WARN", f,
                 f"pack folder '{pack_folder}' does not exactly match Name "
                 f"'{identifier}' (acceptable for OmniScript composite names)")
        else:
            fail(
                f"pack folder '{pack_folder}' does not match identifier "
                f"'{identifier}' — they MUST match for vlocity to find the pack")

    # Per-type required fields
    spec = TYPE_REQUIRED.get(dp_type)
    if spec:
        for k in spec["error"]:
            if k not in data:
                fail(f"type='{dp_type}' missing required field '{k}'")
        for k in spec["warn"]:
            if k not in data:
                emit("WARN", f, f"type='{dp_type}' missing recommended field '{k}'")

    # SObject sanity: should reference an SObject ending in __c (custom) OR a
    # known standard object like Product2 / ContentVersion.
    if sobj and not (sobj.endswith("__c") or sobj in {"Product2", "ContentVersion"}):
        emit("WARN", f,
             f"VlocityRecordSObjectType='{sobj}' is not a custom (__c) object "
             f"and not a recognized standard SObject — please double-check")

    # All structural checks passed for this file
    if not file_had_error:
        emit("OK", f, f"type='{dp_type}', sobject='{sobj}'")
PY
)
  RC_STRUCTURAL=$?
  if [ "$RC_STRUCTURAL" -ne 0 ]; then
    record_error "Internal: structural validator exited ${RC_STRUCTURAL}"
  fi

  # Replay the python output line-by-line and route to ok/warn/error.
  while IFS='|' read -r status file message; do
    [ -z "$status" ] && continue
    case "$status" in
      OK)
        record_ok    "$(basename "$file"): ${message}"
        PACK_RESULTS+=("ok|${file}|${message}")
        ;;
      WARN)
        record_warning "$(basename "$file"): ${message}"
        PACK_RESULTS+=("warn|${file}|${message}")
        ;;
      ERROR)
        record_error "$(basename "$file"): ${message}"
        PACK_RESULTS+=("error|${file}|${message}")
        ;;
      *)
        record_warning "(unexpected validator output) ${status}|${file}|${message}"
        ;;
    esac
  done <<< "$STRUCTURAL_OUTPUT"
fi

# ------------------------------------------------------------------------------
# 4) Build-time validation via `vlocity packBuildAllFiles`
#    This catches issues the structural pass cannot:
#      • broken expansions (one of a pack's sibling files is malformed)
#      • cross-pack references that don't resolve
#      • datapack-type-specific compilation issues (e.g. OmniScript LWC compile)
# ------------------------------------------------------------------------------
section "Vlocity Build Tool — packBuildAllFiles (local build check)"

install_vlocity_cli
configure_puppeteer "$ORG_ALIAS"

SF_USERNAME="$(resolve_vlocity_username "$ORG_ALIAS")"

if [ -z "$SF_USERNAME" ]; then
  record_warning "No SF user resolved for alias '${ORG_ALIAS}' — running offline build with -vlocity.namespace ${NAMESPACE_FALLBACK}"
  set +e
  vlocity \
    -vlocity.namespace "$NAMESPACE_FALLBACK" \
    -projectPath "$PROJECT_PATH" \
    -job "$JOB_FILE" \
    packBuildAllFiles \
    --verbose true \
    --simpleLogging true \
    2>&1 | tee "$BUILD_LOG"
  RC_BUILD=${PIPESTATUS[0]}
  set -e
else
  vlocity_log "Building all packs as SFDX user: ${SF_USERNAME}"
  set +e
  vlocity \
    -sfdx.username "$SF_USERNAME" \
    -projectPath "$PROJECT_PATH" \
    -job "$JOB_FILE" \
    packBuildAllFiles \
    --verbose true \
    --simpleLogging true \
    2>&1 | tee "$BUILD_LOG"
  RC_BUILD=${PIPESTATUS[0]}
  set -e
fi

if [ "$RC_BUILD" -eq 0 ]; then
  record_ok "packBuildAllFiles completed (every pack under ${PROJECT_PATH} assembled cleanly)"
else
  record_error "packBuildAllFiles failed (exit ${RC_BUILD}) — see ${BUILD_LOG} for the offending pack(s)"
fi

# ------------------------------------------------------------------------------
# 5) Summary + machine-readable artifact + exit
# ------------------------------------------------------------------------------
section "Summary"
ERR_COUNT=${#ERRORS[@]}
WARN_COUNT=${#WARNINGS[@]}

echo "  Errors   : ${ERR_COUNT}"   | tee -a "$SUMMARY_LOG"
echo "  Warnings : ${WARN_COUNT}"  | tee -a "$SUMMARY_LOG"
echo "  Packs    : ${#DATAPACK_FILES[@]} datapack JSON file(s) checked" | tee -a "$SUMMARY_LOG"

if [ "$ERR_COUNT" -gt 0 ]; then
  FINAL_STATUS="Failed"
  FINAL_EXIT=1
else
  FINAL_STATUS="Succeeded"
  FINAL_EXIT=0
fi

# Build a JSON array of per-pack results
PACKS_JSON="[]"
if [ "${#PACK_RESULTS[@]}" -gt 0 ]; then
  PACKS_JSON=$(
    printf '%s\n' "${PACK_RESULTS[@]}" \
    | awk -F'|' '{printf "{\"status\":\"%s\",\"file\":\"%s\",\"message\":\"%s\"}\n", $1, $2, $3}' \
    | jq -s .
  )
fi

ERRORS_JSON='[]'
[ "${#ERRORS[@]}"   -gt 0 ] && ERRORS_JSON=$(printf '%s\n' "${ERRORS[@]}"   | jq -R . | jq -s .)
WARNINGS_JSON='[]'
[ "${#WARNINGS[@]}" -gt 0 ] && WARNINGS_JSON=$(printf '%s\n' "${WARNINGS[@]}" | jq -R . | jq -s .)

jq -nc \
  --arg status         "$FINAL_STATUS" \
  --arg username       "${SF_USERNAME:-}" \
  --arg jobFile        "$JOB_FILE" \
  --arg projectPath    "$PROJECT_PATH" \
  --argjson returnCode "$FINAL_EXIT" \
  --argjson buildRC    "$RC_BUILD" \
  --argjson packs      "$PACKS_JSON" \
  --argjson errors     "$ERRORS_JSON" \
  --argjson warnings   "$WARNINGS_JSON" \
  '{
     result: {
       status:       $status,
       returnCode:   $returnCode,
       buildExitCode:$buildRC,
       jobFile:      $jobFile,
       projectPath:  $projectPath,
       username:     $username,
       packs:        $packs,
       errors:       $errors,
       warnings:     $warnings
     }
   }' \
  > "$SUMMARY_JSON"

echo ""
if [ "$FINAL_EXIT" -eq 0 ]; then
  echo "✅ STAGE COMPLETED: Vlocity validation passed (${WARN_COUNT} warning(s))"
else
  echo "❌ STAGE FAILED: Vlocity validation found ${ERR_COUNT} error(s) — see above"
fi

exit "$FINAL_EXIT"

#!/bin/bash
# ==============================================================================
# Pre-Flight Orphaned Dependency Scanner
# ==============================================================================
# Scans force-app/ for references to components scheduled for deletion in this
# PR (per delta/destructiveChanges/destructiveChanges.xml). Fails the pipeline
# with a Markdown report listing exact file:line locations the developer must
# clean up before Salesforce will permit deletion.
#
# Outputs:
#   reports/dependency-errors.md   - Markdown block (also auto-injected into
#                                    the executive summary by
#                                    scripts/build_executive_summary.sh).
#
# Bypass (use sparingly, for legitimate false positives):
#   SKIP_DEPENDENCY_SCAN=true ./scripts/scan_dependencies.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_deployment_lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_deployment_lib.sh"

REPORT_FILE="reports/dependency-errors.md"
mkdir -p reports
: > "$REPORT_FILE"

echo ""
echo "🔍 STAGE 3.5: PRE-FLIGHT ORPHANED DEPENDENCY SCAN"
echo "================================================="

if [ "${SKIP_DEPENDENCY_SCAN:-false}" = "true" ]; then
  echo "⚠️  SKIP_DEPENDENCY_SCAN=true — bypassing scan."
  echo "    (Use this only for documented false positives; the dry-run will still catch true breakages.)"
  exit 0
fi

detect_destructive_changes
if [ "${HAS_DESTRUCTIVE_CHANGES:-false}" != "true" ]; then
  echo "ℹ️  No destructive changes in this PR — nothing to scan."
  exit 0
fi

if [ ! -d force-app ]; then
  echo "ℹ️  force-app/ directory not present — nothing to scan."
  exit 0
fi

# Capture the list of files this PR is deleting so the scanner doesn't hit them
# (they're already on their way out and would inflate the report with noise).
DELETED_FILES=""
TARGET_BRANCH="${TARGET_BRANCH:-${GITHUB_BASE_REF:-}}"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1 && [ -n "$TARGET_BRANCH" ]; then
  if git rev-parse --verify "origin/${TARGET_BRANCH}" >/dev/null 2>&1; then
    DELETED_FILES="$(git diff --diff-filter=D --name-only "origin/${TARGET_BRANCH}" HEAD 2>/dev/null || true)"
  fi
fi

# NB: DELETED_FILES can list thousands of paths (e.g. a folder restructure),
# which overflows Linux's per-env-var limit (MAX_ARG_STRLEN, 128KB) and fails
# with "Argument list too long". Stage it in a temp file and let python read it.
DELETED_LIST_FILE="$(mktemp)"
printf '%s' "$DELETED_FILES" > "$DELETED_LIST_FILE"

set +e
SCAN_DELETED_FILES_FILE="$DELETED_LIST_FILE" \
SCAN_DESTRUCTIVE_FILE="$DESTRUCTIVE_CHANGES_FILE" \
SCAN_REPORT_FILE="$REPORT_FILE" \
python3 - <<'PY'
import os, re, sys
import xml.etree.ElementTree as ET
from collections import OrderedDict
from pathlib import Path

destructive_xml = Path(os.environ["SCAN_DESTRUCTIVE_FILE"])
report_path     = Path(os.environ["SCAN_REPORT_FILE"])

deleted_files = set()
_deleted_list_file = os.environ.get("SCAN_DELETED_FILES_FILE")
if _deleted_list_file and os.path.exists(_deleted_list_file):
    with open(_deleted_list_file, encoding="utf-8") as _fh:
        deleted_files = {line.strip() for line in _fh if line.strip()}

ns = {"md": "http://soap.sforce.com/2006/04/metadata"}

# ---- 1. Parse destructive members ------------------------------------------
deleted_members = []  # list of (type, member)
try:
    root = ET.parse(destructive_xml).getroot()
    for t in root.findall("md:types", ns):
        type_name = (t.findtext("md:name", default="", namespaces=ns) or "").strip()
        for m in t.findall("md:members", ns):
            text = (m.text or "").strip()
            if text:
                deleted_members.append((type_name, text))
except Exception as exc:
    print(f"⚠️  Unable to parse destructive XML: {exc}", flush=True)
    sys.exit(0)

if not deleted_members:
    print("ℹ️  Destructive package has no members.", flush=True)
    sys.exit(0)

print(f"📦 {len(deleted_members)} component(s) marked for deletion.", flush=True)
for mt, m in deleted_members:
    print(f"   • {mt}: {m}", flush=True)
print("🔎 Scanning force-app/ for orphaned references…", flush=True)

# ---- 2. Build search patterns ----------------------------------------------
# Strategy:
#   - "Object.Field" form (CustomField): match BOTH the fully-qualified
#     reference (most common in profiles/permsets) AND the bare field name as
#     a whole word (catches layouts, classes, flow XML).
#   - Bare names (CustomObject, ApexClass, Flow, …): match the bare name as a
#     whole word — minimises 20-year-old-org false positives.
#   - LightningComponentBundle / AuraDefinitionBundle members are JS module
#     names; whole-word still works because they're always referenced by name.

def patterns_for(member: str):
    pats = []
    if "." in member:
        pats.append(re.compile(re.escape(member)))                       # full Object.Field
        bare = member.rsplit(".", 1)[-1]
        pats.append(re.compile(rf"\b{re.escape(bare)}\b"))               # bare field name
    else:
        pats.append(re.compile(rf"\b{re.escape(member)}\b"))
    return pats

# Map metadata type → folder under force-app/main/default. We skip the
# component's own folder when searching, otherwise an Object's child fields
# inflate the report with self-references.
TYPE_TO_FOLDER = {
    "CustomObject":             "objects",
    "ApexClass":                "classes",
    "ApexTrigger":              "triggers",
    "ApexPage":                 "pages",
    "ApexComponent":            "components",
    "Flow":                     "flows",
    "LightningComponentBundle": "lwc",
    "AuraDefinitionBundle":     "aura",
    "Profile":                  "profiles",
    "PermissionSet":            "permissionsets",
    "PermissionSetGroup":       "permissionsetgroups",
    "Layout":                   "layouts",
    "FlexiPage":                "flexipages",
    "StaticResource":           "staticresources",
    "Workflow":                 "workflows",
    "EmailTemplate":            "email",
}

# Directories to skip entirely (the component's own home).
own_dirs = set()
for mt, m in deleted_members:
    folder = TYPE_TO_FOLDER.get(mt)
    if folder and "." not in m:
        own_dirs.add(Path("force-app/main/default") / folder / m)

# Build the per-member pattern table once.
member_patterns = []
for mt, m in deleted_members:
    member_patterns.append((mt, m, patterns_for(m)))

# Files we never read.
SKIP_EXT = {
    ".png", ".jpg", ".jpeg", ".gif", ".svg", ".pdf", ".zip", ".jar",
    ".class", ".ico", ".woff", ".woff2", ".ttf", ".eot", ".mp3", ".mp4",
}

# Apex source files. For these, a reference only blocks a Salesforce deletion
# when it is a COMPILE-TIME (static) reference — e.g. List<Obj>, new Obj(),
# inline [SELECT ... FROM Obj], or a typed Obj.Field. Names that appear only
# inside string literals (dynamic SOQL / getGlobalDescribe / SObject.put/get)
# or inside comments are resolved at runtime and do NOT prevent deletion, so we
# must not block on them. We strip strings + comments before matching, but still
# report the ORIGINAL line for context.
APEX_EXT = {".cls", ".trigger"}

def strip_apex(lines):
    """Blank out single-quoted string literals and //, /* */ comments so that
    only real Apex code tokens remain for matching. Returns a list parallel to
    `lines` (same length); original lines are kept separately for the report."""
    out = []
    in_block = False  # inside an unterminated /* ... */
    for line in lines:
        res = []
        i, n = 0, len(line)
        in_str = False
        while i < n:
            c = line[i]
            if in_block:
                end = line.find("*/", i)
                if end == -1:
                    i = n
                else:
                    i = end + 2
                    in_block = False
                continue
            if in_str:
                if c == "\\":
                    i += 2
                    continue
                if c == "'":
                    in_str = False
                i += 1
                continue
            if c == "'":                                   # start string literal
                in_str = True
                i += 1
                continue
            if c == "/" and i + 1 < n and line[i + 1] == "/":   # line comment
                break
            if c == "/" and i + 1 < n and line[i + 1] == "*":   # block comment
                in_block = True
                i += 2
                continue
            res.append(c)
            i += 1
        out.append("".join(res))
    return out

force_app = Path("force-app")
errors = OrderedDict()  # member_key -> {file_path: [(lineno, content), …]}

# ---- 3. Walk + scan --------------------------------------------------------
for path in force_app.rglob("*"):
    if not path.is_file():
        continue
    if path.suffix.lower() in SKIP_EXT:
        continue

    rel = str(path)

    if rel in deleted_files:
        continue

    # Skip files inside an own_dir (component's own folder).
    if any(d in path.parents or path == d for d in own_dirs):
        continue
    if any(rel.startswith(str(d) + os.sep) for d in own_dirs):
        continue

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.readlines()
    except Exception:
        continue

    # For Apex, match against a stripped copy (strings/comments removed) so only
    # compile-time references count; everything else matches the raw line.
    if path.suffix.lower() in APEX_EXT:
        match_lines = strip_apex(lines)
    else:
        match_lines = lines

    # For each line, check all patterns. A line counts at most once per member.
    # We match on `scanline` (possibly stripped) but report the ORIGINAL line.
    for i, (line, scanline) in enumerate(zip(lines, match_lines), 1):
        for mt, m, pats in member_patterns:
            for p in pats:
                if p.search(scanline):
                    key = f"{mt}: {m}" if mt else m
                    errors.setdefault(key, OrderedDict()).setdefault(rel, []).append(
                        (i, line.rstrip())
                    )
                    break  # don't double-count this member on this line

if not errors:
    print("✅ Codebase is clean. No orphaned references found.", flush=True)
    sys.exit(0)

# ---- 4. Markdown report ----------------------------------------------------
report_path.parent.mkdir(parents=True, exist_ok=True)
with open(report_path, "w", encoding="utf-8") as out:
    out.write("### 🛑 DEPLOYMENT BLOCKED — Orphaned References Detected\n\n")
    out.write(
        "Your PR deletes the components below, but they are **still referenced** "
        "elsewhere in the codebase. Salesforce will refuse the deletion until every "
        "reference is removed. Please clean up each file/line listed and push again.\n\n"
    )
    for member_key, files in errors.items():
        total_lines = sum(len(v) for v in files.values())
        out.write(f"#### ⚠️ References to `{member_key}`\n\n")
        out.write(f"_Found in **{len(files)} file(s)**, **{total_lines} line(s)**:_\n\n")
        out.write("```text\n")
        for fp, hits in files.items():
            for lineno, content in hits:
                snippet = content.strip()
                if len(snippet) > 160:
                    snippet = snippet[:157] + "…"
                out.write(f"{fp}:{lineno}: {snippet}\n")
        out.write("```\n\n")
    out.write("---\n\n")
    out.write(
        "<sub>To bypass this check for a documented false positive, set "
        "<code>SKIP_DEPENDENCY_SCAN=true</code> as a workflow env var on a re-run. "
        "The Salesforce dry-run will still catch true breakages downstream.</sub>\n"
    )

print("", flush=True)
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", flush=True)
print("💥 DEPLOYMENT BLOCKED — Orphaned references detected", flush=True)
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", flush=True)
for member_key, files in errors.items():
    total_lines = sum(len(v) for v in files.values())
    print("", flush=True)
    print(
        f"❌ {member_key}  →  {total_lines} reference(s) in {len(files)} file(s)",
        flush=True,
    )
    for fp, hits in files.items():
        for lineno, content in hits:
            snippet = content.strip()
            if len(snippet) > 110:
                snippet = snippet[:107] + "…"
            print(f"      ↳ {fp}:{lineno}  |  {snippet}", flush=True)
print("", flush=True)
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", flush=True)
print("👉 ACTION: remove the references above, commit, and re-push.", flush=True)
print(f"📄 Same report posted to PR comment + saved at {report_path}", flush=True)
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", flush=True)
sys.exit(1)
PY
EXIT_CODE=$?
set -e
rm -f "$DELETED_LIST_FILE"

# Mirror the Markdown report into the run's step summary so it surfaces on the
# Actions UI even before the executive-summary step runs.
if [ "$EXIT_CODE" -ne 0 ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -s "$REPORT_FILE" ]; then
  cat "$REPORT_FILE" >> "$GITHUB_STEP_SUMMARY"
fi

exit "$EXIT_CODE"

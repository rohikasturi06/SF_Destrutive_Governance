#!/usr/bin/env bash
# ==============================================================================
# Resolve Parameterized Test Execution Inputs
# ==============================================================================
# Single source of truth for the "Salesforce Quality Gate Orchestrator"
# pipeline. Resolves the Apex test level, specified test classes, target
# environment, and execution mode (validate vs dry-run) from one of three
# user-input vectors, then enforces all platform & policy guardrails.
#
# Resolution precedence (highest first):
#   1. workflow_dispatch form inputs   (typed: choice/boolean/string)
#   2. Applied PR label                (test-level:<Level>)
#   3. Checked markdown checkbox        (in the PR body)
#   4. RunLocalTests                    (safe default)
#
# SECURITY (Phase 4.1): untrusted PR text is read ONLY from $GITHUB_EVENT_PATH
# via jq into shell variables. This script must be invoked with user-controlled
# values passed through environment variables — never interpolated by the caller
# directly into a shell line. Outputs are written to $GITHUB_OUTPUT (when set)
# and echoed for local testing.
#
# Inputs (environment variables):
#   EVENT_NAME            github.event_name (pull_request | workflow_dispatch)
#   GITHUB_EVENT_PATH     path to the event payload JSON (PR events)
#   INPUT_TEST_LEVEL      workflow_dispatch: chosen test level
#   INPUT_SPECIFIED_TESTS workflow_dispatch: comma/space separated classes
#   INPUT_TARGET_ENV      workflow_dispatch: sandbox-dev|sandbox-uat|production
#   TARGET_BRANCH         base ref of the PR (pull_request events)
#   MAX_TESTS_HEADER_BYTES  override the 8 KB guardrail (default 8192)
#
# Outputs (KEY=VALUE -> $GITHUB_OUTPUT + stdout):
#   TEST_LEVEL  SPECIFIED_TESTS  TARGET_ENV  EXECUTION_MODE
# ==============================================================================

set -euo pipefail

EVENT_NAME="${EVENT_NAME:-}"
GITHUB_EVENT_PATH="${GITHUB_EVENT_PATH:-}"
TARGET_BRANCH="${TARGET_BRANCH:-}"
MAX_TESTS_HEADER_BYTES="${MAX_TESTS_HEADER_BYTES:-8192}"   # 8 KB REST header cap

VALID_LEVELS="NoTestRun RunSpecifiedTests RunLocalTests RunAllTestsInOrg"

die() { echo "::error::$*" >&2; exit 1; }
info() { echo "$*" >&2; }

emit() { # name value  -> GITHUB_OUTPUT (if set) and stdout
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
  printf '%s=%s\n' "$1" "$2"
}

is_valid_level() {
  case " $VALID_LEVELS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# Read the PR body / labels safely from the event payload (never from CLI args).
read_pr_body() {
  [ -n "$GITHUB_EVENT_PATH" ] && [ -f "$GITHUB_EVENT_PATH" ] || { echo ""; return; }
  jq -r '.pull_request.body // ""' "$GITHUB_EVENT_PATH" 2>/dev/null || echo ""
}
read_pr_labels() {
  [ -n "$GITHUB_EVENT_PATH" ] && [ -f "$GITHUB_EVENT_PATH" ] || { echo ""; return; }
  jq -r '.pull_request.labels[]?.name // empty' "$GITHUB_EVENT_PATH" 2>/dev/null || echo ""
}

# Extract the class list that follows the "Specified Target Apex Classes" header.
# Stops at the next blank line, bold header, checkbox, or closing code fence so a
# malformed body cannot run away. Code-fence markers are stripped.
extract_specified_tests() {
  local body="$1"
  printf '%s\n' "$body" \
    | awk '
        f==1 {
          if ($0 ~ /^[[:space:]]*```/)      { next }
          if ($0 ~ /^[[:space:]]*$/)        { exit }
          if ($0 ~ /^[[:space:]]*\*\*/)     { exit }
          if ($0 ~ /^[[:space:]]*- \[/)     { exit }
          print
        }
        /Specified Target Apex Classes/ { f=1 }
      ' \
    | tr ',' ' ' | tr '\n' ' ' | tr -s ' ' \
    | sed 's/^ *//; s/ *$//'
}

# ------------------------------------------------------------------------------
# Step 1: Resolve raw values from the active input vector
# ------------------------------------------------------------------------------
RESOLVED_LEVEL="RunLocalTests"
RESOLVED_TESTS=""
RESOLVED_ENV="sandbox-dev"
# How the level was chosen: dispatch | label | checkbox | default. Consumers use
# this to decide whether to OVERRIDE a pipeline's own default test strategy
# (they should only override when a level was explicitly selected).
SELECTION_SOURCE="default"

if [ "$EVENT_NAME" = "workflow_dispatch" ]; then
  info "🎛  Resolving parameters from manual workflow_dispatch inputs"
  RESOLVED_LEVEL="${INPUT_TEST_LEVEL:-RunLocalTests}"
  RESOLVED_TESTS="${INPUT_SPECIFIED_TESTS:-}"
  RESOLVED_ENV="${INPUT_TARGET_ENV:-sandbox-dev}"
  SELECTION_SOURCE="dispatch"
else
  info "🔎 Resolving parameters from pull_request event"

  # 1a. PR labels (highest precedence among PR signals).
  PR_LABELS="$(read_pr_labels)"
  LABEL_MATCH=""
  if printf '%s\n' "$PR_LABELS" | grep -q '^test-level:NoTestRun$'; then
    LABEL_MATCH="NoTestRun"
  elif printf '%s\n' "$PR_LABELS" | grep -q '^test-level:RunSpecifiedTests$'; then
    LABEL_MATCH="RunSpecifiedTests"
  elif printf '%s\n' "$PR_LABELS" | grep -q '^test-level:RunAllTestsInOrg$'; then
    LABEL_MATCH="RunAllTestsInOrg"
  elif printf '%s\n' "$PR_LABELS" | grep -q '^test-level:RunLocalTests$'; then
    LABEL_MATCH="RunLocalTests"
  fi

  PR_BODY="$(read_pr_body)"
  # Normalize "[X]" -> "[x]" so either casing of a checked box is recognized.
  PR_BODY="$(printf '%s' "$PR_BODY" | sed 's/- \[X\]/- [x]/g')"

  if [ -n "$LABEL_MATCH" ]; then
    info "🏷  Matched level via label: $LABEL_MATCH"
    RESOLVED_LEVEL="$LABEL_MATCH"
    SELECTION_SOURCE="label"
  else
    # 1b. Markdown checkbox parsing (fixed-string match; brackets are literal).
    info "🧾 No label match — evaluating PR body checkboxes"
    if   printf '%s' "$PR_BODY" | grep -qF -- '- [x] `- [ ] NoTestRun`'; then
      RESOLVED_LEVEL="NoTestRun"; SELECTION_SOURCE="checkbox"
    elif printf '%s' "$PR_BODY" | grep -qF -- '- [x] `- [ ] RunSpecifiedTests`'; then
      RESOLVED_LEVEL="RunSpecifiedTests"; SELECTION_SOURCE="checkbox"
    elif printf '%s' "$PR_BODY" | grep -qF -- '- [x] `- [ ] RunAllTestsInOrg`'; then
      RESOLVED_LEVEL="RunAllTestsInOrg"; SELECTION_SOURCE="checkbox"
    elif printf '%s' "$PR_BODY" | grep -qF -- '- [x] `- [ ] RunLocalTests`'; then
      RESOLVED_LEVEL="RunLocalTests"; SELECTION_SOURCE="checkbox"
    else
      info "ℹ️  No checkbox checked — defaulting to RunLocalTests"
    fi
  fi

  # Specified tests are only meaningful for RunSpecifiedTests.
  if [ "$RESOLVED_LEVEL" = "RunSpecifiedTests" ]; then
    RESOLVED_TESTS="$(extract_specified_tests "$PR_BODY")"
  fi

  # Map the PR's base branch to a target environment.
  #   main        -> production
  #   release/**  -> sandbox-uat
  #   everything  -> sandbox-dev
  case "$TARGET_BRANCH" in
    main|refs/heads/main)            RESOLVED_ENV="production" ;;
    release/*|refs/heads/release/*)  RESOLVED_ENV="sandbox-uat" ;;
    *)                               RESOLVED_ENV="sandbox-dev" ;;
  esac
fi

# Normalize the test list to a single-space-separated string of class names.
RESOLVED_TESTS="$(printf '%s' "$RESOLVED_TESTS" | tr ',' ' ' | tr -s ' \t' ' ' | sed 's/^ *//; s/ *$//')"

info "   • test_level     = $RESOLVED_LEVEL"
info "   • target_env     = $RESOLVED_ENV"
info "   • specified_tests= ${RESOLVED_TESTS:-<none>}"

# ------------------------------------------------------------------------------
# Step 2: Guardrails
# ------------------------------------------------------------------------------
is_valid_level "$RESOLVED_LEVEL" \
  || die "Unknown test level '$RESOLVED_LEVEL'. Allowed: $VALID_LEVELS"

# 2a. Target-environment policy matrix.
#   Sandbox    -> { NoTestRun, RunSpecifiedTests, RunLocalTests, RunAllTestsInOrg }
#   Production -> {            RunSpecifiedTests, RunLocalTests, RunAllTestsInOrg }
case "$RESOLVED_ENV" in
  production)
    PERMITTED="RunSpecifiedTests RunLocalTests RunAllTestsInOrg" ;;
  sandbox-dev|sandbox-uat)
    PERMITTED="$VALID_LEVELS" ;;
  *)
    die "Unknown target environment '$RESOLVED_ENV'." ;;
esac
case " $PERMITTED " in
  *" $RESOLVED_LEVEL "*) : ;;
  *) die "Test level '$RESOLVED_LEVEL' is not permitted for target '$RESOLVED_ENV'. Production requires a minimum of RunLocalTests for Apex; NoTestRun is restricted to sandboxes." ;;
esac

# 2b. RunSpecifiedTests must declare at least one class.
if [ "$RESOLVED_LEVEL" = "RunSpecifiedTests" ] && [ -z "$RESOLVED_TESTS" ]; then
  die "RunSpecifiedTests was selected but no target test classes were provided. List them under '**Specified Target Apex Classes ...**' (PR body) or the dispatch 'specified_tests' field."
fi

# 2c. 8 KB REST header guardrail for the --tests parameter.
#     Header length = sum(len(class_i)) + (n - 1)  == length of the comma-joined
#     string. Exceeding the cap triggers HTTP 431 before the runner is reached.
if [ "$RESOLVED_LEVEL" = "RunSpecifiedTests" ] && [ -n "$RESOLVED_TESTS" ]; then
  # shellcheck disable=SC2086
  set -- $RESOLVED_TESTS
  TEST_COUNT="$#"
  JOINED="$(printf '%s' "$RESOLVED_TESTS" | tr ' ' ',')"
  HEADER_BYTES="$(printf '%s' "$JOINED" | wc -c | tr -d ' ')"
  info "🧮 RunSpecifiedTests header check: ${TEST_COUNT} class(es), ${HEADER_BYTES} bytes (cap ${MAX_TESTS_HEADER_BYTES})"
  if [ "$HEADER_BYTES" -ge "$MAX_TESTS_HEADER_BYTES" ]; then
    die "The --tests parameter is ${HEADER_BYTES} bytes (>= ${MAX_TESTS_HEADER_BYTES} / 8 KB) and will trigger an HTTP 431 (Request Header Fields Too Large). Group the classes into an Apex Test Suite and use --suite-names with RunLocalTests/RunAllTestsInOrg, or split this validation into smaller runs."
  fi
fi

# 2d. Execution mode: NoTestRun cannot run under `deploy validate`, so it maps to
#     `deploy start --dry-run`. All other levels run under `deploy validate`.
if [ "$RESOLVED_LEVEL" = "NoTestRun" ]; then
  EXEC_MODE="dry-run"
else
  EXEC_MODE="validate"
fi
info "⚙️  execution_mode = $EXEC_MODE"

# ------------------------------------------------------------------------------
# Step 3: Emit resolved, validated outputs
# ------------------------------------------------------------------------------
emit "TEST_LEVEL"       "$RESOLVED_LEVEL"
emit "SPECIFIED_TESTS"  "$RESOLVED_TESTS"
emit "TARGET_ENV"       "$RESOLVED_ENV"
emit "EXECUTION_MODE"   "$EXEC_MODE"
emit "SELECTION_SOURCE" "$SELECTION_SOURCE"

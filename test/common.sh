# Shared harness setup for prep-compact's suites: sandboxed HOME and fixtures,
# PASS/FAIL counters, assertions, and the hook runners. Sourced by run-tests.sh,
# which owns SCRIPT_DIR, shell options and the final guards.

[[ -n "${SCRIPT_DIR:-}" ]] || { printf 'test/common.sh: source this from run-tests.sh, do not run it directly\n' >&2; exit 1; }

HOOK="$SCRIPT_DIR/../hooks/check-context-size.sh"
TEST_DIR="$(mktemp -d 2>/dev/null || printf '/tmp/prep-compact-test-%s' "$$")"
mkdir -p "$TEST_DIR/fixtures"
# Copy static fixtures into a sandboxed working area
for fx in transcript-usage.jsonl transcript-malformed-tail.jsonl ups-real.json; do
  if [[ -f "$SCRIPT_DIR/fixtures/$fx" ]]; then
    cp "$SCRIPT_DIR/fixtures/$fx" "$TEST_DIR/fixtures/$fx"
  fi
done
# v3 fixtures
for fx in stop-real.json transcript-handoff-multi-turn.jsonl transcript-handoff-no-user-text.jsonl transcript-handoff-tool-blob.jsonl transcript-handoff-oversized-line.jsonl handoff-prior.json; do
  if [[ -f "$SCRIPT_DIR/fixtures/$fx" ]]; then
    cp "$SCRIPT_DIR/fixtures/$fx" "$TEST_DIR/fixtures/$fx"
  fi
done
FIX="$TEST_DIR/fixtures"

# Sandboxed HOME so the hook's ~/.claude/cache expansion lands INSIDE the
# harness, not in the real live-sessions cache.
SANDBOX_HOME="$TEST_DIR/sandbox-home"
CACHE="$SANDBOX_HOME/.claude/cache"
mkdir -p "$CACHE"

FAIL=0
PASS=0

# Python resolution: mirror the hook. Tests invoke python for fixture
# generation.
if command -v python3 >/dev/null 2>&1; then
  PY=python3
elif command -v python >/dev/null 2>&1 && python -c 'import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)' 2>/dev/null; then
  PY=python
else
  printf 'run-tests: Python 3 not found on PATH (tried python3 and python).\n' >&2
  exit 1
fi

# --- T-0: real-fixture gate. Codex r4 mandate.
# Stop-hook tests require a captured Stop event payload to ensure schema parity.
# - Missing fixture: skip Stop-hook tests with explicit message (local dev only).
# - Malformed fixture (parse fail OR missing required keys): hard-fail.
# - $CI set: any skip is treated as a failure.
# NOTE: stop-real.json shipped is synthetic (matches Claude Code hook schema).
# Replace with a real captured payload before claiming Stop-hook coverage in CI.
STOP_FIXTURE_OK=0
STOP_FIXTURE_REASON=""
if [[ -f "$FIX/stop-real.json" ]]; then
  # Pipe via stdin (not path arg) so MSYS paths don't reach Windows Python.
  if "$PY" -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    print(f'parse-fail: {e}', file=sys.stderr); sys.exit(2)
required = {'session_id','transcript_path','cwd','permission_mode','hook_event_name'}
missing = required - set(d.keys())
if missing:
    print(f'missing-keys: {sorted(missing)}', file=sys.stderr); sys.exit(2)
if d.get('hook_event_name') != 'Stop':
    print(f'wrong-event: {d.get(\"hook_event_name\")!r}', file=sys.stderr); sys.exit(2)
" <"$FIX/stop-real.json" 2>/dev/null; then
    STOP_FIXTURE_OK=1
  else
    printf 'FAIL: T-0 stop-real.json present but malformed\n' >&2
    exit 2
  fi
else
  STOP_FIXTURE_REASON="missing test/fixtures/stop-real.json — capture from a live session before claiming Stop-hook coverage"
  if [[ -n "${CI:-}" ]]; then
    printf 'FAIL: T-0 in CI: %s\n' "$STOP_FIXTURE_REASON" >&2
    exit 2
  fi
  printf 'SKIP: T-0 gate: %s\n' "$STOP_FIXTURE_REASON" >&2
fi

# CLAUDE_CODE_SESSION_ID is cleared so the UPS hook's env-first safe_sid
# derivation falls through to the stdin session_id these tests supply (the real
# session id leaks into the harness env otherwise). Env-first behaviour is
# exercised by calling the hook directly with the var set (T-84/T-85).
run_hook() {
  local stdin=$1; shift
  printf '%s' "$stdin" | CLAUDE_CODE_SESSION_ID= HOME="$SANDBOX_HOME" bash "$HOOK" "$@" 2>/dev/null
}

# Variant that preserves stderr so tests can capture warn messages. T-14 needs
# this because run_hook above silences stderr by design to keep expected-silent
# tests clean.
run_hook_err() {
  local stdin=$1; shift
  printf '%s' "$stdin" | CLAUDE_CODE_SESSION_ID= HOME="$SANDBOX_HOME" bash "$HOOK" "$@"
}

assert_eq() {
  local name=$1 expected=$2 actual=$3
  if [[ "$expected" == "$actual" ]]; then
    printf 'PASS: %s\n' "$name"; PASS=$((PASS+1))
  else
    printf 'FAIL: %s\n  expected: <%s>\n  actual:   <%s>\n' "$name" "$expected" "$actual" >&2
    FAIL=$((FAIL+1))
  fi
}

assert_true() {
  local name=$1 cond=$2
  if eval "$cond"; then
    printf 'PASS: %s\n' "$name"; PASS=$((PASS+1))
  else
    printf 'FAIL: %s (cond: %s)\n' "$name" "$cond" >&2
    FAIL=$((FAIL+1))
  fi
}

cleanup() {
  rm -rf "$CACHE"
  mkdir -p "$CACHE"
}

# Helper: write a transcript fixture line-by-line to a temp path.
make_transcript() {
  local path=$1; shift
  : >"$path"
  for line in "$@"; do
    printf '%s\n' "$line" >>"$path"
  done
}

# Helper: convert MSYS path -> mixed-form Windows path (forward slashes,
# drive letter prefix) so the harness's Windows-native Python can open files
# written under sandbox $HOME, AND the resulting string is safe to embed in
# Python code (no backslash-escape pitfalls like "\U..."). cygpath -m yields
# e.g. "C:/Users/.../handoff.json". No-op on Linux/macOS.
to_native() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1" 2>/dev/null || printf '%s' "$1"
  else
    printf '%s' "$1"
  fi
}

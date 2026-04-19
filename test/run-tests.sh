#!/usr/bin/env bash
# Test harness for check-context-size.sh.
# Explicit PASS count: false-green is blocked by a final assertion on $PASS == expected.

set -uo pipefail

# Resolve paths relative to this script so the harness works both in-repo
# (bash test/run-tests.sh from plugin root) and from arbitrary CWDs.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/check-context-size.sh"
TEST_DIR="$(mktemp -d 2>/dev/null || printf '/tmp/prep-compact-test-%s' "$$")"
# Seed fixtures from the in-repo copies so CI / clean checkouts work without
# requiring Task-0-style prior fixture capture.
mkdir -p "$TEST_DIR/fixtures"
if [[ -f "$SCRIPT_DIR/fixtures/ups-real.json" ]]; then
  cp "$SCRIPT_DIR/fixtures/ups-real.json" "$TEST_DIR/fixtures/ups-real.json"
fi
FIX=$TEST_DIR/fixtures
# Sandboxed HOME so the hook's ~/.claude/cache expansion lands INSIDE the
# harness, not in the real live-sessions cache. Previous versions used
# ~/.claude/cache directly; the harness cleanup() then wiped flags belonging
# to real sessions and caused the production hook to re-fire reminders.
SANDBOX_HOME="$TEST_DIR/sandbox-home"
CACHE="$SANDBOX_HOME/.claude/cache"

mkdir -p "$FIX" "$CACHE"
FAIL=0
PASS=0
# Expected pass count depends on whether the platform supports real symlinks
# for tests 25/26 (Windows Git Bash makes ln -s create text files; `[[ -L ]]`
# returns false; the symlink-defense tests are skipped on those platforms).
case "${OSTYPE:-}" in
  msys*|cygwin*|win32) EXPECTED_PASS=68 ;;  # skip tests 25 + 26 (4 assertions)
  *)                   EXPECTED_PASS=72 ;;
esac

make_random_file() { head -c "$2" </dev/urandom >"$1"; }

run_hook() {
  local stdin=$1; shift
  # HOME=$SANDBOX_HOME makes the hook's ~/.claude/cache resolve inside our
  # sandbox instead of the live user cache.
  printf '%s' "$stdin" | HOME="$SANDBOX_HOME" bash "$HOOK" "$@" 2>/dev/null
}

run_hook_stderr() {
  local stdin=$1; shift
  local errfile; errfile=$(mktemp)
  printf '%s' "$stdin" | HOME="$SANDBOX_HOME" bash "$HOOK" "$@" 2>"$errfile" >/dev/null
  printf '%s' "$errfile"
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

cleanup() { rm -f "$CACHE"/compact-level-* 2>/dev/null || true; }

# --- 1: below threshold + state absent -> no-op
cleanup
make_random_file "$FIX/small.jsonl" 500
OUT=$(CLAUDE_CONTEXT_WARN_BYTES=1000 run_hook '{"session_id":"s1","transcript_path":"'"$FIX/small.jsonl"'"}')
assert_eq "below+absent -> silent" "" "$OUT"

# --- 2: above soft threshold + state absent -> soft reminder + level file
cleanup
make_random_file "$FIX/big.jsonl" 2000
OUT=$(CLAUDE_CONTEXT_WARN_BYTES=1000 run_hook '{"session_id":"s2","transcript_path":"'"$FIX/big.jsonl"'"}')
assert_true "above+absent -> reminder contains 'prep-compact'" '[[ "$OUT" == *"prep-compact"* ]]'
assert_true "above+absent -> soft reminder carries level=soft marker" '[[ "$OUT" == *"level=soft"* ]]'
assert_true "above+absent -> level file created" '[[ -e "$CACHE/compact-level-s2" ]]'
assert_eq "above+absent -> level file content == 'soft'" "soft" "$(cat "$CACHE/compact-level-s2" | tr -d '[:space:]')"
# Soft body copy regression guards — catches silent rewording that would
# weaken the prompt-layer gate (e.g. dropping "Informational only" or the
# "do not treat this reminder as the user's request" clause).
assert_true "soft body: 'Informational only' phrase" '[[ "$OUT" == *"Informational only"* ]]'
assert_true "soft body: 'do not treat this reminder as the user' phrase" '[[ "$OUT" == *"Do not treat this reminder as the user"* ]]'

# --- 3: above threshold + state=soft -> silent (same-level, no upgrade)
OUT=$(CLAUDE_CONTEXT_WARN_BYTES=1000 run_hook '{"session_id":"s2","transcript_path":"'"$FIX/big.jsonl"'"}')
assert_eq "above+same-level -> silent" "" "$OUT"

# --- 4: below threshold + state present -> state cleared (stale-level cleanup)
# The below-threshold branch clears the state file so the next above-threshold
# crossing fires a fresh reminder. Covers the threshold-change scenario where
# a user raises CLAUDE_CONTEXT_WARN_BYTES after an earlier warning was emitted.
cleanup
printf 'soft\n' >"$CACHE/compact-level-s4"
OUT=$(CLAUDE_CONTEXT_WARN_BYTES=1000 run_hook '{"session_id":"s4","transcript_path":"'"$FIX/small.jsonl"'"}')
assert_true "below+present -> stale level cleared" '[[ ! -e "$CACHE/compact-level-s4" ]]'

# --- 5: RESET scope — deletes only the target level file
cleanup
printf 'soft\n' >"$CACHE/compact-level-target"
printf 'soft\n' >"$CACHE/compact-level-bystander"
run_hook '{"session_id":"target"}' RESET >/dev/null
assert_true "RESET -> target deleted" '[[ ! -e "$CACHE/compact-level-target" ]]'
assert_true "RESET -> bystander intact" '[[ -e "$CACHE/compact-level-bystander" ]]'
rm -f "$CACHE/compact-level-bystander"

# --- 6: missing transcript -> no-op, exit 0
OUT=$(run_hook '{"session_id":"s6","transcript_path":"/tmp/nope.jsonl"}'); RC=$?
assert_eq "missing transcript -> silent" "" "$OUT"
# Fail-open integration sanity folded in here:
printf '' | bash "$HOOK" >/dev/null 2>&1; EMPTY_RC=$?
assert_eq "empty stdin -> exit 0" "0" "$EMPTY_RC"

# --- 7: malformed JSON -> no-op
OUT=$(run_hook 'not json'); assert_eq "malformed JSON -> silent" "" "$OUT"

# --- 8: exotic session_id (path traversal) -> safe filename
cleanup
make_random_file "$FIX/big.jsonl" 2000
OUT=$(CLAUDE_CONTEXT_WARN_BYTES=1000 run_hook '{"session_id":"../../../evil","transcript_path":"'"$FIX/big.jsonl"'"}' 2>/dev/null)
# No level file escaped the cache dir
ESCAPED=$(find "$SANDBOX_HOME/.claude" -path "$CACHE" -prune -o -name 'compact-level-*' -print 2>/dev/null | head -n 1)
assert_eq "path traversal -> no escaped level file" "" "$ESCAPED"

# --- 9: oversized session_id -> hashed fallback, not raw name
cleanup
LONG=$(printf 'a%.0s' {1..200})
OUT=$(CLAUDE_CONTEXT_WARN_BYTES=1000 run_hook "{\"session_id\":\"$LONG\",\"transcript_path\":\"$FIX/big.jsonl\"}" 2>/dev/null)
assert_true "oversized sid -> not used raw" '[[ ! -e "$CACHE/compact-level-$LONG" ]]'
SHA1=$(python -c "import hashlib; print(hashlib.sha1(b'$LONG').hexdigest())")
assert_true "oversized sid -> hash level file created" '[[ -e "$CACHE/compact-level-$SHA1" ]]'

# --- 10: env var override lowers threshold
cleanup
make_random_file "$FIX/medium.jsonl" 1500
OUT=$(CLAUDE_CONTEXT_WARN_BYTES=2000 run_hook '{"session_id":"s10","transcript_path":"'"$FIX/medium.jsonl"'"}')
assert_eq "env override (threshold 2000, 1500b) -> silent" "" "$OUT"
cleanup
OUT=$(CLAUDE_CONTEXT_WARN_BYTES=1000 run_hook '{"session_id":"s10b","transcript_path":"'"$FIX/medium.jsonl"'"}')
assert_true "env override (threshold 1000, 1500b) -> reminder" '[[ "$OUT" == *"prep-compact"* ]]'

# --- 11: real Task 0 payload parity
cleanup
if [[ -s "$FIX/ups-real.json" ]]; then
  # If Task 0 transcript path no longer exists, build a stand-in.
  REAL_TP=$(python -c "import json,sys; print(json.load(sys.stdin).get('transcript_path',''))" <"$FIX/ups-real.json")
  if [[ -z "$REAL_TP" || ! -r "$REAL_TP" ]]; then
    cp "$FIX/big.jsonl" "$FIX/real-standin.jsonl"
    # Use minified JSON (separators=(',',':')) to match Claude Code's actual
    # stdin shape. Python's default dumps adds ": " spaces; CC and the hook's
    # bash fallback both expect no spaces around the field separator.
    REAL_JSON=$(python -c "import json,sys; d=json.load(sys.stdin); d['transcript_path']='$FIX/real-standin.jsonl'; print(json.dumps(d, separators=(',', ':')))" <"$FIX/ups-real.json")
  else
    REAL_JSON=$(cat "$FIX/ups-real.json")
  fi
  OUT=$(CLAUDE_CONTEXT_WARN_BYTES=1 run_hook "$REAL_JSON")
  assert_true "real UPS payload -> reminder" '[[ "$OUT" == *"prep-compact"* ]]'
else
  # If Task 0 skipped fixture capture (e.g. spike aborted), fail loud.
  printf 'FAIL: ups-real.json missing — Task 0 did not capture real fixture\n' >&2
  FAIL=$((FAIL+1))
fi

# --- 12: empty session_id logs stderr + creates no level file
cleanup
ERRFILE=$(run_hook_stderr '{"session_id":"","transcript_path":"'"$FIX/big.jsonl"'"}')
assert_true "empty session_id -> stderr contains 'empty/unparseable'" 'grep -q "empty/unparseable session_id" "$ERRFILE"'
assert_true "empty session_id -> no level file created" '! ls "$CACHE"/compact-level-* 2>/dev/null | grep -q .'
rm -f "$ERRFILE"

# --- 14: CLAUDE_PLUGIN_DATA overrides the cache-dir fallback
cleanup
PDATA="$TEST_DIR/plugin-data"
rm -rf "$PDATA" 2>/dev/null
mkdir -p "$PDATA"
make_random_file "$FIX/big.jsonl" 2000
printf '%s' '{"session_id":"s14","transcript_path":"'"$FIX/big.jsonl"'"}' \
  | CLAUDE_PLUGIN_DATA="$PDATA" CLAUDE_CONTEXT_WARN_BYTES=1000 HOME="$SANDBOX_HOME" bash "$HOOK" 2>/dev/null >/dev/null
assert_true "CLAUDE_PLUGIN_DATA -> level file created inside plugin data dir" '[[ -e "$PDATA/compact-level-s14" ]]'
assert_true "CLAUDE_PLUGIN_DATA -> no level file in fallback cache" '[[ ! -e "$CACHE/compact-level-s14" ]]'

# --- 17: pure-bash fallback (PREP_COMPACT_DISABLE_PYTHON=1) happy path
cleanup
make_random_file "$FIX/big.jsonl" 2000
OUT=$(printf '%s' "{\"session_id\":\"s17\",\"transcript_path\":\"$FIX/big.jsonl\"}" \
  | CLAUDE_CONTEXT_WARN_BYTES=1000 PREP_COMPACT_DISABLE_PYTHON=1 HOME="$SANDBOX_HOME" bash "$HOOK" 2>/dev/null)
assert_true "fallback: above+absent -> reminder" '[[ "$OUT" == *"prep-compact"* ]]'
assert_true "fallback: above+absent -> level file created" '[[ -e "$CACHE/compact-level-s17" ]]'

# --- 18: pure-bash fallback + oversized session_id -> sha1sum/shasum hash fallback, not raw
cleanup
LONG_SID=$(printf 'b%.0s' {1..200})
OUT=$(printf '%s' "{\"session_id\":\"$LONG_SID\",\"transcript_path\":\"$FIX/big.jsonl\"}" \
  | CLAUDE_CONTEXT_WARN_BYTES=1000 PREP_COMPACT_DISABLE_PYTHON=1 HOME="$SANDBOX_HOME" bash "$HOOK" 2>/dev/null)
assert_true "fallback: oversized sid not used raw" '[[ ! -e "$CACHE/compact-level-$LONG_SID" ]]'
# Compute expected hash the same way the hook's sha1_hex does (prefer sha1sum, else shasum).
if command -v sha1sum >/dev/null 2>&1; then
  EXPECTED_HASH=$(printf '%s' "$LONG_SID" | sha1sum | cut -d' ' -f1)
elif command -v shasum >/dev/null 2>&1; then
  EXPECTED_HASH=$(printf '%s' "$LONG_SID" | shasum -a 1 | cut -d' ' -f1)
else
  EXPECTED_HASH=""
fi
if [[ -n "$EXPECTED_HASH" ]]; then
  assert_true "fallback: oversized sid -> sha1 hash level file created" '[[ -e "$CACHE/compact-level-$EXPECTED_HASH" ]]'
else
  # Harness is running on a box with neither sha1sum nor shasum — assert the
  # tr-truncation path produced *some* level file under the cache dir.
  LEVELS=$(find "$CACHE" -name 'compact-level-*' 2>/dev/null | wc -l | tr -d ' ')
  assert_true "fallback: oversized sid -> truncation level file created (no sha1/shasum)" '[[ "$LEVELS" -gt 0 ]]'
fi

# --- 19: pure-bash fallback extraction — unit tests of the grep+sed pipeline.
# Split into two focused assertions to avoid JSON-escaping-inside-shell-quoting
# contortions. Covers: (a) sed un-escape of JSON '\\' -> '\' (used on Windows
# transcript_paths), and (b) grep -oE first-match behavior (so a prompt field
# with an embedded "session_id":"..." substring doesn't spoof the real one).
INPUT_19A='C:\\Users\\koen\\big.jsonl'
OUTPUT_19A=$(printf '%s' "$INPUT_19A" | sed 's|\\\\|\\|g')
assert_eq "fallback: sed un-escapes JSON backslash-backslash to single backslash" 'C:\Users\koen\big.jsonl' "$OUTPUT_19A"
INPUT_19B='"session_id":"real","dummy":"y","session_id":"fake"'
OUTPUT_19B=$(printf '%s' "$INPUT_19B" | grep -oE '"session_id":"[^"]*"' | head -n 1 | sed 's/^"session_id":"//;s/"$//')
assert_eq "fallback: grep -oE + head -n 1 picks first session_id" "real" "$OUTPUT_19B"

# --- 13: cache-dir mkdir failure logs stderr (force by pointing HOME at a non-creatable path)
cleanup
ERRFILE=$(mktemp)
# /dev/null/x cannot be mkdir-p'd; HOME= override makes ~/.claude/cache expand under it.
printf '%s' '{"session_id":"s13","transcript_path":"'"$FIX/big.jsonl"'"}' | HOME=/dev/null/x bash "$HOOK" 2>"$ERRFILE" >/dev/null
assert_true "mkdir fail -> stderr 'cannot create'" 'grep -q "cannot create" "$ERRFILE"'
rm -f "$ERRFILE"

# --- 15: threshold change — stale low-threshold state clears when a higher
# threshold is applied. Regression guard for the `CLAUDE_CONTEXT_WARN_BYTES`
# config-change scenario.
cleanup
make_random_file "$FIX/medium.jsonl" 1500
OUT=$(CLAUDE_CONTEXT_WARN_BYTES=1000 run_hook '{"session_id":"s15","transcript_path":"'"$FIX/medium.jsonl"'"}')
assert_true "low-threshold crossing creates level file" '[[ -e "$CACHE/compact-level-s15" ]]'
# Raise threshold above current bytes (1500 < 2000): level should clear.
OUT=$(CLAUDE_CONTEXT_WARN_BYTES=2000 run_hook '{"session_id":"s15","transcript_path":"'"$FIX/medium.jsonl"'"}')
assert_true "raised threshold > bytes -> stale level cleared" '[[ ! -e "$CACHE/compact-level-s15" ]]'

# --- 16: above-threshold -> RESET -> above-threshold rewarns. End-to-end
# PostCompact re-arming check (complements test 5 which only checks RESET scope).
cleanup
make_random_file "$FIX/big.jsonl" 2000
OUT1=$(CLAUDE_CONTEXT_WARN_BYTES=1000 run_hook '{"session_id":"s16","transcript_path":"'"$FIX/big.jsonl"'"}')
assert_true "first crossing emits reminder" '[[ "$OUT1" == *"prep-compact"* ]]'
run_hook '{"session_id":"s16"}' RESET >/dev/null
assert_true "RESET cleared level" '[[ ! -e "$CACHE/compact-level-s16" ]]'
OUT2=$(CLAUDE_CONTEXT_WARN_BYTES=1000 run_hook '{"session_id":"s16","transcript_path":"'"$FIX/big.jsonl"'"}')
assert_true "second crossing after RESET emits fresh reminder" '[[ "$OUT2" == *"prep-compact"* ]]'

# --- 20: Option A delta-tracking — PostCompact with transcript_path writes
# baseline; UPS with bytes == baseline (delta 0) stays silent; bytes > baseline
# + threshold fires a NEW reminder. Regression guard for the append-only
# transcript problem where absolute-threshold would nag every turn post-compact.
cleanup
make_random_file "$FIX/growing.jsonl" 2500
# PostCompact records baseline = 2500
printf '%s' "{\"session_id\":\"s20\",\"transcript_path\":\"$FIX/growing.jsonl\"}" \
  | HOME="$SANDBOX_HOME" bash "$HOOK" RESET 2>/dev/null
assert_true "RESET writes baseline file" '[[ -e "$CACHE/compact-baseline-s20" ]]'
SAVED_BASELINE=$(cat "$CACHE/compact-baseline-s20" 2>/dev/null | tr -d '[:space:]')
assert_eq "baseline content matches transcript bytes at RESET" "2500" "$SAVED_BASELINE"
# UPS with unchanged transcript: delta=0, below threshold, silent
OUT=$(printf '%s' "{\"session_id\":\"s20\",\"transcript_path\":\"$FIX/growing.jsonl\"}" \
  | CLAUDE_CONTEXT_WARN_BYTES=1000 HOME="$SANDBOX_HOME" bash "$HOOK" 2>/dev/null)
assert_eq "post-RESET, bytes==baseline (delta 0) -> silent" "" "$OUT"
# Grow transcript to baseline + 1500 (delta 1500, above threshold 1000): fire
head -c 4000 </dev/urandom >"$FIX/growing.jsonl"
OUT=$(printf '%s' "{\"session_id\":\"s20\",\"transcript_path\":\"$FIX/growing.jsonl\"}" \
  | CLAUDE_CONTEXT_WARN_BYTES=1000 HOME="$SANDBOX_HOME" bash "$HOOK" 2>/dev/null)
assert_true "post-RESET, delta above threshold -> reminder fires" '[[ "$OUT" == *"prep-compact"* ]]'
assert_true "post-RESET reminder mentions delta vs baseline" '[[ "$OUT" == *"since last compact"* ]]'

# --- 21: pathless RESET with pre-existing baseline preserves the baseline and
# clears the level file. Documents the v0.2.0 behavior where a PostCompact event
# without transcript_path in stdin cannot refresh the baseline — known
# limitation, but at least the level-clear path still runs so the next above-
# delta-threshold crossing will fire correctly (relative to old baseline).
# Also covers Codex r2 ask: "pathless PostCompact clearing both flags" — with
# single-state model the level file replaces both soft+hard flags.
cleanup
printf '%s\n' 2500 >"$CACHE/compact-baseline-s21"
printf 'critical\n' >"$CACHE/compact-level-s21"
printf '%s' '{"session_id":"s21"}' | HOME="$SANDBOX_HOME" bash "$HOOK" RESET 2>/dev/null
assert_true "pathless RESET clears level file (regardless of prior level value)" '[[ ! -e "$CACHE/compact-level-s21" ]]'
PRESERVED=$(cat "$CACHE/compact-baseline-s21" 2>/dev/null | tr -d '[:space:]')
assert_eq "pathless RESET preserves existing baseline" "2500" "$PRESERVED"

# --- 22: BYTES < BASELINE (unexpected but defensively handled — e.g.
# transcript rotation). Hook treats DELTA = BYTES (falls back to absolute-
# threshold semantics for this prompt) rather than a negative delta.
cleanup
make_random_file "$FIX/small-after-baseline.jsonl" 500
printf '%s\n' 5000 >"$CACHE/compact-baseline-s22"
# bytes=500 < baseline=5000; delta treated as 500. threshold=1000 -> below, silent.
OUT=$(printf '%s' "{\"session_id\":\"s22\",\"transcript_path\":\"$FIX/small-after-baseline.jsonl\"}" \
  | CLAUDE_CONTEXT_WARN_BYTES=1000 HOME="$SANDBOX_HOME" bash "$HOOK" 2>/dev/null)
assert_eq "bytes<baseline: delta=bytes, below threshold -> silent" "" "$OUT"

# --- 23: malformed baseline file is ignored (treated as baseline=0)
cleanup
printf 'not-a-number\n' >"$CACHE/compact-baseline-s23"
make_random_file "$FIX/big.jsonl" 2000
OUT=$(printf '%s' "{\"session_id\":\"s23\",\"transcript_path\":\"$FIX/big.jsonl\"}" \
  | CLAUDE_CONTEXT_WARN_BYTES=1000 HOME="$SANDBOX_HOME" bash "$HOOK" 2>/dev/null)
assert_true "malformed baseline -> ignored, absolute-threshold fires" '[[ "$OUT" == *"prep-compact"* ]]'

# --- 24: invalid CLAUDE_CONTEXT_WARN_BYTES / CLAUDE_CONTEXT_CRITICAL_BYTES
# doesn't crash the hook (fail-open guarantee); logs stderr and falls back to
# the default. Covers non-digit strings, leading-zero literals (would be read
# as invalid octal by bash arithmetic), floats, negatives.
cleanup
make_random_file "$FIX/big.jsonl" 2000
for BAD in "not-a-number" "08" "3.14" "-1"; do
  ERRFILE=$(mktemp)
  printf '%s' "{\"session_id\":\"s24\",\"transcript_path\":\"$FIX/big.jsonl\"}" \
    | CLAUDE_CONTEXT_WARN_BYTES="$BAD" HOME="$SANDBOX_HOME" bash "$HOOK" 2>"$ERRFILE"
  EXIT_24=$?
  assert_eq "bad CLAUDE_CONTEXT_WARN_BYTES=$BAD -> hook exits 0" "0" "$EXIT_24"
  assert_true "bad CLAUDE_CONTEXT_WARN_BYTES=$BAD -> stderr warns 'ignoring invalid'" 'grep -q "ignoring invalid CLAUDE_CONTEXT_WARN_BYTES" "$ERRFILE"'
  rm -f "$ERRFILE"
done
# Single-value smoke test for CRITICAL invalid: hook still exits 0 and warns.
cleanup
ERRFILE=$(mktemp)
printf '%s' "{\"session_id\":\"s24c\",\"transcript_path\":\"$FIX/big.jsonl\"}" \
  | CLAUDE_CONTEXT_CRITICAL_BYTES="bogus" HOME="$SANDBOX_HOME" bash "$HOOK" 2>"$ERRFILE"
EXIT_24C=$?
assert_eq "bad CLAUDE_CONTEXT_CRITICAL_BYTES=bogus -> hook exits 0" "0" "$EXIT_24C"
assert_true "bad CLAUDE_CONTEXT_CRITICAL_BYTES=bogus -> stderr warns 'ignoring invalid'" 'grep -q "ignoring invalid CLAUDE_CONTEXT_CRITICAL_BYTES" "$ERRFILE"'
rm -f "$ERRFILE"

# --- 27: critical threshold fires auto-invoke reminder + writes level=critical
cleanup
make_random_file "$FIX/huge.jsonl" 4000
OUT=$(CLAUDE_CONTEXT_WARN_BYTES=1000 CLAUDE_CONTEXT_CRITICAL_BYTES=2000 \
  run_hook '{"session_id":"s27","transcript_path":"'"$FIX/huge.jsonl"'"}')
assert_true "hard crossing: output carries level=critical marker" '[[ "$OUT" == *"level=critical"* ]]'
assert_true "hard crossing: level file exists" '[[ -e "$CACHE/compact-level-s27" ]]'
assert_eq "hard crossing: level file content == 'critical'" "critical" "$(cat "$CACHE/compact-level-s27" | tr -d '[:space:]')"
# Critical body copy regression guards — catches silent rewording that would
# lose the urgency phrase or the auto-invoke instruction.
assert_true "critical body: 'critically high' phrase" '[[ "$OUT" == *"critically high"* ]]'
assert_true "critical body: 'Invoke the prep-compact skill' phrase" '[[ "$OUT" == *"Invoke the prep-compact skill"* ]]'

# --- 28: stale-critical re-arm after CRITICAL raised. Regression guard for the
# Codex r2 finding: with two-flag bookkeeping, a user who raised CRITICAL
# after the hard fired would never see the hard reminder again for that cycle.
# Single-state model downgrades silently when delta drops below the current
# level's threshold, so the next genuine crossing re-fires cleanly.
cleanup
make_random_file "$FIX/growing.jsonl" 1500
# Phase 1: SOFT=500, CRITICAL=1000, bytes=1500 -> target=critical.
OUT1=$(CLAUDE_CONTEXT_WARN_BYTES=500 CLAUDE_CONTEXT_CRITICAL_BYTES=1000 \
  run_hook '{"session_id":"s28","transcript_path":"'"$FIX/growing.jsonl"'"}')
assert_true "phase 1: critical emitted" '[[ "$OUT1" == *"level=critical"* ]]'
# Phase 2: user raises CRITICAL to 2000. bytes=1500 still > SOFT=500 but <
# CRITICAL=2000 -> target=soft. Current state=critical -> downgrade SILENTLY.
OUT2=$(CLAUDE_CONTEXT_WARN_BYTES=500 CLAUDE_CONTEXT_CRITICAL_BYTES=2000 \
  run_hook '{"session_id":"s28","transcript_path":"'"$FIX/growing.jsonl"'"}')
assert_eq "phase 2: silent (downgrade)" "" "$OUT2"
assert_eq "phase 2: level file downgraded to 'soft'" "soft" "$(cat "$CACHE/compact-level-s28" | tr -d '[:space:]')"
# Phase 3: transcript grows past new CRITICAL=2000. target=critical again,
# current=soft -> upgrade fires hard reminder.
head -c 2500 </dev/urandom >"$FIX/growing.jsonl"
OUT3=$(CLAUDE_CONTEXT_WARN_BYTES=500 CLAUDE_CONTEXT_CRITICAL_BYTES=2000 \
  run_hook '{"session_id":"s28","transcript_path":"'"$FIX/growing.jsonl"'"}')
assert_true "phase 3: critical re-emitted after rise" '[[ "$OUT3" == *"level=critical"* ]]'

# --- 29: invalid threshold ordering (CRITICAL <= WARN) disables hard for the
# turn with a stderr warning. Hook must not silently swap (which would mask
# the config error). Covers both `<` and `==` cases.
cleanup
make_random_file "$FIX/big.jsonl" 2000
# 29a: CRITICAL < WARN
ERRFILE=$(mktemp)
OUT=$(printf '%s' "{\"session_id\":\"s29a\",\"transcript_path\":\"$FIX/big.jsonl\"}" \
  | CLAUDE_CONTEXT_WARN_BYTES=1000 CLAUDE_CONTEXT_CRITICAL_BYTES=500 \
    HOME="$SANDBOX_HOME" bash "$HOOK" 2>"$ERRFILE")
assert_true "CRITICAL<WARN: stderr warns 'must exceed'" 'grep -q "must exceed CLAUDE_CONTEXT_WARN_BYTES" "$ERRFILE"'
assert_true "CRITICAL<WARN: hard disabled -> soft reminder emitted" '[[ "$OUT" == *"level=soft"* ]]'
rm -f "$ERRFILE"
# 29b: CRITICAL == WARN (boundary; the hook's `<=` check must reject equality too).
cleanup
ERRFILE=$(mktemp)
OUT=$(printf '%s' "{\"session_id\":\"s29b\",\"transcript_path\":\"$FIX/big.jsonl\"}" \
  | CLAUDE_CONTEXT_WARN_BYTES=1000 CLAUDE_CONTEXT_CRITICAL_BYTES=1000 \
    HOME="$SANDBOX_HOME" bash "$HOOK" 2>"$ERRFILE")
assert_true "CRITICAL==WARN: stderr warns 'must exceed'" 'grep -q "must exceed CLAUDE_CONTEXT_WARN_BYTES" "$ERRFILE"'
assert_true "CRITICAL==WARN: hard disabled -> soft reminder emitted" '[[ "$OUT" == *"level=soft"* ]]'
rm -f "$ERRFILE"

# Tests 25 + 26 exercise the symlink-poisoning defenses. They require real
# POSIX symlinks (ln -s → `lrwxrwxrwx`). Windows Git Bash without the
# MSYS=winsymlinks:nativestrict env setting makes ln -s create text files,
# which defeats the `[[ -L ]]` check used in the defense. CI Linux runs the
# tests; Windows CI and local Windows dev skip them.
case "${OSTYPE:-}" in
  msys*|cygwin*|win32)
    # Symlink defense tested on Linux CI; skip on Windows. +0 assertions here.
    :
    ;;
  *)
    # --- 25: LEVEL_FILE symlink-poisoning attempt refused (security).
    cleanup
    VICTIM_25=$(mktemp)
    printf 'original-content\n' >"$VICTIM_25"
    ln -sfn "$VICTIM_25" "$CACHE/compact-level-s25"
    make_random_file "$FIX/big.jsonl" 2000
    ERRFILE=$(mktemp)
    printf '%s' "{\"session_id\":\"s25\",\"transcript_path\":\"$FIX/big.jsonl\"}" \
      | CLAUDE_CONTEXT_WARN_BYTES=1000 HOME="$SANDBOX_HOME" bash "$HOOK" 2>"$ERRFILE" >/dev/null
    assert_true "LEVEL-symlink attack: stderr logs refusal" 'grep -q "refusing to .* symlink" "$ERRFILE"'
    assert_eq "LEVEL-symlink attack: victim file unchanged" "original-content" "$(cat "$VICTIM_25")"
    rm -f "$VICTIM_25" "$CACHE/compact-level-s25" "$ERRFILE"

    # --- 26: BASELINE_FILE symlink-poisoning attempt refused during RESET.
    cleanup
    VICTIM_26=$(mktemp)
    printf 'original-content\n' >"$VICTIM_26"
    ln -sfn "$VICTIM_26" "$CACHE/compact-baseline-s26"
    make_random_file "$FIX/big.jsonl" 2000
    ERRFILE=$(mktemp)
    printf '%s' "{\"session_id\":\"s26\",\"transcript_path\":\"$FIX/big.jsonl\"}" \
      | HOME="$SANDBOX_HOME" bash "$HOOK" RESET 2>"$ERRFILE" >/dev/null
    assert_true "BASELINE-symlink attack: stderr logs refusal" 'grep -q "refusing to write through symlink" "$ERRFILE"'
    assert_eq "BASELINE-symlink attack: victim file unchanged" "original-content" "$(cat "$VICTIM_26")"
    rm -f "$VICTIM_26" "$CACHE/compact-baseline-s26" "$ERRFILE"
    ;;
esac

cleanup
rm -f "$FIX/transcript-"*.jsonl "$FIX/real-standin.jsonl" "$FIX/growing.jsonl" "$FIX/small-after-baseline.jsonl" "$FIX/huge.jsonl" "$CACHE"/compact-baseline-* 2>/dev/null

printf '\n'
if [[ "$FAIL" -eq 0 && "$PASS" -eq "$EXPECTED_PASS" ]]; then
  printf 'All %d assertions passed\n' "$PASS"
  exit 0
elif [[ "$FAIL" -eq 0 ]]; then
  printf 'FALSE-GREEN GUARD: expected %d passes, got %d — likely a skipped test\n' "$EXPECTED_PASS" "$PASS" >&2
  exit 2
else
  printf '%d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi

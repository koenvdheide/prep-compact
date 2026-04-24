#!/usr/bin/env bash
# Test harness for prep-compact v2.0.0 check-context-size.sh (token-only).
# Explicit PASS count: false-green blocked by final EXPECTED_PASS guard.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/check-context-size.sh"
TEST_DIR="$(mktemp -d 2>/dev/null || printf '/tmp/prep-compact-test-%s' "$$")"
mkdir -p "$TEST_DIR/fixtures"
# Copy static fixtures into a sandboxed working area
for fx in transcript-usage.jsonl transcript-malformed-tail.jsonl ups-real.json; do
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
# EXPECTED_PASS MUST equal the exact count of assert_eq + assert_true calls.
# Tally (T-1..T-20):  3+2+2+2+2+2+2+1+1+1+2+2+2+1+8+2+2+1+1+6 = 45
# Tally (snapshot fast-path; T-23 collapsed, T-25/T-27/T-28/T-29a absent):
#   T-21(2) + T-22(2) + T-23(2) + T-24(1) + T-29b(1) = 8
# Tally (writer; W-5, W-4a, W-4b, W-3 sanity-check absent):
#   W-1(1) + W-2(1) + W-3(1) + W-4(1) = 4
# Total: 45 + 8 + 4 = 57
EXPECTED_PASS=57

# Python resolution: mirror the hook. Tests invoke python for fixture
# generation and SHA-1 hashing.
if command -v python3 >/dev/null 2>&1; then
  PY=python3
elif command -v python >/dev/null 2>&1 && python -c 'import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)' 2>/dev/null; then
  PY=python
else
  printf 'run-tests: Python 3 not found on PATH (tried python3 and python).\n' >&2
  exit 1
fi

run_hook() {
  local stdin=$1; shift
  printf '%s' "$stdin" | HOME="$SANDBOX_HOME" USERPROFILE="$SANDBOX_HOME" bash "$HOOK" "$@" 2>/dev/null
}

# Variant that preserves stderr so tests can capture warn messages. T-14 and
# T-15 need this because run_hook above silences stderr by design to keep
# expected-silent tests clean.
run_hook_err() {
  local stdin=$1; shift
  printf '%s' "$stdin" | HOME="$SANDBOX_HOME" USERPROFILE="$SANDBOX_HOME" bash "$HOOK" "$@"
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

# Snapshot-path helpers.
# SNAP_DIR is the bash view of the snapshot dir; bash file tests handle
# Git Bash /tmp/ aliases fine, so [[ -f "$SNAP_DIR/foo.json" ]] works.
# Python I/O cannot — Windows-native python.exe cannot open /tmp/...
# Writer and hook's inline Python both compute paths via os.path.expanduser,
# and HOME+USERPROFILE are overridden below so expanduser lands in-sandbox.
# Test-side Python read-backs use `snap_python` to get the same behavior.
SNAP_DIR="$SANDBOX_HOME/.claude/cache/prep-compact-snapshots"
WRITER="$SCRIPT_DIR/../scripts/write_context_snapshot.py"

# Invoke Python with HOME+USERPROFILE pointed at the sandbox so
# os.path.expanduser('~') resolves to the same place as the writer/hook use.
snap_python() {
  HOME="$SANDBOX_HOME" USERPROFILE="$SANDBOX_HOME" "$PY" "$@"
}

# Emit "mtime_ns size" (one line) for a transcript file. Inline cygpath -w
# bridges Git Bash /c/... paths to Windows-native form so native python.exe
# can stat them; no-op on Linux/macOS where cygpath is absent.
get_transcript_meta() {
  local path=$1
  if command -v cygpath >/dev/null 2>&1; then
    path=$(cygpath -w "$1" 2>/dev/null || printf '%s' "$1")
  fi
  "$PY" -c 'import os,sys; s=os.stat(sys.argv[1]); print(s.st_mtime_ns, s.st_size)' "$path"
}

# Write a snapshot fixture for a given session and transcript, matching the
# transcript's current mtime_ns + size so the fast path accepts it. Use
# write_snapshot_raw() to force a deliberate mismatch.
write_snapshot_for() {
  local safe_sid=$1 tokens=$2 transcript=$3 mtime size
  read -r mtime size < <(get_transcript_meta "$transcript")
  write_snapshot_raw "$safe_sid" "$tokens" "$mtime" "$size"
}

write_snapshot_raw() {
  local safe_sid=$1 tokens=$2 mtime_ns=$3 size=$4
  mkdir -p "$SNAP_DIR"
  "$PY" -c '
import json, sys
d = {"current_context_tokens": int(sys.argv[1]),
     "transcript_mtime_ns":    int(sys.argv[2]),
     "transcript_size":        int(sys.argv[3])}
with open(sys.argv[4], "w", encoding="utf-8") as f: json.dump(d, f)
' "$tokens" "$mtime_ns" "$size" "$SNAP_DIR/$safe_sid.json"
}

# Read a single snapshot field via the same expanduser computation the
# writer/hook use. Returns empty on any error.
read_snapshot_field() {
  snap_python -c '
import json, os, sys
p = os.path.join(os.path.expanduser("~"), ".claude", "cache", "prep-compact-snapshots", sys.argv[1]+".json")
try:
    with open(p) as f: d = json.load(f)
    print(d.get(sys.argv[2], ""))
except Exception: pass
' "$1" "$2" 2>/dev/null
}

# Invoke the writer script with stdin JSON. Sandboxed env so expanduser
# lands inside SANDBOX_HOME.
run_writer() {
  printf '%s' "$1" | snap_python "$WRITER" 2>/dev/null
}

# --- T-1: token count above threshold -> reminder fires with token message
cleanup
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=200000 run_hook '{"session_id":"s1","transcript_path":"'"$FIX/transcript-usage.jsonl"'"}')
assert_true "T-1: above threshold -> reminder fires" '[[ "$OUT" == *"prep-compact"* ]]'
assert_true "T-1: message names tokens not bytes" '[[ "$OUT" == *"tokens"* ]] && [[ "$OUT" != *"bytes"* ]]'
assert_true "T-1: flag file written" '[[ -e "$CACHE/compact-warned-s1" ]]'

# --- T-2: token count below threshold with stale flag -> silent + flag cleared
cleanup
: >"$CACHE/compact-warned-s2"
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=300000 run_hook '{"session_id":"s2","transcript_path":"'"$FIX/transcript-usage.jsonl"'"}')
assert_eq "T-2: below threshold -> silent" "" "$OUT"
assert_true "T-2: stale flag cleared" '[[ ! -e "$CACHE/compact-warned-s2" ]]'

# --- T-3: isSidechain: true is newest usage line -> earlier main-chain line used
cleanup
MAIN_A='{"message":{"role":"assistant","usage":{"input_tokens":5,"cache_creation_input_tokens":99995,"cache_read_input_tokens":0}}}'
SIDECHAIN='{"isSidechain":true,"message":{"role":"assistant","usage":{"input_tokens":10,"cache_creation_input_tokens":888888,"cache_read_input_tokens":0}}}'
make_transcript "$FIX/t3.jsonl" "$MAIN_A" "$SIDECHAIN"
# MAIN_A sums to 100000; sidechain-skip means token path returns 100000.
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=50000 run_hook '{"session_id":"s3","transcript_path":"'"$FIX/t3.jsonl"'"}')
assert_true "T-3: sidechain skipped, earlier main-chain used, reminder fires" '[[ "$OUT" == *"prep-compact"* ]]'
assert_true "T-3: reminder reports N=100000 not sidechain huge value" '[[ "$OUT" == *"100000"* ]]'

# --- T-4: isApiErrorMessage: true is newest usage line -> earlier main-chain line used
cleanup
API_ERR='{"isApiErrorMessage":true,"message":{"role":"assistant","usage":{"input_tokens":10,"cache_creation_input_tokens":999999,"cache_read_input_tokens":0}}}'
make_transcript "$FIX/t4.jsonl" "$MAIN_A" "$API_ERR"
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=50000 run_hook '{"session_id":"s4","transcript_path":"'"$FIX/t4.jsonl"'"}')
assert_true "T-4: api-error skipped, earlier main-chain used, reminder fires" '[[ "$OUT" == *"prep-compact"* ]]'
assert_true "T-4: reminder reports N=100000 not api-error huge value" '[[ "$OUT" == *"100000"* ]]'

# --- T-5: no .message.usage in file (pre-first-turn) -> silent, no flag
cleanup
USER_MSG='{"message":{"role":"user","content":"hello"}}'
make_transcript "$FIX/t5.jsonl" "$USER_MSG"
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=1 run_hook '{"session_id":"s5","transcript_path":"'"$FIX/t5.jsonl"'"}')
assert_eq "T-5: pre-first-turn -> silent" "" "$OUT"
assert_true "T-5: no flag written" '[[ ! -e "$CACHE/compact-warned-s5" ]]'

# --- T-6: malformed last usage line -> earlier valid line used
cleanup
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=200000 run_hook '{"session_id":"s6","transcript_path":"'"$FIX/transcript-malformed-tail.jsonl"'"}')
assert_true "T-6: malformed tail skipped, earlier valid line used" '[[ "$OUT" == *"prep-compact"* ]]'
assert_true "T-6: reminder reports N=250010" '[[ "$OUT" == *"250010"* ]]'

# --- T-7: missing transcript_path -> silent
cleanup
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=1 run_hook '{"session_id":"s7","transcript_path":"/nonexistent/path/xyz.jsonl"}')
assert_eq "T-7: missing transcript_path -> silent" "" "$OUT"
assert_true "T-7: no flag written" '[[ ! -e "$CACHE/compact-warned-s7" ]]'

# --- T-8: empty stdin -> silent
cleanup
OUT=$(run_hook '' 2>/dev/null)
assert_eq "T-8: empty stdin -> silent" "" "$OUT"

# --- T-9: malformed stdin JSON -> silent
cleanup
OUT=$(run_hook '{not valid json' 2>/dev/null)
assert_eq "T-9: malformed stdin -> silent" "" "$OUT"

# --- T-10: path traversal session_id -> no flag escapes cache dir
cleanup
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=1 run_hook '{"session_id":"../../../evil","transcript_path":"'"$FIX/transcript-usage.jsonl"'"}' 2>/dev/null)
ESCAPED=$(find "$SANDBOX_HOME/.claude" -path "$CACHE" -prune -o -name 'compact-warned-*' -print 2>/dev/null | head -n 1)
assert_eq "T-10: path traversal -> no escaped flag" "" "$ESCAPED"

# --- T-11: oversized session_id -> SHA-1 hex fallback
cleanup
LONG=$(printf 'a%.0s' {1..200})
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=1 run_hook "{\"session_id\":\"$LONG\",\"transcript_path\":\"$FIX/transcript-usage.jsonl\"}" 2>/dev/null)
assert_true "T-11: oversized sid -> raw name NOT used" '[[ ! -e "$CACHE/compact-warned-$LONG" ]]'
SHA1=$("$PY" -c "import hashlib; print(hashlib.sha1(b'$LONG').hexdigest())")
assert_true "T-11: oversized sid -> hash flag created" '[[ -e "$CACHE/compact-warned-$SHA1" ]]'

# --- T-12: empty session_id -> silent, no flag
cleanup
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=1 run_hook '{"session_id":"","transcript_path":"'"$FIX/transcript-usage.jsonl"'"}' 2>/dev/null)
assert_eq "T-12: empty sid -> silent" "" "$OUT"
ANY_FLAG=$(find "$CACHE" -name 'compact-warned-*' 2>/dev/null | head -n 1)
assert_eq "T-12: empty sid -> no flag created" "" "$ANY_FLAG"

# --- T-13: CLAUDE_PLUGIN_DATA override -> flag written there
cleanup
OVERRIDE_DIR="$TEST_DIR/alt-cache"
mkdir -p "$OVERRIDE_DIR"
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=1 CLAUDE_PLUGIN_DATA="$OVERRIDE_DIR" run_hook '{"session_id":"s13","transcript_path":"'"$FIX/transcript-usage.jsonl"'"}' 2>/dev/null)
assert_true "T-13: override dir -> flag written there" '[[ -e "$OVERRIDE_DIR/compact-warned-s13" ]]'
assert_true "T-13: override dir -> no flag in fallback cache" '[[ ! -e "$CACHE/compact-warned-s13" ]]'

# --- T-14: mkdir failure on cache dir -> stderr warn, hook disabled this turn
cleanup
# Point CLAUDE_PLUGIN_DATA at a path whose parent is a regular file,
# making mkdir -p fail. Create a file to serve as the obstruction.
OBSTRUCTION="$TEST_DIR/obstructed"
printf 'not a dir\n' >"$OBSTRUCTION"
# Use run_hook_err to preserve stderr for the warn-message assertion.
ERR=$(CLAUDE_CONTEXT_WARN_TOKENS=1 CLAUDE_PLUGIN_DATA="$OBSTRUCTION/nope" run_hook_err '{"session_id":"s14","transcript_path":"'"$FIX/transcript-usage.jsonl"'"}' 2>&1 >/dev/null)
assert_true "T-14: mkdir failure -> stderr warn" '[[ "$ERR" == *"cannot create"* ]]'

# --- T-15: bad CLAUDE_CONTEXT_WARN_TOKENS -> default substituted, stderr warn
for BAD in "not-a-number" "08" "3.14" "-1"; do
  cleanup
  # Use run_hook_err to capture stderr for the warn-message assertion.
  ERR=$(CLAUDE_CONTEXT_WARN_TOKENS="$BAD" run_hook_err '{"session_id":"s15","transcript_path":"'"$FIX/transcript-usage.jsonl"'"}' 2>&1 >/dev/null)
  assert_true "T-15[$BAD]: invalid env -> stderr warn 'ignoring invalid'" '[[ "$ERR" == *"ignoring invalid"* ]]'
  # Default 450000 > 250000 fixture -> silent (no reminder on stdout)
  OUT=$(CLAUDE_CONTEXT_WARN_TOKENS="$BAD" run_hook '{"session_id":"s15b","transcript_path":"'"$FIX/transcript-usage.jsonl"'"}' 2>/dev/null)
  assert_eq "T-15[$BAD]: default 450000 substituted -> silent on 250000 fixture" "" "$OUT"
done

# --- T-16: raise threshold above current N -> stale flag cleared
cleanup
# First fire: TOKENS=100000 < N=250000 -> flag written
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=100000 run_hook '{"session_id":"s16","transcript_path":"'"$FIX/transcript-usage.jsonl"'"}')
assert_true "T-16: initial fire -> flag written" '[[ -e "$CACHE/compact-warned-s16" ]]'
# Raise threshold above N
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=500000 run_hook '{"session_id":"s16","transcript_path":"'"$FIX/transcript-usage.jsonl"'"}')
assert_true "T-16: raised threshold -> stale flag cleared" '[[ ! -e "$CACHE/compact-warned-s16" ]]'

# --- T-17: role != 'assistant' is newest -> earlier assistant line used
cleanup
USER_WITH_USAGE='{"message":{"role":"user","usage":{"input_tokens":10,"cache_creation_input_tokens":888888,"cache_read_input_tokens":0}}}'
make_transcript "$FIX/t17.jsonl" "$MAIN_A" "$USER_WITH_USAGE"
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=50000 run_hook '{"session_id":"s17","transcript_path":"'"$FIX/t17.jsonl"'"}')
assert_true "T-17: non-assistant usage skipped, earlier assistant used" '[[ "$OUT" == *"prep-compact"* ]]'
assert_true "T-17: reminder reports main-chain N=100000" '[[ "$OUT" == *"100000"* ]]'

# --- T-18: oversized last line > tail cap -> silent no-op (not a rescue)
# Codex r2 flagged that a single JSONL record > 256 KB at the end of the
# transcript straddles the tail cap. Our tail window contains only a
# mid-string slice of that oversized record; prior lines are outside the
# window and NOT recoverable. Correct behavior: silent no-op. This test
# guards that we fail-open (not crash, not return garbage).
cleanup
EARLIER_VALID='{"message":{"role":"assistant","usage":{"input_tokens":10,"cache_creation_input_tokens":123446,"cache_read_input_tokens":0}}}'
PAD=$("$PY" -c "print('A' * 300000)")  # 300 KB of A pushes the record past the 256 KB tail cap
OVERSIZED="{\"message\":{\"role\":\"assistant\",\"content\":\"$PAD\",\"usage\":{\"input_tokens\":10,\"cache_creation_input_tokens\":50000,\"cache_read_input_tokens\":0}}}"
make_transcript "$FIX/t18.jsonl" "$EARLIER_VALID" "$OVERSIZED"
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=1 run_hook '{"session_id":"s18","transcript_path":"'"$FIX/t18.jsonl"'"}')
assert_eq "T-18: oversized straddling last record -> silent no-op" "" "$OUT"

# --- T-19: real UserPromptSubmit payload shape parity
# Exercises the live-captured UPS stdin fixture so stdin-shape regressions are
# caught. Swaps the real transcript_path with a known token-bearing fixture
# so the test is deterministic across machines.
cleanup
if [[ -s "$FIX/ups-real.json" ]]; then
  cp "$FIX/transcript-usage.jsonl" "$FIX/real-standin.jsonl"
  REAL_JSON=$("$PY" -c "import json,sys; d=json.load(sys.stdin); d['transcript_path']='$FIX/real-standin.jsonl'; print(json.dumps(d, separators=(',', ':')))" <"$FIX/ups-real.json")
  OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=1 run_hook "$REAL_JSON")
  assert_true "T-19: real UPS payload -> reminder fires" '[[ "$OUT" == *"prep-compact"* ]]'
else
  printf 'FAIL: ups-real.json missing (T-19 cannot run)\n' >&2
  FAIL=$((FAIL+1))
fi

# --- T-20: end-to-end warn -> /compact (context drops) -> re-arm cycle
# Codex diff-review flagged that v2.0.0 removes PostCompact and claims the
# natural below-threshold branch handles re-arm, but the harness only tested
# threshold-change stale-flag cleanup (T-16), never the real post-compact
# flow: transcript shrinks because /compact rewrites it, usage drops, flag
# clears, then transcript grows again and we re-warn cleanly.
cleanup
# Step 1: big transcript -> reminder fires, flag set
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=200000 run_hook '{"session_id":"s20","transcript_path":"'"$FIX/transcript-usage.jsonl"'"}')
assert_true "T-20: step 1 big transcript -> reminder fires" '[[ "$OUT" == *"prep-compact"* ]]'
assert_true "T-20: step 1 flag set" '[[ -e "$CACHE/compact-warned-s20" ]]'

# Step 2: /compact simulation — transcript rewritten to a smaller one
# whose newest main-chain usage is below threshold.
POSTCOMPACT='{"message":{"role":"assistant","usage":{"input_tokens":5,"cache_creation_input_tokens":50000,"cache_read_input_tokens":0}}}'
make_transcript "$FIX/t20-post-compact.jsonl" "$POSTCOMPACT"
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=200000 run_hook '{"session_id":"s20","transcript_path":"'"$FIX/t20-post-compact.jsonl"'"}')
assert_eq "T-20: step 2 post-compact small transcript -> silent" "" "$OUT"
assert_true "T-20: step 2 flag cleared by below-threshold branch" '[[ ! -e "$CACHE/compact-warned-s20" ]]'

# Step 3: transcript grows again -> re-arm fires a fresh reminder
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=200000 run_hook '{"session_id":"s20","transcript_path":"'"$FIX/transcript-usage.jsonl"'"}')
assert_true "T-20: step 3 re-arm fires reminder" '[[ "$OUT" == *"prep-compact"* ]]'
assert_true "T-20: step 3 flag re-set" '[[ -e "$CACHE/compact-warned-s20" ]]'

# --- v2.2.0 snapshot fast-path tests (T-21..T-29b) and writer tests (W-1..W-4).

# Single-line transcript fixtures. Sums: _100K=100k, _500K=500k, _50K=~50k.
LINE_100K='{"message":{"role":"assistant","usage":{"input_tokens":50000,"cache_creation_input_tokens":50000,"cache_read_input_tokens":0}}}'
LINE_500K='{"message":{"role":"assistant","usage":{"input_tokens":250000,"cache_creation_input_tokens":250000,"cache_read_input_tokens":0}}}'
LINE_50K='{"message":{"role":"assistant","usage":{"input_tokens":5,"cache_creation_input_tokens":50000,"cache_read_input_tokens":0}}}'

# --- T-21: snap=500k + transcript=100k + threshold=200k -> reminder carries
# 500k (transcript fallback would be silent -> fast path proven).
cleanup
make_transcript "$FIX/t21.jsonl" "$LINE_100K"
write_snapshot_for "s21" 500000 "$FIX/t21.jsonl"
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=200000 run_hook '{"session_id":"s21","transcript_path":"'"$FIX/t21.jsonl"'"}')
assert_true "T-21: fast path above threshold -> reminder fires" '[[ "$OUT" == *"prep-compact"* ]]'
assert_true "T-21: reminder reports 500000 (impossible via fallback)" '[[ "$OUT" == *"500000"* ]]'

# --- T-22: snap=100k + transcript=500k + threshold=200k + stale flag ->
# silent + flag cleared (transcript fallback would leave flag set).
cleanup
make_transcript "$FIX/t22.jsonl" "$LINE_500K"
write_snapshot_for "s22" 100000 "$FIX/t22.jsonl"
: >"$CACHE/compact-warned-s22"
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=200000 run_hook '{"session_id":"s22","transcript_path":"'"$FIX/t22.jsonl"'"}')
assert_eq "T-22: fast path below threshold -> silent" "" "$OUT"
assert_true "T-22: flag cleared via snapshot path" '[[ ! -e "$CACHE/compact-warned-s22" ]]'

# --- T-23: end-to-end re-arm flow. Stale snap + small transcript + stale
# flag -> fallback clears flag (composes with T-2 to cover post-/compact).
cleanup
make_transcript "$FIX/t23.jsonl" "$LINE_500K"
read -r T23_MTIME T23_SIZE < <(get_transcript_meta "$FIX/t23.jsonl")
write_snapshot_raw "s23" 750000 "$T23_MTIME" "$T23_SIZE"
: >"$CACHE/compact-warned-s23"
make_transcript "$FIX/t23.jsonl" "$LINE_50K"
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=200000 run_hook '{"session_id":"s23","transcript_path":"'"$FIX/t23.jsonl"'"}')
assert_eq "T-23: stale snap + small transcript -> silent" "" "$OUT"
assert_true "T-23: stale flag cleared via fallback" '[[ ! -e "$CACHE/compact-warned-s23" ]]'

# --- T-24: mtime_ns mismatch -> fallback. (Size mismatch is the same
# branch via the Python `and`; not retested.)
cleanup
make_transcript "$FIX/t24.jsonl" "$LINE_100K"
read -r _ T24_SIZE < <(get_transcript_meta "$FIX/t24.jsonl")
write_snapshot_raw "s24" 500000 "99999999999" "$T24_SIZE"
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=200000 run_hook '{"session_id":"s24","transcript_path":"'"$FIX/t24.jsonl"'"}')
assert_eq "T-24: mtime mismatch -> fallback silent" "" "$OUT"

# --- T-29b: bogus /c/... path -> silent, no crash (readability guard).
cleanup
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=1 run_hook '{"session_id":"s29b","transcript_path":"/c/nonexistent/bogus/t29b.jsonl"}' 2>/dev/null)
assert_eq "T-29b: bogus /c/... path -> silent, no crash" "" "$OUT"

writer_stdin() {
  local sid=$1 transcript=$2 cw=$3
  printf '{"session_id":"%s","transcript_path":"%s","context_window":%s}' "$sid" "$transcript" "$cw"
}

# --- W-1: current_usage sum excludes output_tokens.
cleanup
make_transcript "$FIX/w1.jsonl" "$LINE_100K"
run_writer "$(writer_stdin w1 "$FIX/w1.jsonl" '{"context_window_size":1000000,"used_percentage":30,"current_usage":{"input_tokens":100000,"output_tokens":9999999,"cache_creation_input_tokens":200000,"cache_read_input_tokens":50000}}')" >/dev/null
assert_eq "W-1: 100k+200k+50k = 350k (output_tokens excluded)" "350000" "$(read_snapshot_field w1 current_context_tokens)"

# --- W-2: fallback rounds used_percentage * size.
cleanup
make_transcript "$FIX/w2.jsonl" "$LINE_100K"
run_writer "$(writer_stdin w2 "$FIX/w2.jsonl" '{"context_window_size":1000000,"used_percentage":44.5,"current_usage":null}')" >/dev/null
assert_eq "W-2: round(44.5/100 * 1M) = 445000" "445000" "$(read_snapshot_field w2 current_context_tokens)"

# --- W-3: null on both sources -> stale snapshot deleted.
cleanup
make_transcript "$FIX/w3.jsonl" "$LINE_100K"
write_snapshot_raw "w3" 999999 "1" "1"
run_writer "$(writer_stdin w3 "$FIX/w3.jsonl" '{"context_window_size":1000000,"used_percentage":null,"current_usage":null}')" >/dev/null
assert_true "W-3: both sources null -> snapshot deleted" '[[ ! -f "$SNAP_DIR/w3.json" ]]'

# --- W-4: traversal sid must hash, not escape SNAP_DIR.
cleanup
make_transcript "$FIX/w4.jsonl" "$LINE_100K"
W4_CW='{"context_window_size":1000,"used_percentage":10,"current_usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'
W4_EVIL='../../evil'
W4_EVIL_SHA1=$("$PY" -c "import hashlib,sys; print(hashlib.sha1(sys.argv[1].encode()).hexdigest())" "$W4_EVIL")
run_writer "$(writer_stdin "$W4_EVIL" "$FIX/w4.jsonl" "$W4_CW")" >/dev/null
assert_true "W-4: traversal sid -> hashed filename, no escape" '[[ -f "$SNAP_DIR/$W4_EVIL_SHA1.json" ]] && [[ ! -e "$SNAP_DIR/../../evil.json" ]]'

# --- W-5 intentionally absent. Schema shape is enforced by the writer's
# literal record dict; a shape regression would fail T-21/T-22/T-23 via
# the hook's freshness gate before any schema-exactness test would catch it.

# --- Final guard: false-green blocker
if (( PASS != EXPECTED_PASS )); then
  printf 'FAIL: expected %d assertions to pass, got %d (PASS) + %d (FAIL)\n' "$EXPECTED_PASS" "$PASS" "$FAIL" >&2
  exit 1
fi

if (( FAIL > 0 )); then
  printf '\nFAILED: %d assertion(s) failed\n' "$FAIL" >&2
  exit 1
fi

printf '\nAll %d assertions passed\n' "$PASS"
exit 0

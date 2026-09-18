#!/usr/bin/env bash
# Test harness for prep-compact. Sources the per-area suites and applies the
# shared guards. Run: bash test/run-tests.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

. "$SCRIPT_DIR/common.sh"

# EXPECTED_PASS is the count of assertions expected to PASS for the harness as
# it currently stands. SKIPPED tracks Stop-dep assertions skipped due to missing
# fixture. False-green guard at end requires PASS + SKIPPED == EXPECTED_PASS.
# Per-task targets (advisory; Task 11 recounts authoritatively):
#   After T1: EXPECTED_PASS=45, SKIPPED=0    (this task — only adds the gate)
#   After T2: EXPECTED_PASS=52, SKIPPED=7    (when fixture missing)
#   After T3: EXPECTED_PASS=72, SKIPPED=27
#   After T4: EXPECTED_PASS=84, SKIPPED=39
#   After T6: EXPECTED_PASS=87, SKIPPED=39   (T6 tests not Stop-dep)
#   After T7: EXPECTED_PASS=88, SKIPPED=39   (T7 test not Stop-dep)
#   PR-comment fix: +3 Stop-dep (T-32cap +1 short-still-captured, T-32prior +2)
#   v3.1 Task 1: +15 Stop-dep (T-24 +1, T-60..T-69 +14)
#   v3.1 Task 2: UPS tests flag-driven (-48 old +37 new, non-Stop); +5 Stop-dep (T-70..T-74)
#   v3.1 Task 3: +2 non-Stop (T-86), +6 Stop-dep (T-87 x4, T-88 x2)
#   v3.1 gate fix: +2 Stop-dep (T-75: no-usage must not clear an existing flag)
#   v3.1 gate fix: +2 non-Stop (T-89: trailing-junk flag -> malformed/re-arm)
#   -> EXPECTED_PASS 152 total; 64 non-Stop + 88 Stop-dep (verified by a
#      fixture-missing run: PASS=64 + SKIPPED=88 == 152).
EXPECTED_PASS=152
SKIPPED=0

. "$SCRIPT_DIR/ups-hook.sh"
. "$SCRIPT_DIR/stop-hook.sh"
. "$SCRIPT_DIR/resolver.sh"

# Report assertion failures first: they also depress PASS, so the false-green
# guard below would otherwise fire on every ordinary failure and report a
# count mismatch instead of the failures themselves.
if (( FAIL > 0 )); then
  printf '\nFAILED: %d assertion(s) failed\n' "$FAIL" >&2
  exit 1
fi

# --- Final guard: false-green blocker (reached only when nothing failed, so
# a mismatch here means assertions went missing rather than failing).
if (( PASS + SKIPPED != EXPECTED_PASS )); then
  printf 'FAIL: expected %d (got PASS=%d + SKIPPED=%d)\n' "$EXPECTED_PASS" "$PASS" "$SKIPPED" >&2
  exit 1
fi

printf '\nAll %d assertions passed\n' "$PASS"
exit 0

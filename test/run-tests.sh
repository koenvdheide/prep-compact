#!/usr/bin/env bash
# Test harness for prep-compact. Sources the per-area suites and applies the
# shared guards. Run: bash test/run-tests.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

. "$SCRIPT_DIR/common.sh"

# EXPECTED_PASS is the count of assertions expected to PASS for the harness as
# it currently stands. SKIPPED tracks Stop-dep assertions skipped due to missing
# fixture. False-green guard at end requires PASS + SKIPPED == EXPECTED_PASS.
#   -> EXPECTED_PASS 152 total; 64 non-Stop + 88 Stop-dep (verified by a
#      fixture-missing run: PASS=64 + SKIPPED=88 == 152).
EXPECTED_PASS=152
SKIPPED=0

. "$SCRIPT_DIR/ups-hook.sh"
if (( STOP_FIXTURE_OK == 1 )); then
  . "$SCRIPT_DIR/stop-hook.sh"
else
  SKIPPED=88
fi
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

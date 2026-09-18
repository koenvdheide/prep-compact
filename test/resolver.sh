# Skill suite: the session-binding helper (resolve-handoff.sh) and the
# SKILL.md contract assertions.
# Sourced by run-tests.sh after common.sh.

[[ -n "${TEST_DIR:-}" ]] || { printf '%s: source this from run-tests.sh, do not run it directly\n' "${BASH_SOURCE[0]}" >&2; exit 1; }
# ===================================================================
# resolve-handoff.sh — session-binding helper (T-42..T-50)
# ===================================================================
RESOLVE="$SCRIPT_DIR/../skills/prep-compact/resolve-handoff.sh"
PDATA="$SANDBOX_HOME/.claude/plugins/data"

# Write a handoff fixture at an arbitrary path, or under a named install dir.
write_handoff_at() {  # $1=abs json path  $2=cwd
  mkdir -p "$(dirname "$1")"
  "$PY" - "$1" "$2" <<'PYW'
import json,sys
json.dump({"version":"3.0","session_id":"x","cwd":sys.argv[2],"cumulative_files":[],
           "recent_user_requests":[],"in_progress":[],"in_progress_status":"unknown",
           "recent_task_launches":[]}, open(sys.argv[1],"w",encoding="utf-8"))
PYW
}
write_handoff() { write_handoff_at "$PDATA/$1/handoff-$2.json" "$3"; }   # $1=install $2=sid $3=cwd

# Run resolver, capture RAW stdout to a file; set RSTATUS / RPATH / RLINES.
# Extra env (e.g. CLAUDE_PLUGIN_DATA=...) may be prefixed before the call.
run_resolve_f() {  # $1=sid (may be empty)  $2=cwd
  local out="$TEST_DIR/resolve.out"
  CLAUDE_CODE_SESSION_ID="$1" \
  CLAUDE_CODE_PLUGIN_CACHE_DIR="$SANDBOX_HOME/.claude/plugins" \
  HOME="$SANDBOX_HOME" bash "$RESOLVE" "$2" >"$out" 2>/dev/null
  RLINES=$(wc -l < "$out" | tr -d ' ')
  RSTATUS=$(sed -n 1p "$out")
  RPATH=$(sed -n 2p "$out")
}
reset_pdata() { cleanup; rm -rf "$PDATA"; mkdir -p "$PDATA"; }

# T-42 HIT: own handoff, matching cwd, exactly two lines
reset_pdata
write_handoff "prep-compact-inline" "sidA" "C:/proj/one"
run_resolve_f "sidA" "C:/proj/one"
assert_eq   "T-42: HIT status"            "HIT" "$RSTATUS"
assert_true "T-42: HIT path is sidA file" '[[ "$RPATH" == *"handoff-sidA.json"* ]]'
assert_eq   "T-42: HIT is exactly 2 lines" "2"  "$RLINES"

# T-43 negative regression (THE bug): own absent, sibling same cwd -> MISS
reset_pdata
write_handoff "prep-compact-inline" "sidB" "C:/proj/one"
run_resolve_f "sidA" "C:/proj/one"
assert_eq "T-43: sibling not selected -> MISS" "MISS" "$RSTATUS"
assert_eq "T-43: MISS is exactly 1 line"        "1"    "$RLINES"

# T-44 cwd-mismatch (D5): own handoff exists, different cwd -> MISS
reset_pdata
write_handoff "prep-compact-inline" "sidA" "C:/proj/other"
run_resolve_f "sidA" "C:/proj/one"
assert_eq "T-44: cwd mismatch -> MISS" "MISS" "$RSTATUS"

# T-45 NOSID (D4): no session id -> NOSID even with siblings, exactly 1 line
reset_pdata
write_handoff "prep-compact-inline" "sidB" "C:/proj/one"
run_resolve_f "" "C:/proj/one"
assert_eq "T-45: empty sid -> NOSID"      "NOSID" "$RSTATUS"
assert_eq "T-45: NOSID is exactly 1 line" "1"     "$RLINES"

# T-46 malformed-skip: bad candidate in higher-priority root, valid in lower
reset_pdata
mkdir -p "$PDATA/aaa-inline"
echo "{not json" > "$PDATA/aaa-inline/handoff-sidA.json"        # sorts first (higher priority)
write_handoff "zzz-inline" "sidA" "C:/proj/one"                 # valid, lower priority
run_resolve_f "sidA" "C:/proj/one"
assert_eq   "T-46: malformed skipped -> HIT"        "HIT" "$RSTATUS"
assert_true "T-46: valid lower-root candidate chosen" '[[ "$RPATH" == *"zzz-inline"* ]]'

# T-46b semantic-malformed (cwd is a list, not a string) is skipped, not fatal
reset_pdata
mkdir -p "$PDATA/aaa-inline"
# to_native: the path is interpolated INTO the python -c code, so MSYS does not
# translate it (unlike an argv path); without this, Windows python resolves the
# /tmp/... MSYS path to a non-existent C:\tmp\... and the malformed fixture is
# never written, making this test pass for the wrong reason.
"$PY" -c "import json;json.dump({'cwd':['oops']},open(r'$(to_native "$PDATA/aaa-inline/handoff-sidA.json")','w'))"
write_handoff "zzz-inline" "sidA" "C:/proj/one"
run_resolve_f "sidA" "C:/proj/one"
assert_eq   "T-46b: non-string cwd skipped, scan continues -> HIT" "HIT" "$RSTATUS"
assert_true "T-46b: zzz-inline chosen (parallel to T-46)" '[[ "$RPATH" == *"zzz-inline"* ]]'

# T-47 collision: same sid+cwd in explicit $CLAUDE_PLUGIN_DATA and a glob root
#   -> explicit root (priority 0) wins; sibling root NOT chosen
reset_pdata
write_handoff "zzz-inline" "sidA" "C:/proj/one"
OVR="$SANDBOX_HOME/explicit"
write_handoff_at "$OVR/handoff-sidA.json" "C:/proj/one"
out="$TEST_DIR/resolve.out"
CLAUDE_CODE_SESSION_ID="sidA" CLAUDE_PLUGIN_DATA="$OVR" \
CLAUDE_CODE_PLUGIN_CACHE_DIR="$SANDBOX_HOME/.claude/plugins" \
HOME="$SANDBOX_HOME" bash "$RESOLVE" "C:/proj/one" >"$out" 2>/dev/null
assert_eq   "T-47: collision -> HIT"                 "HIT" "$(sed -n 1p "$out")"
assert_true "T-47: explicit priority-0 root chosen"  '[[ "$(sed -n 2p "$out")" == *"explicit"* ]]'
assert_true "T-47: sibling glob root NOT chosen"     '[[ "$(sed -n 2p "$out")" != *"zzz-inline"* ]]'

# T-48 oversized sid is unusable -> NOSID, no filename guessed
reset_pdata
LONGSID=$(printf 'a%.0s' {1..200})
run_resolve_f "$LONGSID" "C:/proj/one"
assert_eq "T-48: oversized sid -> NOSID" "NOSID" "$RSTATUS"

# T-49 traversal sid is unusable -> NOSID, no path escape
reset_pdata
run_resolve_f "../../evil" "C:/proj/one"
assert_eq "T-49: traversal sid -> NOSID" "NOSID" "$RSTATUS"

# T-50 cwd canonicalization. The drive-letter form only exists on Windows, so
# assert the equivalence each platform actually has: stored backslash C:\.. vs
# current MSYS /c/.. there, stored trailing slash vs current bare path on POSIX.
reset_pdata
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    write_handoff "prep-compact-inline" "sidA" 'C:\proj\one'
    run_resolve_f "sidA" "/c/proj/one" ;;
  *)
    write_handoff "prep-compact-inline" "sidA" '/proj/one/'
    run_resolve_f "sidA" "/proj/one" ;;
esac
assert_eq "T-50: cwd canonicalize-equal -> HIT" "HIT" "$RSTATUS"

# --- T-41: SKILL.md documents session-id binding via the helper (not mtime)
SKILL="$SCRIPT_DIR/../skills/prep-compact/SKILL.md"
assert_true "T-41: SKILL.md documents resolve-handoff.sh binding" '[[ "$(cat "$SKILL")" == *"resolve-handoff.sh"* ]]'
assert_true "T-41: SKILL.md no longer documents mtime discovery"  '[[ "$(cat "$SKILL")" != *"mtime"* ]]'

# --- T-51: single-line /compact enforcement
assert_true "T-51: multi-line escape hatch removed"   '[[ "$(cat "$SKILL")" != *"Multi-line form is permitted"* ]]'
assert_true "T-51: verify gate present (single line)" '[[ "$(cat "$SKILL")" == *"single physical line"* ]]'
assert_true "T-51: verify gate present (goal literal)" '[[ "$(cat "$SKILL")" == *"begins with the literal characters"* ]]'

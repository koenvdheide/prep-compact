# Stop hook suite (update-handoff.sh): handoff writing, the context-warn flag,
# and the Stop+UPS integration cases. Sourced by run-tests.sh after common.sh.

[[ -n "${TEST_DIR:-}" ]] || { printf '%s: source this from run-tests.sh, do not run it directly\n' "${BASH_SOURCE[0]}" >&2; exit 1; }
STOP_HOOK="$SCRIPT_DIR/../hooks/update-handoff.sh"

# CLAUDE_CODE_SESSION_ID is cleared so the hook's env-first safe_sid derivation
# falls through to the stdin session_id these tests supply. The real session's
# id leaks into the harness env otherwise, and env-first would bind every test
# to it. Env-first behaviour itself is exercised by calling the hook directly
# with CLAUDE_CODE_SESSION_ID set (T-66..T-69).
run_stop_hook() {
  local stdin=$1; shift
  printf '%s' "$stdin" | CLAUDE_CODE_SESSION_ID= HOME="$SANDBOX_HOME" bash "$STOP_HOOK" "$@" 2>/dev/null
}
run_stop_hook_err() {
  local stdin=$1; shift
  printf '%s' "$stdin" | CLAUDE_CODE_SESSION_ID= HOME="$SANDBOX_HOME" bash "$STOP_HOOK" "$@"
}

# --- T-21: missing transcript_path -> fail-open silent
cleanup
OUT=$(run_stop_hook '{"session_id":"s21","transcript_path":"/nonexistent/foo.jsonl","cwd":"/x","permission_mode":"default","hook_event_name":"Stop"}')
assert_eq "T-21: missing transcript -> silent" "" "$OUT"
EXIT=$(printf '%s' '{"session_id":"s21","transcript_path":"/nonexistent/foo.jsonl","cwd":"/x","permission_mode":"default","hook_event_name":"Stop"}' | HOME="$SANDBOX_HOME" bash "$STOP_HOOK" 2>/dev/null; echo "exit=$?")
assert_true "T-21: missing transcript -> exit 0 (fail-open)" '[[ "$EXIT" == *"exit=0"* ]]'

# --- T-22: empty stdin -> fail-open silent
cleanup
OUT=$(run_stop_hook '' 2>/dev/null)
assert_eq "T-22: empty stdin -> silent" "" "$OUT"

# --- T-23: malformed stdin -> fail-open silent
cleanup
OUT=$(run_stop_hook '{not valid' 2>/dev/null)
assert_eq "T-23: malformed stdin -> silent" "" "$OUT"

# --- T-24: oversized session_id -> skip (v3.1 drops the SHA-1 fallback)
cleanup
LONG=$(printf 'b%.0s' {1..200})
OUT=$(run_stop_hook "{\"session_id\":\"$LONG\",\"transcript_path\":\"$FIX/transcript-handoff-multi-turn.jsonl\",\"cwd\":\"/x\",\"permission_mode\":\"default\",\"hook_event_name\":\"Stop\"}")
assert_true "T-24: oversized sid -> raw name NOT used" '[[ ! -e "$CACHE/handoff-$LONG.json" ]]'
ANY24=$(find "$CACHE" -type f -name 'handoff-*.json' 2>/dev/null | head -1)
assert_eq "T-24: oversized sid -> no handoff written at all (no SHA-1 fallback)" "" "$ANY24"

# --- T-25: path traversal session_id -> no escape
cleanup
OUT=$(run_stop_hook '{"session_id":"../../evil","transcript_path":"'"$FIX/transcript-handoff-multi-turn.jsonl"'","cwd":"/x","permission_mode":"default","hook_event_name":"Stop"}' 2>/dev/null)
ESCAPED=$(find "$SANDBOX_HOME/.claude" -path "$CACHE" -prune -o -name 'handoff-*.json' -print 2>/dev/null | head -n 1)
assert_eq "T-25: path traversal -> no escaped handoff" "" "$ESCAPED"

# --- T-26: oversized single line in transcript -> not OOM, fail-open silent
cleanup
OUT=$(run_stop_hook '{"session_id":"s26","transcript_path":"'"$FIX/transcript-handoff-oversized-line.jsonl"'","cwd":"/x","permission_mode":"default","hook_event_name":"Stop"}')
EXIT=$(printf '%s' '{"session_id":"s26","transcript_path":"'"$FIX/transcript-handoff-oversized-line.jsonl"'","cwd":"/x","permission_mode":"default","hook_event_name":"Stop"}' | HOME="$SANDBOX_HOME" bash "$STOP_HOOK" 2>/dev/null; echo "exit=$?")
assert_true "T-26: oversized line -> exit 0 (skipped, fail-open)" '[[ "$EXIT" == *"exit=0"* ]]'

# --- T-26b: malformed JSONL line MID-transcript -> hook skips bad line, processes valid lines
cleanup
FIX_ENV="$FIX" "$PY" -c "
import json, os
good1 = json.dumps({'message':{'role':'user','content':[{'type':'text','text':'first valid'}]}})
bad = '{not-valid json line'
good2 = json.dumps({'message':{'role':'user','content':[{'type':'text','text':'second valid'}]}})
with open(os.environ['FIX_ENV']+'/t26b.jsonl','w') as f:
    f.write(good1+'\n'+bad+'\n'+good2+'\n')
"
run_stop_hook '{"session_id":"s26b","transcript_path":"'"$FIX/t26b.jsonl"'","cwd":"/x","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s26b.json")
HAS_BOTH=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); r=d.get('recent_user_requests',[]); print('yes' if any('first valid' in q for q in r) and any('second valid' in q for q in r) else 'no')")
assert_eq "T-26b: malformed mid-line skipped, good lines processed" "yes" "$HAS_BOTH"

# --- T-27: multi-turn fixture -> handoff written, parseable JSON, all keys present
cleanup
run_stop_hook '{"session_id":"s27","transcript_path":"'"$FIX/transcript-handoff-multi-turn.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s27.json")
assert_true "T-27: handoff file written" '[[ -e "$HANDOFF" ]]'
assert_true "T-27: handoff parses as JSON with required keys" "$PY -c 'import json,sys; d=json.load(open(\"$HANDOFF\")); req={\"version\",\"session_id\",\"cwd\",\"transcript_path\",\"transcript_mtime_at_write\",\"written_at\",\"cumulative_files\",\"recent_files\",\"in_progress_status\",\"in_progress\",\"recent_task_launches\",\"recent_user_requests\"}; missing = req - set(d.keys()); sys.exit(0 if not missing else 1)'"

# --- T-28: recent_files contains Tier-A paths from Read/Edit, NOT user-text mentions
cleanup
run_stop_hook '{"session_id":"s28","transcript_path":"'"$FIX/transcript-handoff-multi-turn.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s28.json")
HAS_AUTH=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if 'src/auth.ts' in d['recent_files'] else 'no')")
HAS_SESSION=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if 'src/session.ts' in d['recent_files'] else 'no')")
HAS_TESTS=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if 'tests/auth.test.ts' in d['recent_files'] else 'no')")
assert_eq "T-28: recent_files has src/auth.ts (Tier-A)" "yes" "$HAS_AUTH"
assert_eq "T-28: recent_files has src/session.ts (Tier-A)" "yes" "$HAS_SESSION"
assert_eq "T-28: recent_files does NOT have tests/auth.test.ts (only in user text, no tool call)" "no" "$HAS_TESTS"

# --- T-28b: Tier-B Glob result extraction — paths in tool_result of a Glob tool_use end up in recent_files
cleanup
FIX_ENV="$FIX" "$PY" -c "
import json, os
turns = [
    {'message':{'role':'assistant','content':[{'type':'tool_use','id':'g1','name':'Glob','input':{'pattern':'src/**/*.ts'}}],'usage':{'input_tokens':100,'cache_creation_input_tokens':1000,'cache_read_input_tokens':0}}},
    {'message':{'role':'user','content':[{'type':'tool_result','tool_use_id':'g1','content':'src/found/a.ts\nsrc/found/b.ts\nnot-a-path-line\n'}]}},
    {'message':{'role':'assistant','content':[{'type':'tool_use','id':'gr1','name':'Grep','input':{'pattern':'foo','output_mode':'content'}}],'usage':{'input_tokens':100,'cache_creation_input_tokens':1000,'cache_read_input_tokens':0}}},
    {'message':{'role':'user','content':[{'type':'tool_result','tool_use_id':'gr1','content':[{'type':'text','text':'src/match/c.ts:42:foo\nsrc/match/d.ts:13:foo\n'}]}]}},
]
with open(os.environ['FIX_ENV']+'/t28b.jsonl','w') as f:
    for t in turns: f.write(json.dumps(t)+'\n')
"
run_stop_hook '{"session_id":"s28b","transcript_path":"'"$FIX/t28b.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s28b.json")
HAS_GLOB_A=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if 'src/found/a.ts' in d['recent_files'] else 'no')")
HAS_GREP_C=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if 'src/match/c.ts' in d['recent_files'] else 'no')")
HAS_NOT_PATH=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if 'not-a-path-line' in d['recent_files'] else 'no')")
assert_eq "T-28b: Glob result path extracted (src/found/a.ts)" "yes" "$HAS_GLOB_A"
assert_eq "T-28b: Grep result path extracted (path:line:match -> path only)" "yes" "$HAS_GREP_C"
assert_eq "T-28b: non-path-shaped line dropped" "no" "$HAS_NOT_PATH"

# --- T-29: recent_user_requests skips tool_result blocks; includes text blocks
cleanup
run_stop_hook '{"session_id":"s29","transcript_path":"'"$FIX/transcript-handoff-multi-turn.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s29.json")
HAS_TR=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if any('Edit applied' in r for r in d['recent_user_requests']) else 'no')")
HAS_PUB=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if any('do NOT change the public signature' in r for r in d['recent_user_requests']) else 'no')")
assert_eq "T-29: recent_user_requests SKIPS tool_result content" "no" "$HAS_TR"
assert_eq "T-29: recent_user_requests INCLUDES text content" "yes" "$HAS_PUB"

# --- T-30: in_progress_status known + in_progress contains the active todo
cleanup
run_stop_hook '{"session_id":"s30","transcript_path":"'"$FIX/transcript-handoff-multi-turn.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s30.json")
STATUS=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print(d['in_progress_status'])")
HAS_NPM=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if any('Run npm test' in t for t in d['in_progress']) else 'no')")
assert_eq "T-30: in_progress_status == known" "known" "$STATUS"
assert_eq "T-30: in_progress contains 'Run npm test'" "yes" "$HAS_NPM"

# --- T-31: recent_task_launches contains rendered subagent_type+description
cleanup
run_stop_hook '{"session_id":"s31","transcript_path":"'"$FIX/transcript-handoff-multi-turn.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s31.json")
HAS_TASK=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if any('Explore: Find all callers' in t for t in d['recent_task_launches']) else 'no')")
assert_eq "T-31: recent_task_launches has Explore launch" "yes" "$HAS_TASK"

# --- T-32: no-user-text fixture -> recent_user_requests empty, in_progress_status unknown
cleanup
run_stop_hook '{"session_id":"s32","transcript_path":"'"$FIX/transcript-handoff-no-user-text.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s32.json")
N_REQ=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print(len(d['recent_user_requests']))")
STATUS=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print(d['in_progress_status'])")
assert_eq "T-32: recent_user_requests empty" "0" "$N_REQ"
assert_eq "T-32: in_progress_status unknown when no TodoWrite" "unknown" "$STATUS"

# --- T-32cap: recent_user_requests cap-boundary (5-message AND char cap)
cleanup
FIX_ENV="$FIX" "$PY" -c "
import json, os
msgs = [
    {'message':{'role':'user','content':[{'type':'text','text':f'msg-{i:02d} short content here under 50 chars'}]}}
    for i in range(1, 8)
]
with open(os.environ['FIX_ENV']+'/t32cap.jsonl','w') as f:
    for m in msgs: f.write(json.dumps(m)+'\n')
"
run_stop_hook '{"session_id":"s32cap","transcript_path":"'"$FIX/t32cap.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s32cap.json")
N_MSG=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print(len(d['recent_user_requests']))")
assert_eq "T-32cap: 5-message cap (7 in transcript -> 5 in handoff)" "5" "$N_MSG"

cleanup
FIX_ENV="$FIX" "$PY" -c "
import json, os
huge = 'x' * 25000
msgs = [
    {'message':{'role':'user','content':[{'type':'text','text':'short first'}]}},
    {'message':{'role':'user','content':[{'type':'text','text':huge}]}},
]
with open(os.environ['FIX_ENV']+'/t32cap2.jsonl','w') as f:
    for m in msgs: f.write(json.dumps(m)+'\n')
"
run_stop_hook '{"session_id":"s32cap2","transcript_path":"'"$FIX/t32cap2.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s32cap2.json")
HAS_HUGE=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); r=d.get('recent_user_requests',[]); total = sum(len(q) for q in r); print('yes' if total > 20000 else 'no')")
assert_eq "T-32cap: char-cap respected (total chars NOT over 20000)" "no" "$HAS_HUGE"
# Codex PR-comment fix: oversized message should be SKIPPED, not abort the loop. Older shorter msg should still be captured.
HAS_SHORT=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); r=d.get('recent_user_requests',[]); print('yes' if any('short first' in q for q in r) else 'no')")
assert_eq "T-32cap: oversized newest skipped, older 'short first' still captured" "yes" "$HAS_SHORT"

# --- T-32prior: prior handoff user_requests preserved when current tail has no user text
# Codex PR-comment fix: prior_user_requests must be merged so a turn with no user text in tail
# does not drop captured intent.
cleanup
"$PY" -c "
import json
prior = {'version':'3.0','session_id':'s32prior','cwd':'/sample/cwd','transcript_path':'/x','transcript_mtime_at_write':0,'written_at':'2026-01-01T00:00:00Z','cumulative_files':[],'recent_files':[],'in_progress_status':'unknown','in_progress':[],'recent_task_launches':[],'recent_user_requests':['prior intent A','prior intent B']}
with open('$(to_native "$CACHE/handoff-s32prior.json")','w') as f: json.dump(prior, f)
"
# Run against the no-user-text fixture (only assistant + tool_result, no user-text blocks).
run_stop_hook '{"session_id":"s32prior","transcript_path":"'"$FIX/transcript-handoff-no-user-text.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s32prior.json")
HAS_PRIOR_A=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if 'prior intent A' in d.get('recent_user_requests',[]) else 'no')")
HAS_PRIOR_B=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if 'prior intent B' in d.get('recent_user_requests',[]) else 'no')")
assert_eq "T-32prior: prior user_requests A preserved when current tail has no user text" "yes" "$HAS_PRIOR_A"
assert_eq "T-32prior: prior user_requests B preserved when current tail has no user text" "yes" "$HAS_PRIOR_B"

# --- T-33: tool-blob fixture -> path-shaped strings inside huge tool_result NOT in recent_files
cleanup
run_stop_hook '{"session_id":"s33","transcript_path":"'"$FIX/transcript-handoff-tool-blob.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s33.json")
HAS_FOO=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if '/tmp/foo.log' in d['recent_files'] else 'no')")
HAS_BAR=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if '/tmp/bar.txt' in d['recent_files'] else 'no')")
assert_eq "T-33: Tier-C dropped — /tmp/foo.log NOT in recent_files" "no" "$HAS_FOO"
assert_eq "T-33: Tier-C dropped — /tmp/bar.txt NOT in recent_files" "no" "$HAS_BAR"

# --- T-34: cumulative_files monotonic across two runs against different transcripts
cleanup
mkdir -p "$CACHE"
cp "$FIX/handoff-prior.json" "$CACHE/handoff-s34.json"
"$PY" -c "
import json
with open('$(to_native "$CACHE/handoff-s34.json")','r') as f: d=json.load(f)
d['session_id']='s34'
with open('$(to_native "$CACHE/handoff-s34.json")','w') as f: json.dump(d,f)
"
run_stop_hook '{"session_id":"s34","transcript_path":"'"$FIX/transcript-handoff-multi-turn.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s34.json")
HAS_LEGACY=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if 'src/legacy/old.ts' in d['cumulative_files'] else 'no')")
HAS_AUTH=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if 'src/auth.ts' in d['cumulative_files'] else 'no')")
assert_eq "T-34: prior cumulative_files preserved (src/legacy/old.ts)" "yes" "$HAS_LEGACY"
assert_eq "T-34: new path added (src/auth.ts)" "yes" "$HAS_AUTH"

# --- T-34b: prior recent_task_launches preserved across runs
cleanup
"$PY" -c "
import json
prior = {'version':'3.0','session_id':'s34b','cwd':'/sample/cwd','transcript_path':'/x','transcript_mtime_at_write':0,'written_at':'2026-01-01T00:00:00Z','cumulative_files':[],'recent_files':[],'in_progress_status':'unknown','in_progress':[],'recent_task_launches':['Explore: prior unique launch'],'recent_user_requests':[]}
with open('$(to_native "$CACHE/handoff-s34b.json")','w') as f: json.dump(prior, f)
"
run_stop_hook '{"session_id":"s34b","transcript_path":"'"$FIX/transcript-handoff-multi-turn.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s34b.json")
HAS_PRIOR_TASK=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if any('prior unique launch' in t for t in d['recent_task_launches']) else 'no')")
HAS_NEW_TASK=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if any('Explore: Find all callers' in t for t in d['recent_task_launches']) else 'no')")
assert_eq "T-34b: prior recent_task_launches preserved" "yes" "$HAS_PRIOR_TASK"
assert_eq "T-34b: new launches appended" "yes" "$HAS_NEW_TASK"

# --- T-35: FIFO cap at 200 — older entries dropped first
cleanup
"$PY" -c "
import json
prior = {'version':'3.0','session_id':'s35','cwd':'/sample/cwd','transcript_path':'/x','transcript_mtime_at_write':0,'written_at':'2026-01-01T00:00:00Z','cumulative_files':[f'/old/path/{i:03d}.ts' for i in range(200)],'recent_files':[],'in_progress_status':'unknown','in_progress':[],'recent_task_launches':[],'recent_user_requests':[]}
with open('$(to_native "$CACHE/handoff-s35.json")','w') as f: json.dump(prior, f)
"
run_stop_hook '{"session_id":"s35","transcript_path":"'"$FIX/transcript-handoff-multi-turn.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s35.json")
N=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print(len(d['cumulative_files']))")
HAS_FIRST_OLD=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if '/old/path/000.ts' in d['cumulative_files'] else 'no')")
HAS_NEW=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if 'src/auth.ts' in d['cumulative_files'] else 'no')")
assert_eq "T-35: cumulative_files capped at 200" "200" "$N"
assert_eq "T-35: oldest entry evicted (/old/path/000.ts)" "no" "$HAS_FIRST_OLD"
assert_eq "T-35: new entry kept (src/auth.ts)" "yes" "$HAS_NEW"

# --- T-36: PREP_COMPACT_NO_USER_QUOTES=1 -> empty + eager-clear prior quotes
cleanup
"$PY" -c "
import json
prior = {'version':'3.0','session_id':'s36','cwd':'/sample/cwd','transcript_path':'/x','transcript_mtime_at_write':0,'written_at':'2026-01-01T00:00:00Z','cumulative_files':[],'recent_files':[],'in_progress_status':'unknown','in_progress':[],'recent_task_launches':[],'recent_user_requests':['old quote 1','old quote 2']}
with open('$(to_native "$CACHE/handoff-s36.json")','w') as f: json.dump(prior, f)
"
PREP_COMPACT_NO_USER_QUOTES=1 run_stop_hook '{"session_id":"s36","transcript_path":"'"$FIX/transcript-handoff-multi-turn.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s36.json")
N_REQ=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print(len(d['recent_user_requests']))")
assert_eq "T-36: env var blanks recent_user_requests AND clears prior quotes" "0" "$N_REQ"

# --- T-37: round-trip backticks/quotes/newlines verbatim
cleanup
FIX_ENV="$FIX" "$PY" -c "
import json, os
tricky = 'Has \`\`\`fences\`\`\` and \"quotes\" and\nnewlines\nand\ttabs'
line = json.dumps({'message':{'role':'user','content':[{'type':'text','text':tricky}]}})
with open(os.environ['FIX_ENV']+'/t37.jsonl','w') as f: f.write(line + '\n')
"
run_stop_hook '{"session_id":"s37","transcript_path":"'"$FIX/t37.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s37.json")
ROUND_TRIP_OK=$("$PY" -c "
import json
d=json.load(open('$HANDOFF'))
expected = 'Has \`\`\`fences\`\`\` and \"quotes\" and\nnewlines\nand\ttabs'
print('yes' if d['recent_user_requests'][0] == expected else 'no')
")
assert_eq "T-37: backticks/quotes/newlines round-trip verbatim" "yes" "$ROUND_TRIP_OK"

# --- T-38: atomic write — corrupted prior handoff treated as no-prior, write succeeds
cleanup
echo "{not valid json" > "$CACHE/handoff-s38.json"
run_stop_hook '{"session_id":"s38","transcript_path":"'"$FIX/transcript-handoff-multi-turn.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s38.json")
PARSE_OK=$("$PY" -c "
import json
try:
    json.load(open('$HANDOFF'))
    print('yes')
except Exception:
    print('no')
")
assert_eq "T-38: corrupted prior -> new write succeeds, parses cleanly" "yes" "$PARSE_OK"

# --- T-38p: PermissionError simulation — prior file preserved, stderr warning
cleanup
"$PY" -c "
import json
prior = {'version':'3.0','session_id':'s38p','cwd':'/sample/cwd','transcript_path':'/x','transcript_mtime_at_write':0,'written_at':'2026-01-01T00:00:00Z','cumulative_files':['SENTINEL/prior.ts'],'recent_files':[],'in_progress_status':'unknown','in_progress':[],'recent_task_launches':[],'recent_user_requests':[]}
with open('$(to_native "$CACHE/handoff-s38p.json")','w') as f: json.dump(prior, f)
"
ERR=$(PREP_COMPACT_TEST_REPLACE_FAIL=1 run_stop_hook_err '{"session_id":"s38p","transcript_path":"'"$FIX/transcript-handoff-multi-turn.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' 2>&1 >/dev/null)
HANDOFF=$(to_native "$CACHE/handoff-s38p.json")
PRIOR_INTACT=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if 'SENTINEL/prior.ts' in d.get('cumulative_files',[]) else 'no')")
assert_eq "T-38p: simulated replace fail -> prior preserved (sentinel intact)" "yes" "$PRIOR_INTACT"
assert_true "T-38p: stderr warning printed on simulated fail" '[[ "$ERR" == *"replace failed twice, prior preserved"* ]]'

# --- T-38g: async ordering guard — a newer on-disk handoff is NOT clobbered by an older run.
# Pre-write a handoff with a far-future transcript_mtime_at_write; the run (whose
# fixture transcript has a normal mtime) must SKIP the replace, leaving the
# sentinel written_at untouched. Distinguishes the guard from cumulative_files
# merge (which would preserve prior entries even on a write).
cleanup
"$PY" -c "
import json
prior = {'version':'3.0','session_id':'s38g','cwd':'/sample/cwd','transcript_path':'/x','transcript_mtime_at_write':9999999999.0,'written_at':'2099-01-01T00:00:00Z','cumulative_files':[],'recent_files':[],'in_progress_status':'unknown','in_progress':[],'recent_task_launches':[],'recent_user_requests':[]}
with open('$(to_native "$CACHE/handoff-s38g.json")','w') as f: json.dump(prior, f)
"
run_stop_hook '{"session_id":"s38g","transcript_path":"'"$FIX/transcript-handoff-multi-turn.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s38g.json")
WRITTEN_AT=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print(d.get('written_at',''))")
assert_eq "T-38g: newer on-disk handoff preserved (guard skips stale replace)" "2099-01-01T00:00:00Z" "$WRITTEN_AT"

# T-52: file noise filter — .git/temp/plugin-data excluded, real path kept
cleanup
FIX_ENV="$FIX" "$PY" -c "
import json, os
t=[{'message':{'role':'assistant','content':[
  {'type':'tool_use','id':'r1','name':'Read','input':{'file_path':'src/keep.ts'}},
  {'type':'tool_use','id':'r2','name':'Read','input':{'file_path':'.git/hooks/pre-commit.sample'}},
  {'type':'tool_use','id':'r3','name':'Read','input':{'file_path':'/tmp/codex-x.txt'}},
  {'type':'tool_use','id':'r4','name':'Read','input':{'file_path':'C:/Users/u/.claude/plugins/data/prep-compact-inline/handoff-z.json'}},
  {'type':'tool_use','id':'r5','name':'Read','input':{'file_path':'C:/Users/u/.claude/settings.json'}},
  {'type':'tool_use','id':'r6','name':'Read','input':{'file_path':'.claude/plugins/data/prep-compact-inline/handoff-rel.json'}}],
  'usage':{'input_tokens':1,'cache_creation_input_tokens':1,'cache_read_input_tokens':0}}}]
open(os.environ['FIX_ENV']+'/t52.jsonl','w').write('\n'.join(json.dumps(x) for x in t)+'\n')
"
run_stop_hook '{"session_id":"s52","transcript_path":"'"$FIX/t52.jsonl"'","cwd":"/sample","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s52.json")
assert_eq "T-52: real path kept"         "yes" "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if 'src/keep.ts' in d['recent_files'] else 'no')")"
assert_eq "T-52: .git filtered"          "no"  "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if any('.git' in p for p in d['recent_files']) else 'no')")"
assert_eq "T-52: temp NOT filtered (kept)" "yes" "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if any('codex-x' in p for p in d['recent_files']) else 'no')")"
assert_eq "T-52: plugin-data filtered"   "no"  "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if any('handoff-z' in p for p in d['recent_files']) else 'no')")"
assert_eq "T-52: ~/.claude/settings.json kept" "yes" "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if any('settings.json' in p for p in d['recent_files']) else 'no')")"
assert_eq "T-52: relative plugin-data filtered" "no" "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if any('handoff-rel' in p for p in d['recent_files']) else 'no')")"

# T-53: prior cumulative_files noise purged on next write
cleanup
"$PY" -c "
import json
p={'version':'3.0','session_id':'s53','cwd':'/sample','transcript_path':'/x','transcript_mtime_at_write':0,'written_at':'2026-01-01T00:00:00Z','cumulative_files':['src/old.ts','.git/config','/tmp/noise.txt'],'recent_files':[],'in_progress_status':'unknown','in_progress':[],'recent_task_launches':[],'recent_user_requests':[]}
open('$(to_native "$CACHE/handoff-s53.json")','w').write(json.dumps(p))
"
run_stop_hook '{"session_id":"s53","transcript_path":"'"$FIX/transcript-handoff-multi-turn.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s53.json")
assert_eq "T-53: prior real path kept" "yes" "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if 'src/old.ts' in d['cumulative_files'] else 'no')")"
assert_eq "T-53: prior .git noise purged" "no"  "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if any('.git/config' in p for p in d['cumulative_files']) else 'no')")"

# T-54: injected user messages filtered from recent_user_requests
cleanup
FIX_ENV="$FIX" "$PY" -c "
import json, os
t=[{'message':{'role':'user','content':[{'type':'text','text':'real request: do the thing'}]}},
   {'message':{'role':'user','content':[{'type':'text','text':'<task-notification>\nbg done\n</task-notification>'}]}},
   {'message':{'role':'user','content':[{'type':'text','text':'Base directory for this skill: C:/x\n# Skill\nblah'}]}},
   {'message':{'role':'user','content':[{'type':'text','text':'[SYSTEM NOTIFICATION - NOT USER INPUT]\nbackground event'}]}}]
open(os.environ['FIX_ENV']+'/t54.jsonl','w').write('\n'.join(json.dumps(x) for x in t)+'\n')
"
run_stop_hook '{"session_id":"s54","transcript_path":"'"$FIX/t54.jsonl"'","cwd":"/sample","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s54.json")
assert_eq "T-54: real request kept"        "yes" "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if any('real request' in q for q in d['recent_user_requests']) else 'no')")"
assert_eq "T-54: task-notification filtered" "no" "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if any('task-notification' in q for q in d['recent_user_requests']) else 'no')")"
assert_eq "T-54: skill-load filtered"      "no"  "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if any('Base directory for this skill' in q for q in d['recent_user_requests']) else 'no')")"
assert_eq "T-54: system-notification filtered" "no" "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if any('SYSTEM NOTIFICATION' in q for q in d['recent_user_requests']) else 'no')")"

# T-55: prior recent_user_requests injected noise purged on merge (mirrors T-53 for requests)
cleanup
"$PY" -c "
import json
p={'version':'3.0','session_id':'s55','cwd':'/sample/cwd','transcript_path':'/x','transcript_mtime_at_write':0,'written_at':'2026-01-01T00:00:00Z','cumulative_files':[],'recent_files':[],'in_progress_status':'unknown','in_progress':[],'recent_task_launches':[],'recent_user_requests':['real prior intent','<task-notification>\nold bg event\n</task-notification>']}
open('$(to_native "$CACHE/handoff-s55.json")','w').write(json.dumps(p))
"
run_stop_hook '{"session_id":"s55","transcript_path":"'"$FIX/transcript-handoff-no-user-text.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s55.json")
assert_eq "T-55: prior real request kept" "yes" "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if any('real prior intent' in q for q in d['recent_user_requests']) else 'no')")"
assert_eq "T-55: prior injected purged"   "no"  "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if any('task-notification' in q for q in d['recent_user_requests']) else 'no')")"

# T-56: Tier-B grep-result extraction rejects shell/code lines. Regression: a grep
# CONTEXT line "357-SKILL=\"\$DIR/../skills/prep-compact/SKILL.md\"" was captured as a path.
cleanup
JUNK_LINE='357-SKILL="$SCRIPT_DIR/../skills/prep-compact/SKILL.md"' \
REAL_LINE='src/real/keep.ts:42:SKILL' \
LEGIT_LINE='fixtures/a=b.json:1:match' \
FIX_ENV="$FIX" "$PY" -c "
import json, os
content = os.environ['JUNK_LINE'] + '\n' + os.environ['REAL_LINE'] + '\n' + os.environ['LEGIT_LINE'] + '\n'
turns = [
  {'message':{'role':'assistant','content':[{'type':'tool_use','id':'gj1','name':'Grep','input':{'pattern':'SKILL','output_mode':'content'}}],'usage':{'input_tokens':100,'cache_creation_input_tokens':1000,'cache_read_input_tokens':0}}},
  {'message':{'role':'user','content':[{'type':'tool_result','tool_use_id':'gj1','content':content}]}},
]
with open(os.environ['FIX_ENV']+'/t56.jsonl','w') as f:
  for t in turns: f.write(json.dumps(t)+'\n')
"
run_stop_hook '{"session_id":"s56","transcript_path":"'"$FIX/t56.jsonl"'","cwd":"/sample","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s56.json")
assert_eq "T-56: real grep path kept"      "yes" "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if any('src/real/keep.ts' in p for p in d['recent_files']) else 'no')")"
assert_eq "T-56: legit =-char path kept"   "yes" "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if any('a=b.json' in p for p in d['recent_files']) else 'no')")"
assert_eq "T-56: shell-junk line rejected" "no"  "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if any(('SCRIPT_DIR' in p) or ('SKILL=' in p) or ('prep-compact/SKILL.md' in p) for p in d['recent_files']) else 'no')")"

# ============================================================
# v3.1 Task 1: Stop hook writes/clears the context-warn flag
# ============================================================
# Single assistant usage summing to 300000 (100000 + 200000 + 0).
TOK_300K='{"message":{"role":"assistant","usage":{"input_tokens":100000,"cache_creation_input_tokens":200000,"cache_read_input_tokens":0}}}'

# --- T-60: above threshold -> context-warn flag written with "<tokens> <threshold>"
cleanup
make_transcript "$FIX/t60.jsonl" "$TOK_300K"
CLAUDE_CONTEXT_WARN_TOKENS=200000 run_stop_hook '{"session_id":"s60","transcript_path":"'"$FIX/t60.jsonl"'","cwd":"/x","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
assert_true "T-60: above threshold -> context-warn flag written" '[[ -e "$CACHE/context-warn-s60" ]]'
assert_eq "T-60: flag content is '<tokens> <threshold>'" "300000 200000" "$(cat "$CACHE/context-warn-s60" 2>/dev/null)"

# --- T-61: below threshold -> stale flag cleared (re-arm)
cleanup
make_transcript "$FIX/t61.jsonl" "$TOK_300K"
: >"$CACHE/context-warn-s61"
CLAUDE_CONTEXT_WARN_TOKENS=500000 run_stop_hook '{"session_id":"s61","transcript_path":"'"$FIX/t61.jsonl"'","cwd":"/x","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
assert_true "T-61: below threshold -> stale flag cleared" '[[ ! -e "$CACHE/context-warn-s61" ]]'

# --- T-62: invalid CLAUDE_CONTEXT_WARN_TOKENS -> default 450000 (300k below -> no flag) + stderr warn
cleanup
make_transcript "$FIX/t62.jsonl" "$TOK_300K"
ERR=$(CLAUDE_CONTEXT_WARN_TOKENS="not-a-number" run_stop_hook_err '{"session_id":"s62","transcript_path":"'"$FIX/t62.jsonl"'","cwd":"/x","permission_mode":"default","hook_event_name":"Stop"}' 2>&1 >/dev/null)
assert_true "T-62: invalid threshold -> stderr 'ignoring invalid'" '[[ "$ERR" == *"ignoring invalid"* ]]'
assert_true "T-62: default 450000 -> 300k below -> no flag" '[[ ! -e "$CACHE/context-warn-s62" ]]'

# --- T-63: flag written with a trailing newline (atomic-write contract)
cleanup
make_transcript "$FIX/t63.jsonl" "$TOK_300K"
CLAUDE_CONTEXT_WARN_TOKENS=1 run_stop_hook '{"session_id":"s63","transcript_path":"'"$FIX/t63.jsonl"'","cwd":"/x","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
assert_eq "T-63: flag is exactly one line (trailing newline present)" "1" "$(wc -l < "$CACHE/context-warn-s63" | tr -d ' ')"

# --- T-64: stale run (future-mtime existing handoff) writes no flag (mtime-guard covers flag)
cleanup
make_transcript "$FIX/t64.jsonl" "$TOK_300K"
"$PY" -c "
import json
prior = {'version':'3.0','session_id':'s64','cwd':'/x','transcript_path':'/x','transcript_mtime_at_write':9999999999.0,'written_at':'2099-01-01T00:00:00Z','cumulative_files':[],'recent_files':[],'in_progress_status':'unknown','in_progress':[],'recent_task_launches':[],'recent_user_requests':[]}
open('$(to_native "$CACHE/handoff-s64.json")','w').write(json.dumps(prior))
"
CLAUDE_CONTEXT_WARN_TOKENS=1 run_stop_hook '{"session_id":"s64","transcript_path":"'"$FIX/t64.jsonl"'","cwd":"/x","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
assert_true "T-64: stale run (future-mtime handoff) writes no flag" '[[ ! -e "$CACHE/context-warn-s64" ]]'

# --- T-65: Stop scan skips sidechain, uses earlier main-chain (same filters as UPS)
cleanup
SIDE_HUGE='{"isSidechain":true,"message":{"role":"assistant","usage":{"input_tokens":10,"cache_creation_input_tokens":888888,"cache_read_input_tokens":0}}}'
make_transcript "$FIX/t65.jsonl" "$TOK_300K" "$SIDE_HUGE"
CLAUDE_CONTEXT_WARN_TOKENS=250000 run_stop_hook '{"session_id":"s65","transcript_path":"'"$FIX/t65.jsonl"'","cwd":"/x","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
assert_eq "T-65: sidechain skipped -> flag uses main-chain 300000" "300000 250000" "$(cat "$CACHE/context-warn-s65" 2>/dev/null)"

# --- T-66: safe_sid parity: env-valid + stdin-missing -> env sid used
cleanup
make_transcript "$FIX/t66.jsonl" "$TOK_300K"
printf '%s' '{"transcript_path":"'"$FIX/t66.jsonl"'","cwd":"/x","permission_mode":"default","hook_event_name":"Stop"}' | CLAUDE_CONTEXT_WARN_TOKENS=1 CLAUDE_CODE_SESSION_ID="envsid66" HOME="$SANDBOX_HOME" bash "$STOP_HOOK" >/dev/null 2>&1
assert_true "T-66: env-valid + stdin-missing -> flag named by env sid" '[[ -e "$CACHE/context-warn-envsid66" ]]'
assert_true "T-66: handoff also named by env sid" '[[ -e "$CACHE/handoff-envsid66.json" ]]'

# --- T-67: safe_sid parity: env-valid + stdin-different -> env wins
cleanup
make_transcript "$FIX/t67.jsonl" "$TOK_300K"
printf '%s' '{"session_id":"stdin67","transcript_path":"'"$FIX/t67.jsonl"'","cwd":"/x","permission_mode":"default","hook_event_name":"Stop"}' | CLAUDE_CONTEXT_WARN_TOKENS=1 CLAUDE_CODE_SESSION_ID="env67" HOME="$SANDBOX_HOME" bash "$STOP_HOOK" >/dev/null 2>&1
assert_true "T-67: env wins -> flag named by env sid" '[[ -e "$CACHE/context-warn-env67" ]]'
assert_true "T-67: stdin sid NOT used" '[[ ! -e "$CACHE/context-warn-stdin67" ]]'

# --- T-68: safe_sid parity: env-invalid + stdin-valid -> stdin used
cleanup
make_transcript "$FIX/t68.jsonl" "$TOK_300K"
printf '%s' '{"session_id":"stdin68","transcript_path":"'"$FIX/t68.jsonl"'","cwd":"/x","permission_mode":"default","hook_event_name":"Stop"}' | CLAUDE_CONTEXT_WARN_TOKENS=1 CLAUDE_CODE_SESSION_ID="bad/sid" HOME="$SANDBOX_HOME" bash "$STOP_HOOK" >/dev/null 2>&1
assert_true "T-68: env invalid -> stdin sid used" '[[ -e "$CACHE/context-warn-stdin68" ]]'

# --- T-69: safe_sid parity: both invalid -> skip (no handoff, no flag)
cleanup
make_transcript "$FIX/t69.jsonl" "$TOK_300K"
printf '%s' '{"session_id":"../evil","transcript_path":"'"$FIX/t69.jsonl"'","cwd":"/x","permission_mode":"default","hook_event_name":"Stop"}' | CLAUDE_CONTEXT_WARN_TOKENS=1 CLAUDE_CODE_SESSION_ID="" HOME="$SANDBOX_HOME" bash "$STOP_HOOK" >/dev/null 2>&1
ANY69=$(find "$CACHE" -type f \( -name 'context-warn-*' -o -name 'handoff-*' \) 2>/dev/null | head -1)
assert_eq "T-69: both invalid sid -> nothing written" "" "$ANY69"

# --- Token-detection edge cases (moved from the UPS hook; the scan now lives in Stop) ---

# --- T-70: api-error line skipped -> flag uses earlier main-chain usage
cleanup
APIERR_HUGE='{"isApiErrorMessage":true,"message":{"role":"assistant","usage":{"input_tokens":10,"cache_creation_input_tokens":999999,"cache_read_input_tokens":0}}}'
make_transcript "$FIX/t70.jsonl" "$TOK_300K" "$APIERR_HUGE"
CLAUDE_CONTEXT_WARN_TOKENS=250000 run_stop_hook '{"session_id":"s70","transcript_path":"'"$FIX/t70.jsonl"'","cwd":"/x","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
assert_eq "T-70: api-error skipped -> flag uses main-chain 300000" "300000 250000" "$(cat "$CACHE/context-warn-s70" 2>/dev/null)"

# --- T-71: pre-first-turn (no usable usage) -> no flag written
cleanup
USERMSG='{"message":{"role":"user","content":"hello"}}'
make_transcript "$FIX/t71.jsonl" "$USERMSG"
CLAUDE_CONTEXT_WARN_TOKENS=1 run_stop_hook '{"session_id":"s71","transcript_path":"'"$FIX/t71.jsonl"'","cwd":"/x","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
assert_true "T-71: no usable usage -> no context-warn flag" '[[ ! -e "$CACHE/context-warn-s71" ]]'

# --- T-72: malformed last usage line skipped -> flag uses earlier valid line (250010)
cleanup
CLAUDE_CONTEXT_WARN_TOKENS=1 run_stop_hook '{"session_id":"s72","transcript_path":"'"$FIX/transcript-malformed-tail.jsonl"'","cwd":"/x","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
assert_eq "T-72: malformed tail skipped -> flag uses earlier valid 250010" "250010 1" "$(cat "$CACHE/context-warn-s72" 2>/dev/null)"

# --- T-73: non-assistant usage skipped -> flag uses earlier assistant line
cleanup
USERUSAGE='{"message":{"role":"user","usage":{"input_tokens":10,"cache_creation_input_tokens":888888,"cache_read_input_tokens":0}}}'
make_transcript "$FIX/t73.jsonl" "$TOK_300K" "$USERUSAGE"
CLAUDE_CONTEXT_WARN_TOKENS=250000 run_stop_hook '{"session_id":"s73","transcript_path":"'"$FIX/t73.jsonl"'","cwd":"/x","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
assert_eq "T-73: non-assistant usage skipped -> flag uses main-chain 300000" "300000 250000" "$(cat "$CACHE/context-warn-s73" 2>/dev/null)"

# --- T-74: oversized last record beyond the 1 MB tail -> no usable usage -> no flag
cleanup
EARLIER_VALID='{"message":{"role":"assistant","usage":{"input_tokens":10,"cache_creation_input_tokens":123446,"cache_read_input_tokens":0}}}'
PAD=$("$PY" -c "print('A' * 1300000)")  # 1.3 MB pushes the earlier valid line past the 1 MB tail
OVERSIZED="{\"message\":{\"role\":\"assistant\",\"content\":\"$PAD\",\"usage\":{\"input_tokens\":10,\"cache_creation_input_tokens\":50000,\"cache_read_input_tokens\":0}}}"
make_transcript "$FIX/t74.jsonl" "$EARLIER_VALID" "$OVERSIZED"
CLAUDE_CONTEXT_WARN_TOKENS=1 run_stop_hook '{"session_id":"s74","transcript_path":"'"$FIX/t74.jsonl"'","cwd":"/x","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
assert_true "T-74: oversized straddling last record -> no context-warn flag" '[[ ! -e "$CACHE/context-warn-s74" ]]'

# --- T-75: no usable usage must NOT clear an existing flag (absence != below-threshold)
cleanup
USERONLY='{"message":{"role":"user","content":"hello"}}'
make_transcript "$FIX/t75.jsonl" "$USERONLY"
printf '300000 200000\n' > "$CACHE/context-warn-s75"
CLAUDE_CONTEXT_WARN_TOKENS=200000 run_stop_hook '{"session_id":"s75","transcript_path":"'"$FIX/t75.jsonl"'","cwd":"/x","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
assert_true "T-75: no-usage Stop preserves an existing flag" '[[ -e "$CACHE/context-warn-s75" ]]'
assert_eq "T-75: preserved flag content intact" "300000 200000" "$(cat "$CACHE/context-warn-s75" 2>/dev/null)"

# --- Stop+UPS integration: re-arm and stale-Stop race (red-team edge cases) ---

# --- T-87: delayed clear after /compact -> Stop clears flag -> UPS re-arms
cleanup
make_transcript "$FIX/t87.jsonl" "$TOK_300K"
CLAUDE_CONTEXT_WARN_TOKENS=200000 run_stop_hook '{"session_id":"s87","transcript_path":"'"$FIX/t87.jsonl"'","cwd":"/x","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
OUT=$(run_hook '{"session_id":"s87"}')
assert_true "T-87: step1 Stop wrote flag -> UPS warns" '[[ "$OUT" == *"prep-compact"* ]]'
# /compact: transcript shrinks below threshold; a later Stop clears the flag.
SMALL_50K='{"message":{"role":"assistant","usage":{"input_tokens":5,"cache_creation_input_tokens":50000,"cache_read_input_tokens":0}}}'
make_transcript "$FIX/t87.jsonl" "$SMALL_50K"
CLAUDE_CONTEXT_WARN_TOKENS=200000 run_stop_hook '{"session_id":"s87","transcript_path":"'"$FIX/t87.jsonl"'","cwd":"/x","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
assert_true "T-87: step2 below-threshold Stop cleared flag" '[[ ! -e "$CACHE/context-warn-s87" ]]'
OUT=$(run_hook '{"session_id":"s87"}')
assert_eq "T-87: step3 UPS silent after clear" "" "$OUT"
assert_true "T-87: step3 compact-warned cleared (re-armed)" '[[ ! -e "$CACHE/compact-warned-s87" ]]'

# --- T-88: stale Stop must not clear a newer flag (mtime-guard covers clears too)
cleanup
# A newer Stop already ran (future-mtime handoff) and a fresh flag is present.
# A STALE Stop (old transcript, below-threshold tokens) would clear the flag if
# it proceeded; the mtime-guard skips it, so the newer flag stays intact.
make_transcript "$FIX/t88.jsonl" "$SMALL_50K"
"$PY" -c "
import json
newer = {'version':'3.0','session_id':'s88','cwd':'/x','transcript_path':'/x','transcript_mtime_at_write':9999999999.0,'written_at':'2099-01-01T00:00:00Z','cumulative_files':[],'recent_files':[],'in_progress_status':'unknown','in_progress':[],'recent_task_launches':[],'recent_user_requests':[]}
open('$(to_native "$CACHE/handoff-s88.json")','w').write(json.dumps(newer))
"
printf '300000 200000\n' > "$CACHE/context-warn-s88"
CLAUDE_CONTEXT_WARN_TOKENS=200000 run_stop_hook '{"session_id":"s88","transcript_path":"'"$FIX/t88.jsonl"'","cwd":"/x","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
assert_true "T-88: stale Stop does not clear a newer flag" '[[ -e "$CACHE/context-warn-s88" ]]'
assert_eq "T-88: newer flag content intact" "300000 200000" "$(cat "$CACHE/context-warn-s88" 2>/dev/null)"

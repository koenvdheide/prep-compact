#!/usr/bin/env bash
# Stop hook for prep-compact v3.0.
# Tail-reads the session transcript and writes a continuously-fresh handoff
# JSON at ${CLAUDE_PLUGIN_DATA}/handoff-<safe_sid>.json. Always exits 0
# (fail-open). Sister to check-context-size.sh.
#
# Extracts paths (Tier-A and Tier-B), user requests, in-progress todos, and
# Task launches per turn. Tier-C (regex over Bash command text) is dropped.
# Merge of cumulative_files with prior handoff and atomic-write land in Task 4.

set -uo pipefail

CACHE_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/cache}"

if ! mkdir -p "$CACHE_DIR" 2>/dev/null; then
  printf 'update-handoff: cannot create %s; hook disabled this turn.\n' "$CACHE_DIR" >&2
  exit 0
fi

STDIN_JSON=$(cat 2>/dev/null)

# Python 3 required. If absent, fail open with a stderr warning.
if command -v python3 >/dev/null 2>&1; then
  PY=python3
elif command -v python >/dev/null 2>&1 && python -c 'import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)' 2>/dev/null; then
  PY=python
else
  printf 'update-handoff: Python 3 not found on PATH; hook disabled this turn.\n' >&2
  exit 0
fi

# Extract session_id, transcript_path, cwd from stdin JSON.
EXTRACTED=$(printf '%s' "$STDIN_JSON" | "$PY" -c "
import sys, json, hashlib, re
try:
    d = json.load(sys.stdin)
    sid = d.get('session_id', '') or ''
    tp = d.get('transcript_path', '') or ''
    cwd = d.get('cwd', '') or ''
except Exception:
    sid = ''; tp = ''; cwd = ''

if sid and re.fullmatch(r'[A-Za-z0-9_-]{1,64}', sid):
    safe = sid
elif sid:
    safe = hashlib.sha1(sid.encode('utf-8')).hexdigest()
else:
    safe = ''
print(safe)
print(tp)
print(cwd)
" 2>/dev/null || printf '\n\n\n')
SAFE_SID=$(printf '%s' "$EXTRACTED" | sed -n '1p')
TRANSCRIPT_PATH=$(printf '%s' "$EXTRACTED" | sed -n '2p')
CWD=$(printf '%s' "$EXTRACTED" | sed -n '3p')

if [[ -z "$SAFE_SID" ]]; then
  exit 0
fi

if [[ -z "$TRANSCRIPT_PATH" || ! -r "$TRANSCRIPT_PATH" ]]; then
  exit 0
fi

# cygpath bridge for Git Bash on Windows.
if command -v cygpath >/dev/null 2>&1; then
  TRANSCRIPT_NATIVE=$(cygpath -w "$TRANSCRIPT_PATH" 2>/dev/null || printf '%s' "$TRANSCRIPT_PATH")
else
  TRANSCRIPT_NATIVE="$TRANSCRIPT_PATH"
fi

HANDOFF_PATH="$CACHE_DIR/handoff-$SAFE_SID.json"

# Apply same cygpath bridge to handoff path (Python opens it for write).
if command -v cygpath >/dev/null 2>&1; then
  HANDOFF_NATIVE=$(cygpath -w "$HANDOFF_PATH" 2>/dev/null || printf '%s' "$HANDOFF_PATH")
else
  HANDOFF_NATIVE="$HANDOFF_PATH"
fi

# Tail-read transcript (bounded), iterate lines (per-line capped), extract
# handoff fields, and write JSON. Always exits 0; errors logged to stderr.
"$PY" - "$TRANSCRIPT_NATIVE" "$HANDOFF_NATIVE" "$SAFE_SID" "$CWD" "$TRANSCRIPT_PATH" <<'PYEOF' 2>/dev/null || true
import sys, os, json, datetime

TAIL_BYTES = 1_048_576
MAX_LINE_BYTES = 1_048_576
TOOL_RESULT_TRUNC = 2000
USER_REQUESTS_MAX_MSGS = 5
USER_REQUESTS_MAX_CHARS = 20000

transcript_path_native, handoff_path, safe_sid, cwd, transcript_path_logical = (
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
)

try:
    size = os.path.getsize(transcript_path_native)
    transcript_mtime = os.path.getmtime(transcript_path_native)
except OSError:
    sys.exit(0)

try:
    with open(transcript_path_native, 'rb') as f:
        f.seek(max(0, size - TAIL_BYTES))
        tail = f.read()
except OSError:
    sys.exit(0)

text = tail.decode('utf-8', errors='replace')
lines = text.splitlines()

# Parse all lines (oldest -> newest direction is preserved by transcript order).
parsed = []
for line in lines:
    if len(line.encode('utf-8', errors='replace')) > MAX_LINE_BYTES:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    if isinstance(d, dict):
        parsed.append(d)

# Helpers ---------------------------------------------------------------

def get_message(entry):
    m = entry.get('message')
    return m if isinstance(m, dict) else None

def is_sidechain(entry):
    return entry.get('isSidechain') is True

def content_blocks(msg):
    c = msg.get('content')
    if isinstance(c, list):
        return c
    if isinstance(c, str):
        return [{'type': 'text', 'text': c}]
    return []

# Extract recent_files (Tier A then B). Walk newest -> oldest.
recent_files_seen = []
def add_path(p):
    if isinstance(p, str) and p and p not in recent_files_seen:
        recent_files_seen.append(p)

TIER_A_TOOLS = {'Read', 'Edit', 'Write', 'NotebookEdit'}
TIER_A_FIELDS = {'file_path', 'notebook_path'}
TIER_B_TOOLS = {'Glob', 'Grep'}
TIER_B_FIELDS = {'file_path', 'path', 'notebook_path'}

# First pass: Tier A
for entry in reversed(parsed):
    if is_sidechain(entry):
        continue
    msg = get_message(entry)
    if not msg or msg.get('role') != 'assistant':
        continue
    for block in content_blocks(msg):
        if block.get('type') == 'tool_use' and block.get('name') in TIER_A_TOOLS:
            inp = block.get('input', {}) or {}
            for k, v in inp.items():
                if k in TIER_A_FIELDS:
                    add_path(v)

# Second pass: Tier B (paths in tool inputs)
for entry in reversed(parsed):
    if is_sidechain(entry):
        continue
    msg = get_message(entry)
    if not msg:
        continue
    for block in content_blocks(msg):
        if block.get('type') == 'tool_use' and block.get('name') in TIER_B_TOOLS:
            inp = block.get('input', {}) or {}
            for k, v in inp.items():
                if k in TIER_B_FIELDS and isinstance(v, str):
                    add_path(v)

# Tier B (continued): scan tool_result content of Glob/Grep tool_uses for path-
# shaped lines. Walk newest-first parity with Tier-A; extract path TOKEN (not
# whole line) so "src/foo.ts:12:match" becomes "src/foo.ts"; handle Windows drive letters.

def first_path_token(line):
    if not line:
        return None
    rest = line
    prefix = ''
    if (len(rest) >= 2 and rest[0].isalpha() and rest[1] == ':'
            and (len(rest) == 2 or rest[2] in '/\\')):
        prefix = rest[:2]
        rest = rest[2:]
    parts = rest.split(':', 1)
    candidate = prefix + parts[0]
    if not ('/' in candidate or '\\' in candidate):
        return None
    last_sep = max(candidate.rfind('/'), candidate.rfind('\\'))
    tail = candidate[last_sep+1:]
    if '.' in tail and len(tail) > 1:
        return candidate
    return None

glob_grep_ids = set()
for entry in parsed:
    if is_sidechain(entry):
        continue
    msg = get_message(entry)
    if not msg or msg.get('role') != 'assistant':
        continue
    for block in content_blocks(msg):
        if block.get('type') == 'tool_use' and block.get('name') in TIER_B_TOOLS:
            tid = block.get('id')
            if isinstance(tid, str) and tid:
                glob_grep_ids.add(tid)

for entry in reversed(parsed):
    if is_sidechain(entry):
        continue
    msg = get_message(entry)
    if not msg or msg.get('role') != 'user':
        continue
    for block in content_blocks(msg):
        if block.get('type') != 'tool_result':
            continue
        if block.get('tool_use_id') not in glob_grep_ids:
            continue
        content = block.get('content', '')
        if isinstance(content, list):
            content = '\n'.join(
                b.get('text', '') for b in content
                if isinstance(b, dict) and b.get('type') == 'text'
            )
        if not isinstance(content, str):
            continue
        truncated = content[:TOOL_RESULT_TRUNC]
        for line in truncated.splitlines():
            tok = first_path_token(line.strip())
            if tok is not None:
                add_path(tok)

recent_files = recent_files_seen

# Extract recent_user_requests
user_requests = []
total_chars = 0
for entry in reversed(parsed):
    if is_sidechain(entry):
        continue
    msg = get_message(entry)
    if not msg or msg.get('role') != 'user':
        continue
    text_chunks = []
    for block in content_blocks(msg):
        if block.get('type') == 'text':
            t = block.get('text')
            if isinstance(t, str) and t:
                text_chunks.append(t)
        elif block.get('type') == 'tool_result':
            continue
    if not text_chunks:
        continue
    combined = '\n'.join(text_chunks)
    if total_chars + len(combined) > USER_REQUESTS_MAX_CHARS:
        break
    user_requests.append(combined)
    total_chars += len(combined)
    if len(user_requests) >= USER_REQUESTS_MAX_MSGS:
        break

# Privacy gate (Task 4 will use the env var; here for forward-compat)
if os.environ.get('PREP_COMPACT_NO_USER_QUOTES'):
    user_requests = []

# Extract in_progress + status
in_progress = []
in_progress_status = 'unknown'
for entry in reversed(parsed):
    if is_sidechain(entry):
        continue
    msg = get_message(entry)
    if not msg or msg.get('role') != 'assistant':
        continue
    for block in content_blocks(msg):
        if block.get('type') == 'tool_use' and block.get('name') == 'TodoWrite':
            inp = block.get('input', {}) or {}
            todos = inp.get('todos', [])
            if isinstance(todos, list):
                in_progress = [
                    t.get('content', '') for t in todos
                    if isinstance(t, dict) and t.get('status') == 'in_progress'
                ]
                in_progress_status = 'known'
                break
    if in_progress_status == 'known':
        break

# Extract recent_task_launches
task_launches = []
for entry in reversed(parsed):
    if is_sidechain(entry):
        continue
    msg = get_message(entry)
    if not msg or msg.get('role') != 'assistant':
        continue
    for block in content_blocks(msg):
        if block.get('type') == 'tool_use' and block.get('name') == 'Task':
            inp = block.get('input', {}) or {}
            stype = inp.get('subagent_type', 'unknown')
            desc = inp.get('description', '')
            task_launches.append(f'{stype}: {desc}')

# Build cumulative_files = recent_files (Task 4 will merge with prior)
cumulative_files = list(recent_files)

# Write JSON. Atomic-write logic added in Task 4; here we write directly.
out = {
    'version': '3.0',
    'session_id': safe_sid,
    'cwd': cwd,
    'transcript_path': transcript_path_logical,
    'transcript_mtime_at_write': transcript_mtime,
    'written_at': datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
    'cumulative_files': cumulative_files,
    'recent_files': recent_files,
    'in_progress_status': in_progress_status,
    'in_progress': in_progress,
    'recent_task_launches': task_launches,
    'recent_user_requests': user_requests,
}
try:
    with open(handoff_path, 'w', encoding='utf-8') as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
except OSError as e:
    print(f'update-handoff: write failed: {e}', file=sys.stderr)
    sys.exit(0)

sys.exit(0)
PYEOF

exit 0

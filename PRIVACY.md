# Privacy

prep-compact is a local-only Claude Code plugin. It does not send data over the network, does not use telemetry, and does not record session content.

## What the plugin accesses

The `UserPromptSubmit` hook receives a JSON payload on stdin from Claude Code. The plugin reads two fields from that payload:

- `session_id` — used to namespace the per-session state file.
- `transcript_path` — used to stat the transcript file and to tail-read the last 256 KB. The tail is parsed to extract API-returned `.message.usage` numbers (specifically `input_tokens`, `cache_creation_input_tokens`, and `cache_read_input_tokens` from the newest main-chain assistant turn). No transcript content is persisted, logged, or transmitted.

The optional v2.2.0 status-line companion script (`scripts/write_context_snapshot.py`) reads the same `session_id` and `transcript_path` from Claude Code's status-line JSON, plus the `context_window` object — specifically `context_window.current_usage.{input,cache_creation_input,cache_read_input}_tokens` (preferred), falling back to `context_window.used_percentage` × `context_window.context_window_size` when `current_usage` is null. `output_tokens` is read only to be deliberately ignored (it's per-turn output, not context size). No transcript content is read by the companion script.

`session_id` is validated against `^[A-Za-z0-9_-]{1,64}$` before use as a filename. Values that don't match fall back to a SHA-1 hex hash of the raw value, so unexpected characters cannot escape the cache directory. Both the hook and the companion script use identical sanitization.

## What the plugin persists

The hook writes one small file under `$CLAUDE_PLUGIN_DATA` (or `~/.claude/cache` as a fallback), per session:

- `compact-warned-<session_id>` — an empty flag file used as a presence marker to avoid re-firing the reminder for the same threshold-crossing.

The file contains no prompts, responses, tool calls, project file paths, or any session content.

If you opt into the v2.2.0 status-line companion (see README), one additional per-session file is written under `~/.claude/cache/prep-compact-snapshots/`:

- `<session_id>.json` — exactly three integer fields: `current_context_tokens` (the token count derived from Claude Code's official `context_window` data), `transcript_mtime_ns` (the transcript file's modification time in nanoseconds — a timestamp, but derived from the transcript's own filesystem metadata, not the plugin's activity), and `transcript_size` (the transcript file's byte size). No session content, no prompt/response text, no project paths, no plugin-activity timestamps, no session_id inside the file (only in the filename, sanitized the same way as the flag file).

The snapshot file is stale the moment the transcript changes; the hook's freshness gate detects that and falls back to the transcript parser automatically. The directory is safe to delete at any time.

(v1.0.x also wrote a `compact-baseline-<session_id>` integer file used by the since-removed byte-path. If any such file is left over on disk, it is unread by v2.0.0+ and can be deleted safely.)

## What the plugin does not do

- No network requests, ever.
- No telemetry, analytics, or usage reporting.
- No writes outside the cache directory.
- No full-transcript reads. Only the last 256 KB is read, and only to extract `.message.usage` integer fields — no prompt/response content is parsed or retained.
- No modifications to your project files, shell environment, or Claude Code settings.

## About the /compact output

The skill drafts a `/compact <instructions>` block. You paste and run it yourself. When you do, the instructions text is sent to Anthropic as part of Claude Code's normal `/compact` flow — the same as any other `/compact` invocation you run by hand. That transmission is governed by Anthropic's privacy policy, not this plugin.

## Third parties

None. The plugin has no external dependencies at runtime beyond your local shell (bash + coreutils) and Python 3.

## Contact

Issues or questions: <https://github.com/koenvdheide/prep-compact/issues>

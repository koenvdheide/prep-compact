# Privacy

prep-compact is a local-only Claude Code plugin. It does not send data over the network, does not use telemetry, and does not record session content.

## What the plugin accesses

The `UserPromptSubmit` and `PostCompact` hooks receive a JSON payload on stdin from Claude Code. The plugin reads two fields from that payload:

- `session_id` — used to namespace per-session state files.
- `transcript_path` — used only to stat the transcript file for its byte size (`wc -c`). The transcript content is never read, parsed, or stored.

`session_id` is validated against `^[A-Za-z0-9_-]{1,64}$` before use as a filename. Values that don't match fall back to a SHA-1 hex hash of the raw value, so unexpected characters cannot escape the cache directory.

## What the plugin persists

The hook writes two small files under `$CLAUDE_PLUGIN_DATA` (or `~/.claude/cache` as a fallback), per session:

- `compact-warned-<session_id>` — an empty flag file used as a presence marker to avoid re-firing the reminder for the same delta-crossing.
- `compact-baseline-<session_id>` — a single integer: the transcript byte count at the time of the last `/compact`.

Neither file contains prompts, responses, tool calls, project file paths, or any session content.

## What the plugin does not do

- No network requests, ever.
- No telemetry, analytics, or usage reporting.
- No writes outside the cache directory.
- No reads of the transcript file's contents.
- No modifications to your project files, shell environment, or Claude Code settings.

## About the /compact output

The skill drafts a `/compact <instructions>` block. You paste and run it yourself. When you do, the instructions text is sent to Anthropic as part of Claude Code's normal `/compact` flow — the same as any other `/compact` invocation you run by hand. That transmission is governed by Anthropic's privacy policy, not this plugin.

## Third parties

None. The plugin has no external dependencies at runtime beyond your local shell (bash + coreutils) and Python 3.

## Contact

Issues or questions: <https://github.com/koenvdheide/prep-compact/issues>

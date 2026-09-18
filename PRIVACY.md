# Privacy

prep-compact runs entirely on your machine. The plugin makes no network calls of its own. The Anthropic API is only contacted when you (the user) run `/prep-compact` or `/compact` through Claude Code's normal flow.

## Local persistence

The plugin writes three kinds of files under `${CLAUDE_PLUGIN_DATA}` (default `~/.claude/cache/` if unset):

- **`compact-warned-<safe_sid>`** — empty presence marker that suppresses repeat reminders for one threshold crossing, removed again once context drops back below the threshold. No content recorded.
- **`context-warn-<safe_sid>`** (new in v3.1) — written by the Stop hook when the newest main-chain assistant usage is at or above the threshold, and removed once it drops below. Holds two integers, the token count and the configured threshold, and nothing else.
- **`handoff-<safe_sid>.json`** (new in v3.0) — the warm handoff. Contents:
  - `cumulative_files`, `recent_files` — file paths the session has touched (extracted from `Read`/`Edit`/`Write`/`NotebookEdit`/`Glob`/`Grep` tool calls). No file CONTENT, only paths.
  - `in_progress`, `recent_task_launches` — your todo state and subagent launches, extracted from `TodoWrite`/`Task` tool calls.
  - **`recent_user_requests`** — verbatim quotes of your most recent user messages (capped at 5 messages OR 20000 chars). This is the most sensitive field; it is the only place the plugin stores raw text from your prompts.
  - `version`, `session_id`, `cwd`, `transcript_path`, `transcript_mtime_at_write`, `written_at` — bookkeeping metadata.

The hook does NOT persist tool result content. It performs a bounded read (≤2000 chars per result) of `Glob` and `Grep` `tool_result` blocks for the sole purpose of extracting path tokens that appear in their output — only the extracted path strings end up in the handoff, never the result text itself. It does NOT read or scan `Read`/`Edit`/`Write` tool results, `Bash` command output, or any other tool result content.

## Opting out of user-quote persistence

Set `PREP_COMPACT_NO_USER_QUOTES=1` in your shell profile or `~/.claude/settings.json` under `env`:

```json
{
  "env": {
    "PREP_COMPACT_NO_USER_QUOTES": "1"
  }
}
```

When set:

1. The Stop hook writes empty `recent_user_requests` going forward.
2. **Eager-clear**: the Stop hook also drops any pre-existing `recent_user_requests` from the prior handoff during merge. You do not need to delete the handoff manually — the next assistant turn will overwrite with no quotes.

## Network and Anthropic flow

- The Stop hook and UserPromptSubmit hook make no network calls.
- The plugin's skill (`/prep-compact`) runs as part of your Claude Code session and uses the same Anthropic API path Claude Code itself uses. Inputs to the skill (including any quoted user messages from the warm handoff) flow through that path.
- When you run the emitted `/compact <instructions>` block, the contents — including any quoted user-message excerpts embedded in the block — are sent to Claude Code's normal Anthropic compaction pipeline. They are subject to whatever data-handling terms apply to your Anthropic account.

## Session ID safety

`session_id` is validated with regex `^[A-Za-z0-9_-]{1,64}$` before use as a filename component. As of v3.1 a value that fails the check never becomes a filename anywhere: both hooks skip it, writing no flag and no handoff, and the skill's resolver reports `NOSID` and surveys the live conversation instead. Path-escape via `../` or an absolute path is blocked by construction.

## Uninstall

Plugin uninstall via `/plugin uninstall` removes the plugin and (per Claude Code's standard plugin lifecycle) clears `${CLAUDE_PLUGIN_DATA}`. To preserve the data dir, use `/plugin uninstall --keep-data`.

## See also

- [README.md](README.md) — feature overview and configuration.
- [LICENSE](LICENSE) — MIT.

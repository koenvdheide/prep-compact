# prep-compact

## Why

Claude Code's auto-compact misses important details and runs late in the 1M Opus context window. Context is usually already degrading by the time it fires, and the default summary generated for compaction is pretty iffy — it often doesn't save which files, decisions, or blockers you wanted preserved, it forgets what subagents were running, and it has no memory of state from *before* the previous compaction. Running `/compact <instructions>` with a tailored prompt gives dramatically cleaner resumption, but requires you to remember to do it and design the prompt. This plugin nags you at the right moment and drafts the tailored prompt for you — and because a sister `Stop` hook continuously merges fresh state into a warm on-disk handoff, the draft carries forward context that **accumulates across multiple compactions**, not just the current in-memory window.

## How It Works

A Claude Code plugin that nudges Claude to prepare tailored `/compact` instructions when the context window is getting full enough that performance has started dropping. Experience suggests this happens around the halfway point of the 1M-token window on Opus.

CC does not programatically expose how many tokens are in use for the current session (even though we can see ourselves with /context), so there is no direct way to fire a reminder based on the current session's token use. However, CC does store how many tokens are in use at the moment of a given user prompt in its transcript file. This plugin works by firing hooks that read the tail end of this transcript file. Under the hood it works like this:

> Between turns, a `Stop` hook tail-reads the transcript and writes a continuously-updated handoff file at `${CLAUDE_PLUGIN_DATA}/handoff-<sid>.json` listing every file the session has touched (cumulative across `/compact` cycles), the most recent user requests quoted verbatim, in-progress todo items, and any active subagent launches.
>
> A `UserPromptSubmit` hook fires on every prompt submission. It tail-reads the last 256 KB of the transcript `.jsonl`, parses the newest main-chain (`role=='assistant'`, non-sidechain, non-api-error) `.message.usage`, and sums `input_tokens + cache_creation_input_tokens + cache_read_input_tokens`. When that total crosses `CLAUDE_CONTEXT_WARN_TOKENS` (default `450000`), an informational reminder names the handoff path and points the user at `/prep-compact:prep-compact`.
>
> The skill reads the warm handoff (extractive fields: cumulative file paths, recent user-message quotes, in-progress todos, recent Task launches) and adds an analytical layer (decisions, constraints, blockers, verb-anchored next-step) to emit a copy-paste `/compact <mini-schema>` block preserving what the post-compact session needs to resume correctly.

The reminder fires once per threshold-crossing. Once the token count drops back below the threshold (after you `/compact`), the flag is auto-cleared on the next turn and future crossings re-arm cleanly. You can also invoke `/prep-compact` manually at any time to refresh the draft right before running `/compact`.


## Install

Add the `agent-tools` marketplace and install the plugin:

```text
/plugin marketplace add koenvdheide/agent-tools
/plugin install prep-compact@agent-tools
```

Run `/reload-plugins` if you installed mid-session.

## Requirements

- **Claude Code with plugin support.** If `/plugin` is unknown, update Claude Code.
- **Python 3** on `PATH` (as `python3` or `python`). The hook uses Python's `json.load` for robust stdin parsing.

## Configuration

One env var controls the threshold:

| Variable | Default | Meaning |
| --- | --- | --- |
| `CLAUDE_CONTEXT_WARN_TOKENS` | `450000` | Real token count (summed `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` of the newest main-chain assistant turn, read from the transcript `.jsonl`'s `.message.usage`). When this crosses the threshold, the reminder fires. |

Set it in your shell profile or `~/.claude/settings.json` under `env`:

```json
{
  "env": {
    "CLAUDE_CONTEXT_WARN_TOKENS": "450000"
  }
}
```

## Security and privacy

The hook reads `session_id` and `transcript_path` from stdin. Nothing is sent over the network. `session_id` is validated against `^[A-Za-z0-9_-]{1,64}$` before use as a filename; exotic values fall back to a SHA-1 hex hash. The flag file is an empty presence marker — no content recorded.

See [PRIVACY.md](PRIVACY.md) for the full statement.

## Known limits

- **Undocumented transcript format.** The hook parses `.message.usage` from the transcript `.jsonl`, which Anthropic doesn't officially document. Silent no-op if the schema changes.
- **Manual invocation.** The reminder is informational — it names the warm handoff path and points at `/prep-compact:prep-compact`. Claude does not auto-invoke the skill; type `/prep-compact` manually when you're ready to compact.
- **Staleness across turns.** The Stop hook refreshes the warm handoff after every assistant message, so `/prep-compact` reads current state. If the conversation has been idle and the handoff has been updated since the last user prompt, the draft will reflect that. There's a one-turn window of stale handoff right after `/compact` runs (UserPromptSubmit fires before the next Stop), but the next assistant turn refreshes it.

## License

MIT. See [LICENSE](LICENSE).

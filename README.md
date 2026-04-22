# prep-compact

## Why

Claude Code's auto-compact misses important details and runs late in the 1M Opus context window. Context is usually already degrading by the time it fires, and the default summary generated for compaction is pretty iffy, it often doesn't save which files, decisions, or blockers you wanted preserved. Running `/compact <instructions>` with a tailored prompt gives dramatically cleaner resumption, but requires you to remember to do it and design the prompt. This plugin nags you at the right moment and drafts the tailored prompt for you.

## How It Works

A Claude Code plugin that nudges Claude to prepare tailored `/compact` instructions when the context window is getting full enough that performance has started dropping. Experience suggests this happens around the halfway point of the 1M-token window on Opus.

A `UserPromptSubmit` hook fires on every prompt submission. It tail-reads the last 256 KB of your session transcript `.jsonl`, parses the newest main-chain (`role=='assistant'`, non-sidechain, non-api-error) `.message.usage`, and sums `input_tokens + cache_creation_input_tokens + cache_read_input_tokens`. When that total crosses `CLAUDE_CONTEXT_WARN_TOKENS` (default `450000`), a one-shot reminder tells Claude to invoke the `prep-compact` skill. The skill surveys the session in four buckets (goal+next, source-of-truth files, decisions+constraints+blockers, execution state) and emits a copy-paste `/compact <mini-schema>` block preserving what the post-compact session needs to resume correctly.

The reminder fires once per threshold-crossing. Once the token count drops back below the threshold (after you `/compact`), the flag is auto-cleared on the next turn and future crossings re-arm cleanly. You can also invoke `/prep-compact` manually at any time to refresh the draft right before running `/compact`.

## Install

```bash
git clone https://github.com/koenvdheide/prep-compact.git
claude --plugin-dir /path/to/prep-compact
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
- **Auto-invoke is prompt-layer.** The reminder tells Claude to invoke the skill; that's best-effort prompt steering. If the skill doesn't auto-run, type `/prep-compact:prep-compact` manually.
- **Staleness after work.** If you keep working for several turns after the reminder fires, the drafted `/compact` block will be stale by compact-time. Re-invoke `/prep-compact:prep-compact` right before running `/compact` to refresh.

## License

MIT. See [LICENSE](LICENSE).

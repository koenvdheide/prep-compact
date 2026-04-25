# prep-compact

## Why

Claude Code's auto-compact misses important details and runs late in the 1M Opus context window. Context is usually already degrading by the time it fires, and the default summary generated for compaction is pretty iffy, it often doesn't save which files, decisions, or blockers you wanted preserved. Running `/compact <instructions>` with a tailored prompt gives dramatically cleaner resumption, but requires you to remember to do it and design the prompt. This plugin nags you at the right moment and drafts the tailored prompt for you.

## How It Works

A Claude Code plugin that nudges Claude to prepare tailored `/compact` instructions when the context window is getting full enough that performance has started dropping. Experience suggests this happens around the halfway point of the 1M-token window on Opus.

CC does not programmatically expose the current session's token count to hooks (even though `/context` displays it), but it does write per-turn usage into the transcript `.jsonl` and exposes a `context_window` object to status-line scripts. This plugin reads the transcript tail by default, with an optional status-line companion (v2.2.0+) that lets it skip the parse and use CC's official numbers when available. Under the hood:

> A `UserPromptSubmit` hook fires on every prompt submission. If the optional status-line companion is configured and has written a fresh snapshot at `~/.claude/cache/prep-compact-snapshots/<session_id>.json` whose transcript fingerprint (`mtime_ns` + `size`) matches the current transcript, the hook uses the snapshot's pre-computed token count. Otherwise it tail-reads the last 256 KB of your session transcript `.jsonl`, parses the newest main-chain (`role=='assistant'`, non-sidechain, non-api-error) `.message.usage`, and sums `input_tokens + cache_creation_input_tokens + cache_read_input_tokens`. When that total crosses `CLAUDE_CONTEXT_WARN_TOKENS` (default `450000`), a one-shot reminder tells Claude to invoke the `prep-compact` skill. The skill surveys the session in four buckets (goal+next, source-of-truth files, decisions+constraints+blockers, execution state) and emits a copy-paste `/compact <mini-schema>` block preserving what the post-compact session needs to resume correctly.

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

## Optional: live context in your status line (v2.2.0)

An optional companion script lets Claude Code's status line drive the hook directly off Claude Code's official `context_window` data instead of tail-scanning the transcript. The hook silently falls back to the transcript parser when the snapshot is absent or stale, so the companion is purely additive.

Add a `statusLine` entry to `~/.claude/settings.json`, pointing at the bundled writer by absolute path:

```json
{
  "statusLine": {
    "type": "command",
    "command": "python /absolute/path/to/prep-compact/scripts/write_context_snapshot.py"
  }
}
```

On each status-line render where Claude Code has supplied a usable `context_window` and the transcript file can be stat'd, the writer stores one tiny JSON file at `~/.claude/cache/prep-compact-snapshots/<session_id>.json` containing the current token count plus the transcript's `mtime_ns` and `size`. When the token count cannot be derived (`current_usage` null early in the session AND `used_percentage` also null, or the transcript cannot be stat'd), the writer deletes any stale snapshot rather than leaving old data behind. The hook prefers the snapshot on the next user prompt when the fingerprint matches the current transcript, and falls back to the tail-scan otherwise. `/compact` invalidates the fingerprint automatically, so re-arm works unchanged.

**Caveat: terminal Claude Code only.** The status line renders reliably in the CLI TUI. Mid-session settings changes do not hot-reload — restart Claude Code after adding the `statusLine` entry. IDE extensions (VSCode, JetBrains) may not drive status-line renders at all; in those environments no snapshot is written and the hook's behavior matches v2.1.1.

**Note on leftover snapshots.** If you use the `statusLine` companion and later remove it, a leftover snapshot may still be fresh for the current transcript on the next user prompt. The hook will use it once; the next rewriting of the transcript (normal assistant turn, `/compact`) makes it stale and the hook falls back. To force clean pure-v2.1.1 behavior, delete `~/.claude/cache/prep-compact-snapshots/`.

## Security and privacy

The hook reads `session_id` and `transcript_path` from stdin. Nothing is sent over the network. `session_id` is validated against `^[A-Za-z0-9_-]{1,64}$` before use as a filename; exotic values fall back to a SHA-1 hex hash. The flag file is an empty presence marker — no content recorded. If you opt into the status-line companion, it writes one tiny snapshot file per session containing three integers (`current_context_tokens`, `transcript_mtime_ns`, `transcript_size`) — no session content.

See [PRIVACY.md](PRIVACY.md) for the full statement.

## Known limits

- **Undocumented transcript format.** The hook parses `.message.usage` from the transcript `.jsonl`, which Anthropic doesn't officially document. Silent no-op if the schema changes.
- **Auto-invoke is prompt-layer.** The reminder tells Claude to invoke the skill; that's best-effort prompt steering. If the skill doesn't auto-run, type `/prep-compact` manually.
- **Staleness after work.** If you keep working for several turns after the reminder fires, the drafted `/compact` block will be stale by compact-time. Re-invoke `/prep-compact` right before running `/compact` to refresh.

## License

MIT. See [LICENSE](LICENSE).

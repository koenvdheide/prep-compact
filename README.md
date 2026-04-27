# prep-compact

## Why

Claude Code's auto-compact misses important details and runs late in the 1M Opus context window. Context is usually already degrading by the time it fires, and the default summary it generates is pretty iffy — it often doesn't save which files, decisions, or blockers you wanted preserved, and it forgets what subagents were running. A second compaction in the same session has no memory of anything that happened before the first. Running `/compact <instructions>` with a tailored prompt gives dramatically cleaner resumption, but requires you to remember to do it and design the prompt. This plugin nags you at the right moment and drafts the tailored prompt for you. It also keeps a small running record on disk between turns — which files you've touched, what you've been asked to do, which subagents are active — and folds that into every draft, so the resumed session carries forward state from the *whole* session, not just what was still in memory at the moment of compaction.

## How It Works

A Claude Code plugin that nudges Claude to prepare tailored `/compact` instructions when the context window is getting full enough that performance has started dropping. Experience suggests this happens around the halfway point of the 1M-token window on Opus.

Three coordinated pieces — two hooks and one skill — together detect threshold crossings AND continuously maintain an on-disk record of session state, so the resulting `/compact` block survives across multiple compactions:

> **Warm handoff** (`Stop` hook, [`hooks/update-handoff.sh`](hooks/update-handoff.sh)). After every assistant message, this hook tail-reads the transcript and extracts cumulative file paths (touched via `Read`/`Edit`/`Write`/`NotebookEdit`/`Glob`/`Grep`), in-progress `TodoWrite` items, recent verbatim user-message quotes, and recent `Task` subagent launches. It **merges with the prior handoff** at `${CLAUDE_PLUGIN_DATA}/handoff-<sid>.json` so state accumulates across the whole session — including across `/compact` boundaries. Even after the in-memory transcript is wiped by a compaction, the handoff still remembers which files mattered and what the user was working on.
>
> **Threshold detection** (`UserPromptSubmit` hook, [`hooks/check-context-size.sh`](hooks/check-context-size.sh)). On every prompt submission, the hook resolves the current token count — preferentially from a fresh snapshot written by the optional status-line companion when its transcript fingerprint (`mtime_ns` + `size`) matches the live transcript, otherwise by tail-reading the last 256 KB of the transcript `.jsonl`, parsing the newest main-chain (`role=='assistant'`, non-sidechain, non-api-error) `.message.usage`, and summing `input_tokens + cache_creation_input_tokens + cache_read_input_tokens`. When the total crosses `CLAUDE_CONTEXT_WARN_TOKENS` (default `450000`), an informational reminder names the warm handoff path and points the user at `/prep-compact:prep-compact`.
>
> **Tailored prompt** (`prep-compact` skill, [`skills/prep-compact/SKILL.md`](skills/prep-compact/SKILL.md)). Reads the warm handoff for extractive fields (cumulative file paths, recent user-message quotes, in-progress todos, recent Task launches), then adds an analytical layer (decisions, constraints, blockers, verb-anchored next-step) and emits a copy-paste `/compact <mini-schema>` block preserving what the post-compact session needs to resume correctly.

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

## Optional: live context in your status line (v3.1.0)

An optional companion script lets Claude Code's status line drive the threshold check directly off Claude Code's official `context_window` data instead of tail-scanning the transcript. The hook silently falls back to the transcript parser when the snapshot is absent or stale, so the companion is purely additive.

Add a `statusLine` entry to `~/.claude/settings.json`, pointing at the bundled writer by absolute path:

```json
{
  "statusLine": {
    "type": "command",
    "command": "python /absolute/path/to/prep-compact/scripts/write_context_snapshot.py"
  }
}
```

On each status-line render where Claude Code has supplied a usable `context_window` and the transcript file can be stat'd, the writer stores one tiny JSON file at `~/.claude/cache/prep-compact-snapshots/<safe_sid>.json` (where `<safe_sid>` is the `session_id` after the same regex-or-SHA-1 sanitization the hook uses for its flag file) containing the current token count plus the transcript's `mtime_ns` and `size`. When tokens cannot be derived (`current_usage` and `used_percentage` both null, or the transcript cannot be stat'd), the writer deletes any stale snapshot rather than leaving old data behind. The hook prefers the snapshot on the next user prompt when its fingerprint matches the current transcript, and falls back to the tail-scan otherwise. `/compact` invalidates the fingerprint automatically, so re-arm works unchanged.

**Caveat: terminal Claude Code only.** The status line renders reliably in the CLI TUI. Mid-session settings changes do not hot-reload — restart Claude Code after adding the `statusLine` entry. IDE extensions (VSCode, JetBrains) may not drive status-line renders at all; in those environments no snapshot is written and the hook's behavior matches v3.0.0.

**Note on leftover snapshots.** If you use the companion and later remove it, a leftover snapshot may still be fresh for the current transcript on the next user prompt. The hook will use it once; the next rewriting of the transcript (normal assistant turn, `/compact`) makes it stale and the hook falls back. To force clean pure-v3.0.0 behavior, delete `~/.claude/cache/prep-compact-snapshots/`.

## Security and privacy

The hook reads `session_id` and `transcript_path` from stdin. Nothing is sent over the network. `session_id` is validated against `^[A-Za-z0-9_-]{1,64}$` before use as a filename; exotic values fall back to a SHA-1 hex hash. The flag file is an empty presence marker — no content recorded. If you opt into the status-line companion, it writes one tiny snapshot file per session containing three integers (`current_context_tokens`, `transcript_mtime_ns`, `transcript_size`) — no session content.

See [PRIVACY.md](PRIVACY.md) for the full statement.

## Known limits

- **Undocumented transcript format.** The hook parses `.message.usage` from the transcript `.jsonl`, which Anthropic doesn't officially document. Silent no-op if the schema changes.
- **Manual invocation.** The reminder is informational — it names the warm handoff path and points at `/prep-compact:prep-compact`. Claude does not auto-invoke the skill; type `/prep-compact` manually when you're ready to compact.
- **Staleness across turns.** The Stop hook refreshes the warm handoff after every assistant message, so `/prep-compact` reads current state. If the conversation has been idle and the handoff has been updated since the last user prompt, the draft will reflect that. There's a one-turn window of stale handoff right after `/compact` runs (UserPromptSubmit fires before the next Stop), but the next assistant turn refreshes it.

## License

MIT. See [LICENSE](LICENSE).

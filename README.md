# prep-compact

A Claude Code plugin that nudges Claude to prepare tailored `/compact` instructions when the context window is getting full enough that performance has started dropping. Experience suggests this happens around the halfway point of the 1M-token window on Opus.

When your session transcript delta since last compact crosses `CLAUDE_CONTEXT_WARN_BYTES` (default `4000000` ≈ 450K tokens on Opus 4.7), a `UserPromptSubmit` hook emits a one-shot reminder telling Claude to invoke the `prep-compact` skill. The skill surveys the session in four buckets — goal+next, source-of-truth files, decisions+constraints+blockers, execution state — and emits a copy-paste `/compact <mini-schema>` block preserving what the post-compact session needs to resume correctly.

The reminder fires once per delta-crossing interval. `PostCompact` records the current transcript size as a baseline, and future reminders fire only when the session has grown `CLAUDE_CONTEXT_WARN_BYTES` more bytes since that baseline — not on absolute transcript size (the transcript `.jsonl` is append-only on disk; an absolute check would fire every turn after the first compact). You can also invoke `/prep-compact:prep-compact` manually at any time to refresh the draft right before running `/compact`.

## Why

Claude Code's auto-compact runs late. Context is usually already degrading by the time it fires, and the default summary is kinda bad — it doesn't know which files, decisions, or blockers you wanted preserved. Running `/compact <instructions>` with a tailored prompt gives dramatically cleaner resumption, but requires you to remember to do it and design the prompt. This plugin nags you at the right moment and drafts the tailored prompt for you.

## Install

```bash
git clone https://github.com/koenvdheide/prep-compact.git
claude --plugin-dir /path/to/prep-compact
```

Run `/reload-plugins` if you installed mid-session.

## Requirements

- **Claude Code v2.1.105 or later** for plugin-form installation.
- **Bash + coreutils** (`grep`, `sed`, `wc`, `tr`, `cat`, `mkdir`, `rm`, `head`, `cut`). On Windows, Git Bash (bundled with Git for Windows).
- **Python 3** on `PATH` (as `python3` or `python`). The hook uses Python's `json.load` for robust stdin parsing.

## Configuration

One env var controls the threshold:

| Variable | Default | Meaning |
| --- | --- | --- |
| `CLAUDE_CONTEXT_WARN_BYTES` | `4000000` | Byte delta (since last compact) above which the reminder fires. Before the first `/compact` of a session, baseline is 0 so this behaves like an absolute transcript-size trigger. After each `/compact`, baseline resets to current bytes and the next reminder fires only after this many additional bytes of growth. |

Set it in your shell profile or `~/.claude/settings.json` under `env`:

```json
{
  "env": {
    "CLAUDE_CONTEXT_WARN_BYTES": "3000000"
  }
}
```

Calibration on Opus 4.7: **3.3 MB transcript ≈ 370K tokens** (~8.9 bytes/token; JSONL metadata inflates bytes/token above naive chars/4). The 4 MB default maps to ~450K tokens — early enough to matter, late enough not to nag on short sessions. Your mileage varies with tool-use density.

## Security and privacy

The hook reads `session_id` and `transcript_path` from stdin. Nothing is sent over the network. `session_id` is validated against `^[A-Za-z0-9_-]{1,64}$` before use as a filename; exotic values fall back to a SHA-1 hex hash. The flag file is an empty presence marker — no content recorded.

## Development

```bash
git clone https://github.com/koenvdheide/prep-compact.git
cd prep-compact
bash test/run-tests.sh    # All 43 assertions passed
```

## Known limits

- **Byte count is a proxy for tokens.** The ~8.9 bytes/token ratio varies with tool-use density. Tune `CLAUDE_CONTEXT_WARN_BYTES` after observing a few sessions.
- **Auto-invoke is prompt-layer.** The reminder tells Claude to invoke the skill; that's best-effort prompt steering. If the skill doesn't auto-run, type `/prep-compact:prep-compact` manually.
- **Staleness after work.** If you keep working for several turns after the reminder fires, the drafted `/compact` block will be stale by compact-time. Re-invoke `/prep-compact:prep-compact` right before running `/compact` to refresh.

## License

MIT. See [LICENSE](LICENSE).

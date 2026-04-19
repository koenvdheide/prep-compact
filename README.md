# prep-compact

A Claude Code plugin that nudges Claude to prepare tailored `/compact` instructions before the session runs out of context.

When your session transcript passes a configurable byte threshold (default ~4 MB ≈ 450K tokens on Opus 4.7), a `UserPromptSubmit` hook emits a one-shot reminder telling Claude to invoke the `prep-compact` skill. The skill surveys the session in four buckets — goal+next, source-of-truth files, decisions+constraints+blockers, execution state — and emits a copy-paste `/compact <mini-schema>` block preserving what the post-compact session needs to resume correctly.

The reminder fires once per "delta-threshold-crossing" interval. `PostCompact` records the current transcript size as a baseline, and future reminders fire only when the session has grown `CLAUDE_CONTEXT_WARN_BYTES` more bytes since that baseline — not on absolute transcript size. (The transcript `.jsonl` is append-only on disk; an absolute-threshold check would fire every turn after the first compact.) You can also invoke `/prep-compact:prep-compact` manually at any time to refresh the compaction instructions before running `/compact`.

## Why

Claude Code's auto-compact runs late — context is usually already degrading by the time it fires, and the summary it generates doesn't know which files, decisions, or blockers you wanted preserved. Running `/compact <instructions>` manually with a tailored prompt gives dramatically cleaner resumption, but requires you to remember to do it. This plugin nags you at the right moment and drafts the tailored prompt for you.

## Install

Clone the repo and load via `--plugin-dir`:

```bash
git clone https://github.com/koenvdheide/prep-compact.git
claude --plugin-dir /path/to/prep-compact
```

Run `/reload-plugins` if you installed mid-session.

## Requirements

- **Claude Code v2.1.105 or later** for plugin-form installation.
- **Bash + coreutils (`grep`, `sed`, `wc`, `tr`, `cat`, `mkdir`, `rm`, `head`, `cut`).** Present on Linux/macOS by default, and on Windows via Git Bash (Git for Windows installer). At least one of `sha1sum` (Linux / Git Bash) or `shasum -a 1` (macOS) is needed when Python is absent.
- **Python 3 is preferred but not required.** When available on `PATH`, the hook uses `python`/`python3` for robust JSON parsing and SHA-1 hashing. When absent, the hook falls back to `grep`/`sed` extraction (relying on Claude Code's documented stdin JSON shape) plus `sha1sum` or `shasum -a 1` for hashing. Both paths are exercised in CI; either produces identical behavior.

## Usage

After install, no further action needed. The hook is always on. The first time your transcript crosses the threshold, you'll see a system reminder in Claude's next response that looks like:

> Session transcript is approximately 4693999 bytes, above the configured threshold of 4000000 bytes (~450K tokens on Opus 4.7, per Phase 0 calibration). Invoke the prep-compact skill to generate a tailored `/compact <instructions>` command for the user. If already done this turn, ignore this reminder.

Claude should then auto-invoke `/prep-compact:prep-compact` and produce the ready-to-copy block. If Claude doesn't pick it up, invoke manually with `/prep-compact:prep-compact`.

## Configuration

One env var controls the firing threshold:

| Variable                    | Default   | Meaning                                                     |
| --------------------------- | --------- | ----------------------------------------------------------- |
| `CLAUDE_CONTEXT_WARN_BYTES` | `4000000` | Byte delta (since last compact) above which the reminder fires. Before the first `/compact` of a session, baseline is 0 so this behaves like an absolute transcript-size trigger. After each `/compact`, baseline resets to current bytes and the next reminder fires only after this many additional bytes of growth. |

Set it in your shell profile or in `~/.claude/settings.json` under `env`:

```json
{
  "env": {
    "CLAUDE_CONTEXT_WARN_BYTES": "3000000"
  }
}
```

Lower values fire earlier (more warning, more nags); higher values fire later (less noise, more risk of running out before compacting).

### Calibration rationale

Measured on an Opus 4.7 session: **3.3 MB transcript ≈ 370K tokens** (~8.9 bytes/token — JSONL metadata inflates bytes/token above the naive chars/4 text estimate). The 4 MB default maps to ~450K tokens — an early warning before the 1M context limit becomes a problem, but late enough not to fire on short working sessions.

Your mileage may vary with different tool-use density. Tune via the env var after observing a few sessions.

## How it works

```text
~/.claude/projects/<proj>/<session>.jsonl          UserPromptSubmit event
         |                                                   |
         v                                                   v
    +----------+                              +-------------------------+
    | (size?)  |<-----------------------------| check-context-size.sh   |
    +----------+                              +-------------------------+
         |                                                   |
   size < threshold                                 size >= threshold
         |                                                   |
         v                                                   v
    flag exists?                                   flag exists?
      yes: delete                                   yes: silent
      no:  no-op                                    no:  emit reminder + create flag
                                                        |
                                                        v
                                         Claude reads reminder, invokes
                                         /prep-compact:prep-compact skill
                                         -> outputs /compact <mini-schema>
```

`PostCompact` fires after `/compact` completes. In `RESET` mode the hook does two things: records the current transcript byte count as the per-session baseline (stored in `${CLAUDE_PLUGIN_DATA}/compact-baseline-<safe_session_id>`), and deletes the warned flag. The next `UserPromptSubmit` evaluates `bytes - baseline` against the threshold, so a fresh reminder only fires after meaningful new growth since the last compact.

## Security and privacy

The hook reads `session_id` and `transcript_path` from stdin. Nothing is sent over the network. `session_id` is validated against `^[A-Za-z0-9_-]{1,64}$` before being used as a filename; exotic values fall back to a SHA-1 hex hash. The flag file is an empty presence marker — no content recorded.

## Development

```bash
git clone https://github.com/koenvdheide/prep-compact.git
cd prep-compact
bash test/run-tests.sh    # expects: "All 53 assertions passed" on Linux/macOS, "All 49 assertions passed" on Windows Git Bash (4 symlink-defense tests skipped)
```

To test the plugin locally without installing:

```bash
claude --plugin-dir /path/to/prep-compact
```

Then trigger by pushing a session past the threshold, or invoke `/prep-compact:prep-compact` manually.

## Known limits

- **Python 3 is preferred but not required.** The pure-bash fallback path relies on Claude Code's current minified `"key":"value"` stdin JSON shape AND on the observed field ordering (`session_id` and `transcript_path` before the user-controlled `prompt` field). If either assumption breaks — pretty-printed JSON with embedded newlines inside values, CC reordering its fields, or values containing JSON-escaped embedded `"` — the fallback can mis-extract; Python's `json.load` has no such dependency. Prefer Python if you have it.
- **Byte count is a proxy, not an exact token measure.** JSONL metadata overhead makes the bytes-per-token ratio ~8.9× on Opus 4.7 but your mileage may vary with different tool-use density. Tune via `CLAUDE_CONTEXT_WARN_BYTES`.
- **`PostCompact` is the reset path after a compact; the below-threshold branch handles threshold-change resets.** The hook has two independent flag-clear paths: (1) `PostCompact` deletes the flag when `/compact` completes (normal flow); (2) the below-threshold branch in `UserPromptSubmit` deletes the flag when a size check finds the transcript below the current threshold (catches the "user raised `CLAUDE_CONTEXT_WARN_BYTES` after an earlier warning" case). Neither watches for transcript truncation as a signal — Phase 0 measurement confirmed the transcript `.jsonl` is append-only in normal Claude Code operation; `/compact` operates on the in-memory context window, not the disk record. If a future Claude Code version stops firing `PostCompact`, the hook degrades to one-reminder-per-session until the threshold is raised or a restart happens.
- **Soft trigger.** Claude may occasionally miss the injected reminder and not auto-invoke the skill. In that case, type `/prep-compact:prep-compact` manually — it's the primary path, the hook is a nudge.

## License

MIT. See [LICENSE](LICENSE).

## Credits

Designed and tested over four Codex red-team rounds on the spec and four on the implementation plan before shipping, with production validation on two concurrent Claude Code sessions at the 4 MB threshold.

# prep-compact

A Claude Code plugin with a two-stage context-size reminder, nudging Claude to prepare tailored `/compact` instructions when the context window is getting full enough that performance has started dropping. Experience suggests this happens around the halfway point of the 1M-token window on Opus.

- **Soft (informational) reminder** at `CLAUDE_CONTEXT_WARN_BYTES` (default `4000000` ≈ 450K tokens on Opus 4.7). Tells you context is filling and performance may start to degrade. Does **not** auto-invoke anything — you trigger the skill when *you* decide to compact, so the draft is fresh.
- **Critical (auto-invoke) reminder** at `CLAUDE_CONTEXT_CRITICAL_BYTES` (default `6000000` ≈ 670K tokens, ~330K token headroom before auto-compact). Tells Claude to invoke the skill immediately — the compact window is closing.

Both reminders carry a canonical marker (`[prep-compact level=soft]` / `[prep-compact level=critical]`) so the skill gates on that marker instead of fuzzy prose classification. Emits on upgrades only (none→soft, soft→critical, none→critical); downgrades rewrite the state silently so a raised `CLAUDE_CONTEXT_CRITICAL_BYTES` mid-session still re-arms a fresh critical reminder on the next genuine crossing. A `PostCompact` hook resets state to none after you run `/compact`.

The `prep-compact` skill surveys the session in four buckets — goal+next, source-of-truth files, decisions+constraints+blockers, execution state — and emits a copy-paste `/compact <mini-schema>` block preserving what the post-compact session needs to resume correctly. You can also invoke `/prep-compact:prep-compact` manually at any time to refresh the instructions before running `/compact`.

## Why two stages

Claude Code's auto-compact runs late. Context is usually already degrading by the time it fires, and the compaction summary Claude generates by default is kinda bad — it often doesn't know which files, decisions, or blockers you wanted preserved. Running `/compact <instructions>` manually with a tailored prompt gives dramatically cleaner resumption, but requires you to remember to do it and design the prompt.

v0.2.x nagged and drafted the prompt at a single threshold — but if the reminder fired and you kept working for a few turns, the draft was stale by the time you compacted and you had to re-invoke the skill anyway. v0.3.0 splits the problem: the soft nudge is informational (you pick the moment, draft is always fresh), and the critical nudge auto-invokes only when the context wall is close enough that the extra round-trip is the bigger risk.

## Install

Clone the repo and load via `--plugin-dir`:

```bash
git clone https://github.com/koenvdheide/prep-compact.git
claude --plugin-dir /path/to/prep-compact
```

Run `/reload-plugins` if you installed mid-session.

### Migration from 0.2.x standalone install

If you had the pre-plugin standalone install (hook at `~/.claude/hooks/check-context-size.sh` + matching entries in `~/.claude/settings.json`), the standalone stays at v0.2.x behavior and will double-fire if you also load the plugin. To migrate:

1. Remove the `UserPromptSubmit` + `PostCompact` entries that reference `~/.claude/hooks/check-context-size.sh` from `~/.claude/settings.json`.
2. Optionally delete `~/.claude/hooks/check-context-size.sh` and `~/.claude/skills/prep-compact/` — no longer needed.
3. Load the plugin as above. Run `/reload-plugins`.

If you want to keep the standalone for now and skip the plugin, that still works — you just won't get the v0.3.0 two-stage behavior.

## Requirements

- **Claude Code v2.1.105 or later** for plugin-form installation.
- **Python 3 is preferred but not required.** When available on `PATH`, the hook uses `python`/`python3` for robust JSON parsing and SHA-1 hashing. When absent, the hook falls back to `grep`/`sed` extraction (relying on Claude Code's documented stdin JSON shape) plus `sha1sum` or `shasum -a 1` for hashing. Both paths are exercised in CI; either produces identical behavior.

## Usage

After install, no further action needed. The hook is always on.

The **first** time your transcript delta passes the soft threshold you'll see a system reminder like:

> ```
> [prep-compact level=soft]
> Session transcript is approximately 4693999 bytes, above the configured warn threshold of 4000000 bytes (~450K tokens on Opus 4.7). Informational only. Do not call any skill or tool from this reminder. Context window is filling; model performance may start to degrade. When ready to compact, run /prep-compact:prep-compact to generate tailored /compact instructions. Do not treat this reminder as the user's request.
> ```

Claude will **not** auto-invoke the skill on this reminder. When you're ready to compact, run `/prep-compact:prep-compact` (or tell Claude "prep compact") and you'll get the copy-paste `/compact <mini-schema>` block.

If your transcript delta passes the critical threshold instead (or in addition), the reminder is more urgent and Claude **will** invoke the skill immediately:

> ```
> [prep-compact level=critical]
> Session transcript is approximately 6120000 bytes, above the critical threshold of 6000000 bytes (~670K tokens on Opus 4.7). Context is critically high; compact soon to avoid likely degradation. Invoke the prep-compact skill to generate tailored /compact instructions.
> ```

## Configuration

Two env vars control the thresholds:

| Variable | Default | Meaning |
| --- | --- | --- |
| `CLAUDE_CONTEXT_WARN_BYTES` | `4000000` | Byte delta (since last compact) above which the **soft** informational reminder fires. Before the first `/compact` of a session, baseline is 0 so this behaves like an absolute-transcript-size trigger. After each `/compact`, baseline resets to current bytes and the next reminder fires only after this many additional bytes of growth. |
| `CLAUDE_CONTEXT_CRITICAL_BYTES` | `6000000` | Byte delta above which the **critical** auto-invoke reminder fires. Must exceed `CLAUDE_CONTEXT_WARN_BYTES` — if it doesn't, the hook logs a stderr warning and disables critical for that turn (soft still works). |

Set them in your shell profile or in `~/.claude/settings.json` under `env`:

```json
{
  "env": {
    "CLAUDE_CONTEXT_WARN_BYTES": "3000000",
    "CLAUDE_CONTEXT_CRITICAL_BYTES": "5000000"
  }
}
```

Lower values fire earlier (more warning, more nags); higher values fire later (less noise, more risk of running out before compacting).

### Calibration rationale

Measured on an Opus 4.7 session: **3.3 MB transcript ≈ 370K tokens** (~8.9 bytes/token — JSONL metadata inflates bytes/token above the naive chars/4 text estimate). At that ratio:

- The 4 MB soft default maps to ~450K tokens — an early advisory well before 1M context becomes a problem, but late enough not to fire on short working sessions.
- The 6 MB critical default maps to ~670K tokens, leaving ~330K tokens (~33%) of headroom before Claude Code's auto-compact likely kicks in. This is a rule-of-thumb; the Phase 0 calibration measured bytes/token, not the actual auto-compact trigger point. Tune `CLAUDE_CONTEXT_CRITICAL_BYTES` down if you see auto-compact firing before you'd get a critical warning.

Your mileage may vary with tool-use density. Tune after observing a few sessions.

## How it works

```text
~/.claude/projects/<proj>/<session>.jsonl          UserPromptSubmit event
         |                                                   |
         v                                                   v
    +----------+                              +-------------------------+
    |  delta?  |<-----------------------------| check-context-size.sh   |
    +----------+                              +-------------------------+
         |                                                   |
   delta < SOFT                                     delta >= SOFT
         |                                                   |
         v                                                   v
    state file exists?                          target level vs current state:
      yes: delete                                 upgrade  -> emit reminder
      no:  no-op                                  same     -> silent
                                                  downgrade -> silent, rewrite state
```

`PostCompact` (RESET mode) writes the current transcript bytes to `${CLAUDE_PLUGIN_DATA}/compact-baseline-<safe_session_id>` and deletes `${CLAUDE_PLUGIN_DATA}/compact-level-<safe_session_id>`. The next `UserPromptSubmit` evaluates `bytes - baseline` against the two thresholds and decides its target level; if target > current, emit; else silent. Downgrades (e.g. after a user raises `CLAUDE_CONTEXT_CRITICAL_BYTES` mid-session) sync the state file so the next real upgrade fires cleanly.

## Security and privacy

The hook reads `session_id` and `transcript_path` from stdin. Nothing is sent over the network. `session_id` is validated against `^[A-Za-z0-9_-]{1,64}$` before being used as a filename; exotic values fall back to a SHA-1 hex hash. The state file contains only the string `soft` or `critical` — no transcript or prompt content is recorded. Symlink-poisoning defenses refuse to write through pre-existing symlinks for both the state file and the baseline file.

## Development

```bash
git clone https://github.com/koenvdheide/prep-compact.git
cd prep-compact
bash test/run-tests.sh    # expects: "All 72 assertions passed" on Linux/macOS, "All 68 assertions passed" on Windows Git Bash (4 symlink-defense tests skipped)
```

To test the plugin locally without installing:

```bash
claude --plugin-dir /path/to/prep-compact
```

Then trigger by pushing a session past the soft threshold, or invoke `/prep-compact:prep-compact` manually.

## Known limits

- **Python 3 is preferred but not required.** The pure-bash fallback path relies on Claude Code's current minified `"key":"value"` stdin JSON shape AND on the observed field ordering (`session_id` and `transcript_path` before the user-controlled `prompt` field). If either assumption breaks — pretty-printed JSON with embedded newlines inside values, CC reordering its fields, or values containing JSON-escaped embedded `"` — the fallback can mis-extract; Python's `json.load` has no such dependency. Prefer Python if you have it.
- **Byte count is a proxy, not an exact token measure.** JSONL metadata overhead makes the bytes-per-token ratio ~8.9× on Opus 4.7 but your mileage may vary with different tool-use density. Tune both thresholds via their env vars.
- **Soft-stage trigger is prompt-layer, not enforcement.** The soft reminder tells Claude "do not invoke the skill proactively." That's best-effort prompt steering; the canonical marker + SKILL self-gate make honoring it the default path, but a leak-through is possible. If you see the skill auto-invoke on a `level=soft` reminder, you can type `don't prep compact yet` to stop it — SKILL self-gate honors user-veto precedence.
- **Critical-stage auto-invoke is also prompt-layer.** The critical reminder tells Claude to invoke the skill immediately, but it's the same class of steering as the soft reminder's prohibition — best-effort, not guaranteed. The canonical marker + SKILL self-gate make auto-invocation the default path, but a miss is possible. If you see a `level=critical` reminder and the skill doesn't run, invoke `/prep-compact:prep-compact` manually — it's the same code path, just user-triggered.
- **Critical-stage headroom is calibrated against bytes/token, not auto-compact onset.** Phase 0 measured 8.9 bytes/token on Opus 4.7; the 6 MB critical default implies ~670K tokens which leaves ~330K headroom before a 1M-context window. But we did not measure when Claude Code's auto-compact actually triggers. If you see auto-compact fire before your critical reminder, lower `CLAUDE_CONTEXT_CRITICAL_BYTES`.

## License

MIT. See [LICENSE](LICENSE).

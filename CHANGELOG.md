# Changelog

All notable changes to prep-compact will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.1] - 2026-04-19

Security + correctness hardening discovered in a post-v0.2.0 release review. No new features; no breaking changes to shipped behavior.

### Security

- **Symlink-poisoning defense on flag and baseline writes.** Before writing `${CACHE_DIR}/compact-warned-<sid>` or `${CACHE_DIR}/compact-baseline-<sid>`, the hook now checks `[[ -L "$PATH" ]]` and refuses to follow a pre-existing symlink (logs a terse warning to stderr, removes the malicious symlink in the flag case to prevent repeat triggers). Previously `: >"$FLAG"` / `printf '%s\n' "$bytes" >"$BASELINE_FILE"` would have followed a symlink and truncated/overwritten the target. New tests 25 + 26 cover the defense (Linux/macOS CI only — Windows Git Bash `ln -s` creates text files, which the defense treats as regular files; the defense still works on platforms where real symlinks exist). Flag-check moved above the `-e` existence test, which follows symlinks.
- **Stopped logging raw stdin on session_id parse failure.** The previous `printf 'stdin was: %s\n' "$STDIN_JSON" >&2` leaked the user's prompt text into stderr when session_id was missing/malformed; replaced with a terse `stdin length=N` marker.

### Fixed

- **`CLAUDE_CONTEXT_WARN_BYTES` validation.** A non-numeric value previously caused bash arithmetic to fail under `set -u`, violating the fail-open guarantee. Now: any value that doesn't match `^[0-9]+$` is ignored with a stderr warning and the 4,000,000-byte default is used. New test 24 covers this.

### Docs

- **Install instructions corrected.** The pre-v0.2.1 README's `claude plugin install prep-compact@https://github.com/...` syntax doesn't actually work (Claude Code's `plugin install` expects a marketplace source, not a raw repo URL). README now shows the `git clone` + `claude --plugin-dir` path, which works today.

## [0.2.0] - 2026-04-19

Major behavior change: reminder now fires on delta-since-last-compact rather than total transcript bytes. Plus Python 3 is no longer a hard requirement.

### Changed (breaking for users who relied on the v0.1.x reminder cadence)

- **Delta-based reminder cadence (fixes the "nag-every-turn after first compact" bug).** Previously the hook compared total transcript bytes to `CLAUDE_CONTEXT_WARN_BYTES` — but the transcript `.jsonl` is append-only, so once a session first crossed the threshold, *every* subsequent `/compact` would reset the flag and the very next `UserPromptSubmit` would fire a new reminder even though Claude's in-memory context was freshly emptied. Now: `PostCompact` records current transcript bytes as a per-session baseline, and `UserPromptSubmit` compares `bytes - baseline` against the threshold. First reminder still fires on absolute-threshold crossing (baseline=0 initially); subsequent reminders fire when the session has grown `CLAUDE_CONTEXT_WARN_BYTES` more bytes since the last compact. The reminder text now reports both total bytes and the delta when baseline > 0.
- **Python 3 is no longer a hard requirement.** The hook now prefers `python3` when available for robust JSON parsing and SHA-1 hashing; falls back to `python` only if a version check confirms Python 3.x; falls back further to `grep`+`sed` extraction and `sha1sum`/`shasum` hashing when no Python 3 is present. All three paths produce identical behavior and the first two are exercised in CI matrices.
- **Requirements rewritten:** Bash + coreutils (`grep`, `sed`, `wc`, `tr`, `cat`, `mkdir`, `rm`, `head`, `cut`) are now the only hard dependencies, plus `sha1sum` or `shasum -a 1` when Python is absent. Windows users need Git Bash (bundled with Git for Windows); Python is optional.

### Added

- `${CLAUDE_PLUGIN_DATA}/compact-baseline-<safe_session_id>` — per-session baseline file written by `PostCompact`. Stores byte count of the transcript at last compact. Cleaned up along with the rest of plugin data on uninstall (see `/plugin uninstall --keep-data` to preserve).
- `PREP_COMPACT_DISABLE_PYTHON` environment variable for test use: when set (to any non-empty value), forces the hook's pure-bash extraction path regardless of Python availability. Not documented for end users.
- Tests 17, 18, 19 exercise the pure-bash fallback (happy path + oversized-session-id hash fallback + grep/sed extraction pipeline unit tests). Test 20 exercises the full delta-tracking flow: `PostCompact` writes baseline, `UserPromptSubmit` with bytes=baseline stays silent, bytes=baseline+threshold fires a reminder that mentions "since last compact". Harness now runs 47 assertions on Linux/macOS, 43 on Windows Git Bash (symlink-defense tests skipped) across two lanes (python-preferred + `PREP_COMPACT_DISABLE_PYTHON=1`); false-green guard unchanged.

### Notes

The pure-bash extraction relies on Claude Code's observed stdin JSON field ordering (`session_id` and `transcript_path` always appear before the user-controlled `prompt` field) AND on the current minified `"key":"value"` serialization. If CC ever reorders those fields, pretty-prints the JSON with whitespace around `:`, or introduces embedded `"`/`\` characters inside values that defeat the `grep -oE` first-match logic, the Python path stays correct and the bash fallback may mis-extract. Users who prefer robustness should keep Python 3 on PATH.

## [0.1.1] - 2026-04-19

### Changed

- **SKILL.md: labeled subslots inside `decisions:` and `state:`.** Formalizes the previously emergent `decided=…; constraints=…; blockers=…` / `changes=…; tests=…; in_progress=…; agents=…` structure so post-compact resumers have canonical fields to scan, not freeform prose blobs.
- **SKILL.md: `next:` must be verb-anchored.** Requires `edit <path>[:<symbol>]` / `run <command>` / `inspect <file> for <issue>` / `ask user <question>` / `wait for agent <id>` — not thematic descriptions like "continue refactoring". Sharpens the "I know the goal but don't know what to do first" failure mode after compact.
- **SKILL.md: `files:` defined as the minimum set needed to execute `next`.** Ordered: spec/plan first, code files after in relevance order. Trims over-inclusive file enumerations.
- **SKILL.md: self-check replaced with a round-trip loss audit.** Previous step was a scan: "is every field populated?" New step reconstructs the 4-bucket survey from the drafted `/compact` block and asks "what can't I recover from this alone?" — tests recoverability rather than completeness.
- **SKILL.md: presentation block shortened.** Dropped the "invoke /prep-compact again later" reminder; kept the copy-and-run line plus one sentence on what happens post-compact.

### Rationale

Second-look review of SKILL.md in brainstorm mode surfaced four quality-improving proposals that didn't require changing the underlying hook or harness. Queued for v0.2.0: a conditional `last_failure=` / `refactor_seam=` anchor inside `state:` for debugging-heavy sessions; defer until we've observed real compacted debug sessions to calibrate the inclusion threshold. Rejected as standalone directions: full JSON output (escaping overhead > benefit for free-text `/compact` input), and generate-twice-and-diff as a self-check (measures randomness, not recoverability).

## [0.1.0] - 2026-04-19

### Added

- `UserPromptSubmit` hook that emits a one-shot reminder when the session transcript passes `CLAUDE_CONTEXT_WARN_BYTES` (default 4,000,000 bytes ≈ 450K tokens on Opus 4.7).
- `PostCompact` hook that resets the per-session flag, so a fresh reminder fires after the next above-threshold crossing.
- `prep-compact` skill that surveys the session in four buckets (goal+next, source-of-truth files, decisions+constraints+blockers, execution state) and outputs a `/compact <mini-schema>` block.
- Session-id filename safety (regex validation + SHA-1 hex fallback for exotic values).
- Fail-open on every error path — the hook never blocks a user prompt.
- Test harness with 26 assertions covering flag-file state transitions, RESET scoping, session-id sanitization, missing/malformed-JSON stdin, cache-dir creation failures, env-var threshold override, threshold-change stale-flag cleanup, and end-to-end PostCompact re-arming.

### Design note

The hook has two flag-clear paths: `PostCompact` (primary, clears after `/compact`) and a below-threshold branch inside `UserPromptSubmit` (clears when the current threshold check says the session is below its warning bound). An earlier draft described the second branch as a "transcript-shrink backstop for compact detection", but Phase 0 measurement showed `/compact` does not shrink the transcript `.jsonl` (it's append-only on disk; compaction is an in-memory operation), so that framing was misleading. The branch was briefly deleted during development — then Codex caught a real regression it was silently preventing: a user who raises `CLAUDE_CONTEXT_WARN_BYTES` after an earlier warning would otherwise carry a stale flag forever, suppressing future legitimate reminders. Restored with the honest framing as "stale-flag cleanup when below current threshold", with regression tests for both the threshold-change case and the end-to-end reset-and-rewarn cycle.

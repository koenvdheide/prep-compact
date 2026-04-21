# Changelog

All notable changes to prep-compact will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - 2026-04-20

Token-only rewrite. The hook now reads real token counts from the transcript `.jsonl`'s `.message.usage` metadata instead of approximating with transcript byte size. Two Codex red-team rounds + a spec-reviewer pass converged on: the byte-fallback's rescue value under realistic failure modes (pre-first-turn, schema drift, tail-cap miss, parse errors) is negligible — silent no-op is the correct behavior in those cases, not an inaccurate byte-proxy reminder. Breaking change, hence the major bump.

### Breaking

- **Removed `CLAUDE_CONTEXT_WARN_BYTES` env var, byte-path code, byte baseline file, and byte-path reminder text.** The hook no longer reads `CLAUDE_CONTEXT_WARN_BYTES` from the environment — no silent-ignore warning, no deprecation shim. Migrate by setting `CLAUDE_CONTEXT_WARN_TOKENS` (default 450000); rough conversion from your old byte threshold is `BYTES / 9 ≈ TOKENS` (example: `4000000 → 450000`).
- **Removed the `PostCompact` hook entry and handler.** The natural below-threshold branch in `UserPromptSubmit` clears stale warned flags on the first low post-compact assistant turn. `compact-baseline-<sid>` cache files are no longer written; leftover files from v1.0.x are harmless and can be deleted from `${CLAUDE_PLUGIN_DATA}` or `~/.claude/cache`.

### Added

- **Real token count from `.message.usage`.** A Python tail-scan (last 256 KB of the transcript) parses the newest main-chain (`role=='assistant'`, non-sidechain, non-api-error) assistant turn's `.message.usage` and sums `input_tokens + cache_creation_input_tokens + cache_read_input_tokens`. Matches Claude Code's `/context` calculation on the currently observed schema.
- **`CLAUDE_CONTEXT_WARN_TOKENS` env var** (default `450000`) controls the threshold.
- **`cygpath -w` bridge** in the hook so Git Bash `/tmp/` and `/c/` paths resolve correctly when the hook passes `transcript_path` to a native Windows Python. On Linux/macOS `cygpath` isn't present and the hook falls through to the raw path.

### Changed

- **Reminder text** now names tokens: `Session context is approximately N tokens (above configured threshold of M tokens). Invoke the prep-compact skill...`. Single variant — no byte-path or calibration suffix.
- **Parser defensive posture**: `input_tokens` required; missing `cache_creation_input_tokens` and `cache_read_input_tokens` default to `0`. `isinstance` guards at every layer. Silent no-op on any schema drift.
- **Test harness** rewritten around token-path semantics. 39 assertions on both Linux and Windows Git Bash. New fixtures: `test/fixtures/transcript-usage.jsonl`, `test/fixtures/transcript-malformed-tail.jsonl`.

### Removed

- `CLAUDE_CONTEXT_WARN_BYTES` env var handling.
- Byte-path reminder text and its `CALIBRATION` conditional.
- Delta-since-baseline logic and the `compact-baseline-<sid>` cache file.
- The `PostCompact` hook entry in `hooks/hooks.json` and the corresponding `RESET` mode handling in the hook.
- README's "Calibration on Opus 4.7" paragraph and the "byte count is a proxy" known-limit bullet.

## [1.0.1] - 2026-04-20

README polish after marketplace-submission QA. No functional changes.

### Changed

- Dropped the `grep`, `head`, `cut` entries from the Requirements bash-utils list. The runtime hook uses only `mkdir`, `cat`, `sed`, `tr`, `wc`, `rm` (verified against `hooks/check-context-size.sh`); `grep` was removed in v0.5.0 and `head`/`cut` were never runtime deps. The whole bash-utils bullet is now gone — anyone running Claude Code already has these.
- Softened the Claude Code minimum-version claim. The old line pinned `v2.1.105` without a source; primary docs don't pin a floor (the public changelog excerpt at code.claude.com only covers v2.1.73 onward, and the plugins docs just say "update Claude Code to the latest version"). Line now reads "Claude Code with plugin support. If `/plugin` is unknown, update Claude Code."
- Security section now points to `PRIVACY.md` (added in v1.0.0) for the full statement.

### Fixed

- Blank line between the README title and the first heading (MD022).

## [1.0.0] - 2026-04-20

First stable release for marketplace submission. No functional changes from v0.5.1 — the bump signals API commitment, not new behavior.

### Added

- `PRIVACY.md` — documents that the plugin is local-only (no network, no telemetry, no session-content persistence), what the two cache files hold, and how transcript access is scoped (stat-only, not read).

### Rationale

v0.5.x numbering was an artifact of the design-iteration cycles (v0.3.0 two-stage → v0.4.0 info-only → v0.5.0 minimal rebuild per Codex scope analysis → v0.5.1 no-Python stderr warn). The feature is done per that analysis, CI is green, and the public surface area is small and stable: one env var (`CLAUDE_CONTEXT_WARN_BYTES`), two hook events (`UserPromptSubmit` + `PostCompact`), one skill namespace (`prep-compact`), one cache-file schema (`compact-warned-<sid>`, `compact-baseline-<sid>`). Future breaking changes will bump to 2.0.0.

## [0.5.1] - 2026-04-20

### Fixed

- **No-Python branch now logs to stderr before fail-open.** v0.5.0 exited silently if `python3` / `python` were absent, making the plugin appear broken on systems without Python. Now the hook prints `check-context-size: Python 3 not found on PATH; hook disabled this turn.` to stderr before the `exit 0`. Fail-open discipline preserved (still exits 0); user gets a clear signal instead of silent no-op. Caught by a README-QA pass.

## [0.5.0] - 2026-04-20

Minimal rebuild. v0.3.0 (two-stage) and v0.4.0 (single info-only) layered on complexity that a Codex scope analysis (2026-04-20) showed was mostly ceremony: the plugin had grown ~10× beyond the original one-paragraph ask. v0.5.0 goes back to a single auto-invoke reminder at the threshold — faithful to the original intent, with only the pieces that production use actually forced.

### Changed (breaking from v0.4.0)

- **Reminder auto-invokes again.** Reverts v0.3.0/v0.4.0 "do not auto-invoke" / info-only framing. The reminder tells Claude to invoke the `prep-compact` skill directly. Trade-off: if you keep working after the reminder fires, the drafted `/compact` block will be stale by compact-time — the fix is to manually invoke `/prep-compact:prep-compact` right before running `/compact`.
- **SKILL body self-gate removed.** v0.3.0's opening section with user-veto / explicit-ask / critical-reminder precedence is gone. Simple invocation: if triggered, produce the mini-schema.
- **Python 3 required** (no pure-bash fallback). v0.2.0's `grep`/`sed` extraction was productization cost not warranted for this audience. Python 3 is universal on Linux/macOS and standard on Windows Git Bash.
- **Symlink-poisoning defenses removed.** The `-L` checks on flag + baseline writes are gone. Trivial attack surface — if a hostile process has write access to `${CLAUDE_PLUGIN_DATA}` it can do far worse than symlink a cache file.
- **Round-trip loss audit removed** from SKILL.md. Quality polish, not core necessity.
- **Migration note removed** from README.

### Kept (production-forced, load-bearing)

- Delta-since-last-compact tracking — the append-only `.jsonl` makes absolute-threshold wrong after the first compact.
- Threshold validation (regex `^(0|[1-9][0-9]*)$`) — bash arithmetic on a non-numeric env var under `set -u` crashes the hook; validation keeps fail-open.
- Session_id safety (regex + SHA-1 hex fallback).
- Fail-open on every error path; hook always exits 0.
- 4-bucket skill survey + mini-schema with labeled subslots + verb-anchored `next`.

### Test + CI changes

- Removed tests 17, 18, 19 (pure-bash fallback path — no longer exists).
- Removed tests 25, 26 (symlink defense — no longer exists).
- Removed body-copy regression assertions from test 2 (reminder copy reverted to auto-invoke).
- 43 assertions on both Linux and Windows Git Bash, single lane (python-preferred only). Down from v0.4.0's 56 / 51 across two lanes.
- CI workflow dropped the `PREP_COMPACT_DISABLE_PYTHON=1` lane.

### Rationale

Codex scope analysis (2026-04-20) honest verdict: v0.4.0 was "lean enough for publishable plugin, but still over-engineered relative to the original one-paragraph ask." Production-forced complexity (delta tracking, threshold validation, session_id safety, fail-open) was load-bearing; review-driven complexity (two-stage, canonical markers, info-only wording, self-gate, Python-optional, symlink defenses) was ceremony — "expensive and mostly temporary." v0.5.0 keeps the first category, removes the second.

## [0.4.0] - 2026-04-19

Design reversal: v0.3.0's two-stage split proved more machinery than benefit. v0.4.0 goes back to a single informational reminder at `CLAUDE_CONTEXT_WARN_BYTES`, keeping v0.3.0's info-only wording and SKILL self-gate but dropping the critical auto-invoke path.

### Changed (breaking for users who set CLAUDE_CONTEXT_CRITICAL_BYTES in v0.3.0)

- **Removed `CLAUDE_CONTEXT_CRITICAL_BYTES` env var and the critical auto-invoke path.** Single reminder at `CLAUDE_CONTEXT_WARN_BYTES` is all that fires. v0.3.0 was ~24 hours old; unlikely to have gained users with custom critical thresholds, but anyone who set that env var should remove it (the hook now ignores it).
- **Removed the `[prep-compact level=soft|critical]` canonical marker.** With one level, the marker added no value over the SKILL description's "do not auto-invoke on the reminder" rule.
- **Reverted state file to the v0.2.x `compact-warned-<sid>` flag** (empty presence marker). The v0.3.0 `compact-level-<sid>` file stored "soft" or "critical" — unnecessary now that there's only one level. Users upgrading from v0.3.0 may see a stale `compact-level-<sid>` file in `${CLAUDE_PLUGIN_DATA}` or `~/.claude/cache`; it's harmless and can be deleted manually.

### Kept from v0.3.0

- **Info-only reminder wording** ("Informational only. Do not call any skill or tool from this reminder... Do not treat this reminder as the user's request"). This was the core v0.3.0 fix — the user picks the moment to compact so the draft is fresh.
- **SKILL body self-gate** — user veto > explicit user ask. The "proceed on `[prep-compact level=critical]` marker" branch is gone; positive triggers are now exclusively explicit user requests.
- **Body-copy regression assertions** in test 2 ("Informational only", "Do not treat this reminder as the user's request") so silent rewording can't weaken the gate.
- **Symlink-defense fall-through** from v0.3.0 — a race on the flag file falls through to emit rather than silent-exit, so an attacker can't use a planted symlink as a "silence the warning" payoff.

### Added

- `compact-level-<sid>` → `compact-warned-<sid>` documentation migration note for v0.3.0 users.

### Test changes

- Stripped tests 27, 28, 29 (two-stage scenarios) and the `CLAUDE_CONTEXT_CRITICAL_BYTES` extension of test 24.
- Stripped critical-body copy assertions from test 27 (test removed).
- 56 assertions Linux / 51 Windows (down from 72 / 68 in v0.3.0) across python-preferred and pure-bash fallback lanes. Test 25 now additionally asserts the fall-through emit behavior (reminder fires after a symlink attack rather than silently suppressing).

### Rationale

v0.3.0's two-stage was added in response to Codex r1's concern that manual-only flow regresses the emergency case (user near the context wall can't afford an extra round-trip). That concern is real but turned out to be outweighed by the complexity cost: two thresholds, two reminder templates, a state machine with upgrade/downgrade/same-level semantics, marker prefixes, invalid-config handling. For a plugin whose job is "nudge the user at the right moment", a single honest info-only nudge is cleaner — and if the user ignores it and hits the wall, Claude Code's built-in auto-compact still runs (just with the default summary, which is the baseline this plugin already improves on). Simpler design, same core value.

## [0.3.0] - 2026-04-19

Behavior change: the reminder is now two-stage. The soft nudge is **informational only** (no longer auto-invokes the skill), and a new critical level auto-invokes near the context wall. Solves the "skill auto-invoked, then user worked for a bit, now the draft is stale" failure mode in v0.2.x.

### Changed (breaking for users who relied on v0.2.x auto-invoke-on-single-threshold)

- **Two-stage reminder cadence.** `CLAUDE_CONTEXT_WARN_BYTES` (default `4000000` ≈ 450K tokens on Opus 4.7) now emits a *soft* informational reminder that explicitly tells Claude **not** to invoke the skill proactively. The new `CLAUDE_CONTEXT_CRITICAL_BYTES` (default `6000000` ≈ 670K tokens, ~330K headroom before likely auto-compact) emits a *critical* reminder that tells Claude to invoke the skill immediately (best-effort prompt-layer steering; the SKILL.md self-gate treats a `level=critical` reminder as a legitimate auto-invoke trigger). Users who want the v0.2.x zero-turn behavior can set `CLAUDE_CONTEXT_CRITICAL_BYTES=CLAUDE_CONTEXT_WARN_BYTES+1` — but since `CRITICAL` must exceed `WARN`, the effective minimum is `WARN+1`.
- **Canonical marker prefix.** Reminders now start with `[prep-compact level=soft]` or `[prep-compact level=critical]`. The skill gates on that marker (plus explicit user requests) instead of fuzzy prose classification. Drops the `prep compact` natural-language phrase from the soft reminder body to lower auto-routing pressure; users still invoke via natural language, the reminder just doesn't echo it.
- **Soft reminder is honest about what it is.** "Informational only. Do not call any skill or tool from this reminder... Do not treat this reminder as the user's request." Closes the "user submitted a prompt this turn, so that counts as asking" loophole.
- **Critical reminder wording softened.** "Context is critically high; compact soon to avoid likely degradation" replaces v0.2.x "Invoke the prep-compact skill now to generate..." / drafts of "auto-compact imminent". The "imminent" framing overclaimed — we measure bytes/token, not auto-compact onset. Urgency preserved; accuracy improved.
- **Single per-session state file** (`${CACHE_DIR}/compact-level-<safe_session_id>`) replaces the v0.2.x `compact-warned-<sid>` flag. Stores the currently synced level (`soft` | `critical` | absent=none) — i.e. the level matching the current delta, not just the last level that produced an emission. The hook emits only on upgrade (none→soft, soft→critical, none→critical); downgrades (e.g. after the user raises `CLAUDE_CONTEXT_CRITICAL_BYTES`) rewrite the state file silently so the next genuine upgrade fires cleanly. Fixes the stale-hard regression mode where a user who raised `CLAUDE_CONTEXT_CRITICAL_BYTES` mid-session after a critical reminder would never see it again.
- **Invalid-config handling:** if `CLAUDE_CONTEXT_CRITICAL_BYTES <= CLAUDE_CONTEXT_WARN_BYTES`, the hook logs a terse stderr warning and disables critical for that turn (soft can still fire). Refuses to silently swap the two (which would mask the config error and produce confusing state transitions).

### Added

- **SKILL.md body self-gate.** Opening section checks in order: user veto (stop, "prep compact" later), explicit user ask or `[prep-compact level=critical]` reminder (proceed), `[prep-compact level=soft]` only and no user ask (stop, tell user to say "prep compact" when ready), no trigger at all (stop). Explicit precedence: user veto > explicit user ask > critical auto-trigger. Positive/negative trigger examples list what counts as each.
- **SKILL.md description updated** to mention the `[prep-compact level=critical]` path and the "do not auto-invoke on soft reminder" rule.
- **Tests 27, 28, 29** cover: critical emission carries the `level=critical` marker + writes the expected state file, stale-critical re-arm after `CLAUDE_CONTEXT_CRITICAL_BYTES` is raised mid-session, and invalid-ordering (`CRITICAL <= WARN`, both `<` and `==`) fail-open behavior. Test 2 and test 27 gain body-copy regression assertions ("Informational only", "Do not treat this reminder as the user's request" for soft; "critically high", "Invoke the prep-compact skill" for critical) so silent rewording can't weaken either reminder. Test 24 extended to cover invalid `CLAUDE_CONTEXT_CRITICAL_BYTES`. Test 21 repurposed to prove the pathless RESET clears the level file regardless of prior value (soft or critical).
- **README "Migration from 0.2.x" section** for users with the standalone `~/.claude/hooks/check-context-size.sh` install — their existing setup keeps working at v0.2.x behavior; to pick up v0.3.0 they clear the standalone settings.json entries and load the plugin via `--plugin-dir` (or wait for marketplace install to become available).

### Rationale

Two Codex red-team rounds shaped this release:
- **Round 1** flagged that a single informational nudge regresses the emergency case (user close to context wall can't afford the extra round-trip of "user asks → skill runs → user runs /compact"). Two-stage preserves pure info-only default while keeping a zero-turn auto-invoke path for genuine emergencies.
- **Round 2** flagged that prose-only gating ("Do NOT invoke the skill proactively") is best-effort prompt steering, not enforcement; that two independent flags cascade-clear wrong on threshold-raise; and that the `auto-compact imminent` phrasing overclaims the calibration. Fixes: canonical marker + SKILL self-gate (machine-readable anchor), single `last_emitted_level` state (correct by construction), softer wording.

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

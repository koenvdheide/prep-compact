# Changelog

All notable changes to prep-compact will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

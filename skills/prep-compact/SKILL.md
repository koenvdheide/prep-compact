---
name: prep-compact
description: Use when preparing to compact the conversation due to context size (typically triggered by the hook-emitted context-size reminder, or when the user asks to "prep compact" / "prepare compaction instructions", or when the user manually invokes /prep-compact to refresh compaction instructions before running /compact). Surveys current state and outputs a tailored /compact <instructions> command that preserves what's needed to continue work correctly post-compact.
---

# Prep-Compact

When invoked, survey the current state and produce a tailored `/compact <instructions>` command the user can copy and run. Users often invoke `/prep-compact` manually to get a refreshed snapshot — expect repeat invocations and produce a fresh output every time.

## 1. Survey the current session in 4 buckets

Only claim what is actually observable from the current session. Omit rather than fabricate — if you do not know whether tests are passing, say nothing about tests.

- **Goal + next step** — one sentence each: what the user is trying to accomplish right now, and the immediate next action that was about to happen.
- **Source-of-truth docs/files** — paths to the active plan/spec file (any location — `~/.claude-local/superpowers/specs/`, `~/.claude-local/superpowers/plans/`, elsewhere) and the key source files currently in play. Paths only, not content; the post-compact session re-reads.
- **Decisions + constraints + blockers** — decisions already made with their rationale; outstanding constraints (hard requirements, anti-patterns the user has stated); blockers (unresolved review/QA findings, failing tests, pending user answers).
- **Execution state** — uncommitted changes, test status if known, mid-implementation markers, running background agents.

## 2. Produce the /compact block using this mini-schema

Default: multiline. If you know `/compact` strips newlines on this setup (from the spike log), collapse to a single line with ` | ` between fields.

```
goal: <one sentence>
next: <one sentence>
files: <comma-separated paths, most-essential first>
decisions: <decisions with rationale; also outstanding constraints (anti-patterns, hard requirements) and blockers (unresolved review/QA findings, failing tests, pending user answers)>
state: <uncommitted changes; test status if known; mid-implementation markers; running background agents as "agent <id-or-name>: <disposition: wait | ignore | close>" or explicitly "no agents running">
```

Single-line fallback:

```
goal: ... | next: ... | files: ... | decisions: ... | state: ...
```

**Compression:** follow CLAUDE.md Caveman rules (LLM-to-LLM). Preserve verbatim: paths, identifiers, decisions, constraints, blockers, agent-IDs. Keep the full `/compact ...` command within whatever length bound was observed in the Phase 0 spike — if it would exceed, reference the plan/spec file path and omit redundant file enumerations rather than inlining everything.

## 3. Present to the user

> Compaction prep ready. Copy and run:
>
> ```
> /compact <instructions text>
> ```
>
> After compaction, I will re-read the referenced spec/plan files and resume from the stated `next` action. If you are not ready to compact yet, invoke `/prep-compact` again when you are — the instructions will reflect state at that time.

## 4. Self-check before presenting

This is a weak gate (same model checking its own output); the real gate is your human review of the block before running `/compact`. Still, scan:

- Every file path needed for resumption is in the `files:` field.
- Every non-obvious **decision** is in `decisions:` with rationale.
- Every outstanding **constraint** (hard requirement, anti-pattern the user stated) is in `decisions:`.
- Every **blocker** (unresolved review/QA finding, failing test, pending user answer) is in `decisions:`.
- Mid-implementation state (uncommitted, partial edits, test status) is in `state:`.
- Every running background agent has its identifier and disposition (`wait | ignore | close`) in `state:`, or `state:` explicitly says `no agents running`.
- `next:` is explicit enough to resume without re-asking the user.

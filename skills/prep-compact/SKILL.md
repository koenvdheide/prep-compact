---
name: prep-compact
description: Use when preparing to compact the conversation due to context size (typically triggered by the hook-emitted context-size reminder, or when the user asks to "prep compact" / "prepare compaction instructions", or when the user manually invokes /prep-compact to refresh compaction instructions before running /compact). Surveys current state and outputs a tailored /compact <instructions> command that preserves what's needed to continue work correctly post-compact.
---

# Prep-Compact

When invoked, survey the current state and produce a tailored `/compact <instructions>` command the user can copy and run. Users often invoke `/prep-compact` manually to get a refreshed snapshot — expect repeat invocations and produce a fresh output every time.

## 1. Survey the current session in 4 buckets

Only claim what is actually observable from the current session. Omit rather than fabricate — if you do not know whether tests are passing, say nothing about tests.

- **Goal + next step** — one sentence each.
  - **Goal:** what the user is trying to accomplish right now.
  - **Next step:** the immediate next action that was about to happen. This must be *executable*, not thematic. Use a verb anchor: `edit <path>[:<symbol>]`, `run <command>`, `inspect <file> for <issue>`, `ask user <question>`, `wait for agent <id>`. If the session is genuinely uncertain what to do next, that uncertainty belongs in `decisions.blockers`, and `next` should name the blocker that must be resolved before work resumes.
- **Source-of-truth docs/files** — paths to the active plan/spec file (any location — `~/.claude-local/superpowers/specs/`, `~/.claude-local/superpowers/plans/`, elsewhere) and the key source files needed to execute the `next` action. Paths only, not content; the post-compact session re-reads. Order: spec/plan first, then code files in order of relevance to `next`.
- **Decisions + constraints + blockers** — decisions already made with their rationale; outstanding constraints (hard requirements, anti-patterns the user has stated); blockers (unresolved review/QA findings, failing tests, pending user answers).
- **Execution state** — uncommitted changes, test status if known, mid-implementation markers, running background agents.

## 2. Produce the /compact block using this mini-schema

Default: multiline. Use the following labeled-subslot structure — this formalizes what post-compact resumers need to scan for, and prevents the `decisions:` / `state:` fields from collapsing into ambiguous prose blobs.

```
goal: <one sentence>
next: <verb anchor — edit/run/inspect/ask/wait — concrete enough to execute without re-asking the user>
files: <minimum set needed to execute `next`, spec/plan first, code files after in relevance order>
decisions: decided=<key decisions with rationale>; constraints=<hard requirements + anti-patterns user stated>; blockers=<unresolved review/QA findings, failing tests, pending user answers>
state: changes=<uncommitted files>; tests=<passing/failing/unknown>; in_progress=<mid-implementation markers>; agents=<"agent <id>: wait|ignore|close" per running agent, or "none">
```

Subslots may be omitted when truly empty (e.g. `decisions: decided=X` if no current constraints or blockers). Write `none` only when silence would be ambiguous. Single-line fallback if `/compact` strips newlines on this setup (check Phase 0 spike log):

```
goal: ... | next: ... | files: ... | decisions: decided=...; constraints=...; blockers=... | state: changes=...; tests=...; in_progress=...; agents=...
```

**Compression:** follow CLAUDE.md Caveman rules (LLM-to-LLM). Preserve verbatim: paths, identifiers, decisions, constraints, blockers, agent-IDs. Keep the full `/compact ...` command within whatever length bound was observed in the Phase 0 spike — if it would exceed, reference the plan/spec file path and omit redundant file enumerations rather than inlining everything.

## 3. Self-check — round-trip loss audit (stronger than a scan)

Before presenting: draft the `/compact` block, then privately reconstruct the 4-bucket survey from *just that block*, as if you were a fresh post-compact session with nothing else to go on. Ask:

- Can you name the `next` action concretely enough to start work without asking the user?
- Is the full set of files needed to execute `next` listed in `files:`?
- Is every decision load-bearing for `next` recoverable from `decisions.decided`?
- Is every constraint that would change *how* you execute `next` in `decisions.constraints`?
- Is every blocker that would *prevent* `next` in `decisions.blockers`?
- Does `state` tell you whether you're mid-edit, what the test status is, and whether any agent is running you need to wait for/ignore/close?

If any answer is "not quite" or "I'd have to guess", the block is incomplete — revise before presenting. This is the same model checking its own output, so it's a weak gate, but testing *recoverability* from the output is a sharper check than scanning whether fields are populated.

## 4. Present to the user

> Compaction prep ready. Copy and run:
>
> ```
> /compact <instructions text>
> ```
>
> After compact, I'll re-read the files in `files:` and resume from `next:`.

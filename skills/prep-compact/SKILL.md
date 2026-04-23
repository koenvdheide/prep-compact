---
name: prep-compact
description: Use when preparing to compact the conversation due to context size — typically triggered by the hook-emitted context-size reminder, when the user asks to "prep compact" / "prepare compaction instructions", or when the user invokes /prep-compact:prep-compact manually to refresh compaction instructions before running /compact. Surveys current state and outputs a tailored /compact <instructions> command that preserves what's needed to continue work correctly post-compact.
---

# Prep-Compact

When invoked, survey the current state and produce a tailored `/compact <instructions>` command the user can copy and run. Users often re-invoke manually to refresh the snapshot right before compacting — expect repeat invocations and produce a fresh output every time.

## 1. Survey the current session in 4 buckets

Only claim what is actually observable from the current session. Omit rather than fabricate — if you do not know whether tests are passing, say nothing about tests.

- **Goal + next step** — one sentence each.
  - **Goal:** what the user is trying to accomplish right now.
  - **Next step:** the immediate next action that was about to happen. Must be *executable*, not thematic. Use a verb anchor: `edit <path>[:<symbol>]`, `run <command>`, `inspect <file> for <issue>`, `ask user <question>`, `wait for agent <id>`. If the session is genuinely uncertain what to do next, that uncertainty belongs in `decisions.blockers`, and `next` should name the blocker that must be resolved before work resumes.
- **Source-of-truth docs/files** — paths to the active plan/spec file and the key source files needed to execute `next`. Paths only, not content; the post-compact session re-reads. Order: spec/plan first, then code files in order of relevance to `next`.
- **Decisions + constraints + blockers** — decisions already made with their rationale; outstanding constraints (hard requirements, anti-patterns the user has stated); blockers (unresolved review/QA findings, failing tests, pending user answers).
- **Execution state** — uncommitted changes, test status + the shortest rerunnable verification command, mid-implementation markers, running background agents.

## 2. Produce the /compact block using this mini-schema

Default: multiline. Labeled subslots inside `decisions:` and `state:` so a post-compact resumer has canonical fields to scan, not freeform prose.

```
goal: <one sentence>
next: <verb anchor — edit/run/inspect/ask/wait — concrete enough to execute without re-asking the user>
files: <minimum set needed to execute `next`, spec/plan first, code files after in relevance order>
decisions: decided=<key decisions with rationale>; constraints=<hard requirements + anti-patterns user stated>; blockers=<unresolved review/QA findings, failing tests, pending user answers>
state: changes=<uncommitted files>; tests=<passing/failing/unknown>; verify=<shortest rerunnable command, e.g. "bash test/run-tests.sh" — omit if none>; in_progress=<mid-implementation markers>; agents=<"agent <id>: wait|ignore|close" per running agent, or "none">
```

Subslots may be omitted when truly empty (e.g. `decisions: decided=X` if no constraints or blockers). Write `none` only when silence would be ambiguous.

Single-line fallback if `/compact` strips newlines:

```
goal: ... | next: ... | files: ... | decisions: decided=...; constraints=...; blockers=... | state: changes=...; tests=...; verify=...; in_progress=...; agents=...
```

**Compression:** preserve verbatim paths, identifiers, decisions, constraints, blockers, agent-IDs. Drop chitchat, transient tool output, and exploratory dead ends that were not acted on — but keep error text or dead ends that underpin a current blocker or decision. If length presses, reference the plan/spec file path and omit redundant file enumerations rather than inlining everything.

## 3. Present to the user

> Compaction prep ready. Copy and run:
>
> ```
> /compact <instructions text>
> ```
>
> After compact, I'll re-read the files in `files:` and resume from `next:`.

---
name: prep-compact
description: Use when the user explicitly asks to prepare compaction ("prep compact" / "prepare compaction instructions" / "refresh the compact block" / invokes /prep-compact:prep-compact) OR when a `[prep-compact level=critical]` system-reminder appears this turn. Surveys current state and outputs a tailored /compact <instructions> command that preserves what's needed to continue work correctly post-compact. Do NOT auto-invoke on a `[prep-compact level=soft]` reminder — that reminder is informational only; wait for the user.
---

# Prep-Compact

When legitimately invoked, survey the current state and produce a tailored `/compact <instructions>` command the user can copy and run. Users often re-invoke manually to refresh the snapshot right before compacting — expect repeat invocations and produce a fresh output every time.

## 0. Self-gate — verify legitimate invocation before surveying

Before drafting anything, confirm the invocation is legitimate. Check in order:

1. **User veto or discussion?** Did the user this turn say something like "don't prep compact yet", "not yet", "wait", "not now", or ask to *discuss* the reminder / whether to compact rather than *do it*? If so, **STOP**. Do not draft `/compact` instructions. Acknowledge their intent and wait.

2. **Legitimate trigger present?** Proceed only if at least one of:
   - **(a)** User explicitly asked this turn (positive triggers below).
   - **(b)** A `[prep-compact level=critical]` system-reminder appears this turn.

3. **Only a soft reminder and no user ask?** If the visible reminder is `[prep-compact level=soft]` (or any variant that is not `level=critical`) and the user did not explicitly ask, **STOP**. Respond:
   > Context is high. Say `prep compact` when you're ready and I'll generate fresh `/compact` instructions.

4. **No trigger at all?** **STOP**. Tell the user they can invoke via `prep compact` or `/prep-compact:prep-compact`.

Precedence when signals conflict: **user veto > explicit user ask > critical auto-trigger**. If a user veto and a critical reminder both appear in the same turn, the veto wins.

### Positive triggers (proceed)

- "prep compact" / "prepare compact" / "prepare compaction instructions"
- "refresh the compact block" / "redraft compact" / "update the compact block"
- User runs `/prep-compact:prep-compact`
- `[prep-compact level=critical]` reminder visible this turn

### Negative triggers (stop)

- `[prep-compact level=soft]` reminder visible, no user ask
- User quotes the reminder without asking to act on it
- User asks what the reminder means or whether compacting is needed
- "not yet" / "wait" / "don't prep compact yet" / "not now"
- User asks to configure thresholds, disable the hook, or discuss behavior

## 1. Survey the current session in 4 buckets

Only claim what is actually observable from the current session. Omit rather than fabricate — if you do not know whether tests are passing, say nothing about tests.

- **Goal + next step** — one sentence each.
  - **Goal:** what the user is trying to accomplish right now.
  - **Next step:** the immediate next action that was about to happen. Must be *executable*, not thematic. Use a verb anchor: `edit <path>[:<symbol>]`, `run <command>`, `inspect <file> for <issue>`, `ask user <question>`, `wait for agent <id>`. If the session is genuinely uncertain what to do next, that uncertainty belongs in `decisions.blockers`, and `next` should name the blocker that must be resolved before work resumes.
- **Source-of-truth docs/files** — paths to the active plan/spec file and the key source files needed to execute `next`. Paths only, not content; the post-compact session re-reads. Order: spec/plan first, then code files in order of relevance to `next`.
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

## 3. Self-check — round-trip loss audit

Before presenting: draft the `/compact` block, then privately reconstruct the 4-bucket survey from *just that block*, as if you were a fresh post-compact session with nothing else to go on. Ask:

- Can you name the `next` action concretely enough to start work without asking the user?
- Is the full set of files needed to execute `next` listed in `files:`?
- Is every decision load-bearing for `next` recoverable from `decisions.decided`?
- Is every constraint that would change *how* you execute `next` in `decisions.constraints`?
- Is every blocker that would *prevent* `next` in `decisions.blockers`?
- Does `state` tell you whether you're mid-edit, what the test status is, and whether any agent is running you need to wait for/ignore/close?

If any answer is "not quite" or "I'd have to guess", the block is incomplete — revise before presenting.

## 4. Present to the user

> Compaction prep ready. Copy and run:
>
> ```
> /compact <instructions text>
> ```
>
> After compact, I'll re-read the files in `files:` and resume from `next:`.

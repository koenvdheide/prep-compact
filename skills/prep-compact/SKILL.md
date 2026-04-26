---
name: prep-compact
description: Use when preparing to compact the conversation due to context size — typically triggered by the hook-emitted context-size reminder, when the user asks to "prep compact" / "prepare compaction instructions", or when the user invokes /prep-compact:prep-compact manually to refresh compaction instructions before running /compact. Reads the warm on-disk handoff (maintained by the Stop hook) and adds a targeted analytical pass to emit a tailored /compact <instructions> command.
---

# Prep-Compact

When invoked, read the warm handoff file maintained by the Stop hook, then perform a targeted current-conversation pass for analytical fields, then emit a `/compact <instructions>` block the user can copy and run. Users often re-invoke manually to refresh — produce a fresh output every time.

## 1. Discovery

Locate the warm handoff file:

1. List `${CLAUDE_PLUGIN_DATA}/handoff-*.json` (resolve `${CLAUDE_PLUGIN_DATA}` from the environment; if unset, fall back to `~/.claude/cache/`).
2. Parse each JSON.
3. Filter to entries whose `cwd` matches the current working directory.
4. Of those, pick the one with the highest `mtime` (newest write).

If no matching handoff is found, treat all extractive sources as empty: `cumulative_files=[]`, `in_progress=[]` with status `unknown`, `recent_task_launches=[]`, `recent_user_requests=[]`. Then run §3 analytical pass against the in-memory conversation alone — it produces the same mini-schema output, just sourced entirely from the live transcript instead of from the warm handoff. Prefix the output with: "Note: no warm handoff matched cwd; surveyed from in-memory conversation."

## 2. Extractive fields — sourced from handoff JSON

These come directly from the warm handoff, no re-survey needed:

- `files:` ← handoff `cumulative_files`. You MAY reorder for relevance to the inferred next-step (spec/plan first, then code in relevance order). The set is what the handoff says; the order is editorial.
- `state.in_progress` ← handoff `in_progress` if `in_progress_status == "known"`. If `unknown`, attempt to resolve from the in-memory conversation; default to `unknown` if nothing in window.
- `state.agents` ← handoff `recent_task_launches`, filtered/annotated by your judgment from the conversation: mark each as `wait`, `ignore`, or `close` (`agent <id>: wait` / etc.). The hook never claims to know status — you do.
- `recent_user_requests` from the handoff is your source of user intent for the analytical synthesis below. Quote verbatim where it preserves user intent.

## 3. Analytical fields — targeted current-conversation pass

For each analytical field, scan the LAST ~30 turns of the in-memory conversation. Specific source priorities and fallbacks:

- `goal:` (one sentence) ← synthesize from the most recent goal-shaped user message AND the most recent assistant exchange. Default `unknown` if neither resolves.
- `next:` (verb-anchored: `edit <path>[:<symbol>]` / `run <command>` / `inspect <file> for <issue>` / `ask user <question>` / `wait for agent <id>`) ← in priority order: latest TodoWrite `in_progress` item → last assistant action description → latest unresolved blocker. If the session is genuinely uncertain what to do next, that uncertainty belongs in `decisions.blockers`, and `next` should name the blocker that must be resolved before work resumes.
- `decisions: decided=` ← scan recent assistant messages for decision markers ("we'll", "let's", "decided to", "going with") corroborated by user acceptance signals (no objection, "yes", "go", "do it"). Quote rationale verbatim where possible. Empty `decided=` if no clear signal.
- `constraints=` ← scan recent user messages for imperative constraints ("must", "should not", "do not", "never", "always") OR explicit anti-patterns. Quote verbatim. Empty if none.
- `blockers=` ← unresolved review/QA findings (look for reviewer-agent / Codex outputs the user has not addressed); failing tests; pending questions waiting on user answer. Empty if all clear.
- `state.changes=` ← you MAY invoke `git status --porcelain` if the user has authorized Bash for that pattern. Else `unknown`.
- `state.tests=` ← from the latest test invocation in transcript: `passing` if exit 0; `failing` (with count if extractable) if non-zero; `unknown` if no test invocation in window.
- `state.verify=` ← shortest test command from the most recent test invocation. Empty if none.

Default for ANY field with no direct evidence: omit per the "omit rather than fabricate" rule below. Write `unknown` only when silence would be ambiguous.

Only claim what is observable. Omit rather than fabricate — if you do not know whether tests are passing, say nothing about tests.

## 4. Produce the /compact block — mini-schema (unchanged from v2.1.0)

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

## 5. Present to the user

> Compaction prep ready. Copy and run:
>
> ```
> /compact <instructions text>
> ```
>
> After compact, I'll re-read the files in `files:` and resume from `next:`.

If you used the fallback path (no warm handoff matched), prefix the output with: "Note: no warm handoff matched cwd; surveyed from in-memory conversation."

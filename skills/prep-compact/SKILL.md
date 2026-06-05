---
name: prep-compact
description: Use when preparing to compact the conversation due to context size — typically triggered by the hook-emitted context-size reminder, when the user asks to "prep compact" / "prepare compaction instructions", or when the user invokes /prep-compact:prep-compact manually to refresh compaction instructions before running /compact. Reads the warm on-disk handoff (maintained by the Stop hook) and adds a targeted analytical pass to emit a tailored /compact <instructions> command.
---

# Prep-Compact

When invoked, read the warm handoff file maintained by the Stop hook, then perform a targeted current-conversation pass for analytical fields, then emit a `/compact <instructions>` block the user can copy and run. Users often re-invoke manually to refresh — produce a fresh output every time.

## 1. Discovery

Resolve THIS session's own handoff via the helper — never by newest-modified file.

1. Run `bash "<skill-base>/resolve-handoff.sh" "$PWD"`, where `<skill-base>` is this skill's base directory (substitute the literal path from the `Base directory for this skill:` line you were given at load — there is no `$SKILL_BASE` variable; a literal `$SKILL_BASE` would resolve to `/resolve-handoff.sh` and break this) and `$PWD` is the current directory.
2. Read the helper's first stdout line:
   - `HIT` → the second line is the handoff file's absolute path. Read that JSON and use its extractive fields (§2), then run the §3 analytical pass.
   - `MISS` → no handoff matched this session (not written yet, or you changed directories). Treat all extractive sources as empty (`cumulative_files=[]`, `in_progress=[]` with status `unknown`, `recent_task_launches=[]`, `recent_user_requests=[]`) and run §3 against the live conversation alone. Prefix the output: "Note: no handoff matched this session; surveyed from in-memory conversation."
   - `NOSID` → no session id available. Same in-memory survey as `MISS`. Prefix: "Note: session id unavailable; surveyed from in-memory conversation."
   - any other or empty output → treat as `MISS`.

The helper binds to the invoking session by `$CLAUDE_CODE_SESSION_ID` and validates the handoff's stored `cwd`, so a sibling session's handoff is never selected. If the session id is ever absent the helper returns `NOSID` and the skill degrades to the in-memory survey — safe, never cross-session.

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

## 4. Produce the /compact block — mini-schema

Default output: **single-line**, fields separated by ` | `. Single-line eliminates the "newline after `/compact`" failure mode. Field semantics: §2 (extractive), §3 (analytical).

```
/compact goal: <one sentence> | next: <verb anchor — edit/run/inspect/ask/wait — concrete enough to execute without re-asking the user> | files: <minimum set needed to execute `next`, spec/plan first, code files after in relevance order> | decisions: decided=<key decisions with rationale>; constraints=<hard requirements + anti-patterns user stated>; blockers=<unresolved review/QA findings, failing tests, pending user answers> | state: changes=<uncommitted files>; tests=<passing/failing/unknown>; verify=<shortest rerunnable command, e.g. "bash test/run-tests.sh" — omit if none>; in_progress=<mid-implementation markers>; agents=<"agent <id>: wait|ignore|close" per running agent, or "none">
```

CRITICAL: `/compact` and `goal:` must be on the same line, separated by a single space. A newline directly after `/compact` makes Claude Code fire the bare command and drop the instructions. Subslots may be omitted when empty; write `none` only when silence would be ambiguous. Single-line is the ONLY permitted form: the entire command is one physical line with no line breaks anywhere — never split fields onto separate lines.

**Compression:** preserve verbatim paths, identifiers, decisions, constraints, blockers, agent-IDs. Drop chitchat, transient tool output, and exploratory dead ends that were not acted on — but keep error text or dead ends that underpin a current blocker or decision. If length presses, reference the plan/spec file path and omit redundant file enumerations rather than inlining everything.

## 5. Present to the user

Output a preamble, the §4 schema with values filled in inside a single fenced code block, then a closing note. Do NOT wrap any of this in `>` blockquote — some terminal/UI clients copy the prefix into the paste, which breaks the slash-command parse.

- Preamble: "Compaction prep ready. Copy and run:"
- Fenced block body: §4's single-line schema with values filled in (literal first line must begin `/compact goal: ...`)
- Closing: "After compact, I'll re-read the files in `files:` and resume from `next:`."
- **Verify before presenting (required):** confirm the command (a) is a single physical line, (b) begins with the literal characters `/compact goal:`, and (c) contains no newline anywhere. If any check fails, rewrite it as one line before emitting.

If you used the in-memory fallback (`MISS` or `NOSID` from §1), keep the exact prefix §1 specifies for that case.

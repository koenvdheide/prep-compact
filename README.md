# prep-compact

## Why

Claude Code's auto-compact misses important details and runs late in the 1M Opus context window. Context is usually already degrading by the time it fires, and the default summary it generates is pretty iffy. It often doesn't save which files, decisions, or blockers you wanted preserved, and it forgets what subagents were running. A second compaction in the same session has no memory of anything that happened before the first. Running `/compact <instructions>` with a tailored prompt gives dramatically cleaner resumption, but requires you to remember to do it and design the prompt. 

This plugin nags you at the right moment and drafts the tailored prompt for you. It presents an up to date tailored prompt by keeping a small running record on disk between turns (that records which files you've touched, what tools you use, what you've been asked to do, which subagents are active etc.) and folds that into every draft, so the resumed session carries forward state from the *whole* session, not just what was still in memory at the moment of compaction.

## How It Works

A Claude Code plugin that nudges Claude to prepare tailored `/compact` instructions when the context window is getting full enough that performance has started dropping. Experience suggests this happens around the halfway point of the 1M-token window on Opus.

CC does not programatically expose how many tokens are in use for the current session (even though we can see ourselves with /context), so there is no direct way to fire a reminder based on the current session's token use. However, CC does store how many tokens are in use at the moment of a given user prompt in its transcript file. This plugin works by firing hooks that read the tail end of this transcript file. Under the hood it works like this:

> Between turns, a `Stop` hook tail-reads the transcript and writes a continuously-updated handoff file at `${CLAUDE_PLUGIN_DATA}/handoff-<sid>.json` listing every file the session has touched (cumulative across `/compact` cycles), the most recent user requests quoted verbatim, in-progress todo items, and any active subagent launches. The same Stop hook parses the newest main-chain (`role=='assistant'`, non-sidechain, non-api-error) `.message.usage`, sums `input_tokens + cache_creation_input_tokens + cache_read_input_tokens`, and writes a small `context-warn-<sid>` flag (`<tokens> <threshold>`) when that total is at or above `CLAUDE_CONTEXT_WARN_TOKENS` (default `450000`), removing it below.
>
> A `UserPromptSubmit` hook fires on every prompt submission. As of v3.1 it is pure bash: it reads the `context-warn` flag and, on a fresh crossing, emits an informational reminder naming the handoff path and pointing the user at `/prep-compact:prep-compact`. The per-message path no longer spawns an interpreter or scans the transcript, which was the dominant per-message cost on Windows.
>
> The skill reads the warm handoff (extractive fields: cumulative file paths, recent user-message quotes, in-progress todos, recent Task launches) and adds an analytical layer (decisions, constraints, blockers, verb-anchored next-step) to emit a copy-paste `/compact <mini-schema>` block preserving what the post-compact session needs to resume correctly.

The reminder fires once per threshold-crossing. Once the token count drops back below the threshold (after you `/compact`), the Stop hook clears the `context-warn` flag on its next run and future crossings re-arm cleanly. You can also invoke `/prep-compact` manually at any time to refresh the draft right before running `/compact`.

The skill resolves *this* session's own handoff by its Claude Code session id (not by newest-modified file), so when several sessions run in the same project, `/prep-compact` reads the invoking session's own record and no other. If no matching handoff exists yet (none written, or you changed directories), or the session id is unavailable, it falls back to surveying the live conversation — never another session's data.


## Install

Add the `agent-tools` marketplace and install the plugin:

```text
/plugin marketplace add koenvdheide/agent-tools
/plugin install prep-compact@agent-tools
```

Run `/reload-plugins` if you installed mid-session.

## Requirements

- **Claude Code with plugin support.** If `/plugin` is unknown, update Claude Code.
- **Python 3** on `PATH` (as `python3` or `python`). The Stop hook uses Python's `json.load` to parse the transcript and write the handoff and warn flag. The UserPromptSubmit hook is pure bash and needs no interpreter.

## Configuration

One env var controls the threshold:

| Variable | Default | Meaning |
| --- | --- | --- |
| `CLAUDE_CONTEXT_WARN_TOKENS` | `450000` | Real token count (summed `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` of the newest main-chain assistant turn, read from the transcript `.jsonl`'s `.message.usage`). When this crosses the threshold, the reminder fires. |

Set it in your shell profile or `~/.claude/settings.json` under `env`:

```json
{
  "env": {
    "CLAUDE_CONTEXT_WARN_TOKENS": "450000"
  }
}
```

## Security and privacy

The hooks read `session_id` from the environment (`$CLAUDE_CODE_SESSION_ID`) or stdin, and the Stop hook reads `transcript_path` from stdin. Nothing is sent over the network. `session_id` is validated against `^[A-Za-z0-9_-]{1,64}$` before use as a filename; a non-conforming id is skipped (no flag, no handoff), with no SHA-1 fallback as of v3.1. The `context-warn` flag records only the token count and threshold; the suppression flag is an empty presence marker.

See [PRIVACY.md](PRIVACY.md) for the full statement.

## Known limits

- **Undocumented transcript format.** The hook parses `.message.usage` from the transcript `.jsonl`, which Anthropic doesn't officially document. Silent no-op if the schema changes.
- **Manual invocation.** The reminder is informational: it names the warm handoff path and points at `/prep-compact:prep-compact`. Claude does not auto-invoke the skill; type `/prep-compact` manually when you're ready to compact.
- **Warning depends on the Stop hook.** As of v3.1 token detection runs in the async Stop hook, which writes the `context-warn` flag the UserPromptSubmit hook reads. If the Stop hook is disabled or fails, an above-threshold session gets no reminder until a later successful Stop run. This extends the existing handoff-depends-on-Stop coupling to the warning; running `/prep-compact` manually works regardless.
- **Staleness across turns.** The Stop hook refreshes the warm handoff after every assistant message, so `/prep-compact` reads current state. If the conversation has been idle and the handoff has been updated since the last user prompt, the draft will reflect that. There's a one-turn window of stale handoff right after `/compact` runs (UserPromptSubmit fires before the next Stop), but the next assistant turn refreshes it.
- **Session-id reliance.** Both hooks and the skill prefer the `CLAUDE_CODE_SESSION_ID` runtime variable, with the hooks falling back to the stdin `session_id`. If a future Claude Code stops exposing it and it is also absent from stdin, the affected hook skips silently and the skill degrades to an in-memory survey (no warm handoff), which is safe but less complete.

## License

MIT. See [LICENSE](LICENSE).

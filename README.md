# prep-compact

## Why

Claude Code's auto-compact fires late in the 1M Opus window, by which point context has usually started degrading, and the summary it writes is fairly rough. It tends to drop the files, decisions and blockers you wanted kept, and it loses track of which subagents were running. A second compaction in the same session knows nothing about what happened before the first. Running `/compact <instructions>` with a prompt you wrote yourself gives you a much cleaner resumption, but you have to remember to do it, and then design the prompt.

This plugin nags you at the right moment and drafts that prompt for you. It keeps a small running record on disk between turns (files you've touched, tools you've used, what you've been asked to do, which subagents are active) and folds that into every draft, so the resumed session carries forward state from the whole session, including the turns that scrolled out of context long before you compacted.

## How it works

The plugin nudges Claude to prepare tailored `/compact` instructions once the context window is full enough that performance has started dropping. That seems to sit somewhere around the halfway point of the 1M-token window on Opus.

Claude Code doesn't expose the current session's token use to a hook (even though you can see it yourself with `/context`), so there's no direct way to fire a reminder off it. It does record the token count at the moment of each user prompt in the session transcript though, so the plugin reads the tail of that file from a pair of hooks:

> Between turns, a `Stop` hook tail-reads the transcript and writes a continuously-updated handoff file at `${CLAUDE_PLUGIN_DATA}/handoff-<sid>.json` listing every file the session has touched (cumulative across `/compact` cycles), the most recent user requests quoted verbatim, in-progress todo items, and any active subagent launches. The same Stop hook parses the newest main-chain (`role=='assistant'`, non-sidechain, non-api-error) `.message.usage`, sums `input_tokens + cache_creation_input_tokens + cache_read_input_tokens`, and writes a small `context-warn-<sid>` flag (`<tokens> <threshold>`) when that total is at or above `CLAUDE_CONTEXT_WARN_TOKENS` (default `450000`), removing it below.
>
> A `UserPromptSubmit` hook fires on every prompt submission. As of v3.1 it is pure bash: it reads the `context-warn` flag and, on a fresh crossing, emits an informational reminder naming the handoff path and pointing the user at `/prep-compact:prep-compact`. The per-message path no longer spawns an interpreter or scans the transcript, which was the dominant per-message cost on Windows.
>
> The skill reads the warm handoff (extractive fields: cumulative file paths, recent user-message quotes, in-progress todos, recent Task launches) and adds an analytical layer (decisions, constraints, blockers, verb-anchored next-step) to emit a copy-paste `/compact <mini-schema>` block preserving what the post-compact session needs to resume correctly.

The reminder fires once per threshold-crossing. Once the token count drops back below the threshold (after you `/compact`), the Stop hook clears the `context-warn` flag on its next run and future crossings re-arm cleanly. You can also invoke `/prep-compact` manually at any time to refresh the draft right before running `/compact`.

The skill resolves the handoff by the invoking session's own Claude Code session id, so when several sessions run in the same project, `/prep-compact` reads the record belonging to the session it was typed in. If no matching handoff exists yet (none written, or you changed directories), or the session id is missing or unusable, it falls back to surveying the live conversation, and never reads another session's data.

## Install

Add the `agent-tools` marketplace and install the plugin:

```text
/plugin marketplace add koenvdheide/agent-tools
/plugin install prep-compact@agent-tools
```

Run `/reload-plugins` if you installed mid-session.

## Requirements

- Claude Code with plugin support. If `/plugin` comes back unknown, update Claude Code first.
- Python 3 on `PATH`, as either `python3` or `python`. The Stop hook uses Python's `json.load` to parse the transcript and write the handoff and the warn flag, and the skill's resolver uses it to read them back. Without Python the resolver reports a miss and the skill falls back to surveying the live conversation. The UserPromptSubmit hook is pure bash and needs no interpreter.

## Configuration

One env var controls the threshold:

| Variable | Default | Meaning |
| --- | --- | --- |
| `CLAUDE_CONTEXT_WARN_TOKENS` | `450000` | Real token count of the newest main-chain assistant turn, summed from `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` in the transcript `.jsonl`'s `.message.usage`. The reminder fires when that total crosses the threshold. |

Set it in your shell profile or `~/.claude/settings.json` under `env`:

```json
{
  "env": {
    "CLAUDE_CONTEXT_WARN_TOKENS": "450000"
  }
}
```

## Security and privacy

The hooks read `session_id` from the environment (`$CLAUDE_CODE_SESSION_ID`) or from stdin, and the Stop hook reads `transcript_path` from stdin. Nothing goes over the network. Before an id becomes a filename it must match `^[A-Za-z0-9_-]{1,64}$`. An id that doesn't match is skipped by the hooks (no flag, no handoff) and treated as unusable by the skill, which surveys the live conversation instead. As of v3.1 neither side hashes it to SHA-1. The `context-warn` flag holds only the token count and the threshold, and the suppression flag is an empty presence marker.

See [PRIVACY.md](PRIVACY.md) for the full statement.

## Known limits

- The hook parses `.message.usage` out of the transcript `.jsonl`, and Anthropic doesn't officially document that format. If the schema changes, the hook silently no-ops.
- The reminder is informational. It names the warm handoff path and points at `/prep-compact:prep-compact`, but Claude won't invoke the skill on its own, so type `/prep-compact` yourself when you're ready to compact.
- Token detection runs in the async Stop hook as of v3.1, which writes the `context-warn` flag that UserPromptSubmit reads. If the Stop hook is disabled or fails, an above-threshold session gets no reminder until a later Stop run succeeds. That extends the existing handoff-depends-on-Stop coupling to the warning as well. Running `/prep-compact` manually still works.
- The Stop hook refreshes the warm handoff after every assistant message, so `/prep-compact` normally reads current state. If the conversation has been idle and the handoff has been updated since the last user prompt, the draft reflects that. There's a one-turn window right after `/compact` where the handoff is stale (UserPromptSubmit fires before the next Stop), and the next assistant turn refreshes it.
- Both hooks and the skill prefer the `CLAUDE_CODE_SESSION_ID` runtime variable, and the hooks fall back to the stdin `session_id`. If some future Claude Code stops exposing it and it's missing from stdin too, the affected hook skips silently and the skill degrades to an in-memory survey (no warm handoff), which is safe but less complete.

## License

MIT. See [LICENSE](LICENSE).

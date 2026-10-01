# prep-compact

## Why

Claude Code's auto-compact fires at the end of the 1M window, by which point performance has usually started degrading, and this auto-compaction drops important details. It tends to drop the files, decisions and blockers you wanted kept, and it loses track of which subagents were running. A second compaction in the same session knows nothing about what happened before the first. Running `/compact <instructions>` with a prompt you wrote yourself can give you a much cleaner resumption, but you have to remember to do it, and then write a huge prompt.

This plugin nags you at the right moment, drafts that prompt for you as a brief, and puts the brief back into the session after `/compact`. It keeps a small running record on disk between turns (files you've touched, tools you've used, what you've been asked to do, which subagents are active etc.) and folds that into every draft, so the resumed session carries forward state from the whole session, including the turns that scrolled out of context long before you compacted.

## How it works

The plugin nudges Claude to prepare tailored `/compact` instructions once the context window is hit about 450k tokens. Anecdotally, performance starts to drop roughly around the 500k mark so this plugin fires early enough to try to preempt that.

Claude Code doesn't (YET) expose the current session's token use to a hook (even though you can see it yourself with `/context`), so there's no direct way to fire a reminder off it. It does record the token count at the moment of each user prompt in the session transcript though, so the plugin reads the tail of that file from a pair of hooks:

> Between turns, a `Stop` hook tail-reads the transcript and writes a continuously-updated handoff file at `${CLAUDE_PLUGIN_DATA}/handoff-<sid>.json` listing the files the session touched through the structured file tools (cumulative across `/compact` cycles), the most recent user requests quoted verbatim, in-progress todo items, and any active subagent launches. The same Stop hook parses the newest main-chain (`role=='assistant'`, non-sidechain, non-api-error) `.message.usage`, sums `input_tokens + cache_creation_input_tokens + cache_read_input_tokens`, and writes a small `context-warn-<sid>` flag (`<tokens> <threshold>`) when that total is at or above `CLAUDE_CONTEXT_WARN_TOKENS` (default `450000`), removing it below.
>
> A `UserPromptSubmit` hook fires on every prompt submission. As of v3.1 it is pure bash: it reads the `context-warn` flag and, on a fresh crossing, emits an informational reminder naming the handoff path and pointing the user at `/prep-compact:prep-compact`. The per-message path no longer spawns an interpreter or scans the transcript, which was the dominant per-message cost on Windows.
>
> The skill reads the warm handoff (extractive fields: cumulative file paths, recent user-message quotes, in-progress todos, recent Task launches) and adds an analytical layer (decisions, constraints, blockers, verb-anchored next-step). It writes the result as a brief, `brief-<sid>.md` beside the handoff, holding what the post-compact session needs to resume correctly.
>
> A `SessionStart` hook with the `compact` matcher runs as part of every compaction, and Claude Code adds its output to the compacted context. It prints the brief there verbatim, so the brief survives without passing through the summary, and deletes it so a later compaction never re-injects it. After a compaction nobody prepared for, such as an automatic one, it names the warm handoff instead. You just type `/compact`, with no pasting: some clients deliver a pasted `/compact` line as an ordinary message instead of running it.

The reminder fires once per threshold-crossing. Once the token count drops back below the threshold (after you `/compact`), the Stop hook clears the `context-warn` flag on its next run and future crossings re-arm cleanly. You can also invoke `/prep-compact` manually at any time to refresh the brief right before running `/compact`.

The skill resolves the handoff by the invoking session's own Claude Code session id, so when several sessions run in the same project, `/prep-compact` reads the record belonging to the session it was typed in. If no matching handoff exists yet (none written, or you changed directories), or the session id is missing or unusable, it falls back to surveying the live conversation (kinda how auto-compaction works).

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

The hooks read `session_id` from the environment (`$CLAUDE_CODE_SESSION_ID`) or from stdin, and the Stop hook reads `transcript_path` from stdin. Before an id becomes a filename it must match `^[A-Za-z0-9_-]{1,64}$`. An id that doesn't match is skipped by the hooks (no flag, no handoff) and treated as unusable by the skill, which surveys the live conversation instead. The `context-warn` flag holds only the token count and the threshold, and the suppression flag is an empty presence marker.

See [PRIVACY.md](PRIVACY.md) for the full statement.

## Known limits

- The hook parses `.message.usage` out of the transcript `.jsonl`, and Anthropic doesn't officially document that format. If the schema changes, the hook silently no-ops.
- The reminder is informational. It names the warm handoff path and points at `/prep-compact:prep-compact`, but Claude intentionally won't invoke the skill on its own, so type `/prep-compact` yourself when you're ready to compact.
- Token detection runs in the async Stop hook as of v3.1, which writes the `context-warn` flag that UserPromptSubmit reads. If the Stop hook is disabled or fails, an above-threshold session gets no reminder until a later Stop run succeeds. That extends the existing handoff-depends-on-Stop coupling to the warning as well. Running `/prep-compact` manually still works.
- The Stop hook refreshes the warm handoff after every assistant message, so `/prep-compact` normally reads current state. If the conversation has been idle and the handoff has been updated since the last user prompt, the draft reflects that. There's a one-turn window right after `/compact` where the handoff is stale (UserPromptSubmit fires before the next Stop), and the next assistant turn refreshes it.
- The handoff records paths from `Read`, `Edit`, `Write`, `NotebookEdit`, `Glob` and `Grep` calls. Work done through `Bash`, such as a `sed` edit or a heredoc write, leaves no trace in `cumulative_files`, so a shell-driven session shows a thin file list. The skill draws `files:` from the conversation as well to cover that.
- The brief records the session as it was when `/prep-compact` ran. Work done between that and `/compact` is only in the default summary, so rerun `/prep-compact` right before compacting. An automatic compaction also consumes a waiting brief, and the injected text tells Claude to trust the summary where it shows later progress.
- The brief lives under `~/.claude`, which Claude Code protects: saving it asks for permission every time (the prompt offers to allow `~/.claude` edits for the rest of the session), `permissions.allow` rules cannot pre-approve it, and `dontAsk` mode refuses it. When the write fails, the skill falls back to the paste flow below.
- The brief needs a handoff to sit beside. When no handoff matches this session in this directory, or there is no usable session id, the skill falls back to a single-line `/compact <instructions>` block to paste.
- Keep the brief under about 9,000 characters: Claude Code caps hook output at 10,000 and passes a longer one on only as a file path and a short preview. The skill asks for this.
- All the hooks and the skill prefer the `CLAUDE_CODE_SESSION_ID` runtime variable, and the hooks fall back to the stdin `session_id`. If some future Claude Code stops exposing it and it's missing from stdin too, the affected hook skips silently and the skill degrades to an in-memory survey (no warm handoff), which is safe but less complete.

## License

MIT. See [LICENSE](LICENSE).

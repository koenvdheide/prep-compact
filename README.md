# better-compact

## Why

Claude Code's auto-compaction tends to drop the files, decisions and blockers you wanted kept, and it loses track of which subagents were running. A second compaction in the same session only sees what the first one kept. Running `/compact <instructions>` with a prompt you wrote yourself can give you a much cleaner resumption, but you have to remember to do it, and then write a huge prompt.

This plugin reminds you at the right moment and supplies that prompt for you. It adds a brief to every compaction, including automatic ones, so you don't have to remember to prepare it yourself.

## How it works

The plugin nudges you to compact once the context window reaches 45%. On a 1M-token window that's about 450k tokens; on a different window the threshold moves with it. Anecdotally, performance starts to drop at about the halfway mark of the context window (so ~500k tokens on a 1M window), so this plugin fires early enough to try to preempt that. You can type `/compact` when you're ready, or let automatic compaction run with the same brief.

Claude Code now exposes the live context percentage and the compaction's instructions to function hooks, so the plugin uses a pair of hooks in `hooks/register.ts`:

> A `session.measure` hook reads the context percentage after a main-thread turn and shows the current level in the status line once it reaches 45%, for example `context 62% — /compact when convenient`. Below that, or when the percentage isn't available, it clears the line.
>
> A `session.compact` hook adds the brief to the instructions used to write the summary. If you typed `/compact <instructions>` yourself, your text comes first and the brief follows. The hook applies to automatic compactions too.

The brief asks for the session's goal, a concrete next step (`edit <path>`, `run <command>`, `ask user <question>` etc.), and the minimum set of files needed to execute it. It also asks for the decisions and their reasoning, the constraints you stated, the blockers still open, and the session state: uncommitted changes, test status with a command to rerun the tests, work left mid-implementation, and any subagents still running. Paths, identifiers, commands, decisions and constraints are to be quoted verbatim. Exploratory dead ends get dropped unless they explain a blocker or a decision that still stands.

The brief is the same in every session. The summarizer already has the conversation; the plugin supplies the instructions for what to keep.

A successful manual or automatic compaction clears the nudge. A skipped compaction or a precomputed summary leaves it alone, since the context hasn't been replaced yet.

## Install

Add the `agent-tools` marketplace and install the plugin:

```text
/plugin marketplace add koenvdheide/agent-tools
/plugin install better-compact@agent-tools
```

Run `/reload-plugins` if you installed mid-session.

## Requirements

- Claude Code with plugin support and mods turned on. If `/plugin` comes back unknown, update Claude Code first. Mods are an early-access feature enabled with `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`; some builds and accounts have them enabled already.
- The plugin is one TypeScript module loaded by Claude Code. It needs no Python, shell or other program on `PATH`.

## Configuration

The threshold is fixed at 45% (`WARN_AT_PERCENT` in `hooks/register.ts`). There is no user setting for it.

## Security and privacy

The plugin reads the compaction's existing instructions and the live context percentage. It writes no files and keeps no session record. It makes no network requests of its own; the brief goes along with Claude Code's normal compaction request.

See [PRIVACY.md](PRIVACY.md) for the full statement.

## Known limits

- The brief asks the summarizer to keep particular details, but compaction is still lossy. There's no guarantee that any individual detail survives.
- The status-line reminder is informational. It doesn't run `/compact` for you.
- The plugin has no error handler of its own. If the module fails to load, it cannot supply the brief or the status-line reminder.
- The plugin keeps no archive across compactions. Whatever the first summary drops is also missing from the context available to the next one.

## License

MIT. See [LICENSE](LICENSE).

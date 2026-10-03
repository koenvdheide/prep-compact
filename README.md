# better-compact

## Why

Compaction drops the things you wanted kept: the files you were editing, the decisions behind them, the blocker you were halfway through. Running `/compact <instructions>` with a prompt you wrote yourself can give a cleaner resumption, but you have to remember to do it, and automatic compactions fire whether you remembered or not.

This plugin puts a brief in front of every compaction, automatic ones included, and shows the context percentage in the status line once it climbs high enough to be worth acting on.

A `/compact` you type steers one compaction, the one you remembered. v3 of this plugin added its brief to the context after the summary was made, through a `SessionStart` hook, so the summarizer itself worked from Claude Code's own instructions. A `session.compact` hook shapes the summary while it is written, on every compaction, and you stop retyping the brief. When you do run `/compact` with your own text, that text leads and the brief follows, so an instruction meant for this one compaction comes first.

## How it works

Two hooks, both in `hooks/register.ts`.

A `session.compact` hook appends the brief to the compaction's instructions. The brief asks for the session's goal in one sentence, a verb-anchored next step (`edit <path>`, `run <command>`, `ask user <question>`), and the minimum set of files needed to execute that step. It also asks for the decisions taken and the reasoning behind them, the constraints you stated as hard requirements, the blockers still open, and the session state: uncommitted changes, test status, work left mid-implementation, any subagent still running. Paths, identifiers, commands, decisions and constraints come through verbatim, and exploratory dead ends that were not acted on get dropped unless one underpins a blocker or a decision that still stands.

The brief is a constant, identical in every session. The summarizer already has the transcript, so the thing missing at compaction time was guidance on what to keep.

A `session.measure` hook writes the context percentage into the status line once it reaches 45%, so you can compact at a moment that suits you. The line reads `context 62% — /compact when convenient`. The 45% is a share of the context window, so the nudge moves with whatever window the model has.

## Install

```text
/plugin marketplace add koenvdheide/agent-tools
/plugin install better-compact@agent-tools
```

The marketplace catalogue still lists the plugin under its old name, so the second line above fails today. Renaming that entry is part of the 4.0.0 release. The old name `prep-compact@agent-tools` still resolves, and installing it gets you v3: the shell hooks and the skill.

## Requirements

A Claude Code build with mods turned on. Mods are an early-access feature, switched on with `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`; some builds and accounts carry it already. To see which you have, clone this repository and run `claude plugin test .` there: with mods on it runs this plugin's tests, and otherwise it prints the early-access notice naming that variable.

The plugin itself is one TypeScript module the harness loads, with no interpreter or shell dependencies and nothing needed on `PATH`.

## Known limits

- The brief steers a summarizer, and compaction is lossy by design. It improves what a summary keeps, with no guarantee about any particular detail.
- A hook that throws is skipped and the engine keeps the previous result; a module that fails to load leaves compaction at Claude Code's default and the status line empty. Nothing reports either case.
- The threshold is a constant 45% in `hooks/register.ts`. Changing it means editing that one line. There is no environment variable and no setting.
- The plugin keeps no archive across compactions, so whatever a summary drops is gone from its own record. A second compaction in the same session sees what the first one kept.

## Privacy

[PRIVACY.md](PRIVACY.md) covers what the plugin reads and what it keeps.

## License

MIT. See [LICENSE](LICENSE).

# Privacy

better-compact keeps nothing.

It writes no file, keeps no session id, and stores no value in session or cross-session storage. It reads two things the engine hands it: the compaction's existing instructions, and the live context percentage. It adds a fixed block of text to the first and draws the second in the status line.

The brief it supplies is a constant, identical in every session, and contains no session content.

The plugin makes no network requests of its own. The brief does travel with the compaction request Claude Code already makes, because steering that request is the plugin's purpose.

## See also

- [README.md](README.md) — what it does and how to install it.
- [LICENSE](LICENSE) — MIT.

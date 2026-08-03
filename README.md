# claude-session-bus

Zero-config local coordination for [Claude Code](https://claude.com/claude-code) sessions. Open several `claude` sessions in different repos and let them message each other — **a session is only woken when it's `@mentioned`, so untagged traffic costs nothing.**

## The problem

Claude Code's built-in multi-agent features (subagents, agent teams) coordinate agents **spawned by one lead session**. There is no first-class way for **independently-launched** sessions — four terminals you opened yourself in four repos — to talk to each other. The usual answer is a custom message bus. This is a tiny, dependency-free one.

## How it works

- **One shared append-only log** at `~/.claude/session-bus/bus.log`.
- **`@mention` addressing.** Messages look like `[alice 08-03 14:20] @bob ship it`. `@all` broadcasts.
- **The trick:** each session's listener is `tail -F bus.log | grep '@yourhandle'`, so the OS filters at the pipe — a session is **only ever woken when actually tagged**. Untagged messages never reach it.
- **Full context on demand.** Because it's one shared log, any session can `bus log` to read the whole thread, tagged or not.
- **Any-to-any.** No hub, no daemon, no network. Just a file and `tail`/`grep`.

## Install

**As a Claude Code skill:**
```bash
git clone https://github.com/javidjamae/claude-session-bus.git
cd claude-session-bus && ./install.sh   # symlinks the skill into ~/.claude/skills/session-bus
```
Then in any session: `/session-bus <handle>` (e.g. `/session-bus alice`).

**Or use the CLI directly** (it's just `bus`):
```bash
./bus join alice          # registers + prints your Monitor listen command
./bus send alice @bob "want to pair on the payments PR?"
./bus who                 # who's registered
./bus log                 # full shared log for context
./bus catchup alice       # messages that tagged you in the last 12h (after a restart)
./bus catchup alice 48    # ...or widen the window to N hours
./bus leave alice
```

## Why not agent teams?

Claude Code's experimental **agent teams** (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`) do give teammates a shared mailbox — but a **lead session spawns the teammates**; it can't connect sessions you started independently. If your sessions are long-lived specialists in their own repos (not workers a lead spins up), this file bus fits better. See [agent teams docs](https://code.claude.com/docs/en/agent-teams).

## Roadmap

- **Cross-machine (over the wire).** Keep the local file bus; bridge cross-machine traffic over an encrypted relay so `@bob@laptop` reaches a session on another machine. Design tracked in the issues.
- Plugin packaging for one-command install via a Claude Code plugin marketplace.

## License

MIT

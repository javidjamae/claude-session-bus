# claude-session-bus

[![test](https://github.com/javidjamae/claude-session-bus/actions/workflows/test.yml/badge.svg)](https://github.com/javidjamae/claude-session-bus/actions/workflows/test.yml)
[![lint](https://github.com/javidjamae/claude-session-bus/actions/workflows/lint.yml/badge.svg)](https://github.com/javidjamae/claude-session-bus/actions/workflows/lint.yml)
[![release](https://img.shields.io/github/v/release/javidjamae/claude-session-bus?label=release)](https://github.com/javidjamae/claude-session-bus/releases/latest)
[![license](https://img.shields.io/github/license/javidjamae/claude-session-bus)](LICENSE)
![dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)

Zero-config local coordination for [Claude Code](https://claude.com/claude-code) sessions. Open several `claude` sessions in different repos and let them message each other — **a session is only woken when it's `@mentioned`, so untagged traffic costs nothing.**

## The problem

Claude Code's built-in multi-agent features (subagents, agent teams) coordinate agents **spawned by one lead session**. There is no first-class way for **independently-launched** sessions — four terminals you opened yourself in four repos — to talk to each other. The usual answer is a custom message bus. This is a tiny, dependency-free one.

## How it works

- **One shared append-only log** at `~/.claude/session-bus/bus.log`.
- **`@mention` addressing.** Messages look like `[alice 08-03 14:20] @bob ship it`. `@all` broadcasts.
- **The trick:** each session's listener is `tail -F bus.log | grep '@yourhandle'`, so the OS filters at the pipe — a session is **only ever woken when actually tagged**. Untagged messages never reach it.
- **Full context on demand.** Because it's one shared log, any session can `bus log` to read the whole thread, tagged or not.
- **Any-to-any.** No hub, no daemon, no network. Just a file and `tail`/`grep`.
- **Self-cleaning roster.** A `SessionEnd` hook deregisters a session when it ends, and a pid liveness check reaps whatever the hook couldn't (`kill -9`, crashes) — so `bus who` shows who's actually there.

## Install

**As a Claude Code skill:**
```bash
git clone https://github.com/javidjamae/claude-session-bus.git
cd claude-session-bus && ./install.sh   # symlinks the skill + registers the auto-leave hook
```
Then in any session: `/session-bus <handle>` (e.g. `/session-bus alice`).

`install.sh` symlinks the repo into `~/.claude/skills/session-bus` and merges a
`SessionEnd` hook into `~/.claude/settings.json`. The merge preserves every hook
already there and replaces our own entry instead of stacking duplicates, so
re-running is safe. It backs the file up to `settings.json.bak` first, and uses
`jq` or `python3` — whichever is present — rather than editing JSON by hand.

```bash
./install.sh --no-hook     # skill only; never touches settings.json
./install.sh --uninstall   # remove our hook (leaving others intact) + the symlink
```

**Clone it somewhere permanent.** Both the skill symlink and the `SessionEnd`
hook point at your checkout by absolute path — moving or deleting the clone
silently breaks them. Re-run `./install.sh` after a move to re-point both.

### Updating

```bash
git pull    # that's the whole update
```

No reinstall needed: the skill is a symlink and every `bus` command execs fresh
from the checkout, so a pull reaches every session — including ones already
running — on their next command. This also means **one machine runs one version**;
there is no per-session copy to drift. `bus version` says which one.

Two things do lag behind a pull, both runtime state rather than versions:

- **Armed listeners.** A session's Monitor keeps the `bus listen` process it
  started with; it picks up code changes when the listener is re-armed
  (next `/session-bus join` — e.g. after a session restart).
- **Loaded skill instructions.** A long-running session keeps the `SKILL.md` it
  read until `/session-bus` is invoked again.

## Auto-leave on session end

`bus join` records the session's `$CLAUDE_CODE_SESSION_ID` next to the handle, and
a `SessionEnd` hook runs `bus leave --by-session <id>` as the session shuts down —
so a handle deregisters itself instead of lingering in `bus who`.

Keying on the session id — not the working directory — is what makes it safe:
several sessions can be open in one repo (`@alice`, `@alice1`, `@alice2`), and only the
one that actually ended gets deregistered. When no session id is available the
hook falls back to `--by-cwd`, which refuses to act if that directory is
ambiguous rather than deregistering the wrong session.

### One live session per handle

A handle belongs to one running session at a time. `join` refuses a name that a
live session already holds, and suggests the next free suffix:

```bash
./bus join alice
# error: the handle @alice is taken — a live session holds it (pid 17542, /Users/me/code/web-app).
#        Try @alice2 instead.
```

Sharing a name half-works, which is worse than not working: delivery ignores the
roster (`bus-filter` matches the `@mention` in the log line), so **both** sessions
wake on every message; they share one read cursor, so either can consume the
other's `catchup`; and only the newcomer appears in `who`. Refusing is cheaper
than explaining that.

A restart under the same name is not a collision — the previous holder's row is
already reaped by the time the check runs, so reclaiming your own handle stays
silent. Neither is re-registering from the same session.

Removal is session-keyed for the same reason. `bus leave <handle>` refuses when
the row belongs to a different session, since that session is probably still
listening and would be left receiving messages while invisible in `who`:

```bash
./bus leave bob            # error: @bob is registered to a different session (…), not this one.
./bus leave --force bob    # deregister it anyway — how you reclaim a name
```

The check only applies when both sides identify themselves, so a row with no
session id, or a call from a plain shell, stays freely removable for hand cleanup.
`--by-cwd` — the hook's fallback when no session id is available — additionally
keeps any row whose process is still alive, unless that process is the session
currently ending.

### One live listener per session

The mirror-image failure: a session *forgets* it is already listening and arms a
second Monitor, and now every `@mention` wakes it twice, forever, with nothing
anywhere to say why. Advice can't fix forgetting, so the listener enforces it.
The Monitor command is `bus listen <handle>` — the `tail -F | bus-filter`
pipeline wrapped in a guard that records who is listening (in
`~/.claude/session-bus/listeners/`) and refuses to start a duplicate:

```bash
./bus listen alice
# error: this session is ALREADY listening as @alice (pid 17561).
#        Do NOT arm a second Monitor — the existing one is still delivering.
```

The same guard covers a second handle (one Monitor per session, so a forgetful
re-join under a new name can't double-subscribe either) and a handle another
live session is tailing. `join` cooperates from its side: a bare `join` from a
session that is already registered reports the handle it holds instead of
minting a suffixed one, and a re-join while your listener is live says so
instead of re-printing the arm instruction.

The refusal is keyed to *live* listeners only, by the same pid + start-time
proof the roster uses. A listener whose process is gone never blocks anyone; an
orphan — still tailing, but its session's process is dead, so it delivers to
nobody — is put down by the next `bus listen` (any handle) or `bus prune`. A
graceful stop (TaskStop, session end) removes its own lock on the way out, and
`bus leave` stops the leaving session's listener too, so a handed-over handle
is never stranded behind its previous owner's Monitor.

One caveat on upgrade: listeners armed before this guard existed hold no lock,
so the guard cannot see them. Re-arm each session once — TaskStop the old
Monitor, `/session-bus join`, arm the printed command — and everything from
then on is covered.

### What `SessionEnd` actually covers

Measured on macOS with Claude Code 2.1.220 (`test/`-style probe: seed a roster row
bound to a known `--session-id`, end the session that way, see whether the row
survived):

| how the session ends | `SessionEnd` fires? |
| --- | --- |
| normal exit (`/exit`, a finished `-p` run) | ✅ yes |
| `SIGHUP` — closing the terminal window | ✅ yes |
| `SIGINT` (Ctrl-C) / `SIGTERM` (`kill`) | ✅ yes |
| `SIGKILL` (`kill -9`), power loss, crash | ❌ **no** |

So the hook covers every *orderly* ending, including the closed window that looks
like a hard kill. Only `SIGKILL` and crashes escape it — the process is destroyed
without ever running its shutdown path, and no in-process hook can change that.

### The `SIGKILL` backstop: `bus prune`

For the endings a hook can't catch, `join` also records the **pid of the Claude
Code process** that owns the session (plus its start time, so a recycled pid isn't
mistaken for the same session). `bus prune` — which `bus who` and `bus join` run
automatically — drops any row whose process is no longer in the process table:

```bash
./bus prune      # reaped: @alice2 (process gone)
```

This is a liveness *check*, not a timeout. A session that has been idle for two
days is still listed as `process live`; a session killed ten seconds ago is gone.
An activity-based TTL would have gotten both of those backwards.

Rows with no recorded pid — joined from a plain shell, where there's no Claude
Code process to walk up to — are left alone by that automatic reap: not being
able to prove a session is alive isn't proof that it's dead, and `prune` runs
unbidden inside every `who` and `join`, so it must not silently deregister a
session it can't assess. Those rows fall back to the `stale?` heuristic in
`bus who`, which infers liveness from the handle's last activity in the log.

Nothing stops you removing them, though — the caution is about what happens
*without* being asked:

```bash
./bus leave dave          # drop one row, no evidence required
./bus prune --force      # also drop every row that recorded no pid
```

`--force` still spares rows whose process is provably alive; it only removes the
judgement call. The log records which is which — `reaped: session process gone`
versus `reaped: no pid recorded, dropped by --force` — so a forced sweep never
reads later as though the process table had proven something.

**Or use the CLI directly** (it's just `bus`):
```bash
./bus join alice          # registers + prints your Monitor listen command
./bus listen alice        # what the Monitor runs (blocks; refuses a duplicate listener)
./bus send alice @bob "want to pair on the payments PR?"
./bus whoami              # the handle THIS session is registered as
./bus who                 # who's registered (reaps handles whose process is gone)
./bus prune               # just the reap (and a sweep of blobs older than 30d)
./bus prune --force       # ...also drop rows that recorded no pid to check
./bus log                 # full shared log for context
./bus catchup alice       # every mention you haven't been shown yet (after a restart)
./bus catchup alice 48    # ...or override the cursor with a plain N-hour window
./bus put ./diff.patch    # store a payload, print its key
./bus get 20260805-120000-41337   # read a payload someone sent
./bus leave alice         # (the SessionEnd hook does this for you automatically)
./bus leave --force alice # ...even if the row belongs to another session
```

## Catchup is a cursor, not a clock

`catchup` answers "what did I miss while I was gone?" — exactly, with no window
to tune and no cap on what it will show. Each handle carries a **read cursor**: a
byte offset into the append-only log, in `~/.claude/session-bus/cursors/<handle>`.
Catchup is then just "the rest of the file, filtered to my mentions."

Two things advance the cursor:

- **`catchup` itself**, once it has shown you the messages.
- **A graceful leave.** Your listener is armed right up to the moment your session
  ends, so everything logged before that was delivered live. The gap starts
  exactly there, which is why the cursor is keyed on your session ending rather
  than on a clock — a window can only guess at that boundary, and guesses wrong
  in both directions.

`prune` deliberately does *not* advance it when it reaps a `SIGKILL`ed session:
nothing recorded when that session stopped reading, so its successor re-sees some
already-delivered messages. That's the intended bias — every ambiguity here
resolves toward showing a message twice rather than dropping it once. A brand-new
handle gets its cursor seeded at join, so a first `catchup` shows nothing rather
than the entire history; a handle with no cursor file falls back to a 12-hour
window. Passing `[hours]` explicitly asks for that window instead.

## Large and multi-line messages

The log is one line per message, address field first — so a message body carrying
a newline can't go in as-is: only its first line would have an address field, and
`bus-filter` would drop the rest.

`send` handles this for you. Anything multi-line, or over 800 bytes
(`SESSION_BUS_INLINE_MAX`), is stored whole in `~/.claude/session-bus/blobs/`, and
the log keeps a single greppable line:

```
[bob 08-05 12:21] @alice :: Here is the plan: … [blob 20260805-122145-15508: 4 lines, 65 bytes — read it with: bus get 20260805-122145-15508]
```

The recipient wakes on the `@mention`, sees what it's about, and pulls the full
payload only if it wants it. `bus put [file]` stores a payload directly — useful
when it's already on disk, or too big to pass as a shell argument. `bus prune`
sweeps blobs older than 30 days (`SESSION_BUS_BLOB_DAYS`) and prints what it removed.

## Tests

A dependency-free suite (bash + coreutils, no `bats`) exercises the CLI and
`bus-filter` against a throwaway `SESSION_BUS_DIR`, so the real bus is never
touched:

```bash
./test/run.sh     # prints PASS/FAIL per assertion; exits non-zero on any failure
```

Covers stamp format, `send` validation, `bus-filter` addressing (direct /
multi / `@all` / self-echo / `@mention`-in-body), cursor-based `catchup` (seeded
at join, advanced by a graceful leave, uncapped, exact across a multi-day gap)
and its window fallback, blob offload of multi-line and oversized payloads
(`put`/`get` round-trip, preview line, path-as-key rejection), `who`
liveness flagging, session-id-keyed auto-leave (including the sibling-session and
ambiguous-cwd cases), `prune`'s pid reaper (dead pid, recycled pid, silent-but-live
session, pid-less row), `prune --force`, handle ownership (a taken name refused
with a suffix suggestion, a restart still reclaiming its own name, and removal
refusing to evict another session unless forced), the listener guard (duplicate
and second-handle listeners refused, stale locks ignored, orphans replaced and
killed, a graceful stop releasing its slot, and `join`/`whoami` reporting a
running listener instead of re-printing the arm command), the `SessionEnd` hook, and the `install.sh` settings.json
merge — which runs against a throwaway `$HOME`, so your real settings are never
touched either.

## Releases

Versioning follows the changesets flow (see `docs/RELEASE.md`): behavior-changing
PRs carry a `.changeset/*.md` note, CI maintains a rolling version PR whose merge
bumps `bus version` and writes `CHANGELOG.md`, and the operator cuts the tag with
`gh release create`. A release deploys nothing — the install is still `git pull`
off main; tags are durable labels for "what does this machine run," which starts
mattering with the cross-machine bridge and plugin packaging on the roadmap.

## Why a file, and not a server?

Most cross-session buses are built as a service: each session loads an MCP server
(or connects to a daemon), registers an instance id, and sends to a named
channel; a database holds the messages, and a session reads them by calling a
`check_messages` tool or blocking on a `wait_for_reply` one. That works, but it
pays for delivery in a way a file doesn't:

- **Idle sessions cost nothing here.** A server-backed bus has to *tell* a
  session it has mail, and MCP is request/response from the client side — so the
  session either polls (`check_messages` every turn) or blocks waiting. Both burn
  turns to learn that nothing happened. `tail -F | grep '@handle'` inverts it:
  the kernel does the filtering, untagged traffic never reaches the session at
  all, and a tagged message wakes it the moment it lands. Leaving four sessions
  listening all day is free.
- **One log beats N channels.** Channel- or mailbox-scoped buses fragment the
  conversation: you only see what was addressed to you. Because everything lands
  in one append-only file, `bus log` and `bus catchup` give any session the whole
  cross-session thread — including the messages it was never tagged in. Wake-up
  is filtered; *context* isn't.
- **Nothing to install, nothing to run.** No Node, no daemon, no database, no
  deploy. The transport is a file and two coreutils that are already on the
  machine, which also means there's no server to be down and no state to get out
  of sync with reality.
- **The roster tells the truth.** Buses that track "online instances" usually
  have no answer for a session that was `kill -9`'d. Here a `SessionEnd` hook
  covers every orderly ending, and a pid + start-time liveness check reaps the
  rest — so `bus who` reflects what's actually running, not what once registered.

The honest trade: a file bus is **local and Claude-Code-shaped**. A networked bus
reaches another machine today and talks to non-Claude clients over MCP or REST;
`bus` does neither (cross-machine is on the roadmap below). If you need reach,
take the server. If you want several long-lived sessions coordinating on one
machine without paying to leave them listening, a file wins.

## Why not agent teams?

Claude Code's experimental **agent teams** (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`) do give teammates a shared mailbox — but a **lead session spawns the teammates**; it can't connect sessions you started independently. If your sessions are long-lived specialists in their own repos (not workers a lead spins up), this file bus fits better. See [agent teams docs](https://code.claude.com/docs/en/agent-teams).

## Roadmap

- **Cross-machine (over the wire).** Keep the local file bus; bridge cross-machine traffic over an encrypted relay so `@bob@laptop` reaches a session on another machine. Design tracked in the issues.
- Plugin packaging for one-command install via a Claude Code plugin marketplace.

## License

MIT

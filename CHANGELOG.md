# claude-session-bus

## 0.4.0

### Minor Changes

- 93a83b4: New `bus wait <handle> [--timeout <seconds>]`: a listener that cannot expire. It
  blocks until the handle is next tagged, prints what arrived, marks it seen and
  exits 0 — so a session arms it as a background command (no time limit, and the
  exit is what wakes the session) and re-arms it after each message, instead of
  relying on a Monitor that goes deaf when its time limit passes. Every wait
  resumes from the handle's read cursor rather than from "now", so a message sent
  between two waits is delivered by the next one. It shares the one-listener-per-
  session guard with `bus listen`, is stopped by `bus leave`, and will not mark
  mail seen for a session whose process is gone. `join` and `whoami` now hand out
  the `bus wait` command, and SKILL.md arms it in place of the Monitor.
  
  Three behaviors change so that the read cursor stays exact under a one-shot
  listener:
  
  - `bus leave` (and the SessionEnd hook) marks the log read only while a
    streaming `bus listen` is running for the handle. Before, every leave did,
    which would mark as seen any mail that landed after a wait had exited. A
    session that used `bus listen` but whose listener had already stopped will
    see some already-delivered mentions again at its next `catchup`.
  - `bus catchup` and `bus wait` refuse a handle the roster says another session
    holds; `bus log` still reads everything. Calls with no session id (a plain
    terminal) are never refused.
  - `bus catchup` reads exactly up to its size snapshot, whole lines only, exits
    non-zero instead of printing "(nothing new)" when its filter cannot run, and
    rewinds a cursor left past the end of a truncated log instead of replaying
    the whole log on every catchup.
  
  Safe to update while sessions are live. On-disk formats are unchanged. A session
  already listening through a Monitor keeps working exactly as before. To switch
  it to `bus wait`: stop that Monitor (TaskStop) first — the one-listener guard
  refuses the wait while it runs — then `/session-bus join <same handle>` and arm
  as the new SKILL.md describes.

## 0.3.0

### Minor Changes

- 3dfb6d4: One live listener per session, enforced. The Monitor command is now `bus listen
<handle>` — the tail|bus-filter pipeline wrapped in a lock — and a session that
  already has a live listener gets a refusal instead of a second monitor
  double-delivering every message. Stale locks (dead listener) never block;
  orphans (session process gone) are put down by any `bus listen` or by `bus
prune`; a graceful stop releases its slot, and `bus leave` now stops the
  leaving session's listener so a handed-over handle is never stranded. `join`
  cooperates: a bare re-join reports the handle the session already holds
  instead of minting a suffixed one, and `join`/`whoami` answer the guard's own
  per-session question — "listener still running — do NOT arm another Monitor" —
  instead of re-printing the arm command. Handles are canonicalized at the door
  (lowercase; letters, digits, `-`, `_` only).

  Upgrade note: listeners armed before this release hold no lock, so the guard
  cannot see them — re-arm each session once (TaskStop the old Monitor, join,
  arm the printed `bus listen` command) and everything after that is covered.

### Patch Changes

- b5d7d75: Every script is now linted by ShellCheck in CI, and the blob sweep no longer
  word-splits its file list — a blob path containing a space would have been
  skipped instead of deleted. The README carries live build, lint, release and
  license badges.

## 0.2.1

### Patch Changes

- d62539f: The release process now says who does what: the maintainer authorizes with an
  explicit phrase and the agent executes, with the authorizing and
  non-authorizing phrases written out literally, the post-approval gate re-run
  required before anything irreversible, and every release pinned to an exact
  commit rather than to whatever main happens to be.

## 0.2.0

### Minor Changes

- 9058d65: Releases are now gated by an end-to-end battery that drives the real
  `tail -F | bus-filter` listener from a fresh clone (`./test/e2e.sh`), and both
  suites run in CI on Linux and macOS so the BSD and GNU fallbacks are each
  actually exercised.

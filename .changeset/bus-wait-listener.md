---
"claude-session-bus": minor
---

New `bus wait <handle> [--timeout <seconds>]`: a listener that cannot expire. It
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

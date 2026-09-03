---
"claude-session-bus": minor
---

One live listener per session, enforced. The Monitor command is now `bus listen
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

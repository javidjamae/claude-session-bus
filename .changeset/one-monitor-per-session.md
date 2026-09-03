---
"claude-session-bus": minor
---

One live listener per session, enforced. The Monitor command is now `bus listen
<handle>` — the tail|bus-filter pipeline wrapped in a lock — and a session that
already has a live listener gets a refusal instead of a second monitor
double-delivering every message. Stale locks (dead listener) never block;
orphans (session process gone) are killed and replaced; a graceful stop
releases its slot. `join` cooperates: a bare re-join reports the handle the
session already holds instead of minting a suffixed one, and `join`/`whoami`
say "listener still running — do NOT arm another Monitor" instead of
re-printing the arm command.

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

`catchup` now reads exactly up to its size snapshot, whole lines only, and a
cursor left past the end of a truncated log is rewound instead of replaying the
whole log on every catchup.

Safe to update while sessions are live. On-disk formats are unchanged. A session
already listening through a Monitor keeps working exactly as before until it
next arms a listener, at which point it follows the new SKILL.md and arms
`bus wait`; run `/session-bus join <same handle>` in a session to switch it now.

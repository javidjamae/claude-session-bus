---
name: release-readiness
description: "Assess whether this repo is merge-ready or release-ready, and prepare (never cut) a release. Triggers: is this merge-ready, can we ship, cut a release, tag a version, prepare the release, release checklist."
---

# release-readiness

Two gates, never conflated:

- **Merge-ready** — the change is correct, verified, and reviewable. Ends at a
  merge. A merge publishes nothing.
- **Release-ready** — merge-ready **plus** the gate in `docs/RELEASE.md`. Ends at
  a tag, which is the release.

"CI is green" is not either one. Answer the question that was asked, and never
report a verdict without emitting the checklist below with **pass**, **N/A
because …**, or **gap** against every item. N/A is always allowed; unargued N/A
is not.

## Merge-ready checklist

1. **Correctness.** `./test/run.sh` green. Every new behavior has an assertion
   added in the same change — not a promise to add one.
2. **Live-verified.** You have SEEN it work, which here means all of: the real
   `bus` CLI (not a snippet), a real bus directory, the real
   `tail -F | bus-filter` listener where delivery is involved, observed from
   where a user stands (the receiving session's inbox, not the sending side),
   and **the exact code under review** — not a sibling branch, not "the same
   change applied by hand". If you cannot say all five, say "not live-verified"
   plainly.
3. **The e2e battery.** `./test/e2e.sh` green. It clones fresh and drives the
   real listener; the unit suite does neither.
4. **Docs current.** A new command appears in `bus help`, the SKILL.md table, and
   the README. The help-drift guard in the suite enforces the first; the others
   are on you.
5. **Formats.** If the change touches log lines, roster rows, cursors or blobs,
   say so explicitly and state what code from the previous version does when it
   reads the new shape.
6. **Public-surface hygiene.** No internal project names, repo paths, or session
   handles anywhere the change publishes — code, config, docs, commit messages,
   PR title and body. Examples use alice/bob/carol/dave. Grep the prose too, and
   do not anchor with `\b` before an `@` (it never matches).
7. **Git hygiene.** Branch + PR, draft until a human marks it ready. Never push
   to main, never force-push a shared branch.

## Release-ready: everything above, plus

Run through `docs/RELEASE.md` in order and report each step's state:

1. Work landed via PR, CI green on both Linux and macOS.
2. The rolling "chore: version + changelog" PR consumes **all** pending
   changesets — check before merging it, and check none remain after.
3. Re-verify the staged commit itself: `./test/e2e.sh <sha>` against the exact
   commit that will be tagged.
4. Draft the release notes, including the one line of update semantics: is it
   safe to update while sessions are live, and why.
5. State the exact command for the maintainer, and stop.

## The hard stop

**Never run `gh release create`, never push a tag, never merge the version PR
on your own initiative.** Approval means an explicit "ship it" or "cut the
release" naming this build, from the maintainer, in their own words. A green
pipeline, a merged PR, "looks good", or approval of an earlier release is not
approval of this one — and approval does not carry to the next build.

Prepare everything, then hand over:

```
gh release create v<X.Y.Z> --generate-notes    # maintainer runs this
```

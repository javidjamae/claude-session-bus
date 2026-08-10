---
name: release-readiness
description: "Assess whether this repo is merge-ready or release-ready, and execute a release once the maintainer authorizes it. Triggers: is this merge-ready, can we ship, release approved, ship it, cut the release, tag a version, release checklist."
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

## Authorization — the one thing you may not decide

You execute the release. You never decide that the moment has come.

**Authorizing** — an imperative naming the act, from the maintainer, in their
own words: "release approved", "ship it", "cut the release", "tag it".

**Not authorizing** — "merge it", "merged", "looks good", "build it", "get it
in", "ready to ship?", a merged PR, a merged version PR, green CI, or an earlier
release's approval. A question asks for a recommendation: answer it and wait.

One approval binds one act, one version, one commit. If the tree moves between
the utterance and the execution, it is void — stop and ask again. If the gate
goes red after approval, nothing ships: report, fix through its own PR, ask
again. If you cannot quote the authorizing utterance, you did not have it.

## On the phrase, execute

Follow "Executing an approved release" in `docs/RELEASE.md` exactly: pin the
sha, confirm the version is staged with no changesets pending, re-run the full
gate **on that sha**, create the release against the pinned commit, watch the
tag build, confirm positively from a fresh clone of the tag, and report — gate
numbers, release URL, build result, the utterance, and what you did not verify.

Never merge the version PR on your own initiative; that is a separate human
checkpoint from the release itself.

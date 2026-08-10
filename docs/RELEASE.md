# Releasing (maintainer ops)

**Two gates, never conflated.** *Merge-ready* means the change is correct and
reviewed — that gate ends at a merge, and a merge publishes nothing. *Release-
ready* means merge-ready **plus** everything on this page. Merging stages a
release; tagging is the release. Anything that blurs the two ("CI is green, so
ship it") has skipped a gate.

Changesets in version-only mode, with an explicitly gated tag — scaled to a repo
where **a release deploys nothing**: the install is a symlink to a checkout and
the update is `git pull` off main, so a tag is a durable label ("this machine
runs v0.1.x"), not a distribution channel. That changes when plugin-marketplace
packaging lands; the flow below is already shaped for it.

## Release gate

1. **Verified live first, and green in CI.** The changed behavior has been
   exercised for real on a local bus — a passing suite is not the same as having
   seen it work — and `test.yml` is green on both Linux and macOS. The matrix is
   not ceremony: the code carries BSD/GNU fallbacks, so one OS only ever proves
   half of each. Never release off a red or skipped run.

   CI runs on every PR, every push to main, and every `v*` tag. Standard runners
   are free on a public repo, so nothing here is rationed — if you find yourself
   reasoning about which runs to skip, that reasoning belongs to a private repo's
   billing, not to this one.
2. **The maintainer authorizes; the agent executes.** An agent may run the
   release — that is the point of having one — but only on an explicit
   authorizing utterance, never on its own initiative and never on an inference.
   See [Authorization](#authorization) for the literal phrases and, just as
   importantly, the literal non-phrases.
3. **Work lands via branch + PR.** The maintainer merges the PR (code-review
   gate), then separately cuts the release. A merge is never a release.
4. **Changesets carry the notes and the bump.** Every behavior-changing PR
   includes a `.changeset/*.md` (see `.changeset/README.md` — it's just a file,
   no CLI needed): `patch` for fixes, `minor` for new commands or log/roster
   format changes, one user-facing sentence. CI maintains a rolling
   "chore: version + changelog" PR; merging it bumps `package.json` **and**
   `BUS_VERSION` in `bus` (via `scripts/sync-version`) and writes CHANGELOG.md —
   the "release is staged" signal.
5. **The on-disk formats are the API.** The log lines, roster rows, cursors and
   blobs outlive any single version: a listener armed before a `git pull` keeps
   running against files the new code writes. So a change to any of those
   grammars is at least a `minor`, the changeset states what older code does with
   the new shape, and where practical the new code reads both shapes for a
   window. Cross-machine format versioning is tracked in the issues.
6. **Every release states its update semantics.** Users update at arbitrary
   times, often mid-session, so the notes answer one question outright: is it
   safe to update while sessions are live, and why. For anything touching the
   listener pipeline the answer involves re-arming, and that belongs in the notes
   rather than in a support conversation.
7. **Verification grows with the change.** A behavior PR adds its check to
   `test/run.sh` or `test/e2e.sh` in the same PR. Hand-verification is how you
   work out what to assert, never the deliverable — an unautomated check is one
   nobody runs again.
8. **Green means green.** No skipped assertions, no "expected" failures, no
   red-and-merge-anyway. Silence is not evidence: a check that passes by finding
   nothing must be able to fail, or it is decoration.

## The flow

```
1. land the work      branch → PR (+ .changeset/*.md) → CI green → maintainer merges
2. stage the release  version-pr.yml opens "chore: version + changelog"
                      → maintainer merges it → bump + CHANGELOG on main
3. verify the staged  CI green on that merge commit, suite green locally,
   commit             behavior seen working on a real bus
4. get approval       maintainer says "ship it" for THAT commit
5. cut the tag        maintainer: gh release create vX.Y.Z --generate-notes
```

Each step is a checkpoint, and they are deliberately not collapsible:

- **Step 1 gates code, step 2 gates the version.** A merge is never a release —
  landing work and deciding to ship it are separate calls, and separating them is
  what lets several PRs accumulate into one coherent version.
- **Step 2 is the only place the version moves.** Never hand-edit `package.json`
  or `BUS_VERSION`; the version PR owns both (via `scripts/sync-version`), and
  the test suite fails if they drift.
- **Step 3 re-verifies the staged commit, not the feature branch.** That commit
  is what gets tagged, and it is not a tree anyone has run before — it is the
  merge of the version bump.
- **Step 4 is a human sentence, not an inference.** "Looks good", "merge it", or
  a green pipeline is not approval to release. Only an explicit "ship it / cut
  the release" naming this build counts, and it does not carry over to the next
  one.
- **Step 5 runs on the authorizing phrase, not before it.** The agent executes
  the release; what it may never do is decide that the moment has arrived. See
  [Authorization](#authorization).

Two checks around step 2 that are easy to skip and expensive to miss:

- **Before merging the version PR**, confirm it consumes every pending
  `.changeset/*.md` (the bot can lag behind the last merge). **After merging**,
  confirm none are left behind. Both directions have gone wrong in practice: a
  changeset stranded on main silently belongs to no release, and a version PR
  built before the last merge ships notes that omit it.
- **Before tagging**, run the e2e battery against the exact candidate commit
  from a fresh clone: `./test/e2e.sh <sha>`. A working checkout carries state a
  new user's clone will not, and the staged commit is a tree nobody has run.

The tag goes on the merge commit of the version PR, so `bus version` inside the
tagged tree agrees with the tag. `--generate-notes` is fine; pasting the new
CHANGELOG section into `--notes-file` is nicer.

## Authorization

A release is authorized by an **imperative naming the act**, from the
maintainer, in their own words:

> "release approved" · "ship it" · "cut the release" · "tag it"

These are **not** authorization, and an agent that treats any of them as
authorization has released without permission:

> "merge it" · "merged" · "looks good" · "build it" · "get it in" · "ready to
> ship?" · a merged PR · a merged version PR · green CI · a previous release's
> approval

Two forms deserve their own line, because they are the ones that actually get
misread:

- **A question is not an approval.** "should we ship it?" asks for a
  recommendation. Answer it, then wait for the imperative.
- **Merging is not approving.** The whole point of two gates is that the
  maintainer merges far more often than they release. An agent that infers
  "merged, therefore ship" has collapsed the gates that exist to be separate.

**An approval binds one act, one version, one commit.** If the tree moves
between the utterance and the execution, the approval is void — stop, say so,
and ask again. Conditional forward authorization ("ship it once CI is green") is
honored only for the condition actually stated.

**Approval does not outrank the gate.** If the gate goes red after approval,
nothing ships: stop, report, fix through its own PR, and ask for a fresh
authorization. An approval is permission to release a *verified* build, not an
instruction to release whatever is there.

**If you cannot quote the utterance, you did not have it.** The completion
report names it.

## Executing an approved release

On the authorizing phrase, in this order:

1. **Pin the commit.** Sync, resolve the exact sha, and use it explicitly for
   everything below. Never release "whatever main is now" — main can move
   between the utterance and the tag.
2. **Confirm the version is staged.** `package.json` and `BUS_VERSION` agree,
   `CHANGELOG.md` has the entry, and no `.changeset/*.md` remain pending.
3. **Re-run the whole gate on that sha** — after approval, before anything
   irreversible: `./test/run.sh`, then `./test/e2e.sh <sha>` from a fresh clone,
   and CI green on that commit for both platforms. A red gate voids the
   approval.
4. **Create the release against the pinned sha**, with notes carrying the
   changelog entry and the update-semantics line:
   `gh release create vX.Y.Z --target <sha> --notes-file <file>`
5. **Watch the tag build to completion.** The `v*` trigger runs the suites
   against the tagged commit; a release whose own build is red is not done.
6. **Confirm positively, from where a user stands.** Clone the tag fresh and
   assert it reports the released version — `bus version` says `vX.Y.Z` — and run
   one real behavior check. Success means an explicit match, never the absence
   of an error: a check that passes by finding nothing must be able to fail.
7. **Report** with the gate numbers on the released sha, the release URL, the
   tag build result, the positive confirmation, the authorizing utterance, and
   an explicit list of anything **not** verified.

### When something is wrong after the tag

Deleting a tag is cheap here precisely because a release deploys nothing:
`gh release delete vX.Y.Z --cleanup-tag`, fix forward, cut again. Do that rather
than force-moving a tag — a moved tag means two different trees answered to one
version, which is the one failure mode a version number exists to prevent.

## What node is doing in a no-dependency repo

Dev tooling only. The bus itself stays bash + coreutils with no runtime
dependencies; `package.json` and `@changesets/cli` exist so CI can maintain the
version PR and CHANGELOG. Nothing is published to npm (`private: true`), and no
user ever needs npm — `npm ci` runs only inside `version-pr.yml`. `test/run.sh`
fails if `BUS_VERSION` and `package.json` ever drift.

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
2. **Only the maintainer ships.** Agent sessions must never run
   `gh release create` (or push tags) on their own initiative or on an ambiguous
   instruction. An agent may propose a release; the maintainer cuts it, or gives
   an explicit "ship it" for THAT build.
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
- **Step 5 is the maintainer's own keystroke.** An agent may prepare everything
  up to it — draft notes, confirm CI, state the exact command — and must stop
  there.

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

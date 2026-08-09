# Releasing (maintainer ops)

Changesets in version-only mode, with an explicitly gated tag — scaled to a repo
where **a release deploys nothing**: the install is a symlink to a checkout and
the update is `git pull` off main, so a tag is a durable label ("this machine
runs v0.1.x"), not a distribution channel. That changes when plugin-marketplace
packaging lands; the flow below is already shaped for it.

## Release gate

1. **Verified live first.** The changed behavior has been exercised for real on
   a local bus, and `./test/run.sh` is green. This is deliberately a LOCAL gate:
   the suite runs in about a second against real shell and process behavior,
   which beats a CI runner for this code, so there is no test CI and local
   discipline is the gate.
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
5. **Format changes get called out.** Anything that changes the log-line
   grammar, the roster row format, or (once the bridge exists) the wire format is
   at least a `minor`, and the changeset says what older versions do with the new
   shape. Cross-machine format versioning itself is tracked in the issues.

## The flow

```
branch → PR carrying a .changeset/*.md → maintainer merges
  → version-pr.yml maintains the rolling "chore: version + changelog" PR
    → maintainer merges it (bump + CHANGELOG land on main)
      → maintainer: gh release create vX.Y.Z --generate-notes
```

The tag goes on the merge commit of the version PR, so `bus version` inside the
tagged tree agrees with the tag. `--generate-notes` is fine; pasting the new
CHANGELOG section into `--notes-file` is nicer.

## What node is doing in a no-dependency repo

Dev tooling only. The bus itself stays bash + coreutils with no runtime
dependencies; `package.json` and `@changesets/cli` exist so CI can maintain the
version PR and CHANGELOG. Nothing is published to npm (`private: true`), and no
user ever needs npm — `npm ci` runs only inside `version-pr.yml`. `test/run.sh`
fails if `BUS_VERSION` and `package.json` ever drift.

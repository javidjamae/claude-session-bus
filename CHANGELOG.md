# claude-session-bus

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

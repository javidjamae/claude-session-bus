# claude-session-bus

## 0.2.0

### Minor Changes

- 9058d65: Releases are now gated by an end-to-end battery that drives the real
  `tail -F | bus-filter` listener from a fresh clone (`./test/e2e.sh`), and both
  suites run in CI on Linux and macOS so the BSD and GNU fallbacks are each
  actually exercised.

---
"claude-session-bus": patch
---

Every script is now linted by ShellCheck in CI, and the blob sweep no longer
word-splits its file list — a blob path containing a space would have been
skipped instead of deleted. The README carries live build, lint, release and
license badges.

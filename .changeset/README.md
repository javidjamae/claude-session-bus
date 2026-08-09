# Changesets

Every PR that changes behavior includes one markdown file here: frontmatter
naming the bump (`patch` for fixes, `minor` for new commands or format
changes), then ONE user-facing sentence. No CLI needed — it's just a file:

```markdown
---
"claude-session-bus": patch
---

Senders that pass their handle as @name no longer receive echoes of their own messages.
```

CI consumes these into a rolling "chore: version + changelog" PR; merging that
PR bumps the version (package.json + `BUS_VERSION` in `bus`) and writes
CHANGELOG.md. The release itself is the operator's explicit
`gh release create` — see docs/RELEASE.md.

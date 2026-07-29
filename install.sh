#!/usr/bin/env bash
# Install claude-session-bus as a Claude Code skill.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p ~/.claude/skills
ln -sfn "$DIR" ~/.claude/skills/session-bus
chmod +x "$DIR/bus"
echo "Installed. In any Claude Code session: /session-bus <handle>"

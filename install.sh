#!/usr/bin/env bash
# Install claude-session-bus as a Claude Code skill.
#
#   ./install.sh              symlink the skill + register the SessionEnd auto-leave hook
#   ./install.sh --no-hook    symlink only; leave ~/.claude/settings.json untouched
#   ./install.sh --uninstall  remove the hook from settings.json and the skill symlink
#
# The hook registration merges into ~/.claude/settings.json: existing hooks of any
# event are preserved, and re-running replaces our own entry rather than stacking
# duplicates, so the install is idempotent and safe to repeat.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
SETTINGS="$HOME/.claude/settings.json"
HOOK="$DIR/hooks/session-end-leave"
MARKER="session-end-leave"        # identifies our entry across repo moves / renames

mode="install"
case "${1:-}" in
  --no-hook)   mode="no-hook" ;;
  --uninstall) mode="uninstall" ;;
  "")          ;;
  *) echo "usage: $0 [--no-hook|--uninstall]" >&2; exit 1 ;;
esac

# --- settings.json editing -------------------------------------------------
# Two backends so the install has no hard dependency: jq if present, else
# python3 (on every macOS/Linux box that runs Claude Code). If neither exists we
# print the snippet to paste rather than hand-editing JSON with sed.
edit_settings() {   # edit_settings <add|remove>
  local action="$1"
  mkdir -p "$(dirname "$SETTINGS")"
  [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

  local tmp="$SETTINGS.tmp.$$"
  if command -v jq >/dev/null 2>&1; then
    jq --arg cmd "$HOOK" --arg marker "$MARKER" --arg action "$action" '
      .hooks = (.hooks // {})
      | .hooks.SessionEnd = (
          [ (.hooks.SessionEnd // [])[]
            # drop any previous entry of ours (flat or grouped form)
            | select((([ .command? // empty ] + [ .hooks[]?.command? // empty ])
                      | map(test($marker)) | any) | not) ]
          + (if $action == "add" then [{hooks: [{type: "command", command: $cmd}]}] else [] end)
        )
      | if (.hooks.SessionEnd | length) == 0 then del(.hooks.SessionEnd) else . end
    ' "$SETTINGS" > "$tmp"
  elif command -v python3 >/dev/null 2>&1; then
    HOOK="$HOOK" MARKER="$MARKER" ACTION="$action" python3 -c '
import json, os, sys
hook, marker, action = os.environ["HOOK"], os.environ["MARKER"], os.environ["ACTION"]
s = json.load(open(sys.argv[1]))
hooks = s.setdefault("hooks", {})
def ours(e):
    cmds = [e.get("command")] + [h.get("command") for h in e.get("hooks", []) or []]
    return any(c and marker in c for c in cmds)
kept = [e for e in hooks.get("SessionEnd", []) if not ours(e)]
if action == "add":
    kept.append({"hooks": [{"type": "command", "command": hook}]})
if kept:
    hooks["SessionEnd"] = kept
else:
    hooks.pop("SessionEnd", None)
with open(sys.argv[2], "w") as f:
    json.dump(s, f, indent=2)
    f.write("\n")
' "$SETTINGS" "$tmp"
  else
    echo "! neither jq nor python3 found — skipping settings.json." >&2
    echo "  Add this to the \"hooks\" object in $SETTINGS by hand:" >&2
    echo "    \"SessionEnd\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"$HOOK\"}]}]" >&2
    return 0
  fi

  # only swap in a result that is valid, non-empty JSON; keep a one-deep backup
  if [ ! -s "$tmp" ]; then echo "! settings.json rewrite produced no output — left unchanged." >&2; rm -f "$tmp"; return 1; fi
  cp "$SETTINGS" "$SETTINGS.bak"
  mv "$tmp" "$SETTINGS"
}

# --- run -------------------------------------------------------------------
if [ "$mode" = "uninstall" ]; then
  edit_settings remove && echo "Removed the SessionEnd auto-leave hook from $SETTINGS (backup: $SETTINGS.bak)"
  if [ -L "$HOME/.claude/skills/session-bus" ]; then rm -f "$HOME/.claude/skills/session-bus"; echo "Removed the skill symlink."; fi
  echo "Uninstalled."
  exit 0
fi

mkdir -p ~/.claude/skills
ln -sfn "$DIR" ~/.claude/skills/session-bus
chmod +x "$DIR/bus" "$DIR/bus-filter" "$HOOK"

if [ "$mode" = "no-hook" ]; then
  echo "Installed (skill only). In any Claude Code session: /session-bus <handle>"
  echo "Auto-leave on session end is NOT registered — run ./install.sh without --no-hook to enable it."
else
  edit_settings add
  echo "Installed. In any Claude Code session: /session-bus <handle>"
  echo "Auto-leave registered as a SessionEnd hook in $SETTINGS (backup: $SETTINGS.bak)."
  echo "It won't fire on a hard kill (SIGKILL / closed terminal) — 'bus who' still flags those as stale."
fi

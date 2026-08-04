#!/usr/bin/env bash
# test/run.sh — dependency-free test suite for the bus CLI + bus-filter.
#
# No bats, no framework — just bash + coreutils, matching the project's ethos.
# Each test runs against a throwaway SESSION_BUS_DIR so the real bus is never
# touched. Prints PASS/FAIL per assertion and exits non-zero if any fail.
#
#   ./test/run.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO="$(dirname "$SCRIPT_DIR")"
BUS="$REPO/bus"
FILTER="$REPO/bus-filter"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0; FAIL=0
if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; B=$'\033[1m'; Z=$'\033[0m'; else G=; R=; B=; Z=; fi

pass() { PASS=$((PASS+1)); printf '  %sPASS%s %s\n' "$G" "$Z" "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  %sFAIL%s %s\n' "$R" "$Z" "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
section() { printf '\n%s%s%s\n' "$B" "$1" "$Z"; }

assert_contains()     { case "$2" in *"$3"*) pass "$1";; *) fail "$1" "want-contains [$3] got [$2]";; esac; }
assert_not_contains() { case "$2" in *"$3"*) fail "$1" "want-absent [$3] got [$2]";; *) pass "$1";; esac; }
assert_eq()           { [ "$2" = "$3" ] && pass "$1" || fail "$1" "want [$3] got [$2]"; }
assert_match()        { printf '%s' "$2" | grep -qE "$3" && pass "$1" || fail "$1" "want-match /$3/ got [$2]"; }

# fresh, isolated bus dir for the next block of assertions
fresh() { export SESSION_BUS_DIR="$(mktemp -d "$TMP_ROOT/bus.XXXXXX")"; }
LOGF()  { printf '%s\n' "$*" >> "$SESSION_BUS_DIR/bus.log"; }        # inject a raw log line
ago()   { date -v-"$1"H '+%m-%d %H:%M' 2>/dev/null || date -d "-$1 hours" '+%m-%d %H:%M'; }

# ---------------------------------------------------------------------------
section "dated timestamp format"
fresh
"$BUS" join alice >/dev/null
"$BUS" join bob   >/dev/null
"$BUS" send bob @alice "hi there" >/dev/null
line="$(grep ':: hi there' "$SESSION_BUS_DIR/bus.log")"
assert_match "send stamps [handle MM-DD HH:MM]" "$line" '^\[bob [0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]\] @alice :: hi there$'
onl="$(grep 'online' "$SESSION_BUS_DIR/bus.log" | head -1)"
assert_match "join online line is dated" "$onl" '^\[alice [0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]\] online'
"$BUS" leave bob >/dev/null
off="$(grep 'offline' "$SESSION_BUS_DIR/bus.log")"
assert_match "leave offline line is dated" "$off" '^\[bob [0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]\] offline$'

# ---------------------------------------------------------------------------
section "send input validation"
fresh
"$BUS" send bob "no at-sign here" >/dev/null 2>&1; assert_eq "missing recipient -> rc 1" "$?" "1"
"$BUS" send bob @alice >/dev/null 2>&1;           assert_eq "empty message -> rc 1"    "$?" "1"
"$BUS" send bob @alice "ok" >/dev/null 2>&1;      assert_eq "valid send -> rc 0"       "$?" "0"

# ---------------------------------------------------------------------------
section "bus-filter addressing"
addr='[alice 08-03 01:00] @bob :: direct to bob'
multi='[alice 08-03 01:00] @bob @carol :: to both'
bcast='[dave 08-03 01:00] @all :: broadcast'
selfb='[bob 08-03 01:00] @all :: bob talking'
body='[alice 08-03 01:00] @carol :: hey @bob look'
assert_contains     "direct @bob wakes bob"        "$(printf '%s\n' "$addr"  | "$FILTER" bob)"   "direct to bob"
assert_eq           "direct @bob does not wake carol" "$(printf '%s\n' "$addr" | "$FILTER" carol)" ""
assert_eq           "sender alice not self-woken"  "$(printf '%s\n' "$addr"  | "$FILTER" alice)" ""
assert_contains     "multi wakes bob"              "$(printf '%s\n' "$multi" | "$FILTER" bob)"   "to both"
assert_contains     "multi wakes carol"            "$(printf '%s\n' "$multi" | "$FILTER" carol)" "to both"
assert_contains     "@all wakes anyone"            "$(printf '%s\n' "$bcast" | "$FILTER" bob)"   "broadcast"
assert_eq           "@all does NOT self-wake sender" "$(printf '%s\n' "$selfb" | "$FILTER" bob)" ""
assert_eq           "@mention in body does not wake" "$(printf '%s\n' "$body"  | "$FILTER" bob)" ""

# ---------------------------------------------------------------------------
section "catchup time-window"
fresh
IN="$(ago 2)"; OUT="$(ago 48)"
LOGF "[dave $IN] @csb :: recent dated mention"
LOGF "[dave $OUT] @csb :: old dated mention"
LOGF "[dave 01:00] @csb :: legacy undated mention"
LOGF "[dave $IN] @all :: recent broadcast"
LOGF "[csb $IN] @all :: my own message"
LOGF "[dave $IN] @carol :: hey @csb in body"
c12="$("$BUS" catchup csb)"
assert_contains     "in-window dated kept"          "$c12" "recent dated mention"
assert_contains     "in-window @all kept"           "$c12" "recent broadcast"
assert_not_contains "out-of-window dated dropped"   "$c12" "old dated mention"
assert_not_contains "undated legacy dropped"        "$c12" "legacy undated mention"
assert_not_contains "own message dropped (self)"    "$c12" "my own message"
assert_not_contains "body @mention dropped"         "$c12" "in body"
c96="$("$BUS" catchup csb 96)"
assert_contains     "wider window includes 48h line" "$c96" "old dated mention"

# ---------------------------------------------------------------------------
section "who liveness"
fresh
J='2026-08-03 00:00'
printf 'alice|/p|%s\nbob|/p|%s\ncarol|/p|%s\n' "$J" "$J" "$J" > "$SESSION_BUS_DIR/roster"
LOGF "[alice $(ago 0)] @all :: active now"
LOGF "[bob $(ago 8)] @all :: dated but 8h old"
LOGF "[carol 01:00] @all :: legacy undated only"
w="$("$BUS" who)"
aline="$(printf '%s\n' "$w" | grep '@alice')"
bline="$(printf '%s\n' "$w" | grep '@bob')"
cline="$(printf '%s\n' "$w" | grep '@carol')"
assert_contains     "active handle shows last seen"   "$aline" "last seen"
assert_not_contains "active handle not stale"         "$aline" "stale?"
assert_contains     "dated >6h flagged stale"         "$bline" "stale?"
assert_contains     "legacy-only flagged stale"       "$cline" "stale?"
assert_contains     "legacy-only labelled pre-upgrade" "$cline" "before dated-stamp upgrade"
fresh
assert_contains     "empty roster message"            "$("$BUS" who)" "nobody registered"

# ---------------------------------------------------------------------------
section "join records session id"
fresh
CLAUDE_CODE_SESSION_ID=sess-aaa "$BUS" join alice >/dev/null
assert_match "roster line is handle|cwd|joined|session_id" \
  "$(grep '^alice|' "$SESSION_BUS_DIR/roster")" '^alice\|.*\|.*\|sess-aaa$'
out="$(env -u CLAUDE_CODE_SESSION_ID "$BUS" join bob 2>&1 >/dev/null)"
assert_contains "warns when session id unavailable" "$out" "auto-leave"
w="$("$BUS" who)"
assert_contains "who still lists a 4-field entry" "$w" "@alice"
assert_not_contains "who does not leak session id into the path column" "$w" "sess-aaa"

# ---------------------------------------------------------------------------
section "leave --by-session (the SessionEnd path)"
fresh
# two sessions, same cwd, different handles — the case cwd alone can't resolve
CLAUDE_CODE_SESSION_ID=sess-1 "$BUS" join apb1 >/dev/null
CLAUDE_CODE_SESSION_ID=sess-2 "$BUS" join apb2 >/dev/null
"$BUS" leave --by-session sess-1 >/dev/null
w="$("$BUS" who)"
assert_not_contains "ending session's handle removed"  "$w" "@apb1"
assert_contains     "sibling session untouched"        "$w" "@apb2"
assert_contains     "offline logged for the one that left" \
  "$(grep 'offline' "$SESSION_BUS_DIR/bus.log")" "[apb1"
"$BUS" leave --by-session sess-unknown >/dev/null 2>&1
assert_eq "unknown session -> rc 0 (never blocks shutdown)" "$?" "0"
assert_contains "unknown session leaves roster alone" "$("$BUS" who)" "@apb2"
printf 'legacy|/p|2026-08-03 00:00\n' > "$SESSION_BUS_DIR/roster"
"$BUS" leave --by-session "" >/dev/null 2>&1
assert_contains "empty session id never matches legacy 3-field rows" "$("$BUS" who)" "@legacy"

# ---------------------------------------------------------------------------
section "leave --by-cwd fallback"
fresh
CLAUDE_CODE_SESSION_ID=sess-1 "$BUS" join solo >/dev/null
"$BUS" leave --by-cwd "$PWD" >/dev/null
assert_contains "unique cwd match is removed" "$("$BUS" who)" "nobody registered"
fresh
CLAUDE_CODE_SESSION_ID=sess-1 "$BUS" join twin1 >/dev/null
CLAUDE_CODE_SESSION_ID=sess-2 "$BUS" join twin2 >/dev/null
err="$("$BUS" leave --by-cwd "$PWD" 2>&1 >/dev/null)"; rc=$?
assert_eq       "ambiguous cwd -> rc 1"        "$rc" "1"
assert_contains "ambiguous cwd explains why"   "$err" "2 handles registered"
w="$("$BUS" who)"
assert_contains "ambiguous cwd removes nothing (1/2)" "$w" "@twin1"
assert_contains "ambiguous cwd removes nothing (2/2)" "$w" "@twin2"
"$BUS" leave --by-cwd --force "$PWD" >/dev/null
assert_contains "--force drops all handles at that cwd" "$("$BUS" who)" "nobody registered"
"$BUS" leave --by-cwd /nowhere >/dev/null 2>&1
assert_eq "unknown cwd -> rc 0" "$?" "0"

# ---------------------------------------------------------------------------
section "SessionEnd hook"
HOOK="$REPO/hooks/session-end-leave"
fresh
CLAUDE_CODE_SESSION_ID=hook-sess "$BUS" join hooked >/dev/null
CLAUDE_CODE_SESSION_ID=other-sess "$BUS" join bystander >/dev/null
printf '{"session_id":"hook-sess","transcript_path":"/t.jsonl","cwd":"/some/dir","hook_event_name":"SessionEnd","reason":"other"}' \
  | "$HOOK" >/dev/null 2>&1
assert_eq "hook exits 0" "$?" "0"
w="$("$BUS" who)"
assert_not_contains "hook deregistered the ending session"   "$w" "@hooked"
assert_contains     "hook left other sessions alone"         "$w" "@bystander"
printf '{"session_id":"never-joined","cwd":"/some/dir","hook_event_name":"SessionEnd"}' | "$HOOK" >/dev/null 2>&1
assert_eq "hook is a no-op rc 0 for non-bus sessions" "$?" "0"
assert_contains "no-op left the roster intact" "$("$BUS" who)" "@bystander"
# pretty-printed payload (multi-line) must parse too
fresh
CLAUDE_CODE_SESSION_ID=pretty-sess "$BUS" join pretty >/dev/null
printf '{\n  "session_id": "pretty-sess",\n  "hook_event_name": "SessionEnd"\n}\n' | "$HOOK" >/dev/null 2>&1
assert_contains "multi-line payload parsed" "$("$BUS" who)" "nobody registered"
# no session_id -> cwd fallback
fresh
CLAUDE_CODE_SESSION_ID=x "$BUS" join bycwd >/dev/null
printf '{"cwd":"%s","hook_event_name":"SessionEnd"}' "$PWD" | "$HOOK" >/dev/null 2>&1
assert_contains "cwd fallback used when session_id absent" "$("$BUS" who)" "nobody registered"
printf '' | "$HOOK" >/dev/null 2>&1
assert_eq "empty payload -> rc 0" "$?" "0"

# ---------------------------------------------------------------------------
section "install.sh settings.json merge"
fresh
FAKE_HOME="$(mktemp -d "$TMP_ROOT/home.XXXXXX")"
mkdir -p "$FAKE_HOME/.claude"
S="$FAKE_HOME/.claude/settings.json"
cat > "$S" <<'JSON'
{
  "model": "opus",
  "hooks": {
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "keep-me.sh"}]}],
    "SessionEnd": [{"hooks": [{"type": "command", "command": "someone-elses-cleanup.sh"}]}]
  }
}
JSON
HOME="$FAKE_HOME" "$REPO/install.sh" >/dev/null 2>&1
s="$(cat "$S")"
assert_contains "unrelated event preserved"        "$s" "keep-me.sh"
assert_contains "unrelated SessionEnd hook kept"   "$s" "someone-elses-cleanup.sh"
assert_contains "other settings preserved"         "$s" "opus"
assert_contains "our hook registered"              "$s" "session-end-leave"
HOME="$FAKE_HOME" "$REPO/install.sh" >/dev/null 2>&1
HOME="$FAKE_HOME" "$REPO/install.sh" >/dev/null 2>&1
n="$(grep -c 'session-end-leave' "$S")"
assert_eq "re-install is idempotent (no duplicate entries)" "$n" "1"
assert_contains "still valid JSON after re-installs" "$( (command -v jq >/dev/null && jq -e . "$S" >/dev/null && echo ok) || (python3 -c 'import json,sys;json.load(open(sys.argv[1]));print("ok")' "$S") )" "ok"
HOME="$FAKE_HOME" "$REPO/install.sh" --uninstall >/dev/null 2>&1
s="$(cat "$S")"
assert_not_contains "uninstall removes our hook"       "$s" "session-end-leave"
assert_contains     "uninstall keeps others' hooks"    "$s" "someone-elses-cleanup.sh"
assert_contains     "uninstall keeps other events"     "$s" "keep-me.sh"
# fresh HOME with no settings.json at all
FAKE_HOME2="$(mktemp -d "$TMP_ROOT/home2.XXXXXX")"
HOME="$FAKE_HOME2" "$REPO/install.sh" >/dev/null 2>&1
assert_contains "creates settings.json when absent" "$(cat "$FAKE_HOME2/.claude/settings.json" 2>/dev/null)" "session-end-leave"
FAKE_HOME3="$(mktemp -d "$TMP_ROOT/home3.XXXXXX")"
HOME="$FAKE_HOME3" "$REPO/install.sh" --no-hook >/dev/null 2>&1
assert_not_contains "--no-hook leaves settings.json alone" "$(cat "$FAKE_HOME3/.claude/settings.json" 2>/dev/null)" "session-end-leave"

# ---------------------------------------------------------------------------
printf '\n%s%d passed, %d failed%s\n' "$B" "$PASS" "$FAIL" "$Z"
[ "$FAIL" -eq 0 ]

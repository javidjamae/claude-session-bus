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
assert_contains     "no-cursor handle falls back to the window" "$c12" "recent dated mention"

# ---------------------------------------------------------------------------
section "catchup read cursor"
fresh
"$BUS" send carol @alice "before alice ever joined" >/dev/null
"$BUS" join alice >/dev/null 2>&1
assert_contains "fresh join seeds cursor: no history dump" "$("$BUS" catchup alice)" "(nothing new)"
"$BUS" send bob @alice "first unread" >/dev/null
"$BUS" send bob @carol "not for alice" >/dev/null
"$BUS" send bob @all   "broadcast unread" >/dev/null
c="$("$BUS" catchup alice)"
assert_contains     "cursor delivers the unread mention"  "$c" "first unread"
assert_contains     "cursor delivers the unread @all"     "$c" "broadcast unread"
assert_not_contains "cursor drops other people's mail"    "$c" "not for alice"
assert_not_contains "cursor drops pre-join history"       "$c" "before alice ever joined"
assert_contains     "catchup advances the cursor"         "$("$BUS" catchup alice)" "(nothing new)"

# A graceful leave marks the log read, so the next session sees the gap and
# only the gap — the whole point of keying on leave rather than on a clock.
"$BUS" send bob @alice "seen live before leaving" >/dev/null
"$BUS" leave alice >/dev/null
"$BUS" send bob @alice "arrived while down" >/dev/null
"$BUS" join alice >/dev/null 2>&1
g="$("$BUS" catchup alice)"
assert_contains     "gap after graceful leave delivered"  "$g" "arrived while down"
assert_not_contains "pre-leave traffic not re-delivered"  "$g" "seen live before leaving"
assert_not_contains "rejoin does not reset an existing cursor" "$g" "first unread"

# The two failures the time window could not avoid.
fresh
"$BUS" join alice >/dev/null 2>&1; "$BUS" leave alice >/dev/null
LOGF "[bob $(ago 30)] @alice :: unread for 30 hours"
assert_contains     "gap wider than the old 12h window survives" "$("$BUS" catchup alice)" "unread for 30 hours"
fresh
"$BUS" join alice >/dev/null 2>&1; "$BUS" leave alice >/dev/null
i=1; while [ "$i" -le 60 ]; do "$BUS" send bob @alice "msg $i" >/dev/null; i=$((i+1)); done
assert_eq "60 unread messages, none clipped" "$("$BUS" catchup alice | grep -c 'msg ')" "60"
# A truncated log makes every offset meaningless; replay beats losing them.
: > "$SESSION_BUS_DIR/bus.log"
"$BUS" send bob @alice "after truncation" >/dev/null
assert_contains "log truncated under us -> replay, not silence" "$("$BUS" catchup alice)" "after truncation"

# ---------------------------------------------------------------------------
section "blob offload for large/multi-line payloads"
fresh
"$BUS" join alice >/dev/null 2>&1; "$BUS" leave alice >/dev/null
"$BUS" send bob @alice "$(printf 'plan header\nstep one\nstep two')" >/dev/null
assert_eq "multi-line send writes exactly one log line" \
  "$(grep -c '@alice ::' "$SESSION_BUS_DIR/bus.log")" "1"
line="$(grep '@alice ::' "$SESSION_BUS_DIR/bus.log")"
assert_contains "log keeps a readable preview"   "$line" "plan header"
assert_not_contains "body lines are not in the log" "$line" "step two"
assert_match    "log carries the blob key"       "$line" '\[blob [0-9]{8}-[0-9]{6}-[0-9]+: 3 lines'
assert_contains "recipient is still woken"       "$("$BUS" catchup alice)" "plan header"
key="$(printf '%s' "$line" | sed -n 's/.*\[blob \([0-9-]*\):.*/\1/p')"
assert_eq       "bus get returns the payload intact" "$("$BUS" get "$key")" "$(printf 'plan header\nstep one\nstep two')"
big="$(head -c 900 /dev/zero | tr '\0' 'x')"
"$BUS" send bob @alice "$big" >/dev/null
assert_contains "oversized single line offloads too" "$(grep -c 'blob ' "$SESSION_BUS_DIR/bus.log")" "2"
"$BUS" send bob @alice "short and single-line" >/dev/null
assert_not_contains "small message stays inline" "$(tail -1 "$SESSION_BUS_DIR/bus.log")" "blob "
k2="$(printf 'from stdin\nsecond line\n' | "$BUS" put)"
assert_eq       "put via stdin round-trips" "$("$BUS" get "$k2")" "$(printf 'from stdin\nsecond line')"
assert_contains "get rejects a path as a key" "$("$BUS" get ../../etc/passwd 2>&1)" "bad blob key"
assert_contains "get reports a missing blob"  "$("$BUS" get no-such-key 2>&1)" "no such blob"

# ---------------------------------------------------------------------------
section "handle ownership (one live session per name)"
dead_pid2() { ( exit 0 ) & p=$!; wait "$p" 2>/dev/null; printf '%s' "$p"; }
livestart="$(ps -o lstart= -p $$ | sed 's/^ *//;s/ *$//')"
LIVEROW() { printf '%s|%s|2026-08-05 13:00|%s|%s|%s\n' "$1" "${3:-/p}" "$2" "$$" "$livestart" >> "$SESSION_BUS_DIR/roster"; }

fresh
LIVEROW apb SID-X
out="$(CLAUDE_CODE_SESSION_ID=SID-B "$BUS" join apb 2>&1)"; rc=$?
assert_eq       "join refuses a name a live session holds" "$rc" "1"
assert_contains "refusal says the name is taken"           "$out" "@apb is taken"
assert_contains "refusal suggests a free alternative"      "$out" "Try @apb2"
assert_eq       "refused join did not touch the roster"    "$(grep -c '^apb|' "$SESSION_BUS_DIR/roster")" "1"
assert_contains "holder's session id survives the attempt" "$(cat "$SESSION_BUS_DIR/roster")" "SID-X"
LIVEROW apb2 SID-Y
assert_contains "suffix suggestion skips taken names"      "$(CLAUDE_CODE_SESSION_ID=SID-B "$BUS" join apb 2>&1)" "Try @apb3"

# The normal restart: the previous holder's process is gone, so the name is free.
fresh
printf 'ugs|/p|2026-08-04 10:00|SID-OLD|%s|\n' "$(dead_pid2)" > "$SESSION_BUS_DIR/roster"
assert_contains "restart reclaims a name whose process died" \
  "$(CLAUDE_CODE_SESSION_ID=SID-NEW "$BUS" join ugs 2>&1)" "joined as 'ugs'"
assert_contains "reclaimed row carries the new session id" "$(cat "$SESSION_BUS_DIR/roster")" "SID-NEW"
fresh
LIVEROW mc SID-A
assert_contains "same session re-registering is not a collision" \
  "$(CLAUDE_CODE_SESSION_ID=SID-A "$BUS" join mc 2>&1)" "joined as 'mc'"

# Removal is session-keyed too, or a displaced session evicts the live holder.
fresh
LIVEROW mc SID-LIVE
out="$(CLAUDE_CODE_SESSION_ID=SID-OTHER "$BUS" leave mc 2>&1)"; rc=$?
assert_eq       "another session cannot leave on your behalf"  "$rc" "1"
assert_contains "refusal names the owning session"             "$out" "SID-LIVE"
assert_contains "holder still registered after refused leave"  "$("$BUS" who)" "@mc"
assert_contains "--force reclaims deliberately" \
  "$(CLAUDE_CODE_SESSION_ID=SID-OTHER "$BUS" leave --force mc 2>&1)" "left."
fresh
LIVEROW mc SID-LIVE
assert_contains "the owner can always leave"      "$(CLAUDE_CODE_SESSION_ID=SID-LIVE "$BUS" leave mc 2>&1)" "left."
fresh
printf 'legacy|/p|2026-08-01 10:00|SID-GONE||\n' > "$SESSION_BUS_DIR/roster"
assert_contains "hand cleanup from a plain shell still works" \
  "$(env -u CLAUDE_CODE_SESSION_ID "$BUS" leave legacy 2>&1)" "left."

# --by-cwd is a guess; it must not evict a row whose process is still running.
fresh
LIVEROW held SID-Z /p/x
assert_contains "--by-cwd keeps a live row from another session" \
  "$("$BUS" leave --by-cwd /p/x 2>&1)" "kept @held"
assert_contains "kept row is still registered" "$("$BUS" who)" "@held"
assert_contains "--by-cwd --force overrides the keep" \
  "$("$BUS" leave --by-cwd --force /p/x 2>&1)" "left: @held"
fresh
printf 'goner|/p/x|2026-08-05 13:00|SID-G|%s|\n' "$(dead_pid2)" > "$SESSION_BUS_DIR/roster"
assert_contains "--by-cwd still removes a row whose process is gone" \
  "$("$BUS" leave --by-cwd /p/x 2>&1)" "left: @goner"

# ---------------------------------------------------------------------------
section "whoami"
fresh
assert_contains "not joined -> says so"      "$("$BUS" whoami 2>&1)" "not on the bus"
"$BUS" whoami >/dev/null 2>&1
assert_eq       "not joined -> rc 1"         "$?" "1"
CLAUDE_CODE_SESSION_ID=SID-W "$BUS" join alice >/dev/null 2>&1
o="$(CLAUDE_CODE_SESSION_ID=SID-W "$BUS" whoami 2>&1)"
assert_contains "reports this session's handle" "$o" "@alice"
assert_contains "says how it matched"           "$o" "matched by session id"
assert_contains "reprints the listen command"   "$o" "bus-filter alice"
# A sibling session in the same repo must resolve to itself, not its neighbour —
# the reason whoami keys on session id rather than cwd in the first place.
CLAUDE_CODE_SESSION_ID=SID-V "$BUS" join alice2 >/dev/null 2>&1
o="$(CLAUDE_CODE_SESSION_ID=SID-V "$BUS" whoami 2>&1)"
assert_contains     "sibling in same cwd resolves to itself"  "$o" "@alice2"
assert_not_contains "sibling did not fall back to a cwd guess" "$o" "a guess"
o="$(CLAUDE_CODE_SESSION_ID=SID-W "$BUS" whoami 2>&1)"
assert_contains     "the first session still resolves to itself" "$o" "@alice"
assert_not_contains "and is not confused by its sibling"         "$o" "@alice2"
# Neither id nor pid: a cwd match is explicitly labelled a guess.
fresh
printf 'ghost|%s|2026-08-05 13:00|||\n' "$PWD" > "$SESSION_BUS_DIR/roster"
o="$(env -u CLAUDE_CODE_SESSION_ID "$BUS" whoami 2>&1)"
assert_contains "cwd fallback still answers"  "$o" "@ghost"
assert_contains "cwd fallback admits it is a guess" "$o" "a guess"

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
assert_match "roster line is handle|cwd|joined|session_id|pid|pstart" \
  "$(grep '^alice|' "$SESSION_BUS_DIR/roster")" '^alice\|.*\|.*\|sess-aaa\|'
out="$(env -u CLAUDE_CODE_SESSION_ID "$BUS" join bob 2>&1 >/dev/null)"
assert_contains "warns when session id unavailable" "$out" "auto-leave"
w="$("$BUS" who)"
assert_contains "who still lists a 4-field entry" "$w" "@alice"
assert_not_contains "who does not leak session id into the path column" "$w" "sess-aaa"

# ---------------------------------------------------------------------------
section "join with no handle (dir slug)"
fresh
slug="$(printf '%s' "${PWD##*/}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-')"
out="$(CLAUDE_CODE_SESSION_ID=s1 "$BUS" join)"
assert_contains "derives a handle from the project dir" "$out" "joined as '$slug'"
out2="$(CLAUDE_CODE_SESSION_ID=s2 "$BUS" join)"
assert_contains "second session in the same dir gets a suffix" "$out2" "joined as '${slug}2'"
w="$("$BUS" who)"
assert_contains "first derived handle survives the second join" "$w" "@$slug "
assert_contains "both derived handles registered" "$w" "@${slug}2"
out3="$(CLAUDE_CODE_SESSION_ID=s1 "$BUS" join "$slug")"
assert_contains "an explicit handle re-registers rather than suffixing" "$out3" "joined as '$slug'"
assert_eq "explicit re-join does not add a row" \
  "$(grep -c "^$slug|" "$SESSION_BUS_DIR/roster")" "1"

# ---------------------------------------------------------------------------
section "prune (hard-kill backstop)"
# A pid that is guaranteed dead: spawn a trivial process and wait for it to exit.
dead_pid() { ( exit 0 ) & p=$!; wait "$p" 2>/dev/null; printf '%s' "$p"; }
ROW() { printf '%s|/p|2026-08-03 00:00|%s|%s|%s\n' "$1" "$2" "$3" "$4" >> "$SESSION_BUS_DIR/roster"; }
mystart="$(ps -o lstart= -p $$ | sed 's/^ *//;s/ *$//')"

fresh
ROW ghost   sess-g "$(dead_pid)" ""            # process gone
ROW livepid sess-l "$$"          "$mystart"    # this test process: alive, start matches
ROW legacy  sess-x ""            ""            # no pid recorded: unjudgeable
out="$("$BUS" prune)"
assert_contains     "prune reports the reaped handle"   "$out" "reaped: @ghost"
w="$("$BUS" who)"
assert_not_contains "dead process's row removed"        "$w" "@ghost"
assert_contains     "live process's row kept"           "$w" "@livepid"
assert_contains     "live row shown as process live"    "$w" "process live"
assert_contains     "pid-less row kept (not provably dead)" "$w" "@legacy"
assert_contains     "reap is logged as offline"         "$(cat "$SESSION_BUS_DIR/bus.log")" "[ghost"
assert_contains     "reap says why"                     "$(cat "$SESSION_BUS_DIR/bus.log")" "reaped"
assert_contains     "nothing left to prune the 2nd time" "$("$BUS" prune)" "nothing to prune"

# --force: the explicit "I know these are gone" sweep for pid-less rows. It is
# never passed by the implicit prunes inside who/join.
fresh
ROW legacy2 sess-x2 ""    ""            # unjudgeable
ROW alive2  sess-l2 "$$"  "$mystart"    # provably live
assert_contains     "implicit prune (via who) keeps pid-less rows" "$("$BUS" who)" "@legacy2"
f="$("$BUS" prune --force)"
assert_contains     "--force reports the dropped row"   "$f" "reaped: @legacy2"
w="$("$BUS" who)"
assert_not_contains "--force drops the pid-less row"    "$w" "@legacy2"
assert_contains     "--force still spares a live row"   "$w" "@alive2"
assert_contains     "forced drop is logged as forced"   "$(cat "$SESSION_BUS_DIR/bus.log")" "dropped by --force"
assert_not_contains "forced drop is not logged as proven-gone" \
  "$(grep legacy2 "$SESSION_BUS_DIR/bus.log")" "session process gone"

# pid reuse: same pid, different start time => the row's session is gone
fresh
ROW recycled sess-r "$$" "Mon Jan  1 00:00:00 2001"
"$BUS" prune >/dev/null
assert_not_contains "recycled pid is not mistaken for the same session" "$("$BUS" who)" "@recycled"

# an idle-but-listening session must survive: no activity in the log at all
fresh
ROW quiet sess-q "$$" "$mystart"
assert_contains "silent live session is never reaped" "$("$BUS" who)" "@quiet"

# the reaper must not disturb the joining session's own state (it runs inside join)
fresh
ROW ghost4 sess-g4 "$(dead_pid)" ""
CLAUDE_CODE_SESSION_ID=sess-keep "$BUS" join joiner >/dev/null 2>&1
assert_match "join still records its own session id after reaping" \
  "$(grep '^joiner|' "$SESSION_BUS_DIR/roster")" '^joiner\|.*\|.*\|sess-keep\|'
assert_not_contains "reaping did not warn about a missing session id" \
  "$(CLAUDE_CODE_SESSION_ID=sess-keep2 "$BUS" join joiner2 2>&1 >/dev/null)" "unset"

# who reaps on its own, and join reaps too
fresh
ROW ghost2 sess-g2 "$(dead_pid)" ""
assert_contains "who reaps and says so" "$("$BUS" who)" "reaped @ghost2"
fresh
ROW ghost3 sess-g3 "$(dead_pid)" ""
CLAUDE_CODE_SESSION_ID=sess-new "$BUS" join newcomer >/dev/null
w="$("$BUS" who)"
assert_not_contains "join reaps dead rows"    "$w" "@ghost3"
assert_contains     "join registers the newcomer" "$w" "@newcomer"

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

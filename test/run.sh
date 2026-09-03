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
LISTEN_PIDS=""   # background `bus listen` processes spawned by tests; reaped on exit
cleanup() {
  for _lp in $LISTEN_PIDS; do kill "$_lp" 2>/dev/null; done
  rm -rf "$TMP_ROOT"
  return 0
}
trap cleanup EXIT

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
fresh() { SESSION_BUS_DIR="$(mktemp -d "$TMP_ROOT/bus.XXXXXX")"; export SESSION_BUS_DIR; }
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
"$BUS" send @bob @alice "at-form sender" >/dev/null
assert_match "sender's leading @ is stripped before logging" \
  "$(grep ':: at-form sender' "$SESSION_BUS_DIR/bus.log")" '^\[bob '

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

# A sender logged in the @-form ('[@alice ' instead of '[alice ') must behave the same:
# no self-echo, and the sender token must never match as if it were an address.
atbcast='[@alice 08-03 01:00] @all :: alice broadcast'
atdirect='[@alice 08-03 01:00] @bob :: alice direct to bob'
assert_eq           "@-form sender: @all does not self-echo"     "$(printf '%s\n' "$atbcast"  | "$FILTER" alice)"    ""
assert_eq           "@-form sender: direct-to-other no self-echo" "$(printf '%s\n' "$atdirect" | "$FILTER" alice)"   ""
assert_contains     "@-form sender: @all still wakes others"     "$(printf '%s\n' "$atbcast"  | "$FILTER" bob)"   "alice broadcast"
assert_contains     "@-form sender: direct still wakes recipient" "$(printf '%s\n' "$atdirect" | "$FILTER" bob)"  "alice direct to bob"
assert_eq           "@-form sender token is not an address"      "$(printf '%s\n' "$atdirect" | "$FILTER" carol)" ""
assert_contains     "bare-form other->alice still delivered"        "$(printf '%s\n' '[dave 08-03 01:00] @alice :: for alice' | "$FILTER" alice)" "for alice"

# ---------------------------------------------------------------------------
section "catchup time-window"
fresh
IN="$(ago 2)"; OUT="$(ago 48)"
LOGF "[dave $IN] @alice :: recent dated mention"
LOGF "[dave $OUT] @alice :: old dated mention"
LOGF "[dave 01:00] @alice :: legacy undated mention"
LOGF "[dave $IN] @all :: recent broadcast"
LOGF "[alice $IN] @all :: my own message"
LOGF "[@alice $IN] @all :: my own @-form message"
LOGF "[@dave $IN] @carol :: at-form sender not for alice"
LOGF "[dave $IN] @carol :: hey @alice in body"
c12="$("$BUS" catchup alice)"
assert_contains     "in-window dated kept"          "$c12" "recent dated mention"
assert_contains     "in-window @all kept"           "$c12" "recent broadcast"
assert_not_contains "out-of-window dated dropped"   "$c12" "old dated mention"
assert_not_contains "undated legacy dropped"        "$c12" "legacy undated mention"
assert_not_contains "own message dropped (self)"    "$c12" "my own message"
assert_not_contains "own @-form message dropped"    "$c12" "my own @-form message"
assert_not_contains "@-form sender token not treated as address" "$c12" "at-form sender not for alice"
assert_not_contains "body @mention dropped"         "$c12" "in body"
c96="$("$BUS" catchup alice 96)"
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

# The sweep: old blobs go, recent ones stay, and the COUNT has to survive the
# loop that deletes them — it is reported to the user, and a loop that runs in a
# subshell would report 0 while deleting everything.
fresh
old="$(printf 'stale payload\n' | "$BUS" put)"
new="$(printf 'fresh payload\n' | "$BUS" put)"
touch -t 202501010000 "$SESSION_BUS_DIR/blobs/$old"
sw="$("$BUS" prune)"
assert_contains     "prune sweeps a blob older than the window" "$sw" "swept: 1 blob"
assert_contains     "swept blob is gone"        "$("$BUS" get "$old" 2>&1)" "no such blob"
assert_eq           "recent blob is untouched"  "$("$BUS" get "$new")" "fresh payload"
# A path with a space must be deleted, not word-split into pieces that survive.
spaced="$SESSION_BUS_DIR/blobs/old key with spaces"
printf 'spaced payload\n' > "$spaced"
touch -t 202501010000 "$spaced"
assert_contains     "sweep handles a blob path containing spaces" "$("$BUS" prune)" "swept: 1 blob"
[ -e "$spaced" ] && fail "spaced blob actually deleted" "still on disk" || pass "spaced blob actually deleted"

# ---------------------------------------------------------------------------
section "handle ownership (one live session per name)"
dead_pid2() { ( exit 0 ) & p=$!; wait "$p" 2>/dev/null; printf '%s' "$p"; }
livestart="$(ps -o lstart= -p $$ | sed 's/^ *//;s/ *$//')"
LIVEROW() { printf '%s|%s|2026-08-05 13:00|%s|%s|%s\n' "$1" "${3:-/p}" "$2" "$$" "$livestart" >> "$SESSION_BUS_DIR/roster"; }

fresh
LIVEROW alice SID-X
out="$(CLAUDE_CODE_SESSION_ID=SID-B "$BUS" join alice 2>&1)"; rc=$?
assert_eq       "join refuses a name a live session holds" "$rc" "1"
assert_contains "refusal says the name is taken"           "$out" "@alice is taken"
assert_contains "refusal suggests a free alternative"      "$out" "Try @alice2"
assert_eq       "refused join did not touch the roster"    "$(grep -c '^alice|' "$SESSION_BUS_DIR/roster")" "1"
assert_contains "holder's session id survives the attempt" "$(cat "$SESSION_BUS_DIR/roster")" "SID-X"
LIVEROW alice2 SID-Y
assert_contains "suffix suggestion skips taken names"      "$(CLAUDE_CODE_SESSION_ID=SID-B "$BUS" join alice 2>&1)" "Try @alice3"

# The normal restart: the previous holder's process is gone, so the name is free.
fresh
printf 'carol|/p|2026-08-04 10:00|SID-OLD|%s|\n' "$(dead_pid2)" > "$SESSION_BUS_DIR/roster"
assert_contains "restart reclaims a name whose process died" \
  "$(CLAUDE_CODE_SESSION_ID=SID-NEW "$BUS" join carol 2>&1)" "joined as 'carol'"
assert_contains "reclaimed row carries the new session id" "$(cat "$SESSION_BUS_DIR/roster")" "SID-NEW"
fresh
LIVEROW bob SID-A
assert_contains "same session re-registering is not a collision" \
  "$(CLAUDE_CODE_SESSION_ID=SID-A "$BUS" join bob 2>&1)" "joined as 'bob'"

# Removal is session-keyed too, or a displaced session evicts the live holder.
fresh
LIVEROW bob SID-LIVE
out="$(CLAUDE_CODE_SESSION_ID=SID-OTHER "$BUS" leave bob 2>&1)"; rc=$?
assert_eq       "another session cannot leave on your behalf"  "$rc" "1"
assert_contains "refusal names the owning session"             "$out" "SID-LIVE"
assert_contains "holder still registered after refused leave"  "$("$BUS" who)" "@bob"
assert_contains "--force reclaims deliberately" \
  "$(CLAUDE_CODE_SESSION_ID=SID-OTHER "$BUS" leave --force bob 2>&1)" "left."
fresh
LIVEROW bob SID-LIVE
assert_contains "the owner can always leave"      "$(CLAUDE_CODE_SESSION_ID=SID-LIVE "$BUS" leave bob 2>&1)" "left."
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
section "listen guard (one live monitor per session)"
# `bus listen` blocks by design, so allowed listeners run in the background and
# are reaped by the exit trap; refused ones exit on their own and are safe to
# run in the foreground.
spawn_listener() { # <sid> <handle>  — sets SPAWNED to the listener's pid
  CLAUDE_CODE_SESSION_ID="$1" "$BUS" listen "$2" >/dev/null 2>&1 &
  SPAWNED=$!
  LISTEN_PIDS="$LISTEN_PIDS $SPAWNED"
}
wait_lockfile() { # <handle> [secs] — until the listener has registered its lock
  _deadline=$(( $(date +%s) + ${2:-10} ))
  while [ "$(date +%s)" -lt "$_deadline" ]; do
    [ -s "$SESSION_BUS_DIR/listeners/$1" ] && return 0
    sleep 0.1
  done
  return 1
}
wait_lock_not_pid() { # <handle> <pid> [secs] — until the lock belongs to someone else
  _deadline=$(( $(date +%s) + ${3:-10} ))
  while [ "$(date +%s)" -lt "$_deadline" ]; do
    if [ -s "$SESSION_BUS_DIR/listeners/$1" ] && ! grep -q "^$2|" "$SESSION_BUS_DIR/listeners/$1"; then return 0; fi
    sleep 0.1
  done
  return 1
}

fresh
spawn_listener SID-L alice; L1=$SPAWNED
wait_lockfile alice && pass "listener records its lock" || fail "listener records its lock" "no lock file appeared"
out="$(CLAUDE_CODE_SESSION_ID=SID-L "$BUS" listen alice 2>&1)"; rc=$?
assert_eq       "same session, same handle: duplicate refused"     "$rc" "1"
assert_contains "refusal says it is already listening"             "$out" "ALREADY listening as @alice"
out="$(CLAUDE_CODE_SESSION_ID=SID-L "$BUS" listen beta 2>&1)"; rc=$?
assert_eq       "same session, new handle: second monitor refused" "$rc" "1"
assert_contains "refusal names the handle already held"            "$out" "@alice"
assert_contains "refusal states the rule"                          "$out" "one Monitor per session"
out="$(CLAUDE_CODE_SESSION_ID=SID-M "$BUS" listen alice 2>&1)"; rc=$?
assert_eq       "another session, same handle: refused"            "$rc" "1"
assert_contains "cross-session refusal says whose it is"           "$out" "different session"
spawn_listener SID-M beta; L2=$SPAWNED
wait_lockfile beta && pass "different session + different handle may listen" \
                   || fail "different session + different handle may listen" "no lock file appeared"
kill "$L1" 2>/dev/null; wait "$L1" 2>/dev/null
[ ! -f "$SESSION_BUS_DIR/listeners/alice" ] && pass "graceful stop removes the lock" \
                                            || fail "graceful stop removes the lock" "lock survived TERM"
spawn_listener SID-L alice; L3=$SPAWNED
wait_lockfile alice && pass "slot reusable after a graceful stop" \
                    || fail "slot reusable after a graceful stop" "no lock file appeared"
kill "$L2" "$L3" 2>/dev/null; wait "$L2" "$L3" 2>/dev/null

# A SIGKILLed listener leaves its lock behind; the dead pid proves it stale.
fresh
mkdir -p "$SESSION_BUS_DIR/listeners"
stale="$(dead_pid2)"
printf '%s|||||alice\n' "$stale" > "$SESSION_BUS_DIR/listeners/alice"
spawn_listener SID-N alice; L4=$SPAWNED
wait_lock_not_pid alice "$stale" && pass "stale lock (dead listener) never blocks" \
                                 || fail "stale lock (dead listener) never blocks" "takeover did not happen"
kill "$L4" 2>/dev/null; wait "$L4" 2>/dev/null

# An orphan — listener alive, owning session's process gone — is replaced, and
# the orphaned pipeline is put down rather than left tailing for nobody.
fresh
mkdir -p "$SESSION_BUS_DIR/listeners"
sleep 30 & ORPHAN=$!
disown "$ORPHAN"   # keep bash from announcing "Terminated" when the guard kills it
LISTEN_PIDS="$LISTEN_PIDS $ORPHAN"
orphan_start="$(ps -o lstart= -p "$ORPHAN" | sed 's/^ *//;s/ *$//')"
printf '%s|%s|%s|%s|SID-DEAD|alice\n' "$ORPHAN" "$orphan_start" "$(dead_pid2)" "Mon Jan  1 00:00:00 2001" > "$SESSION_BUS_DIR/listeners/alice"
spawn_listener SID-NEW alice; L5=$SPAWNED
wait_lock_not_pid alice "$ORPHAN" && pass "orphaned listener is replaced" \
                                  || fail "orphaned listener is replaced" "takeover did not happen"
_deadline=$(( $(date +%s) + 10 )); dead=""
while [ "$(date +%s)" -lt "$_deadline" ]; do kill -0 "$ORPHAN" 2>/dev/null || { dead=1; break; }; sleep 0.1; done
[ -n "$dead" ] && pass "orphaned pipeline is killed" || fail "orphaned pipeline is killed" "orphan pid still alive"
kill "$L5" 2>/dev/null; wait "$L5" 2>/dev/null

# The pid-keyed fallback: with no session ids anywhere, a live listener armed
# by a live process still refuses another would-be listener on the handle.
fresh
mkdir -p "$SESSION_BUS_DIR/listeners"
printf '%s|%s|%s|%s||alice\n' "$$" "$livestart" "$$" "$livestart" > "$SESSION_BUS_DIR/listeners/alice"
out="$(env -u CLAUDE_CODE_SESSION_ID "$BUS" listen alice 2>&1)"; rc=$?
assert_eq       "id-less live listener still refuses a duplicate" "$rc" "1"
assert_contains "id-less refusal takes the cross-session branch"  "$out" "different session"

# Refusal precedence: a session that already holds the one-Monitor slot must
# hear about ITS OWN listener, not be told to kill a healthy foreign one —
# regardless of lock-filename collation order ('alice' sorts before 'zeta').
fresh
mkdir -p "$SESSION_BUS_DIR/listeners"
printf '%s|%s|%s|%s|SID-FOREIGN|alice\n' "$$" "$livestart" "$$" "$livestart" > "$SESSION_BUS_DIR/listeners/alice"
spawn_listener SID-Z zeta; LZ=$SPAWNED
wait_lockfile zeta || fail "zeta listener armed" "no lock file appeared"
out="$(CLAUDE_CODE_SESSION_ID=SID-Z "$BUS" listen alice 2>&1)"; rc=$?
assert_eq           "own-session verdict outranks the foreign holder" "$rc" "1"
assert_contains     "the refusal names the session's own listener"    "$out" "@zeta"
assert_not_contains "and does not advise killing the foreign one"     "$out" "different session"
kill "$LZ" 2>/dev/null; wait "$LZ" 2>/dev/null

# leave puts this session's listener down: a leave that walked away from a live
# listener stranded the handle for its next owner and kept the old session
# waking on mail for a name it no longer held.
fresh
CLAUDE_CODE_SESSION_ID=SID-K "$BUS" join epsilon >/dev/null 2>&1
spawn_listener SID-K epsilon; LK=$SPAWNED
wait_lockfile epsilon || fail "epsilon listener armed" "no lock file appeared"
out="$(CLAUDE_CODE_SESSION_ID=SID-K "$BUS" leave epsilon 2>&1)"
assert_contains "leave reports stopping the listener" "$out" "stopped the @epsilon listener"
[ ! -f "$SESSION_BUS_DIR/listeners/epsilon" ] && pass "leave releases the listener lock" \
                                              || fail "leave releases the listener lock" "lock survived leave"
wait "$LK" 2>/dev/null
kill -0 "$LK" 2>/dev/null && fail "leave put the listener process down" "still running" \
                          || pass "leave put the listener process down"

# Orphans under OTHER handles are reaped too — a crashed session's pipeline
# must not leak until someone happens to reuse its exact handle.
fresh
mkdir -p "$SESSION_BUS_DIR/listeners"
sleep 30 & ORPH3=$!
disown "$ORPH3"
LISTEN_PIDS="$LISTEN_PIDS $ORPH3"
printf '%s|%s|%s|Mon Jan  1 00:00:00 2001|SID-DEAD|other\n' "$ORPH3" "$(ps -o lstart= -p "$ORPH3" | sed 's/^ *//;s/ *$//')" "$(dead_pid2)" > "$SESSION_BUS_DIR/listeners/other"
spawn_listener SID-P mine; LP=$SPAWNED
wait_lockfile mine || fail "mine listener armed" "no lock file appeared"
_deadline=$(( $(date +%s) + 10 )); gone=""
while [ "$(date +%s)" -lt "$_deadline" ]; do [ ! -f "$SESSION_BUS_DIR/listeners/other" ] && { gone=1; break; }; sleep 0.1; done
[ -n "$gone" ] && pass "listen sweeps orphans under other handles" \
               || fail "listen sweeps orphans under other handles" "orphan lock survived"
kill -0 "$ORPH3" 2>/dev/null && fail "the other-handle orphan is put down" "still running" \
                             || pass "the other-handle orphan is put down"
kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null

# prune sweeps the listener directory too — it is the documented SIGKILL
# backstop, and listener litter is exactly what a SIGKILL leaves behind.
fresh
mkdir -p "$SESSION_BUS_DIR/listeners"
printf '%s|||||stalehandle\n' "$(dead_pid2)" > "$SESSION_BUS_DIR/listeners/stalehandle"
sleep 30 & ORPH4=$!
disown "$ORPH4"
LISTEN_PIDS="$LISTEN_PIDS $ORPH4"
printf '%s|%s|%s|Mon Jan  1 00:00:00 2001|SID-DEAD|orphhandle\n' "$ORPH4" "$(ps -o lstart= -p "$ORPH4" | sed 's/^ *//;s/ *$//')" "$(dead_pid2)" > "$SESSION_BUS_DIR/listeners/orphhandle"
p="$("$BUS" prune)"
assert_contains "prune releases stale listener locks" "$p" "released @stalehandle"
assert_contains "prune puts down orphaned listeners"  "$p" "put down @orphhandle"
[ ! -f "$SESSION_BUS_DIR/listeners/stalehandle" ] && [ ! -f "$SESSION_BUS_DIR/listeners/orphhandle" ] \
  && pass "prune leaves no listener litter" || fail "prune leaves no listener litter"
kill -0 "$ORPH4" 2>/dev/null && fail "prune killed the orphaned pipeline" "still running" \
                             || pass "prune killed the orphaned pipeline"
assert_contains "nothing left after the listener sweep" "$("$BUS" prune)" "nothing to prune"

# Handles are canonicalized at the door: they live in log address fields,
# |-delimited roster rows and lock FILENAMES, so anything that would not
# survive all three verbatim is refused, and case is folded.
fresh
out="$("$BUS" join 'bad name' 2>&1)"; rc=$?
assert_eq       "handle with a space is refused"       "$rc" "1"
assert_contains "the refusal says what is allowed"     "$out" "invalid handle"
out="$("$BUS" join 'bad|pipe' 2>&1)"; rc=$?
assert_eq       "handle with a pipe is refused"        "$rc" "1"
out="$(CLAUDE_CODE_SESSION_ID=SID-U "$BUS" join ALICE 2>&1)"
assert_contains "uppercase folds to the canonical form" "$out" "joined as 'alice'"
out="$("$BUS" listen 'bad name' 2>&1)"; rc=$?
assert_eq       "listen refuses an invalid handle too" "$rc" "1"

# join and whoami know about the live listener, so their guidance never talks a
# forgetful session into arming the second Monitor the guard exists to prevent.
fresh
CLAUDE_CODE_SESSION_ID=SID-J "$BUS" join gamma >/dev/null 2>&1
spawn_listener SID-J gamma; LJ=$SPAWNED
wait_lockfile gamma || fail "listener for the join tests armed" "no lock file appeared"
out="$(CLAUDE_CODE_SESSION_ID=SID-J "$BUS" join gamma 2>&1)"
assert_contains     "re-join with a live listener warns instead"     "$out" "do NOT arm another Monitor"
assert_not_contains "re-join with a live listener hides the arm cmd" "$out" "Arm your listener"
out="$(CLAUDE_CODE_SESSION_ID=SID-J "$BUS" join 2>&1)"
assert_contains "bare re-join reports the existing handle"   "$out" "already joined as 'gamma'"
assert_eq       "bare re-join mints no suffixed handle" "$(grep -c '^gamma' "$SESSION_BUS_DIR/roster")" "1"
o="$(CLAUDE_CODE_SESSION_ID=SID-J "$BUS" whoami 2>&1)"
assert_contains "whoami shows the running listener"          "$o" "do NOT arm another Monitor"
# ...and both ask the guard's own per-SESSION question: joining a second handle
# while the @gamma Monitor runs must not hand out an arm command the guard is
# guaranteed to refuse.
out="$(CLAUDE_CODE_SESSION_ID=SID-J "$BUS" join delta 2>&1)"
assert_contains     "join under a second handle names the armed listener" "$out" "listening as @gamma"
assert_not_contains "and withholds the arm command"                       "$out" "Arm your listener"
o="$(CLAUDE_CODE_SESSION_ID=SID-J "$BUS" whoami 2>&1)"
assert_contains     "whoami flags the cross-handle listener"              "$o" "listening as @gamma"
CLAUDE_CODE_SESSION_ID=SID-J "$BUS" leave delta >/dev/null 2>&1
[ -f "$SESSION_BUS_DIR/listeners/gamma" ] && pass "leaving the other handle spares the armed listener" \
  || fail "leaving the other handle spares the armed listener" "gamma lock is gone"
kill "$LJ" 2>/dev/null; wait "$LJ" 2>/dev/null
out="$(CLAUDE_CODE_SESSION_ID=SID-J "$BUS" join gamma 2>&1)"
assert_contains "once the listener stops, join re-arms"      "$out" "Arm your listener"
out="$(CLAUDE_CODE_SESSION_ID=SID-J "$BUS" join 2>&1)"
assert_contains "bare re-join offers the arm cmd when not listening" "$out" "bus listen gamma"

# ---------------------------------------------------------------------------
section "help"
fresh
h="$("$BUS" help 2>/dev/null)"
assert_contains "help prints to stdout"      "$h" "bus — local coordination"
"$BUS" help >/dev/null 2>&1
assert_eq       "help exits 0"               "$?" "0"
for a in -h --help; do
  assert_contains "$a is an alias for help"  "$("$BUS" "$a" 2>/dev/null)" "bus join"
done
u="$("$BUS" jion 2>&1 >/dev/null)"
assert_contains "unknown command names the input" "$u" "unknown command 'jion'"
assert_contains "unknown command shows usage on stderr" "$u" "bus join"
"$BUS" jion >/dev/null 2>&1
assert_eq       "unknown command exits 1"    "$?" "1"
# Guard against drift: every implemented subcommand must appear in help.
missing=""
for c in $(awk '/^cmd=/{f=1} f && /^  [a-z][a-z-]*\)$/{gsub(/[ )]/,"");print}' "$BUS"); do
  printf '%s\n' "$h" | grep -qE "^  bus $c( |$)" || missing="$missing $c"
done
assert_eq "help documents every subcommand" "${missing# }" ""

# ---------------------------------------------------------------------------
section "version"
fresh
v="$("$BUS" version)"
assert_match "version prints 'bus <semver>'" "$v" '^bus [0-9]+\.[0-9]+\.[0-9]+'
assert_contains "version appends the git commit when run from a checkout" "$v" "(git "
"$BUS" version >/dev/null 2>&1
assert_eq "version exits 0" "$?" "0"
# Changesets bumps package.json; scripts/sync-version copies it into the bash.
# This is the guard that makes that pairing safe to trust.
pjv="$(sed -n 's/^  "version": *"\([^"]*\)".*/\1/p' "$REPO/package.json" | head -1)"
busv="$(sed -n 's/^BUS_VERSION="\(.*\)"$/\1/p' "$REPO/bus")"
assert_eq "BUS_VERSION matches package.json (run scripts/sync-version)" "$busv" "$pjv"
# The lock keeps its own copy of the project version. Nothing breaks when it
# drifts (npm ci only validates the dependency tree), which is exactly why it
# went three releases unnoticed — so assert it.
plv="$(sed -n 's/^  "version": *"\([^"]*\)".*/\1/p' "$REPO/package-lock.json" | head -1)"
assert_eq "package-lock.json version matches package.json" "$plv" "$pjv"
# changesets v3 skips PRIVATE packages unless told otherwise — and skips them
# SILENTLY: `changeset version` exits 0 saying "All files have been updated"
# while consuming no changeset and bumping nothing. This repo is private:true,
# so without this config the whole release pipeline is a no-op that looks fine.
# Caught by a smoke test after the v2->v3 bump; asserted here so it stays fixed.
assert_eq "changesets is configured to version private packages" \
  "$(node -e 'try{const c=require("'"$REPO"'/.changeset/config.json");console.log(c.privatePackages&&c.privatePackages.version===true?"yes":"no")}catch(e){console.log("unreadable")}' 2>/dev/null || echo skip)" "yes"

# The release job's own wiring. version-pr.yml only runs on push-to-main, so a
# PR can never exercise it — it broke twice in one afternoon (changesets/action
# v1->v2 renamed every input and hard-errors on the old ones) and both times the
# failure landed on main before anyone could see it. These are static checks of
# the file, which is the only tier that CAN catch it before the merge.
VPR="$REPO/.github/workflows/version-pr.yml"
# Only the changesets step's own `with:` block — the job is itself named
# `version:`, so scanning the whole file would flag the job id as a v1 input.
vpr_with="$(awk '/uses: changesets\/action/{f=1; next} f && /^ *env:/{f=0} f' "$VPR" 2>/dev/null)"
for old in version commit title; do
  assert_not_contains "version-pr.yml does not pass the v1 input '$old' (renamed in v2)" \
    "$(printf '%s\n' "$vpr_with" | grep -E "^ +$old:" )" "$old:"
done
assert_contains "version-pr.yml passes version-script"  "$vpr_with" "version-script:"
assert_contains "version-pr.yml passes commit-message"  "$vpr_with" "commit-message:"
assert_contains "version-pr.yml passes pr-title"        "$vpr_with" "pr-title:"
# Tag safety: both default to TRUE in changesets/action v2, and an automated tag
# would break the one rule the release doc is built around — the maintainer cuts
# the tag. Asserted so a future bump cannot quietly re-enable them.
assert_contains "version-pr.yml never creates GitHub releases" "$(cat "$VPR")" "create-github-releases: false"
assert_contains "version-pr.yml never pushes git tags"         "$(cat "$VPR")" "push-git-tags: false"

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
assert_contains "reprints the listen command"   "$o" "bus listen alice"
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
CLAUDE_CODE_SESSION_ID=sess-1 "$BUS" join alice1 >/dev/null
CLAUDE_CODE_SESSION_ID=sess-2 "$BUS" join alice2 >/dev/null
"$BUS" leave --by-session sess-1 >/dev/null
w="$("$BUS" who)"
assert_not_contains "ending session's handle removed"  "$w" "@alice1"
assert_contains     "sibling session untouched"        "$w" "@alice2"
assert_contains     "offline logged for the one that left" \
  "$(grep 'offline' "$SESSION_BUS_DIR/bus.log")" "[alice1"
"$BUS" leave --by-session sess-unknown >/dev/null 2>&1
assert_eq "unknown session -> rc 0 (never blocks shutdown)" "$?" "0"
assert_contains "unknown session leaves roster alone" "$("$BUS" who)" "@alice2"
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

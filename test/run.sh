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
printf '\n%s%d passed, %d failed%s\n' "$B" "$PASS" "$FAIL" "$Z"
[ "$FAIL" -eq 0 ]

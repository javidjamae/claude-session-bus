#!/usr/bin/env bash
# test/e2e.sh — the end-to-end battery: the real CLI, through the real listener
# pipeline, from a FRESH CLONE.
#
# test/run.sh pipes fixed strings into bus-filter. That proves the matching
# rules and nothing about delivery: the listener a session actually arms is
# `tail -F bus.log | bus-filter <handle>`, a long-running pipeline that has
# failed in ways no unit test could see (it once died with exit 144, and any
# unbuffered stage would silently hold messages until a later write flushed
# them). This exercises that pipeline for real, end to end.
#
# A fresh clone on purpose: a working checkout accumulates state — an untracked
# file, a stale mode bit, a blob directory — that a user installing from scratch
# will not have.
#
#   ./test/e2e.sh            # clone HEAD of this repo, run the battery
#   ./test/e2e.sh <sha>      # ...at an exact commit (what the release gate uses)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SRC="$(dirname "$SCRIPT_DIR")"
REF="${1:-HEAD}"

TMP="$(mktemp -d)"
CLONE="$TMP/clone"
export SESSION_BUS_DIR="$TMP/bus"
TAIL_PID=""; FILTER_PID=""
# Kill BOTH stages by pid. Killing a process group was the obvious way and the
# wrong one: macOS has no setsid, so the pipeline stayed in this script's group,
# the survivors held the caller's stdout pipe open, and the run hung after the
# last assertion — green, and never returning.
stop_listener() {
  for _p in "$FILTER_PID" "$TAIL_PID"; do
    [ -n "$_p" ] && kill "$_p" 2>/dev/null
  done
  wait "$FILTER_PID" "$TAIL_PID" 2>/dev/null
  TAIL_PID=""; FILTER_PID=""
  return 0
}
cleanup() { stop_listener; rm -rf "$TMP"; return 0; }
trap cleanup EXIT

PASS=0; FAIL=0
if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; B=$'\033[1m'; Z=$'\033[0m'; else G=; R=; B=; Z=; fi
pass() { PASS=$((PASS+1)); printf '  %sPASS%s %s\n' "$G" "$Z" "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  %sFAIL%s %s\n' "$R" "$Z" "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
section() { printf '\n%s%s%s\n' "$B" "$1" "$Z"; }

# Wait until <file> contains <string>, up to <secs>. Returns 1 on timeout, so a
# hang is reported as a failure rather than hanging the suite.
wait_for() { # <file> <string> [secs]
  _deadline=$(( $(date +%s) + ${3:-10} ))
  while [ "$(date +%s)" -lt "$_deadline" ]; do
    grep -qF "$2" "$1" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

# ---------------------------------------------------------------------------
section "fresh clone at $REF"
git clone -q "$SRC" "$CLONE" 2>/dev/null || { echo "could not clone $SRC" >&2; exit 1; }
git -C "$CLONE" checkout -q "$REF" 2>/dev/null || { echo "no such ref: $REF" >&2; exit 1; }
BUS="$CLONE/bus"
[ -x "$BUS" ] && pass "bus is executable straight out of the clone" \
              || fail "bus is executable straight out of the clone" "chmod bit not committed"
sha="$(git -C "$CLONE" rev-parse --short HEAD)"
v="$("$BUS" version)"
case "$v" in *"$sha"*) pass "bus version reports the cloned commit ($v)";;
             *) fail "bus version reports the cloned commit" "want $sha in [$v]";; esac

# ---------------------------------------------------------------------------
section "live delivery through tail -F | bus-filter"
"$BUS" join alice >/dev/null 2>&1
"$BUS" join bob   >/dev/null 2>&1
INBOX="$TMP/alice.inbox"
: > "$INBOX"
# The same two stages `bus join` prints, but started separately across a FIFO so
# each has a pid we can kill. Their stderr goes to a file, never to the caller's
# stream, so a survivor can never hold the invoking pipe open.
FIFO="$TMP/listener.fifo"; mkfifo "$FIFO"
tail -F -n 0 "$SESSION_BUS_DIR/bus.log" > "$FIFO" 2>"$TMP/tail.err" &
TAIL_PID=$!
"$CLONE/bus-filter" alice < "$FIFO" >> "$INBOX" 2>"$TMP/filter.err" &
FILTER_PID=$!
sleep 1   # let tail attach before the first write, or the event predates the watch

"$BUS" send bob @alice "ping through the real pipeline" >/dev/null
wait_for "$INBOX" "ping through the real pipeline" && pass "direct mention wakes the live listener" \
  || fail "direct mention wakes the live listener" "nothing arrived in 10s"

"$BUS" send bob @all "broadcast through the real pipeline" >/dev/null
wait_for "$INBOX" "broadcast through the real pipeline" && pass "@all wakes the live listener" \
  || fail "@all wakes the live listener" "nothing arrived in 10s"

# The filter must stay line-buffered: a second message has to arrive on its own,
# not sit in a buffer until a third write flushes it.
"$BUS" send bob @alice "second message arrives on its own" >/dev/null
wait_for "$INBOX" "second message arrives on its own" && pass "listener is line-buffered (no stuck message)" \
  || fail "listener is line-buffered (no stuck message)" "message held in a buffer"

"$BUS" send alice @bob "alice talking to bob" >/dev/null
sleep 1
grep -qF "alice talking to bob" "$INBOX" \
  && fail "sender does not receive its own message" "self-echo reached the listener" \
  || pass "sender does not receive its own message"

"$BUS" send bob @carol "not addressed to alice" >/dev/null
sleep 1
grep -qF "not addressed to alice" "$INBOX" \
  && fail "unaddressed traffic never reaches the listener" "delivered to the wrong handle" \
  || pass "unaddressed traffic never reaches the listener"

stop_listener
# The listener must not have died on its own before we stopped it — a filter
# that exits early looks exactly like a quiet bus.
[ -s "$TMP/filter.err" ] && fail "listener ran without errors" "$(head -2 "$TMP/filter.err")" \
                         || pass "listener ran without errors"

# ---------------------------------------------------------------------------
section "blob round-trip and catchup across a restart"
payload="$(printf 'line one\nline two\nline three')"
"$BUS" send bob @alice "$payload" >/dev/null
key="$(grep '@alice ::' "$SESSION_BUS_DIR/bus.log" | tail -1 | sed -n 's/.*\[blob \([0-9-]*\):.*/\1/p')"
[ -n "$key" ] && pass "multi-line send offloads to a blob" || fail "multi-line send offloads to a blob"
got="$("$BUS" get "$key" 2>/dev/null)"
[ "$got" = "$payload" ] && pass "blob round-trips byte-for-byte" \
  || fail "blob round-trips byte-for-byte" "got [$got]"

"$BUS" leave alice >/dev/null 2>&1
"$BUS" send bob @alice "arrived while alice was away" >/dev/null
"$BUS" join alice >/dev/null 2>&1
c="$("$BUS" catchup alice)"
case "$c" in *"arrived while alice was away"*) pass "catchup delivers the gap after a restart";;
             *) fail "catchup delivers the gap after a restart" "got [$c]";; esac
case "$c" in *"ping through the real pipeline"*) fail "catchup does not re-deliver what was live-delivered";;
             *) pass "catchup does not re-deliver what was live-delivered";; esac

# ---------------------------------------------------------------------------
section "roster reflects reality"
w="$("$BUS" who)"
case "$w" in *"@alice"*) pass "who lists the joined handle";; *) fail "who lists the joined handle" "got [$w]";; esac
"$BUS" leave alice >/dev/null 2>&1; "$BUS" leave bob >/dev/null 2>&1
w="$("$BUS" who)"
case "$w" in *"@alice"*) fail "who drops a handle after leave" "still listed";; *) pass "who drops a handle after leave";; esac

# ---------------------------------------------------------------------------
printf '\n%s%d passed, %d failed%s\n' "$B" "$PASS" "$FAIL" "$Z"
[ "$FAIL" -eq 0 ]

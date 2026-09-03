#!/usr/bin/env bash
# test/e2e.sh — the end-to-end battery: the real CLI, through the real listener
# pipeline, from a FRESH CLONE.
#
# test/run.sh pipes fixed strings into bus-filter. That proves the matching
# rules and nothing about delivery: the listener a session actually arms is
# `bus listen <handle>` — a long-running tail|bus-filter pipeline that has
# failed in ways no unit test could see (it once died with exit 144, and any
# unbuffered stage would silently hold messages until a later write flushed
# them). This exercises that pipeline for real, end to end, including the
# duplicate-listener guard and the lock cleanup on a graceful stop.
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
LISTEN_PID=""
# `bus listen` owns its two pipeline stages and kills them from its own exit
# trap on TERM — that cleanup is part of what this battery proves. The escalation
# to -9 is only so a regression in that trap fails an assertion instead of
# hanging the suite (the survivors would hold the caller's stdout pipe open, and
# the run would sit green after the last assertion, never returning).
stop_listener() {
  [ -n "$LISTEN_PID" ] || return 0
  kill "$LISTEN_PID" 2>/dev/null
  _i=0
  while kill -0 "$LISTEN_PID" 2>/dev/null && [ "$_i" -lt 50 ]; do sleep 0.1; _i=$((_i+1)); done
  kill -9 "$LISTEN_PID" 2>/dev/null
  wait "$LISTEN_PID" 2>/dev/null
  LISTEN_PID=""
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
section "live delivery through bus listen (the real Monitor command)"
"$BUS" join alice >/dev/null 2>&1
"$BUS" join bob   >/dev/null 2>&1
INBOX="$TMP/alice.inbox"
: > "$INBOX"
# Exactly what a session's Monitor runs: `bus listen alice`, stdout into the
# inbox. Its stderr goes to a file, never to the caller's stream, so a survivor
# can never hold the invoking pipe open.
CLAUDE_CODE_SESSION_ID=e2e-alice "$BUS" listen alice >> "$INBOX" 2>"$TMP/listen.err" &
LISTEN_PID=$!
_i=0   # armed = the lock exists; then give tail a beat to attach before the first write
while [ ! -s "$SESSION_BUS_DIR/listeners/alice" ] && [ "$_i" -lt 100 ]; do sleep 0.1; _i=$((_i+1)); done
[ -s "$SESSION_BUS_DIR/listeners/alice" ] && pass "bus listen registers its listener lock" \
  || fail "bus listen registers its listener lock" "no lock file in 10s"
sleep 1

dup="$(CLAUDE_CODE_SESSION_ID=e2e-alice "$BUS" listen alice 2>&1)"; rc=$?
[ "$rc" = "1" ] && pass "a second listener for the same session refuses to start" \
  || fail "a second listener for the same session refuses to start" "rc $rc: $dup"
case "$dup" in *"ALREADY listening"*) pass "the refusal says why";;
               *) fail "the refusal says why" "got [$dup]";; esac

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
[ -s "$TMP/listen.err" ] && fail "listener ran without errors" "$(head -2 "$TMP/listen.err")" \
                         || pass "listener ran without errors"
[ -f "$SESSION_BUS_DIR/listeners/alice" ] && fail "a stopped listener releases its lock" "lock survived" \
                                          || pass "a stopped listener releases its lock"

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

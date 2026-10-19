#!/usr/bin/env bash
# Opt-in live guard for the jcode-api away-supervisor backend. Enable with
# FM_AFK_JCODE_LIVE=1. A private jcode daemon (its own JCODE_HOME, runtime dir,
# and socket) hosts one created session standing in for the lock-owning primary;
# a scratch FM_HOME holds its afk flag and `.lock-session` sidecar. The real
# daemon code delivers one digest through the real harness API, and the guard
# asserts the session transcript gains the record doorbell as a system reminder
# and that the record verifies. The operator's jcode daemon, session, and home
# are never touched, and the private daemon is stopped before the guard exits.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate opt-in FM_AFK_JCODE_LIVE jcode node jq

LAB=
JH=

private_daemon_pids() {
  local d
  [ -n "$JH" ] || return 0
  for d in /proc/[0-9]*; do
    [ "$(cat "$d/comm" 2>/dev/null)" = jcode ] || continue
    tr '\0' '\n' < "$d/environ" 2>/dev/null | grep -qxF "JCODE_HOME=$JH" && printf '%s\n' "${d#/proc/}"
  done
  return 0
}

stop_private_daemon() {
  local pid
  for pid in $(private_daemon_pids); do kill "$pid" 2>/dev/null; done
  return 0
}

cleanup() {
  stop_private_daemon
  sleep 1
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-jcode-live.XXXXXX") || fail "could not create the lab"
LAB=$(cd "$LAB" && pwd -P)
JH="$LAB/jhome"
H="$LAB/home"
mkdir -p "$JH/run" "$H/state" "$H/config"
unset JCODE_SESSION_ID
export JCODE_HOME="$JH" JCODE_RUNTIME_DIR="$JH/run" JCODE_SOCKET="$JH/run/jcode.sock" JCODE_NO_AUTO_UPDATE=1
export FM_HOME="$H" FM_STATE_OVERRIDE="$H/state"
unset FM_ROOT_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE

nohup jcode --quiet --no-update serve --socket "$JCODE_SOCKET" >"$LAB/serve.log" 2>&1 &
for _ in $(seq 1 40); do [ -S "$JCODE_SOCKET" ] && break; sleep 0.25; done
[ -S "$JCODE_SOCKET" ] || fail "the private jcode daemon did not come up: $(tail -n 3 "$LAB/serve.log")"

SID=$(node "$ROOT/bin/fm-jcode-api.mjs" create "$LAB" --note "afk live guard session") \
  || fail "could not create the stand-in primary session"
printf '%s\n' "$SID" > "$H/state/.lock-session"
: > "$H/state/.afk"

# shellcheck source=bin/fm-supervise-daemon.sh
. "$ROOT/bin/fm-supervise-daemon.sh"
FM_SUPERVISOR_BACKEND=jcode-api
FM_SUPERVISOR_TARGET="$SID"
FM_DAEMON_PRIMARY_HARNESS=jcode
export FM_SUPERVISOR_BACKEND FM_SUPERVISOR_TARGET FM_DAEMON_PRIMARY_HARNESS

status=$(node "$ROOT/bin/fm-jcode-api.mjs" status "$SID") || fail "the status verb failed"
[ "$status" != running ] || fail "the stand-in session was unexpectedly running"

inject_msg "done: live guard digest" "$H/state" || fail "delivery was refused: ${INJECT_LAST_FAILURE:-unknown}"

found=
for _ in $(seq 1 40); do
  if grep -rlF 'Firstmate operational input waiting' "$JH/sessions" >/dev/null 2>&1; then found=1; break; fi
  sleep 0.5
done
[ -n "$found" ] || fail "the session transcript never gained the reminder"
grep -rhoF "read '$H/state/operational-inbox/" "$JH/sessions" | head -n 1 | grep -q . \
  || fail "the transcript reminder is not this home's record doorbell"
rec=$(find "$H/state/operational-inbox" -name '*.msg' | head -n 1)
"$ROOT/bin/fm-operational-input.sh" open "$rec" | grep -F 'live guard digest' >/dev/null \
  || fail "the record did not verify and print the digest"

stop_private_daemon
sleep 1
left=$(private_daemon_pids | wc -l | tr -d ' ')
[ "$left" = 0 ] || fail "the private daemon was left running (daemon_left=$left)"
printf 'ok - jcode-api delivers a record doorbell reminder to the lock-owning session on a private daemon (daemon_left=0)\n'

#!/usr/bin/env bash
# tests/fm-jcode-keeper.test.sh - the bridge and keeper lifecycle of
# bin/fm-jcode-keeper.sh and the keeper client bin/fm-jcode-keeper.mjs, against
# tests/fixtures/fake-jcode and fake-jcode-api.mjs (no real jcode, no network).
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v node >/dev/null 2>&1 || { echo "skip - node not installed"; exit 0; }
KEEPER="$ROOT/bin/fm-jcode-keeper.sh"
FAKE_API="$ROOT/tests/fixtures/fake-jcode-api.mjs"
TMP_ROOT=$(fm_test_tmproot fm-jcode-keeper)
XDG="$TMP_ROOT/run"
mkdir -p "$XDG" && chmod 700 "$XDG"
FAKEBIN="$TMP_ROOT/bin"
mkdir -p "$FAKEBIN"
ln -s "$ROOT/tests/fixtures/fake-jcode" "$FAKEBIN/jcode"
export FAKE_JCODE_LOG="$TMP_ROOT/jcode.log"
: >"$FAKE_JCODE_LOG"

FMH="$TMP_ROOT/home"
mkdir -p "$FMH/state"
DDIR="$TMP_ROOT/daemon"
DSOCK="$XDG/jcode.sock"
DPID=

start_daemon() {
  node "$FAKE_API" serve "$DSOCK" "$DDIR" >/dev/null 2>&1 &
  DPID=$!
  local i
  for i in $(seq 1 100); do [ -S "$DSOCK" ] && return 0; sleep 0.05; done
  fail "fake daemon did not start"
}
cleanup_all() {
  keeper "$FMH" stop >/dev/null 2>&1
  keeper "$TMP_ROOT/home2" stop >/dev/null 2>&1
  [ -z "$DPID" ] || kill "$DPID" 2>/dev/null
}
trap cleanup_all EXIT

keeper() {  # <fm-home> <args...>
  local h=$1
  shift
  env FM_HOME="$h" XDG_RUNTIME_DIR="$XDG" JCODE_SOCKET="$DSOCK" "PATH=$FAKEBIN:$PATH" \
    JCODE_ACTIVE_PROVIDER=copilot JCODE_SESSION_ID=stray FM_JCODE_CHILD_ENV_PASS=FAKE_JCODE_LOG "$KEEPER" "$@"
}
run_of() { keeper "$1" env | sed -n 's/^export FM_JCODE_RUN=//p'; }

test_refused_daemon_never_started() {
  local out rc
  out=$(keeper "$FMH" ensure --no-keeper 2>&1); rc=$?
  [ "$rc" -eq 1 ] || fail "ensure must exit 1 when the shared daemon refuses, got $rc"
  assert_contains "$out" "shared jcode daemon is not running" "names the failed component"
  [ ! -s "$FAKE_JCODE_LOG" ] || fail "no jcode invocation expected while the daemon is down"
  pass "a refused daemon socket exits 1 and nothing is started"
}

test_ensure_starts_one_bridge() {
  local out run n
  start_daemon
  out=$(keeper "$FMH" ensure --no-keeper 2>&1) || fail "ensure failed: $out"
  [ "$out" = ready ] || fail "ensure must print ready, got $out"
  run=$(run_of "$FMH")
  [ "$(stat -c %a "$run")" = 700 ] || fail "run dir must be 0700"
  [ "$(printf '%s' "$run/api.sock" | wc -c)" -lt 108 ] || fail "socket path must stay under 108 bytes"
  keeper "$FMH" ensure --no-keeper >/dev/null 2>&1 || fail "second ensure failed"
  n=$(grep -c api-bridge "$FAKE_JCODE_LOG")
  [ "$n" -eq 1 ] || fail "exactly one bridge start expected, got $n"
  if grep -Eq 'serve|server' "$FAKE_JCODE_LOG"; then fail "the daemon must never be started"; fi
  grep -q -- '--api-socket' "$FAKE_JCODE_LOG" || fail "bridge must be started with --api-socket"
  pass "ensure starts exactly one bridge and is idempotent"
}

test_bridge_env_is_clean() {
  local pid
  pid=$(cat "$(run_of "$FMH")/bridge.pid")
  if tr '\0' '\n' <"/proc/$pid/environ" | grep -Eq '^(JCODE_ACTIVE_PROVIDER|JCODE_SESSION_ID)='; then
    fail "stray JCODE_ACTIVE_PROVIDER or JCODE_SESSION_ID leaked into the bridge"
  fi
  tr '\0' '\n' <"/proc/$pid/environ" | grep -q "^JCODE_SOCKET=$DSOCK\$" || fail "bridge must carry the shared daemon socket"
  pass "bridge environment is an allowlist without stray provider variables"
}

test_run_dir_hash_per_home() {
  local a b
  mkdir -p "$TMP_ROOT/home2/state"
  a=$(run_of "$FMH")
  b=$(run_of "$TMP_ROOT/home2")
  [ "$a" != "$b" ] || fail "two homes must not share a run dir"
  [ "$a" = "$(run_of "$FMH")" ] || fail "the run dir must be stable per home"
  pass "the run directory is hash-stable per home and distinct between homes"
}

test_stop_only_this_home() {
  local run2 pid2 run1
  keeper "$TMP_ROOT/home2" ensure --no-keeper >/dev/null 2>&1 || fail "second home ensure failed"
  run2=$(run_of "$TMP_ROOT/home2")
  run1=$(run_of "$FMH")
  pid2=$(cat "$run2/bridge.pid")
  keeper "$FMH" stop >/dev/null || fail "stop failed"
  [ ! -S "$run1/api.sock" ] || fail "this home's api socket must be gone"
  kill -0 "$pid2" 2>/dev/null || fail "stop must not touch another home's bridge"
  kill -0 "$DPID" 2>/dev/null || fail "stop must not touch the daemon"
  keeper "$TMP_ROOT/home2" stop >/dev/null
  pass "stop ends only this home's bridge, never the daemon"
}

test_refused_daemon_never_started
test_ensure_starts_one_bridge
test_bridge_env_is_clean
test_run_dir_hash_per_home
test_stop_only_this_home

# ---- step 4: keeper core ----------------------------------------------------
KENV="FAKE_JCODE_LOG FM_JCODE_KEEPER_SCAN_MS FM_JCODE_KEEPER_BEAT_MS FM_JCODE_KEEPER_CHILD_MS FM_JCODE_KEEPER_IDLE_EXIT_SECS FM_JCODE_KEEPER_BACKOFF_MS"
export FM_JCODE_KEEPER_SCAN_MS=100 FM_JCODE_KEEPER_BEAT_MS=500 FM_JCODE_KEEPER_CHILD_MS=300 FM_JCODE_KEEPER_BACKOFF_MS=100,200
keeper() {  # <fm-home> <args...>
  local h=$1
  shift
  env FM_HOME="$h" XDG_RUNTIME_DIR="$XDG" JCODE_SOCKET="$DSOCK" "PATH=$FAKEBIN:$PATH" \
    JCODE_ACTIVE_PROVIDER=copilot JCODE_SESSION_ID=stray FM_JCODE_CHILD_ENV_PASS="$KENV" "$KEEPER" "$@"
}
api() { node "$ROOT/bin/fm-jcode-api.mjs" --socket "$(run_of "$FMH")/api.sock" "$@"; }
JS="$FMH/state/jcode"
dctl() { printf '%s\n' "$1" >>"$DDIR/ctl"; }
wait_for() {  # <description> <command...>
  local d=$1 i
  shift
  for i in $(seq 1 100); do "$@" 2>/dev/null && return 0; sleep 0.1; done
  fail "timed out waiting for $d"
}
bind_task() {  # <task> <session>
  printf 'backend=jcode\nendpoint_task_id=%s\n' "$1" >"$FMH/state/$1.meta"
  printf 'session=%s\ngen=1\nworktree=/tmp/wt\n' "$2" >"$FMH/state/$1.jcode-session"
}
live_is() { [ "$(cut -d' ' -f1 "$JS/live/$1" 2>/dev/null)" = "$2" ]; }
memory_off_count() { grep -c '"args":\["off"\]' "$DDIR/requests.log"; }

test_keeper_attach_records_and_memory() {
  local sid
  keeper "$FMH" ensure --no-keeper >/dev/null || fail "ensure failed"
  sid=$(api create "$TMP_ROOT" --model m1) || fail "create failed"
  SID1=$sid
  bind_task t1 "$sid"
  keeper "$FMH" ensure >/dev/null || fail "ensure (with keeper) failed"
  wait_for "live record" test -f "$JS/live/$sid"
  wait_for "memory off on attach" grep -q '"args":\["off"\]' "$DDIR/requests.log"
  printf 'go' | api send "$sid" || fail "send failed"
  wait_for "busy" live_is "$sid" busy
  wait_for "idle" live_is "$sid" idle
  grep -q "$(printf '\tjcode\t')" "$JS/transitions" || fail "transitions must carry normalized records"
  grep -q "working" "$JS/transitions" || fail "a working transition is recorded"
  pass "keeper attaches an owned session, applies memory off, records busy and idle"
}

test_injected_and_failure_records() {
  local sid=$SID1
  printf '{"hold":true}' >"$DDIR/script.json"
  printf 'steer' | api soft "$sid" --client-id fm-t1-1 || fail "soft failed"
  wait_for "injected record" grep -q " fm-t1-1 " "$JS/injected/$sid"
  dctl "stop $sid failure model_not_supported"
  wait_for "blocked transition" grep -q "blocked	failure model_not_supported" "$JS/transitions"
  rm -f "$DDIR/script.json"
  pass "soft interrupts land in injected/ and turn_stopped failure becomes a blocked transition"
}

test_memory_resent_after_reconnect() {
  local before
  before=$(memory_off_count)
  dctl "drop"
  wait_for "memory off re-sent" bash -c "[ \$(grep -c '\"args\":\\[\"off\"\\]' '$DDIR/requests.log') -gt $before ]"
  pass "memory off is re-applied on every reattach"
}

test_children_recorded() {
  dctl "child $SID1 helper /tmp/wt"
  wait_for "child record" grep -q "helper" "$FMH/state/t1.jcode-children"
  sleep 0.8
  [ "$(grep -c . "$FMH/state/t1.jcode-children")" -eq 1 ] || fail "a child is recorded once"
  pass "a child of a bound session is recorded in .jcode-children"
}

test_never_attaches_unrecorded() {
  local other
  other=$(api create "$TMP_ROOT" --model m1) || fail "create failed"
  sleep 1
  [ ! -e "$JS/live/$other" ] || fail "the keeper must not hold a session no task records"
  bind_task t2 "$other"
  wait_for "second session owned" test -f "$JS/live/$other"
  touch "$FMH/state/t2.jcode-exited"
  pass "the keeper attaches only recorded sessions"
}

test_keeper_idle_exit() {
  local pid
  rm -f "$FMH/state/t1.jcode-session" "$FMH/state/t2.jcode-session"
  keeper "$FMH" stop >/dev/null
  FM_JCODE_KEEPER_IDLE_EXIT_SECS=1 keeper "$FMH" ensure >/dev/null || fail "ensure failed"
  pid=$(cat "$JS/keeper.pid")
  wait_for "keeper idle exit" bash -c "! kill -0 $pid 2>/dev/null"
  pass "the keeper exits when nothing is bound"
}

test_keeper_attach_records_and_memory
test_injected_and_failure_records
test_memory_resent_after_reconnect
test_children_recorded
test_never_attaches_unrecorded
test_keeper_idle_exit

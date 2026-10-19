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

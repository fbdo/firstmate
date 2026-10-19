#!/usr/bin/env bash
# tests/fm-jcode-api.test.sh - the socket transport and the soft/history/exists/status
# verbs of bin/fm-jcode-api.mjs, against tests/fixtures/fake-jcode-api.mjs.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

API="$ROOT/bin/fm-jcode-api.mjs"
FAKE="$ROOT/tests/fixtures/fake-jcode-api.mjs"
TMP_ROOT=$(fm_test_tmproot fm-jcode-api)
command -v node >/dev/null 2>&1 || { echo "skip - node not installed"; exit 0; }

SOCK="$TMP_ROOT/api.sock"
DIR="$TMP_ROOT/fake"
node "$FAKE" serve "$SOCK" "$DIR" &
FAKE_PID=$!
HOLDER=
trap 'kill "$FAKE_PID" $HOLDER 2>/dev/null' EXIT
for _ in $(seq 1 100); do [ -S "$SOCK" ] && break; sleep 0.05; done
[ -S "$SOCK" ] || fail "fake daemon did not start"

api() { node "$API" --socket "$SOCK" "$@"; }

test_socket_transport_creates_and_sends() {
  local sid out
  sid=$(api create "$TMP_ROOT" --model m1 --note "hello") || fail "create over the socket failed"
  case "$sid" in session_fake_*) ;; *) fail "unexpected session id '$sid'" ;; esac
  # create's connection closed; the session persists because of the no-reply note.
  api exists "$sid" || fail "exists must succeed for a persisted session"
  api exists nope_session; [ $? -eq 1 ] || fail "exists must exit 1 for an unknown session"
  out=$(printf 'do the thing' | api send "$sid") || fail "send must wait for message_accepted and exit 0"
  [ -z "$out" ] || fail "send prints nothing"
  pass "socket transport: create, exists, send (message_accepted)"
  SID=$sid
}

test_history_renders_tail() {
  local i out
  for i in 1 2 3 4 5; do printf 'm%s' "$i" | api soft "$SID" || fail "soft failed"; sleep 0.3; done
  sleep 0.3
  out=$(api history "$SID" --lines 2) || fail "history failed"
  [ "$(printf '%s\n' "$out" | wc -l)" -eq 2 ] || fail "history --lines 2 must print two lines, got: $out"
  assert_contains "$out" "[assistant]" "the tail, not the head, must be rendered"
  out=$(api history "$SID") || fail "history failed"
  assert_contains "$out" "[user] do the thing" "full history keeps the head"
  pass "history renders the transcript tail"
}

test_status_and_soft() {
  local out
  sleep 0.1
  out=$(api status "$SID") || fail "status failed"
  [ "$out" = idle ] || fail "idle session status must be idle, got '$out'"
  printf '{"hold":true}' >"$DIR/script.json"
  printf 'steer' | api soft "$SID" || fail "soft must exit 0 on ok"
  sleep 0.2
  out=$(api status "$SID") || fail "status failed"
  [ "$out" = running ] || fail "status must be running during a held turn, got '$out'"
  rm -f "$DIR/script.json"
  out=$(api cancel "$SID")
  [ "$out" = cancelled ] || fail "cancel over the socket must report cancelled, got '$out'"
  grep -q '"client_id":"fm-' "$DIR/requests.log" || fail "soft_interrupt must carry an fm- client_id"
  pass "status and soft interrupt over the socket"
}

test_step2_verbs() {
  local out sid2
  api create "$TMP_ROOT" >/dev/null 2>&1; [ $? -eq 2 ] || fail "create without --model must exit 2"
  sid2=$(FM_JCODE_API_ALLOW_DEFAULT_MODEL=1 api create "$TMP_ROOT") || fail "create with the escape hatch failed"
  api rename "$SID" "fm:task-1" || fail "rename failed"
  grep -q '"req":"rename_session".*"fm:task-1"' "$DIR/requests.log" || fail "rename_session not sent"
  out=$(api runtime "$SID" memory off) || fail "runtime failed"
  [ "$out" = '{"enabled":false}' ] || fail "memory off must read enabled:false, got $out"
  out=$(api runtime "$SID" memory status) || fail "runtime status failed"
  [ "$out" = '{"enabled":false}' ] || fail "memory off holds while another connection holds the session, got $out"
  api runtime "$sid2" memory off >/dev/null; sleep 0.2
  out=$(api runtime "$sid2" memory status) || fail "runtime status failed"
  [ "$out" = '{"enabled":true}' ] || fail "memory off must not outlive the last connection, got $out"
  api runtime "$SID" bogus >/dev/null 2>&1; [ $? -eq 1 ] || fail "runtime error must exit 1"
  printf 'child %s helper /tmp/x\n' "$SID" >"$DIR/ctl"; sleep 0.3
  out=$(api children "$SID") || fail "children failed"
  assert_contains "$out" "helper	/tmp/x	idle" "children lists label, dir, status"
  [ -z "$(api children "$sid2")" ] || fail "no children expected for an unrelated session"
  printf 'x' | api soft "$SID" --client-id fm-task-1-9 || fail "soft with client id failed"
  grep -q '"client_id":"fm-task-1-9"' "$DIR/requests.log" || fail "soft must pass the caller client id"
  api archive "$sid2"
  pass "rename, runtime, children, soft --client-id, model required"
}

test_refused_socket_exits_4() {
  node "$API" --socket "$TMP_ROOT/none.sock" exists whatever 2>/dev/null
  [ $? -eq 4 ] || fail "a refused or absent socket must exit 4"
  FM_JCODE_API_TRANSPORT=socket JCODE_API_SOCKET="$TMP_ROOT/none.sock" node "$API" status whatever 2>/dev/null
  [ $? -eq 4 ] || fail "the env transport selection must also exit 4"
  pass "an unavailable daemon exits 4"
}

hold_attached() {
  # A turn survives only while a connection stays attached (the daemon's retention rule).
  node -e '
    const net = require("node:net");
    const c = net.createConnection(process.argv[1]);
    c.write(JSON.stringify({ v: 1, id: 1, req: "hello", min_version: 1, max_version: 1 }) + "\n");
    c.write(JSON.stringify({ v: 1, id: 2, req: "attach_session", session_id: process.argv[2] }) + "\n");
    setTimeout(() => process.exit(0), 60000);
  ' "$SOCK" "$SID" &
  HOLDER=$!
  sleep 0.3
}

test_socket_transport_creates_and_sends
hold_attached
test_history_renders_tail
test_status_and_soft
test_step2_verbs
test_refused_socket_exits_4

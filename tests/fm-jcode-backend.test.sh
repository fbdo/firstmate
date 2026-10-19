#!/usr/bin/env bash
# tests/fm-jcode-backend.test.sh - the native jcode runtime adapter
# (bin/backends/jcode.sh) behind the fm-backend.sh dispatcher, the ownership
# guard (D11), and the keeper-transition push seam, against the fake jcode API.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v node >/dev/null 2>&1 || { echo "skip - node not installed"; exit 0; }
KEEPER="$ROOT/bin/fm-jcode-keeper.sh"
FAKE_API="$ROOT/tests/fixtures/fake-jcode-api.mjs"
TMP_ROOT=$(fm_test_tmproot fm-jcode-backend)
XDG="$TMP_ROOT/run"
mkdir -p "$XDG" && chmod 700 "$XDG"
FAKEBIN="$TMP_ROOT/bin"
mkdir -p "$FAKEBIN"
ln -s "$ROOT/tests/fixtures/fake-jcode" "$FAKEBIN/jcode"
FMH="$TMP_ROOT/home"
STATE="$FMH/state"
mkdir -p "$STATE"
DDIR="$TMP_ROOT/daemon"
DSOCK="$XDG/jcode.sock"
WT="$TMP_ROOT/wt"
mkdir -p "$WT"

export FM_HOME="$FMH" XDG_RUNTIME_DIR="$XDG" JCODE_SOCKET="$DSOCK" PATH="$FAKEBIN:$PATH"
export FM_JCODE_KEEPER_SCAN_MS=100 FM_JCODE_KEEPER_BEAT_MS=500 FM_JCODE_KEEPER_CHILD_MS=300 FM_JCODE_INJECT_WAIT_TENTHS=30
export FM_JCODE_CHILD_ENV_PASS="FM_JCODE_KEEPER_SCAN_MS FM_JCODE_KEEPER_BEAT_MS FM_JCODE_KEEPER_CHILD_MS"

node "$FAKE_API" serve "$DSOCK" "$DDIR" >/dev/null 2>&1 &
DPID=$!
trap '"$KEEPER" stop >/dev/null 2>&1; kill "$DPID" 2>/dev/null' EXIT
for _ in $(seq 1 100); do [ -S "$DSOCK" ] && break; sleep 0.05; done
[ -S "$DSOCK" ] || fail "fake daemon did not start"

eval "$("$KEEPER" env)"
"$KEEPER" ensure >/dev/null || fail "ensure failed"
api() { node "$ROOT/bin/fm-jcode-api.mjs" --socket "$JCODE_API_SOCKET" "$@"; }

SID=$(api create "$WT" --model m1) || fail "create failed"
OUTSIDER=$(api create "$WT" --model m1) || fail "create failed"
TASK=jt1
write_meta() {  # <session> [extra lines]
  {
    printf 'backend=jcode\nendpoint_task_id=%s\nwindow=jcode:%s\njcode_session=%s\nworktree=%s\nproject=%s\n' "$TASK" "$1" "$1" "$WT" "$TMP_ROOT"
    printf 'jcode_socket=%s\njcode_api_socket=%s\n' "$DSOCK" "$JCODE_API_SOCKET"
  } >"$STATE/$TASK.meta"
}
write_meta "$SID"
printf 'session=%s\ngen=1\nworktree=%s\n' "$SID" "$WT" >"$STATE/$TASK.jcode-session"
TARGET="jcode:$SID"
. "$ROOT/bin/fm-backend.sh"
fm_backend_validate jcode || fail "jcode must be a known backend"

wait_for() {
  local d=$1 i
  shift
  for i in $(seq 1 100); do "$@" 2>/dev/null && return 0; sleep 0.1; done
  fail "timed out waiting for $d"
}
wait_for "keeper attach" test -f "$STATE/jcode/live/$SID"

test_validate_endpoint() {
  fm_backend_validate_task_endpoint "$STATE/$TASK.meta" "$TASK" || fail "a good record must validate"
  [ "$FM_BACKEND_VALIDATED_BACKEND" = jcode ] && [ "$FM_BACKEND_VALIDATED_TARGET" = "$TARGET" ] || fail "validated backend/target"
  cp "$STATE/$TASK.meta" "$TMP_ROOT/bad.meta"
  sed -i 's|^window=.*|window=jcode:other|' "$TMP_ROOT/bad.meta"
  fm_backend_validate_task_endpoint "$TMP_ROOT/bad.meta" "$TASK" 2>/dev/null && fail "a mismatched window must be refused"
  grep -v '^jcode_api_socket=' "$STATE/$TASK.meta" >"$TMP_ROOT/bad2.meta"
  fm_backend_validate_task_endpoint "$TMP_ROOT/bad2.meta" "$TASK" 2>/dev/null && fail "a missing api socket must be refused"
  fm_backend_validate_task_endpoint "$STATE/$TASK.meta" other 2>/dev/null && fail "a foreign task id must be refused"
  pass "validate_task_endpoint accepts a good jcode record and refuses mismatches"
}

test_composer_and_keys() {
  [ "$(fm_backend_composer_state jcode "$TARGET")" = empty ] || fail "there is no composer"
  fm_backend_send_key jcode "$TARGET" Enter || fail "Enter is a no-op success"
  fm_backend_send_key jcode "$TARGET" F5 2>/dev/null && fail "other keys are refused"
  pass "composer_state is empty, Enter is a no-op, unknown keys are refused"
}

test_send_text_submit_injected() {
  local out
  out=$(fm_backend_send_text_submit jcode "$TARGET" "check the inbox" 1 0 0) || fail "send failed"
  [ "$out" = empty ] || fail "an injected soft interrupt must read empty, got '$out'"
  grep -q " fm-$TASK-" "$STATE/jcode/injected/$SID" || fail "the keeper must record the injection with our client id"
  pass "send_text_submit delivers a soft interrupt and confirms the injected record"
}

test_unowned_session_refused() {
  local out before
  write_meta "$OUTSIDER"
  before=$(grep -c . "$DDIR/requests.log")
  out=$(fm_backend_send_text_submit jcode "jcode:$OUTSIDER" "hello" 1 0 0 2>&1); true
  assert_contains "$out" "send-failed" "an unowned session must not be sent to"
  assert_contains "$out" "not owned" "the refusal names ownership"
  fm_backend_kill jcode "jcode:$OUTSIDER" 2>/dev/null && fail "kill of an unowned session must refuse"
  fm_backend_send_key jcode "jcode:$OUTSIDER" C-c 2>/dev/null && fail "cancel of an unowned session must refuse"
  if tail -n +"$((before + 1))" "$DDIR/requests.log" | grep -q "\"session_id\":\"$OUTSIDER\".*\\(soft_interrupt\\|archive\\|cancel\\)\\|\\(soft_interrupt\\|archive_session\\|\"cancel\"\\).*$OUTSIDER"; then
    fail "no mutating request may reach an unowned session"
  fi
  write_meta "$SID"
  pass "every mutating call on an unowned session refuses before touching the API"
}

test_busy_and_agent_state() {
  [ "$(fm_backend_busy_state jcode "$TARGET")" = idle ] || fail "idle expected, got $(fm_backend_busy_state jcode "$TARGET")"
  printf '{"hold":true}' >"$DDIR/script.json"
  printf 'x' | api send "$SID"
  wait_for "busy live" bash -c "grep -q '^busy' '$STATE/jcode/live/$SID'"
  [ "$(fm_backend_busy_state jcode "$TARGET")" = busy ] || fail "busy expected"
  fm_backend_send_key jcode "$TARGET" C-c || fail "interrupt failed"
  rm -f "$DDIR/script.json"
  wait_for "idle again" bash -c "grep -q '^idle' '$STATE/jcode/live/$SID'"
  fm_backend_target_exists jcode "$TARGET" || fail "target exists"
  [ "$(fm_backend_agent_state jcode "$TARGET")" = alive ] || fail "agent alive expected"
  touch "$STATE/$TASK.jcode-exited"
  [ "$(fm_backend_agent_state jcode "$TARGET")" = dead ] || fail "exited marker reads dead"
  rm -f "$STATE/$TASK.jcode-exited"
  pass "busy_state, interrupt via C-c, target_exists, agent_state"
}

test_capture() {
  local out
  out=$(fm_backend_capture jcode "$TARGET" 3) || fail "capture failed"
  [ "$(printf '%s\n' "$out" | wc -l)" -le 3 ] || fail "capture honours the line bound"
  assert_contains "$out" "[" "capture renders transcript rows"
  pass "capture renders the transcript tail"
}

test_push_seam() {
  local rec rc
  fm_backend_has_push jcode || fail "jcode must be push capable"
  fm_backend_events_capable jcode jcode || fail "a live keeper makes events capable"
  rm -f "$STATE/.jcode-transitions-cursor"
  printf '%s\tjcode\tworking\tblocked\tfailure boom\n' "$SID" >>"$STATE/jcode/transitions"
  rec=$(fm_backend_wait_transition jcode jcode 5 "$STATE" "$TARGET"); rc=$?
  [ "$rc" -eq 0 ] || fail "a fresh blocked record must return 0, got $rc"
  [ "$(fm_transition_to_status "$rec")" = blocked ] || fail "record must be the blocked edge"
  fm_backend_commit_transition jcode "$STATE" jcode "$rec" || fail "commit failed"
  printf '%s\tjcode\tworking\tblocked\tagain\n' "$SID" >>"$STATE/jcode/transitions"
  fm_backend_wait_transition jcode jcode 2 "$STATE" "$TARGET" >/dev/null; rc=$?
  [ "$rc" -eq 1 ] || fail "a committed marker must suppress the repeat (timeout 1), got $rc"
  fm_backend_clear_transition jcode "$STATE" "jcode:jcode:$SID"
  # A record for a different session never wakes this window.
  printf 'other_session\tjcode\tworking\tblocked\tx\n' >>"$STATE/jcode/transitions"
  fm_backend_wait_transition jcode jcode 2 "$STATE" "$TARGET" >/dev/null; rc=$?
  [ "$rc" -eq 1 ] || fail "another session's record must be ignored, got $rc"
  touch -d '2 minutes ago' "$STATE/jcode/keeper.beat"
  fm_backend_wait_transition jcode jcode 2 "$STATE" "$TARGET" >/dev/null; rc=$?
  [ "$rc" -eq 2 ] || fail "a stale beat must return 2, got $rc"
  fm_backend_events_capable jcode jcode && fail "a stale beat is not events capable"
  pass "wait_transition: fresh blocked 0, committed repeat 1, other session ignored, stale beat 2"
}

test_kill_archives_children_then_worker() {
  local before
  printf 'child %s helper %s\n' "$SID" "$WT" >"$DDIR/ctl"
  printf 'child %s outsider /somewhere/else\n' "$SID" >>"$DDIR/ctl"
  wait_for "children recorded" bash -c "[ \$(grep -c . '$STATE/$TASK.jcode-children' 2>/dev/null) -ge 2 ]"
  before=$(grep -c . "$DDIR/requests.log")
  fm_backend_kill jcode "$TARGET" 2>"$TMP_ROOT/kill.err" || fail "kill failed: $(cat "$TMP_ROOT/kill.err")"
  assert_contains "$(cat "$TMP_ROOT/kill.err")" "outside the task worktree" "an outside child is logged, not acted on"
  tail -n +"$((before + 1))" "$DDIR/requests.log" >"$TMP_ROOT/kill.req"
  grep -n archive_session "$TMP_ROOT/kill.req" | head -3 >"$TMP_ROOT/kill.arch"
  [ "$(grep -c archive_session "$TMP_ROOT/kill.req")" -eq 2 ] || fail "exactly the in-worktree child and the worker are archived"
  [ "$(tail -n 1 "$TMP_ROOT/kill.arch" | grep -o "$SID" | head -1)" = "$SID" ] || fail "the worker is archived after its children"
  fm_backend_kill jcode "$TARGET" || fail "kill of an already archived session returns 0"
  pass "kill archives in-worktree children before the worker, skips outside children, and is idempotent"
}

test_validate_endpoint
test_composer_and_keys
test_send_text_submit_injected
test_unowned_session_refused
test_busy_and_agent_state
test_capture
test_push_seam
test_kill_archives_children_then_worker

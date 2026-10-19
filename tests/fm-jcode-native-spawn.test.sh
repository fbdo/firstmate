#!/usr/bin/env bash
# tests/fm-jcode-native-spawn.test.sh - the native jcode path of bin/fm-spawn.sh
# (backend=jcode) against the fake jcode API: selection, refusals, meta, session
# titling, keeper-gated brief delivery, and abort cleanup.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v node >/dev/null 2>&1 || { echo "skip - node not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip - python3 not installed"; exit 0; }
FAKE_API="$ROOT/tests/fixtures/fake-jcode-api.mjs"
TMP_ROOT=$(fm_test_tmproot fm-jcode-native-spawn)
SCRUB=(-u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u FM_OMP_HARNESS -u PI_CODING_AGENT
  -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GROK_AGENT -u GEMINI_CLI -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI
  -u JCODE_SESSION_ID -u JCODE_HOME -u FM_HOME -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_BACKEND)

XDG="$TMP_ROOT/run"
mkdir -p "$XDG" && chmod 700 "$XDG"
DSOCK="$XDG/jcode.sock"
DDIR="$TMP_ROOT/daemon"
HOOKCFG="$TMP_ROOT/jcode-config.toml"
"$ROOT/bin/fm-jcode-setup.sh" print | grep -v '^#' >"$HOOKCFG"
DPID=
HOMES=()
cleanup_all() {
  local h
  for h in "${HOMES[@]}"; do FM_HOME="$h" XDG_RUNTIME_DIR="$XDG" "$ROOT/bin/fm-jcode-keeper.sh" stop >/dev/null 2>&1; done
  [ -z "$DPID" ] || kill "$DPID" 2>/dev/null
}
trap cleanup_all EXIT
node "$FAKE_API" serve "$DSOCK" "$DDIR" >/dev/null 2>&1 &
DPID=$!
for _ in $(seq 1 100); do [ -S "$DSOCK" ] && break; sleep 0.05; done
[ -S "$DSOCK" ] || fail "fake daemon did not start"

make_case() {  # <name> <id> -> "dir|home|proj|wt|fakebin"
  local name=$1 id=$2 dir home proj wt fb
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/wt"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  fm_test_spawn_brief "$home" "$id" "Exercise native jcode dispatch."
  printf 'jcode\n' >"$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fb="$dir/fakebin"
  mkdir -p "$fb"
  ln -s "$ROOT/tests/fixtures/fake-jcode" "$fb/jcode"
  fm_fake_exit0 "$fb" gh-axi gh
  cat >"$fb/treehouse" <<SH
#!/usr/bin/env bash
case "\$1" in get) printf '%s\n' '$wt'; exit 0 ;; esac
exit 0
SH
  chmod +x "$fb/treehouse"
  HOMES+=("$home")
  printf '%s|%s|%s|%s|%s\n' "$dir" "$home" "$proj" "$wt" "$fb"
}

run_spawn() {  # <case> <id> [spawn args...]
  local dir home proj wt fb id=$2
  IFS='|' read -r dir home proj wt fb <<EOF
$1
EOF
  shift 2
  env "${SCRUB[@]}" HOME="$home" FM_HOME="$home" FM_ROOT_OVERRIDE='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 XDG_RUNTIME_DIR="$XDG" JCODE_SOCKET="$DSOCK" FM_JCODE_CONFIG="${SPAWN_HOOKCFG:-$HOOKCFG}" \
    FM_JCODE_KEEPER_SCAN_MS=100 FM_JCODE_KEEPER_BEAT_MS=500 FM_JCODE_READY_POLLS="${FM_JCODE_READY_POLLS:-60}" FM_JCODE_POLL_INTERVAL=0.1 \
    FM_JCODE_CHILD_ENV_PASS="FM_JCODE_KEEPER_SCAN_MS FM_JCODE_KEEPER_BEAT_MS FM_JCODE_KEEPER_ATTACH_DELAY_MS" \
    PATH="$fb:$(dirname "$(command -v node)"):/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" --mode no-mistakes --yolo off "$@" 2>&1
}

test_native_spawn() {
  local rec dir home proj wt fb id=nsp1 out rc meta sid
  rec=$(make_case ok "$id")
  IFS='|' read -r dir home proj wt fb <<EOF
$rec
EOF
  printf 'native\n' >"$home/config/jcode-runtime"
  out=$(run_spawn "$rec" "$id" --model m1 --effort low); rc=$?
  [ "$rc" -eq 0 ] || fail "a native spawn must succeed (rc=$rc): $out"
  meta="$home/state/$id.meta"
  assert_grep 'backend=jcode' "$meta" "config/jcode-runtime=native must select backend=jcode"
  assert_grep 'harness=jcode' "$meta" "harness"
  sid=$(sed -n 's/^jcode_session=//p' "$meta")
  [ -n "$sid" ] || fail "meta must carry jcode_session"
  assert_grep "window=jcode:$sid" "$meta" "the window is jcode:<session>"
  assert_grep "endpoint_task_id=$id" "$meta" "endpoint binding"
  assert_grep "jcode_socket=$DSOCK" "$meta" "the shared daemon socket is recorded"
  assert_grep 'jcode_api_socket=' "$meta" "this home's API socket is recorded"
  assert_no_grep 'jcode_home=' "$meta" "no private jcode home on the shared daemon"
  assert_no_grep 'jcode_runtime_dir=' "$meta" "no private runtime dir on the shared daemon"
  assert_grep "session=$sid" "$home/state/$id.jcode-session" "session record"
  assert_grep "\"title\":\"fm:$id\"" "$DDIR/state.json" "the session is titled fm:<task> for fleet visibility"
  grep -q '"req":"create_session".*' "$DDIR/requests.log" || fail "a session must be created"
  grep -q '"req":"set_model","session_id":"'"$sid"'","model":"m1"' "$DDIR/requests.log" || fail "the model must be set explicitly"
  grep -q '"args":\["off"\]' "$DDIR/requests.log" || fail "the keeper must apply memory off on attach"
  grep -q 'Exercise native jcode dispatch' "$DDIR/requests.log" || fail "the brief must be delivered"
  [ -f "$home/state/jcode/live/$sid" ] || fail "the keeper must hold the session"
  pass "native spawn: selection, meta, title, explicit model, keeper attach, brief delivery"
}

test_refusals() {
  local rec dir home proj wt fb id out rc
  id=nsp2
  rec=$(make_case nomodel "$id")
  IFS='|' read -r dir home proj wt fb <<EOF
$rec
EOF
  printf 'native\n' >"$home/config/jcode-runtime"
  out=$(run_spawn "$rec" "$id"); rc=$?
  [ "$rc" -ne 0 ] || fail "a native spawn without a model must refuse"
  assert_contains "$out" "explicit model" "the refusal names the model rule"
  [ ! -e "$home/state/$id.meta" ] || fail "no record may remain"

  id=nsp3
  rec=$(make_case otherharness "$id")
  IFS='|' read -r dir home proj wt fb <<EOF
$rec
EOF
  out=$(run_spawn "$rec" "$id" claude --backend jcode --model m1); rc=$?
  [ "$rc" -ne 0 ] || fail "a non-jcode harness on backend jcode must refuse"
  assert_contains "$out" "only the jcode harness" "the refusal names the harness rule"

  id=nsp4
  rec=$(make_case secondmate "$id")
  IFS='|' read -r dir home proj wt fb <<EOF
$rec
EOF
  out=$(run_spawn "$rec" "$id" --backend jcode --model m1 --secondmate 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "--secondmate on backend jcode must refuse"

  id=nsp5
  rec=$(make_case nohooks "$id")
  IFS='|' read -r dir home proj wt fb <<EOF
$rec
EOF
  printf 'native\n' >"$home/config/jcode-runtime"
  : >"$TMP_ROOT/empty.toml"
  out=$(SPAWN_HOOKCFG="$TMP_ROOT/empty.toml" run_spawn "$rec" "$id" --model m1); rc=$?
  [ "$rc" -ne 0 ] || fail "unregistered hooks must refuse the native spawn"
  assert_contains "$out" "hooks are not registered" "the refusal names the hook registration"

  id=nsp6
  rec=$(make_case pane "$id")
  IFS='|' read -r dir home proj wt fb <<EOF
$rec
EOF
  printf 'pane\n' >"$home/config/jcode-runtime"
  out=$(run_spawn "$rec" "$id" --model m1 2>&1); rc=$?
  assert_no_grep 'backend=jcode' "$home/state/$id.meta" "pane (default) must not select backend jcode" 2>/dev/null || true
  pass "native spawn refusals: model required, jcode harness only, no secondmate, hooks registered"
}

test_keeper_timeout_aborts() {
  local rec dir home proj wt fb id=nsp7 out rc
  rec=$(make_case timeout "$id")
  IFS='|' read -r dir home proj wt fb <<EOF
$rec
EOF
  # A keeper that never attaches: point the scan at a huge interval.
  out=$(FM_JCODE_KEEPER_ATTACH_DELAY_MS=600000 FM_JCODE_READY_POLLS=5 run_spawn "$rec" "$id" --backend jcode --model m1); rc=$?
  [ "$rc" -ne 0 ] || fail "a keeper that never attaches must fail the spawn"
  assert_contains "$out" "keeper never attached" "the failure names the keeper"
  grep -q '"req":"archive_session"' "$DDIR/requests.log" || fail "the failed spawn must archive its session"
  grep -q 'Exercise native jcode dispatch' <(tail -n 5 "$DDIR/requests.log") && fail "the brief must not be sent before the keeper holds the session"
  pass "a keeper attach timeout archives the session and sends no brief"
}

test_native_spawn
test_refusals
test_keeper_timeout_aborts

# ---- control: interrupt, exit, relaunch on a spawned native task -------------
control() {  # <case> <verb> <id> [args...]
  local dir home proj wt fb
  IFS='|' read -r dir home proj wt fb <<EOF
$1
EOF
  shift
  env "${SCRUB[@]}" HOME="$home" FM_HOME="$home" FM_ROOT_OVERRIDE='' \
    XDG_RUNTIME_DIR="$XDG" JCODE_SOCKET="$DSOCK" FM_JCODE_CONFIG="$HOOKCFG" \
    FM_JCODE_KEEPER_SCAN_MS=100 FM_JCODE_KEEPER_BEAT_MS=500 FM_CONTROL_EXIT_WAIT=10 FM_CONTROL_SETTLE_WAIT=3 \
    FM_JCODE_CHILD_ENV_PASS="FM_JCODE_KEEPER_SCAN_MS FM_JCODE_KEEPER_BEAT_MS" \
    PATH="$fb:$(dirname "$(command -v node)"):/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

test_control_native() {
  local rec dir home proj wt fb id=nsp8 out rc sid before
  rec=$(make_case ctl "$id")
  IFS='|' read -r dir home proj wt fb <<EOF
$rec
EOF
  out=$(run_spawn "$rec" "$id" --backend jcode --model m1); rc=$?
  [ "$rc" -eq 0 ] || fail "spawn for the control test failed: $out"
  sid=$(sed -n 's/^jcode_session=//p' "$home/state/$id.meta")
  printf '{"hold":true}' >"$DDIR/script.json"
  printf 'work' | node "$ROOT/bin/fm-jcode-api.mjs" --socket "$(sed -n 's/^jcode_api_socket=//p' "$home/state/$id.meta")" send "$sid"
  for _ in $(seq 1 50); do grep -q '^busy' "$home/state/jcode/live/$sid" && break; sleep 0.1; done
  out=$(control "$rec" "$id" interrupt); rc=$?
  [ "$rc" -eq 0 ] || fail "interrupt failed: $out"
  assert_contains "$out" "cancelled" "interrupt reports the cancel claim"
  rm -f "$DDIR/script.json"
  out=$(control "$rec" "$id" exit); rc=$?
  [ "$rc" -eq 0 ] || fail "exit failed: $out"
  assert_contains "$out" "stopped" "exit stops the worker"
  [ -e "$home/state/$id.jcode-exited" ] || fail "exit must record the exited marker"
  printf 'Progress: resumed after review.' >"$TMP_ROOT/note.txt"
  before=$(grep -c "Exercise native jcode dispatch" "$DDIR/requests.log")
  out=$(control "$rec" "$id" relaunch --note-file "$TMP_ROOT/note.txt"); rc=$?
  [ "$rc" -eq 0 ] || fail "relaunch failed: $out"
  [ ! -e "$home/state/$id.jcode-exited" ] || fail "relaunch clears the exited marker"
  [ "$(grep -c "Exercise native jcode dispatch" "$DDIR/requests.log")" -gt "$before" ] || fail "relaunch re-prompts the same session with the brief"
  grep -q "$sid" "$home/state/$id.jcode-session" || fail "relaunch keeps the same session"
  out=$(control "$rec" "$id" relaunch --harness claude --note "x"); rc=$?
  [ "$rc" -ne 0 ] || fail "a cross-harness relaunch must refuse on the native backend"
  pass "control on a native task: interrupt cancels, exit records the marker, relaunch re-prompts in place"
}

test_control_native

#!/usr/bin/env bash
# tests/fm-jcode-harness.test.sh - the portable regression for the jcode
# primary integration: detection, session-lock identity under a shared daemon,
# the swarm delegation fence, the pre_tool and turn_end hook dispatcher, the
# supervision protocol rendering, and the hook registration helper.
#
# jcode's identity checks are HARNESS-DEPENDENT (a process name and two records
# the daemon writes). This suite pins the LOGIC with real processes named
# `jcode` (symlinks to the system shell), a fake JCODE_HOME, and a fake `jcode`
# binary for the harness API, so CI enforces it with no jcode installed.
# docs/verification/supervision.md "jcode primary hooks" records the live
# evidence against a real, isolated jcode daemon; no automated live guard yet.
#
# The load-bearing contracts:
#   1. Detection is the anchored process name `jcode`; jcodex and xjcode never
#      identify, and JCODE_SESSION_ID alone is not a marker.
#   2. A `jcode serve` daemon pid is never a lock anchor and never proves
#      ownership by ancestry, because every session it hosts shares it.
#   3. JCODE_SESSION_ID is trusted only when active_pids/<id> names the jcode
#      ancestor; the anchor is that session's newest live TUI client from
#      client_sessions, and a stale client record is ignored.
#   4. Two sessions under one daemon cannot both own one home's lock.
#   5. The swarm tool passes for read-only actions and is denied otherwise;
#      agentgrep is not delegation.
#   6. The dispatcher acts only for its own primary home, runs the seatbelts on
#      pre_tool (including batch), and bounds turn_end to one reminder.
# shellcheck disable=SC2016 # single quotes are deliberate: library expressions expand inside the fixture daemon's tool shell
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
LIB="$ROOT/bin/fm-session-lock-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-jcode-harness)
fm_git_identity fmtest fmtest@example.invalid
SCRUB=(-u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u FM_OMP_HARNESS -u PI_CODING_AGENT
  -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GROK_AGENT -u GEMINI_CLI -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI
  -u JCODE_SESSION_ID -u JCODE_HOME -u FM_HOME -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE)

# Symlinks to the system shell whose process names are the given words.
NAMED="$TMP_ROOT/named"
mkdir -p "$NAMED"
for name in jcode jcodex xjcode; do
  ln -sf /bin/bash "$NAMED/$name"
done

# Run a command ORPHANED, so its process tree is reparented to init (or the
# session's subreaper, such as `systemd --user`) before the command runs: the
# harness ancestry walk then stops inside the fixture and cannot climb into
# whatever harness (often jcode itself) runs this suite.
# Prints the command's stdout and returns its status.
orphaned() {  # <command> [args...]
  local out="$TMP_ROOT/orphan.$$.$RANDOM" rc
  rm -f "$out.rc" "$out.out"
  # shellcheck disable=SC2016 # the inner body expands in the intermediate shell
  bash -c 'launcher=$$; (
      i=0
      while [ "$(ps -o ppid= -p "$BASHPID" 2>/dev/null | tr -d " ")" = "$launcher" ] && [ "$i" -lt 200 ]; do sleep 0.02; i=$((i + 1)); done
      "$@" > "$0.out"; printf "%s\n" "$?" > "$0.rc.tmp"; mv "$0.rc.tmp" "$0.rc"
    ) & exit 0' "$out" "$@"
  for _ in $(seq 1 600); do
    [ -f "$out.rc" ] && break
    sleep 0.05
  done
  [ -f "$out.rc" ] || { echo "orphaned: command did not finish" >&2; return 99; }
  cat "$out.out"
  rc=$(cat "$out.rc")
  rm -f "$out.rc" "$out.out"
  return "$rc"
}

# --- 1. Detection --------------------------------------------------------------

test_detection_is_anchored_and_markerless() {
  local out
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(orphaned env "${SCRUB[@]}" "$NAMED/jcode" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = jcode ] || fail "a process named jcode must detect as jcode, got '$out'"
  for decoy in jcodex xjcode; do
    # shellcheck disable=SC2016 # the quoted body expands inside the named shell
    out=$(orphaned env "${SCRUB[@]}" "$NAMED/$decoy" -c '"$1"; :' _ "$HARNESS")
    [ "$out" != jcode ] || fail "'$decoy' merely contains jcode and must not detect as jcode"
  done
  # shellcheck disable=SC2016 # the quoted body expands inside the plain shell
  out=$(orphaned env "${SCRUB[@]}" JCODE_SESSION_ID=session_x bash -c '"$1"; :' _ "$HARNESS")
  [ "$out" != jcode ] || fail "JCODE_SESSION_ID without a jcode ancestor must not identify jcode"
  out=$(env "${SCRUB[@]}" FM_SUPERVISION_ACTOR=branch FM_SUPERVISION_PRIMARY_HARNESS=jcode "$HARNESS")
  [ "$out" = jcode ] || fail "the supervision-branch pin must accept jcode, got '$out'"
  pass "fm-harness: jcode detects by its anchored process name only"
}

# --- 2-4. Session lock identity under a shared daemon ------------------------

# Start a fake daemon (`jcode serve`) whose child is a shell running the probe,
# plus a fake TUI client (`jcode`) recorded in client_sessions. The probe walks
# its ancestry exactly as a jcode tool subprocess does: shell -> daemon.
make_jcode_home() {  # <dir>
  mkdir -p "$1/active_pids" "$1/client_sessions" "$1/state"
}

# Run one library expression inside a tool-shaped process under a fake daemon.
# Each call starts a fresh daemon, so the daemon-owned sessions listed in
# FM_TEST_OWNED (space-separated) get their active_pids record rewritten to
# that daemon's pid first, exactly as a live daemon keeps them. Prints the
# expression's stdout; returns its status.
daemon_eval() {  # <jcode-home> <session-id> <expression>
  local home=$1 sid=$2 expr=$3
  # shellcheck disable=SC2016 # the quoted bodies expand inside the fake daemon and its tool shell
  orphaned env "${SCRUB[@]}" JCODE_HOME="$home" ${sid:+JCODE_SESSION_ID="$sid"} FM_TEST_EXPR="$expr" FM_TEST_LIB="$LIB" \
    FM_TEST_OWNED="${FM_TEST_OWNED:-}" \
    "$NAMED/jcode" -c 'for s in $FM_TEST_OWNED; do printf "%s\n" "$$" > "$JCODE_HOME/active_pids/$s"; done; bash -c ". \"\$FM_TEST_LIB\"; eval \"\$FM_TEST_EXPR\""; rc=$?; exit $rc' serve
}

# Start a long-lived fake TUI client and print its pid.
start_client() {  # <jcode-home> <session-id>
  local pid
  "$NAMED/jcode" -c 'sleep 60; :' >/dev/null 2>&1 &
  pid=$!
  printf '%s\n' "$2" > "$1/client_sessions/$pid"
  printf '%s\n' "$pid"
}

test_daemon_is_never_an_anchor_or_owner() {
  local home out rc=0
  home="$TMP_ROOT/no-client"
  make_jcode_home "$home"
  export FM_TEST_OWNED=session_a
  out=$(daemon_eval "$home" session_a 'fm_session_lock_anchor_pid') || rc=$?
  [ "$rc" -ne 0 ] || fail "a daemon-hosted session with no live client must have no lock anchor, got '$out'"
  out=$(daemon_eval "$home" session_a 'fm_session_lock_anchor_failure_reason')
  assert_contains "$out" "jcode session identity unproven" "anchor failure must name the jcode reason"
  out=$(daemon_eval "$home" '' 'fm_session_lock_anchor_failure_reason')
  assert_contains "$out" "JCODE_SESSION_ID is not set" "anchor failure must name the missing session id"
  # A lock recorded against the daemon pid is not owned merely by ancestry.
  rc=0
  daemon_eval "$home" '' 'printf "%s\n" "$PPID" > "$JCODE_HOME/state/.lock"; fm_session_lock_owned_by_self "$JCODE_HOME/state"' || rc=$?
  [ "$rc" -ne 0 ] || fail "a lock naming the shared daemon pid must not be owned by daemon ancestry alone"
  unset FM_TEST_OWNED
  pass "session lock: the shared jcode daemon never anchors or proves a lock"
}

test_trusted_id_anchor_and_two_sessions() {
  local home client_a client_b stale out rc
  home="$TMP_ROOT/two-sessions"
  make_jcode_home "$home"
  client_a=$(start_client "$home" session_a)
  client_b=$(start_client "$home" session_b)
  # A stale record for session_a whose pid is not a live jcode process.
  stale=999999
  printf '%s\n' session_a > "$home/client_sessions/$stale"
  export FM_TEST_OWNED='session_a session_b'

  out=$(daemon_eval "$home" session_a 'fm_session_lock_trusted_session_id')
  [ "$out" = session_a ] || fail "an id owned by the jcode ancestor must be trusted, got '$out'"
  out=$(daemon_eval "$home" session_a 'fm_session_lock_anchor_pid')
  [ "$out" = "$client_a" ] || fail "session_a must anchor on its live client $client_a, got '$out'"
  out=$(daemon_eval "$home" session_b 'fm_session_lock_anchor_pid')
  [ "$out" = "$client_b" ] || fail "session_b must anchor on its live client $client_b, got '$out'"

  # session_a records the lock; session_b sees a foreign live owner and does not own it.
  printf '%s\n' "$client_a" > "$home/state/.lock"
  printf '%s\n' session_a > "$home/state/.lock-session"
  rc=0
  daemon_eval "$home" session_a 'fm_session_lock_owned_by_self "$JCODE_HOME/state"' || rc=$?
  [ "$rc" -eq 0 ] || fail "the recording session must own its lock"
  rc=0
  daemon_eval "$home" session_b 'fm_session_lock_owned_by_self "$JCODE_HOME/state"' || rc=$?
  [ "$rc" -ne 0 ] || fail "a second session under the same daemon must not own the first session's lock"
  out=$(daemon_eval "$home" session_b 'fm_session_lock_foreign_owner_live "$JCODE_HOME/state" && printf "%s\n" "$FM_SESSION_LOCK_FOREIGN_OWNER_PID"')
  [ "$out" = "$client_a" ] || fail "session_b must see session_a's client as the foreign live owner, got '$out'"

  # An id the daemon does not own (record names another pid) is not trusted.
  printf '%s\n' 1 > "$home/active_pids/session_c"
  rc=0
  out=$(daemon_eval "$home" session_c 'fm_session_lock_trusted_session_id') || rc=$?
  [ "$rc" -ne 0 ] || fail "an id whose active_pids record names another process must not be trusted, got '$out'"
  rc=0
  out=$(daemon_eval "$home" 'bad id;x' 'fm_session_lock_trusted_session_id') || rc=$?
  [ "$rc" -ne 0 ] || fail "a malformed session id must not be trusted"

  kill "$client_a" "$client_b" 2>/dev/null
  wait "$client_a" "$client_b" 2>/dev/null
  rc=0
  out=$(daemon_eval "$home" session_a 'fm_session_lock_anchor_pid') || rc=$?
  [ "$rc" -ne 0 ] || fail "with its client gone the session must have no anchor, got '$out'"
  unset FM_TEST_OWNED
  pass "session lock: jcode ids are trusted through active_pids and anchored on live clients; two sessions never share ownership"
}

# --- 5. Delegation fence -------------------------------------------------------

test_swarm_fence() {
  local primary rc
  primary="$TMP_ROOT/fence-primary"
  mkdir -p "$primary/bin" "$primary/state"
  printf '# fixture\n' > "$primary/AGENTS.md"
  git -C "$primary" init -q
  run_fence() {
    env FM_ROOT_OVERRIDE="$primary" FM_HOME="$primary" FM_STATE_OVERRIDE="$primary/state" \
      "$ROOT/bin/fm-subagent-pretool-check.sh" --claude "$@" >/dev/null 2>&1
  }
  for action in status list summary read_context plan_status list_swarms STATUS; do
    run_fence --tool swarm --action "$action" || fail "swarm action $action must be allowed"
  done
  for action in spawn assign_task run_plan fill_slots task_graph dm broadcast stop ''; do
    rc=0
    run_fence --tool swarm --action "$action" || rc=$?
    [ "$rc" -eq 2 ] || fail "swarm action '${action:-<none>}' must be denied, got $rc"
  done
  rc=0
  printf '%s' '{"tool_name":"swarm","tool_input":{"action":"spawn"}}' | env FM_ROOT_OVERRIDE="$primary" FM_HOME="$primary" \
    FM_STATE_OVERRIDE="$primary/state" "$ROOT/bin/fm-subagent-pretool-check.sh" --claude >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "stdin swarm spawn must be denied, got $rc"
  run_fence --tool agentgrep || fail "agentgrep is read-only search and must be allowed"
  pass "subagent guard: swarm is fenced by action; agentgrep is not delegation"
}

# --- 6. Hook dispatcher --------------------------------------------------------

# A plain, primary-shaped clone of this repository's bin/ and AGENTS.md, so the
# dispatcher's own-home scoping resolves to it.
make_primary_copy() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  cp -R "$ROOT/bin" "$dir/bin"
  cp -R "$ROOT/docs" "$dir/docs"
  cp "$ROOT/AGENTS.md" "$dir/AGENTS.md"
  mkdir -p "$dir/state"
}

hook_pre_tool() {  # <primary> <cwd> <tool> <input>
  printf '%s' "$4" | env "${SCRUB[@]}" JCODE_HOOK_EVENT=pre_tool JCODE_HOOK_TOOL_NAME="$3" \
    JCODE_HOOK_CWD="$2" JCODE_HOOK_SESSION_ID=session_t "$1/bin/fm-jcode-hook.sh" 2>"$TMP_ROOT/hook.err" >/dev/null
}

test_dispatcher_pre_tool() {
  local primary other rc
  command -v node >/dev/null 2>&1 || { pass "dispatcher pre_tool: skipped (node unavailable)"; return; }
  primary="$TMP_ROOT/dispatch-primary"
  make_primary_copy "$primary"
  other="$TMP_ROOT/unrelated"
  mkdir -p "$other"
  git -C "$other" init -q

  hook_pre_tool "$primary" "$primary" bash '{"command":"ls"}' || fail "an ordinary bash call must be allowed"
  hook_pre_tool "$primary" "$primary" swarm '{"action":"status"}' || fail "swarm status must be allowed"
  hook_pre_tool "$primary" "$primary" read '{"file_path":"x"}' || fail "read must be allowed"
  for case in 'bash|{"command":"bin/fm-watch.sh"}|watcher-direct' \
              'bash|{"command":"bin/fm-watch-arm.sh &"}|watcher-background' \
              'swarm|{"action":"spawn","prompt":"x"}|subagent-dispatch' \
              'batch|{"tool_calls":[{"tool":"read","file_path":"a"},{"tool":"swarm","action":"spawn"}]}|subagent-dispatch'; do
    IFS='|' read -r tool input code <<EOF
$case
EOF
    rc=0
    hook_pre_tool "$primary" "$primary" "$tool" "$input" || rc=$?
    [ "$rc" -eq 2 ] || fail "$tool $input must be blocked with exit 2, got $rc"
    assert_contains "$(cat "$TMP_ROOT/hook.err")" "[$code]" "$tool deny must carry the [$code] reason as plain text"
    assert_not_contains "$(cat "$TMP_ROOT/hook.err")" "hookSpecificOutput" "$tool deny must not leak the Claude JSON envelope"
  done
  hook_pre_tool "$primary" "$other" swarm '{"action":"spawn"}' || fail "a session outside this home must be ignored"
  hook_pre_tool "$primary" "$primary/state" swarm '{"action":"spawn"}' && fail "a cwd below the home must still resolve to it"
  hook_pre_tool "$primary" "$primary" bash 'not json' || fail "malformed tool input must fail open"
  printf '%s' '{}' | env "${SCRUB[@]}" JCODE_HOOK_EVENT=post_tool JCODE_HOOK_CWD="$primary" "$primary/bin/fm-jcode-hook.sh" \
    || fail "an unhandled event must be a no-op"
  pass "dispatcher pre_tool: seatbelts gate bash, swarm, and batch in this home only"
}

# A fake jcode whose `api-bridge --stdio` records the reminder and acknowledges it.
make_fake_jcode_api() {  # <dir> <log>
  cat > "$1/jcode" <<SH
#!/usr/bin/env node
const fs = require("fs");
let buf = "";
process.stdin.on("data", (d) => {
  buf += d;
  let i;
  while ((i = buf.indexOf("\\n")) >= 0) {
    const f = JSON.parse(buf.slice(0, i)); buf = buf.slice(i + 1);
    const out = (o) => process.stdout.write(JSON.stringify(o) + "\\n");
    if (f.req === "hello") out({ v: 1, reply_to: f.id, ev: "hello_ok", version: 1, capabilities: [] });
    else if (f.req === "attach_session") out({ v: 1, reply_to: f.id, ev: "attached", session: { session_id: f.session_id } });
    else if (f.req === "send_message") { fs.appendFileSync("$2", JSON.stringify({ session: f.session_id, reminder: f.system_reminder }) + "\\n"); out({ v: 1, reply_to: f.id, ev: "ok" }); }
  }
});
SH
  chmod +x "$1/jcode"
}

test_dispatcher_turn_end_is_bounded() {
  local primary fake log count
  command -v node >/dev/null 2>&1 || { pass "dispatcher turn_end: skipped (node unavailable)"; return; }
  command -v jq >/dev/null 2>&1 || { pass "dispatcher turn_end: skipped (jq unavailable for the shared guard)"; return; }
  primary="$TMP_ROOT/turnend-primary"
  make_primary_copy "$primary"
  fm_write_meta "$primary/state/fakejob.meta" window=fake:1 harness=claude kind=ship
  fake=$(fm_fakebin "$TMP_ROOT/fake-jcode")
  log="$TMP_ROOT/reminders.log"
  : > "$log"
  make_fake_jcode_api "$fake" "$log"
  run_turn_end() {
    env "${SCRUB[@]}" PATH="$fake:$PATH" JCODE_HOOK_EVENT=turn_end JCODE_HOOK_CWD="$primary" \
      JCODE_HOOK_SESSION_ID=session_t "$primary/bin/fm-jcode-hook.sh" </dev/null
  }
  run_turn_end || fail "turn_end must always exit 0"
  count=$(wc -l < "$log" | tr -d ' ')
  [ "$count" -eq 1 ] || fail "an unsupervised turn end must send exactly one reminder, sent $count"
  assert_contains "$(cat "$log")" "TURN WOULD END BLIND" "the reminder must carry the guard banner"
  assert_contains "$(cat "$log")" '"session":"session_t"' "the reminder must target the hook's own session"
  [ -f "$primary/state/.jcode-turnend-followup" ] || fail "the latch must record the nudged session"
  run_turn_end
  count=$(wc -l < "$log" | tr -d ' ')
  [ "$count" -eq 1 ] || fail "the follow-up turn's own turn_end must not send another reminder, total $count"
  [ ! -e "$primary/state/.jcode-turnend-followup" ] || fail "the latch must clear after the follow-up turn"
  run_turn_end
  count=$(wc -l < "$log" | tr -d ' ')
  [ "$count" -eq 2 ] || fail "a later unsupervised turn must be nudged again, total $count"
  rm -f "$primary/state/fakejob.meta" "$primary/state/.jcode-turnend-followup"
  run_turn_end
  count=$(wc -l < "$log" | tr -d ' ')
  [ "$count" -eq 2 ] || fail "with nothing needing supervision no reminder may be sent, total $count"
  pass "dispatcher turn_end: one reminder per unsupervised turn, never a loop"
}

# --- rendering and registration -------------------------------------------------

test_supervision_protocol_renders() {
  local out
  out=$("$ROOT/bin/fm-supervision-instructions.sh" --harness jcode)
  assert_contains "$out" "primary harness: jcode" "jcode must render its own block"
  assert_contains "$out" "Mode: jcode background-wake supervision." "jcode must render its protocol"
  assert_contains "$out" "run_in_background: true" "the protocol must name the tracked background arm"
  assert_not_contains "$out" "__FM_" "no placeholder may leak"
  out=$("$ROOT/bin/fm-supervision-instructions.sh" --harness jcode --repair-line)
  assert_contains "$out" "run_in_background and wake" "the repair line must name the jcode arm shape"
  pass "supervision instructions: jcode renders its protocol and repair line"
}

test_setup_helper() {
  local cfg out
  if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import tomllib' 2>/dev/null; then
    pass "setup helper: skipped (python3 tomllib unavailable)"
    return
  fi
  cfg="$TMP_ROOT/jcode-config/config.toml"
  mkdir -p "${cfg%/*}"
  printf '[hooks]\npre_tool = "/opt/other-policy"\n\n[ambient]\nenabled = false\n' > "$cfg"
  FM_JCODE_CONFIG="$cfg" "$ROOT/bin/fm-jcode-setup.sh" status >/dev/null && fail "status must report an unregistered home"
  FM_JCODE_CONFIG="$cfg" "$ROOT/bin/fm-jcode-setup.sh" install >/dev/null || fail "install must succeed"
  FM_JCODE_CONFIG="$cfg" "$ROOT/bin/fm-jcode-setup.sh" status >/dev/null || fail "status must report a registered home after install"
  out=$(python3 -c 'import sys,tomllib; d=tomllib.load(open(sys.argv[1],"rb")); print(d["hooks"]["pre_tool"]); print(d["hooks"]["turn_end"]); print(d["ambient"]["enabled"])' "$cfg")
  assert_contains "$out" "/opt/other-policy" "install must keep another tool's hook"
  assert_contains "$out" "fm-jcode-hook.sh" "install must register this home's dispatcher"
  assert_contains "$out" "False" "install must leave unrelated tables alone"
  ls "${cfg%/*}"/config.toml.pre-firstmate-* >/dev/null 2>&1 || fail "install must leave a backup"
  printf 'broken = [\n' > "$cfg"
  FM_JCODE_CONFIG="$cfg" "$ROOT/bin/fm-jcode-setup.sh" install >/dev/null 2>&1 && fail "install must refuse a config that does not parse"
  assert_equals "$(cat "$cfg")" "broken = [" "a refused install must not change the file"
  pass "setup helper: registers alongside other hooks, backs up, and refuses broken configs"
}

test_detection_is_anchored_and_markerless
test_daemon_is_never_an_anchor_or_owner
test_trusted_id_anchor_and_two_sessions
test_swarm_fence
test_dispatcher_pre_tool
test_dispatcher_turn_end_is_bounded
test_supervision_protocol_renders
test_setup_helper

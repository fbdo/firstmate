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

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

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

# --- 7. Crewmate and scout workers ---------------------------------------------
#
# A jcode worker is a daemon session the pane only views. These cases pin the
# worker contracts with a fake `jcode` (a bash script, so a live holder process
# really is named jcode) and a fake harness API daemon (node), driving the real
# bin/fm-jcode-api.mjs, bin/fm-jcode-hook.sh, bin/fm-spawn.sh, and
# bin/fm-control.sh:
#   7. A created session is persisted by a no-reply note; a refused model
#      archives it; a cancel repeats until the turn reports done.
#   8. The attached client is proven by its client_sessions record, a live
#      jcode process, and a command line resuming that exact session.
#   9. turn_start and turn_end move a bound worker's busy record only for its
#      own session, in its own worktree, under its own busy generation.
#  10. The spawn creates and binds the session before launch and sends the
#      brief only once the pane's client is attached.
#  11. Interrupt cancels through the API; exit cancels, then signals the
#      proven client, and refuses an unattributed one.

JC_HOLDERS="$TMP_ROOT/jcode-holders"
: > "$JC_HOLDERS"
jc_cleanup() {
  local pid
  while read -r pid; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done < "$JC_HOLDERS"
  return 0
}
trap 'jc_cleanup; fm_test_cleanup' EXIT

# make_fake_jcode <dir>: a fakebin holding the fake jcode CLI and API daemon.
# Its state lives in <dir>: api.log (one JSON line per request), sessions/
# (working dir per session), running/ (sessions with a turn in flight).
make_fake_jcode() {  # <dir> -> fakebin
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  mkdir -p "$dir/sessions" "$dir/running"
  : > "$dir/api.log"
  cat > "$fb/jcode" <<SH
#!/bin/bash
D=$dir
case " \$* " in
  *" api-bridge "*) exec node "\$D/api.js" ;;
  *" model list "*)
    printf '{"provider":"Fake","selected_model":"fake/good","models":["fake/good","fake/other"]}\n'
    exit 0
    ;;
  *" --hold "*) trap 'exit 0' TERM; while :; do sleep 0.1; done ;;
esac
if [ "\${1:-}" = --resume ]; then
  [ -z "\${FAKE_JCODE_NO_CLIENT:-}" ] || exit 0
  "\$0" --hold --resume "\$2" >/dev/null 2>&1 </dev/null &
  mkdir -p "\${JCODE_HOME:?}/client_sessions"
  printf '%s\n' "\$2" > "\$JCODE_HOME/client_sessions/\$!"
  printf '%s\n' "\$!" >> "$JC_HOLDERS"
fi
exit 0
SH
  chmod +x "$fb/jcode"
  cat > "$dir/api.js" <<'JS'
const fs = require("fs");
const { spawnSync } = require("child_process");
const D = __dirname;
const log = (o) => fs.appendFileSync(D + "/api.log", JSON.stringify(o) + "\n");
const out = (o) => process.stdout.write(JSON.stringify({ v: 1, ...o }) + "\n");
const running = (id) => fs.existsSync(D + "/running/" + id);
const clientAttached = (id) => {
  const dir = (process.env.JCODE_HOME || "") + "/client_sessions";
  try {
    for (const f of fs.readdirSync(dir)) {
      if (fs.readFileSync(dir + "/" + f, "utf8").trim() !== id) continue;
      try { process.kill(Number(f), 0); return true; } catch {}
    }
  } catch {}
  return false;
};
const hook = (event, id) => {
  if (process.env.FAKE_JCODE_NO_HOOKS) return;
  const cwd = fs.readFileSync(D + "/sessions/" + id, "utf8").trim();
  spawnSync(process.env.FAKE_JCODE_HOOK, [], {
    env: { ...process.env, JCODE_HOOK_EVENT: event, JCODE_HOOK_SESSION_ID: id, JCODE_HOOK_CWD: cwd },
    stdio: "ignore",
  });
};
const endTurn = (id) => {
  fs.rmSync(D + "/running/" + id, { force: true });
  out({ ev: "turn_done", session_id: id });
  hook("turn_end", id);
};
let buf = "";
process.stdin.on("data", (d) => {
  buf += d;
  let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const f = JSON.parse(buf.slice(0, i));
    buf = buf.slice(i + 1);
    const id = f.session_id;
    switch (f.req) {
      case "hello": out({ reply_to: f.id, ev: "hello_ok", version: 1 }); break;
      case "create_session": {
        const n = fs.readdirSync(D + "/sessions").length + 1;
        const sid = "session_fake_" + n;
        fs.writeFileSync(D + "/sessions/" + sid, f.working_dir + "\n");
        log({ req: f.req, session: sid, working_dir: f.working_dir });
        out({ reply_to: f.id, ev: "attached", session: { session_id: sid, working_dir: f.working_dir, status: "idle" } });
        break;
      }
      case "set_model":
        log({ req: f.req, session: id, model: f.model });
        if (f.model === "fake/refused") out({ reply_to: f.id, ev: "error", code: "invalid_request", message: "unsupported model" });
        else out({ reply_to: f.id, ev: "ok" });
        break;
      case "set_reasoning_effort":
        log({ req: f.req, session: id, effort: f.effort });
        out({ reply_to: f.id, ev: "ok" });
        break;
      case "archive_session":
        log({ req: f.req, session: id });
        out({ reply_to: f.id, ev: "ok" });
        break;
      case "list_sessions":
        out({ reply_to: f.id, ev: "sessions", sessions: fs.readdirSync(D + "/sessions").map((s) => ({ session_id: s, status: "idle" })) });
        break;
      case "attach_session":
        out({ ev: "session_status", session_id: id, status: "attached" });
        out({ reply_to: f.id, ev: "attached", session: { session_id: id } });
        out({ ev: "session_status", session_id: id, status: running(id) ? "running" : "idle" });
        break;
      case "send_message":
        log({ req: f.req, session: id, no_reply: !!f.no_reply, content: f.content, client_attached: clientAttached(id) });
        if (f.no_reply) { out({ reply_to: f.id, ev: "ok" }); break; }
        out({ ev: "message_accepted", session_id: id });
        fs.writeFileSync(D + "/running/" + id, "0");
        hook("turn_start", id);
        if (!process.env.FAKE_JCODE_HOLD_TURN) endTurn(id);
        break;
      case "cancel": {
        log({ req: f.req, session: id });
        out({ reply_to: f.id, ev: "ok" });
        if (!running(id)) break;
        const count = Number(fs.readFileSync(D + "/running/" + id, "utf8")) + 1;
        fs.writeFileSync(D + "/running/" + id, String(count));
        if (count >= Number(process.env.FAKE_JCODE_CANCELS_NEEDED || 1)) endTurn(id);
        break;
      }
      default: out({ reply_to: f.id, ev: "error", code: "unknown_request", message: f.req });
    }
  }
});
JS
  printf '%s\n' "$fb"
}

jc_requests() {  # <dir> <req> -> count
  grep -c "\"req\":\"$2\"" "$1/api.log" || true
}

test_api_client_creates_persists_and_cancels() {
  local dir fb out rc sid
  command -v node >/dev/null 2>&1 || { pass "api client: skipped (node unavailable)"; return; }
  dir="$TMP_ROOT/api-client"
  fb=$(make_fake_jcode "$dir")
  mkdir -p "$dir/wt" "$dir/jhome"
  api() { env PATH="$fb:$PATH" JCODE_HOME="$dir/jhome" FAKE_JCODE_NO_HOOKS=1 node "$ROOT/bin/fm-jcode-api.mjs" "$@"; }

  sid=$(api create "$dir/wt" --model fake/good --effort low --note 'marker note') || fail "create must succeed"
  [ "$sid" = session_fake_1 ] || fail "create must print the new session id, got '$sid'"
  assert_contains "$(cat "$dir/api.log")" '"req":"set_model","session":"session_fake_1","model":"fake/good"' "create must apply the model"
  assert_contains "$(cat "$dir/api.log")" '"req":"set_reasoning_effort","session":"session_fake_1","effort":"low"' "create must apply the effort"
  assert_contains "$(cat "$dir/api.log")" '"no_reply":true,"content":"marker note"' "create must persist the session with a no-reply note"

  rc=0
  api create "$dir/wt" --model fake/refused >/dev/null 2>"$dir/err" || rc=$?
  [ "$rc" -eq 1 ] || fail "a refused model must exit 1, got $rc"
  assert_contains "$(cat "$dir/api.log")" '"req":"archive_session","session":"session_fake_2"' "a refused model must archive the new session"
  [ "$(jc_requests "$dir" send_message)" -eq 1 ] || fail "a refused model must not persist its session"

  out=$(api cancel session_fake_1) || fail "cancel on an idle session must succeed"
  [ "$out" = not-running ] || fail "an idle cancel must report not-running, got '$out'"
  [ "$(jc_requests "$dir" cancel)" -eq 0 ] || fail "an idle session must not be sent a cancel"

  printf 'start' | FAKE_JCODE_HOLD_TURN=1 api send session_fake_1 || fail "send must succeed"
  out=$(FAKE_JCODE_CANCELS_NEEDED=3 api cancel session_fake_1) || fail "a repeated cancel must succeed: $out"
  [ "$out" = cancelled ] || fail "a cancel that ends the turn must report cancelled, got '$out'"
  [ "$(jc_requests "$dir" cancel)" -eq 3 ] || fail "the cancel must repeat until turn_done, sent $(jc_requests "$dir" cancel)"

  printf 'start' | FAKE_JCODE_HOLD_TURN=1 api send session_fake_1 || fail "send must succeed"
  rc=0
  out=$(FAKE_JCODE_CANCELS_NEEDED=1000 FM_JCODE_CANCEL_WAIT_MS=700 api cancel session_fake_1) || rc=$?
  [ "$rc" -eq 1 ] && [ "$out" = unconfirmed ] || fail "a turn that never ends must report unconfirmed with exit 1, got '$out' rc=$rc"
  rm -f "$dir/running/session_fake_1"
  pass "api client: create persists and pins, a refused model archives, cancel repeats until the turn is done"
}

test_client_pid_needs_all_three_proofs() {
  local dir fb home pid other
  dir="$TMP_ROOT/client-proof"
  fb=$(make_fake_jcode "$dir")
  home="$dir/jhome"
  # shellcheck source=bin/fm-jcode-lib.sh
  . "$ROOT/bin/fm-jcode-lib.sh"
  ! fm_jcode_client_pid session_a "$home" >/dev/null || fail "no record must mean no client"
  JCODE_HOME="$home" "$fb/jcode" --resume session_a
  pid=$(tail -n 1 "$JC_HOLDERS")
  [ "$(fm_jcode_client_pid session_a "$home")" = "$pid" ] || fail "a live jcode resuming the session must be its client"
  ! fm_jcode_client_pid session_b "$home" >/dev/null || fail "a client of another session must not count"
  # A record naming session_b on a live jcode that resumes session_a.
  printf 'session_b\n' > "$home/client_sessions/$pid"
  ! fm_jcode_client_pid session_b "$home" >/dev/null || fail "a command line resuming another session must not count"
  printf 'session_a\n' > "$home/client_sessions/$pid"
  # A record whose pid is a live process that is not jcode.
  sleep 30 &
  other=$!
  printf '%s\n' "$other" >> "$JC_HOLDERS"
  printf 'session_c\n' > "$home/client_sessions/$other"
  ! fm_jcode_client_pid session_c "$home" >/dev/null || fail "a live non-jcode process must not count"
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  ! fm_jcode_client_pid session_a "$home" >/dev/null || fail "a record that outlived its client must not count"
  pass "client proof: the record, a live jcode process, and its resume command line must all agree"
}

test_dispatcher_records_worker_busy() {
  local primary wt other gen rec
  primary="$TMP_ROOT/worker-primary"
  make_primary_copy "$primary"
  wt="$TMP_ROOT/worker-wt"
  other="$TMP_ROOT/worker-other"
  mkdir -p "$wt" "$other"
  git -C "$wt" init -q
  git -C "$other" init -q
  gen=$("$primary/bin/fm-busy-event.sh" arm "$primary/state" w1) || fail "could not arm the busy contract"
  # shellcheck source=bin/fm-jcode-lib.sh
  . "$ROOT/bin/fm-jcode-lib.sh"
  fm_jcode_write_session_record "$primary/state" w1 session_w "$gen" "$wt" || fail "could not bind the session"
  hook() {  # <event> <session> <cwd>
    env "${SCRUB[@]}" JCODE_HOOK_EVENT="$1" JCODE_HOOK_SESSION_ID="$2" JCODE_HOOK_CWD="$3" \
      "$primary/bin/fm-jcode-hook.sh" </dev/null
  }
  rec() { fm_busy_record_read "$primary/state" w1 2>/dev/null || true; }
  # shellcheck source=bin/fm-busy-lib.sh
  . "$ROOT/bin/fm-busy-lib.sh"
  hook turn_end session_x "$wt" || fail "hooks always exit 0"
  hook turn_end session_w "$other" || fail "hooks always exit 0"
  case "$(rec)" in "busy fm-spawn "*) ;; *) fail "an unbound session or a foreign cwd must not move the record, got '$(rec)'" ;; esac
  hook turn_end session_w "$wt/." || fail "hooks always exit 0"
  case "$(rec)" in "idle jcode-hook turn-end "*) ;; *) fail "turn_end must close the bound worker's record, got '$(rec)'" ;; esac
  [ -f "$primary/state/w1.turn-ended" ] || fail "turn_end must touch the worker's turn-ended notification"
  hook turn_start session_w "$wt" || fail "hooks always exit 0"
  case "$(rec)" in "busy jcode-hook turn-start "*) ;; *) fail "turn_start must open the bound worker's record, got '$(rec)'" ;; esac
  # A relaunch re-arms a fresh generation; the retired session's record still
  # names the old one, so its late events are refused.
  "$primary/bin/fm-busy-event.sh" arm "$primary/state" w1 >/dev/null || fail "could not re-arm"
  hook turn_end session_w "$wt" || fail "hooks always exit 0"
  case "$(rec)" in "busy fm-spawn "*) ;; *) fail "an event from a retired incarnation must be refused, got '$(rec)'" ;; esac
  printf '%s' '{"action":"spawn"}' | env "${SCRUB[@]}" JCODE_HOOK_EVENT=pre_tool JCODE_HOOK_TOOL_NAME=swarm \
    JCODE_HOOK_SESSION_ID=session_w JCODE_HOOK_CWD="$wt" "$primary/bin/fm-jcode-hook.sh" >/dev/null 2>&1 \
    || fail "the primary seatbelts must not gate a worker session"
  pass "dispatcher: a bound worker's turns move only its own record, in its own worktree, under its own generation"
}

# The spawn flow through the real fm-spawn.sh with a fake tmux whose send-keys
# sources the staged launch file for real, so the fake jcode client attaches.
make_jcode_spawn_case() {  # <name> <id> -> "case|home|proj|wt|fakebin"
  local name=$1 id=$2 dir home proj wt fb
  dir="$TMP_ROOT/spawn-$name"
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/wt"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$dir/jhome/run"
  fm_test_spawn_brief "$home" "$id" "Exercise jcode dispatch."
  printf 'jcode\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fb=$(make_fake_jcode "$dir")
  fm_fake_exit0 "$fb" treehouse gh-axi gh
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"${JCFAKE_TMUX_LOG:?}"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${JCFAKE_PANE_PATH:?}"; exit 0 ;;
  *"#{cursor_y}"*) printf '1\n'; exit 0 ;;
esac
window_file="$(dirname "$0")/.spawn-window"
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) [ ! -s "$window_file" ] || cat "$window_file"; exit 0 ;;
  new-window)
    name=; previous=
    for arg in "$@"; do [ "$previous" = -n ] && name=$arg; previous=$arg; done
    printf '%s\n' "$name" > "$window_file"
    exit 0
    ;;
  kill-window) : > "$window_file"; exit 0 ;;
  send-keys)
    literal=; prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    case "$literal" in
      ". '"*)
        launch=${literal#". '"}
        launch=${launch%"'"}
        [ -f "$launch" ] || exit 0
        cat "$launch" >>"${JCFAKE_LAUNCH_LOG:?}"
        bash -c "$(cat "$launch")" >/dev/null 2>&1 </dev/null || true
        ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  : > "$dir/tmux.log"
  : > "$dir/launch.log"
  printf '%s|%s|%s|%s|%s\n' "$dir" "$home" "$proj" "$wt" "$fb"
}

run_jcode_spawn() {  # <case-record> <id> [spawn args...]
  local dir home proj wt fb id=$2
  IFS='|' read -r dir home proj wt fb <<EOF
$1
EOF
  shift 2
  env "${SCRUB[@]}" HOME="$home" FM_HOME="$home" FM_ROOT_OVERRIDE='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" JCODE_HOME="$dir/jhome" JCODE_SOCKET="$dir/jhome/run/jcode.sock" \
    JCFAKE_TMUX_LOG="$dir/tmux.log" JCFAKE_LAUNCH_LOG="$dir/launch.log" JCFAKE_PANE_PATH="$wt" \
    FAKE_JCODE_HOOK="$ROOT/bin/fm-jcode-hook.sh" \
    FM_JCODE_READY_POLLS="${FM_JCODE_READY_POLLS:-40}" FM_JCODE_POLL_INTERVAL="${FM_JCODE_POLL_INTERVAL:-0.1}" \
    PATH="$fb:$(dirname "$(command -v node)"):/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" --harness jcode --mode no-mistakes --yolo off "$@" 2>&1
}

test_spawn_creates_binds_and_delivers_after_attach() {
  local rec dir home proj wt fb id=jcspawn1 out rc meta launch sends
  command -v node >/dev/null 2>&1 || { pass "spawn: skipped (node unavailable)"; return; }
  rec=$(make_jcode_spawn_case ok "$id")
  IFS='|' read -r dir home proj wt fb <<EOF
$rec
EOF
  out=$(run_jcode_spawn "$rec" "$id" --model fake/good --effort low); rc=$?
  expect_code 0 "$rc" "a jcode spawn should succeed (output: $out)"
  meta="$home/state/$id.meta"
  assert_grep 'harness=jcode' "$meta" "the record must name jcode"
  assert_grep 'jcode_session=session_fake_1' "$meta" "the record must bind the created session"
  assert_grep "jcode_home=$dir/jhome" "$meta" "the record must keep the daemon's JCODE_HOME"
  assert_grep "jcode_socket=$dir/jhome/run/jcode.sock" "$meta" "the record must keep the daemon's JCODE_SOCKET"
  assert_no_grep 'jcode_runtime_dir=' "$meta" "an unset JCODE_RUNTIME_DIR must not be recorded"
  assert_grep 'session=session_fake_1' "$home/state/$id.jcode-session" "the session record must name the session"
  assert_grep "worktree=$wt" "$home/state/$id.jcode-session" "the session record must name the worktree"
  assert_grep "gen=$(cat "$home/state/$id.busy-gen")" "$home/state/$id.jcode-session" "the session record must carry the armed generation"
  assert_contains "$(cat "$dir/api.log")" "\"req\":\"create_session\",\"session\":\"session_fake_1\",\"working_dir\":\"$wt\"" \
    "the session must be created in the worktree"
  assert_contains "$(cat "$dir/api.log")" '"effort":"low"' "the effort must be applied at creation"
  launch=$(cat "$dir/launch.log")
  assert_contains "$launch" "--resume 'session_fake_1' --no-update --no-selfdev" "the pane must resume the created session"
  assert_contains "$launch" "JCODE_HOME='$dir/jhome'" "the pane's client must dial the spawn's daemon"
  assert_not_contains "$launch" "__JCODE" "the launch left a jcode placeholder unsubstituted"
  sends=$(grep '"req":"send_message"' "$dir/api.log" | grep '"no_reply":false')
  [ "$(printf '%s\n' "$sends" | grep -c .)" -eq 1 ] || fail "exactly one brief turn must be sent, got: $sends"
  assert_contains "$sends" '"client_attached":true' "the brief must be sent only while the pane's client is attached"
  assert_contains "$sends" "Exercise jcode dispatch." "the brief must ride the API message"
  case "$(fm_busy_record_read "$home/state" "$id")" in
    *" jcode-hook "*) ;;
    *) fail "the brief turn's hooks must advance the busy record, got '$(fm_busy_record_read "$home/state" "$id")'" ;;
  esac
  pass "fm-spawn: the jcode session is created and bound before launch, and the brief goes out only after the client attaches"
}

test_spawn_refusals_and_failed_gates() {
  local rec dir home proj wt fb out rc
  command -v node >/dev/null 2>&1 || { pass "spawn refusals: skipped (node unavailable)"; return; }
  rec=$(make_jcode_spawn_case unlisted jcbad1)
  IFS='|' read -r dir home proj wt fb <<EOF
$rec
EOF
  rc=0
  out=$(run_jcode_spawn "$rec" jcbad1 --model fake/unlisted) || rc=$?
  [ "$rc" -ne 0 ] || fail "an unlisted model must refuse the spawn"
  assert_contains "$out" "is not listed" "the refusal must name the catalog"
  [ "$(jc_requests "$dir" create_session)" -eq 0 ] || fail "an unlisted model must refuse before any session exists"

  rec=$(make_jcode_spawn_case noclient jcbad2)
  IFS='|' read -r dir home proj wt fb <<EOF
$rec
EOF
  rc=0
  out=$(FAKE_JCODE_NO_CLIENT=1 FM_JCODE_READY_POLLS=3 run_jcode_spawn "$rec" jcbad2) || rc=$?
  [ "$rc" -ne 0 ] || fail "a pane whose client never attaches must fail the spawn"
  assert_contains "$out" "no jcode client attached" "the failure must name the missing client"
  [ "$(grep -c '"no_reply":false' "$dir/api.log")" -eq 0 ] || fail "the brief must never be sent without an attached client"
  assert_contains "$(cat "$dir/api.log")" '"req":"archive_session"' "a failed gate must archive its session"
  [ ! -e "$home/state/jcbad2.jcode-session" ] || fail "a failed gate must retire the session binding"
  assert_contains "$(cat "$dir/tmux.log")" "kill-window" "a failed gate must close the endpoint it launched"

  rec=$(make_jcode_spawn_case nohooks jcbad3)
  IFS='|' read -r dir home proj wt fb <<EOF
$rec
EOF
  rc=0
  out=$(FAKE_JCODE_NO_HOOKS=1 FM_JCODE_READY_POLLS=3 run_jcode_spawn "$rec" jcbad3) || rc=$?
  [ "$rc" -ne 0 ] || fail "a daemon that never runs this home's hooks must fail the spawn"
  assert_contains "$out" "fm-jcode-setup.sh status" "the failure must point at the hook registration"
  assert_contains "$(sed -E 's/ \[at=[0-9]+\]//' "$home/state/jcbad3.status")" "failed: jcode session" \
    "the failed gate must record the failure in the task status"

  rec=$(make_jcode_spawn_case secondmate jcbad4)
  rc=0
  out=$(run_jcode_spawn "$rec" jcbad4 --secondmate 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a jcode secondmate must be refused"
  pass "fm-spawn: jcode refuses unlisted models and secondmates, and fails loudly without an attached client or hooks"
}

# A tmux stub for the control plane: the pane runs jcode exactly while the
# recorded holder process lives, which is what the agent-state classifier reads.
make_jcode_control_case() {  # <name> -> case dir
  local dir="$TMP_ROOT/control-$1" fb
  fb=$(make_fake_jcode "$dir")
  mkdir -p "$dir/home/state" "$dir/home/data/jc1" "$dir/jhome" "$dir/wt"
  git -C "$dir/wt" init -q
  printf '# brief\n' > "$dir/home/data/jc1/brief.md"
  printf '%s\n' "$dir/wt" > "$dir/sessions/session_c"
  fm_write_meta "$dir/home/state/jc1.meta" "window=fmses:fm-jc1" "endpoint_task_id=jc1" "worktree=$dir/wt" \
    "project=$dir/wt" "harness=jcode" "kind=ship" "mode=no-mistakes" "yolo=off" "model=default" \
    "effort=default" "jcode_session=session_c" "jcode_home=$dir/jhome"
  cat > "$fb/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  display-message)
    for a in "\$@"; do
      case "\$a" in
        *pane_current_command*)
          if [ -s "$dir/holder" ] && kill -0 "\$(cat "$dir/holder")" 2>/dev/null; then printf 'jcode\n'; else printf 'zsh\n'; fi
          exit 0 ;;
        *pane_current_path*) printf '%s\n' "$dir/wt"; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  list-windows) printf 'fm-jc1\n'; exit 0 ;;
  capture-pane) printf '\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$dir"
}

run_jcode_control() {  # <case-dir> <args...>
  local dir=$1
  shift
  env "${SCRUB[@]}" PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FAKE_JCODE_HOOK=/bin/true \
    FM_CONTROL_POLL=0.05 FM_CONTROL_SETTLE_WAIT=2 FM_CONTROL_EXIT_WAIT=3 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

jc_attach_holder() {  # <case-dir>
  JCODE_HOME="$1/jhome" "$1/fakebin/jcode" --resume session_c
  tail -n 1 "$JC_HOLDERS" > "$1/holder"
}

test_control_interrupts_and_exits_through_the_api() {
  local dir out rc pid
  command -v node >/dev/null 2>&1 || { pass "control: skipped (node unavailable)"; return; }
  dir=$(make_jcode_control_case main)
  jc_attach_holder "$dir"
  pid=$(cat "$dir/holder")
  printf '1' > "$dir/running/session_c"
  out=$(FAKE_JCODE_CANCELS_NEEDED=2 run_jcode_control "$dir" jc1 interrupt); rc=$?
  expect_code 0 "$rc" "interrupt should succeed: $out"
  assert_contains "$out" "cancel=cancelled" "interrupt must report the turn cancelled"
  kill -0 "$pid" 2>/dev/null || fail "interrupt must leave the client running"
  ! grep -q '"req":"send_message"' "$dir/api.log" || fail "interrupt must type and send nothing"

  printf '0' > "$dir/running/session_c"
  out=$(run_jcode_control "$dir" jc1 exit); rc=$?
  expect_code 0 "$rc" "exit should succeed: $out"
  assert_contains "$out" "stopped" "exit must report the client stopped"
  assert_contains "$out" "cancel=cancelled" "exit must cancel a running turn first"
  for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  ! kill -0 "$pid" 2>/dev/null || fail "exit must stop the proven client"
  [ -e "$dir/sessions/session_c" ] || fail "exit must leave the session itself alone"

  out=$(run_jcode_control "$dir" jc1 exit); rc=$?
  expect_code 0 "$rc" "a second exit should be idempotent: $out"
  assert_contains "$out" "already-stopped" "a stopped client must read already-stopped"

  # A pane that reads alive with no client of the recorded session in it.
  dir=$(make_jcode_control_case foreign)
  JCODE_HOME="$dir/jhome" "$dir/fakebin/jcode" --resume session_other
  tail -n 1 "$JC_HOLDERS" > "$dir/holder"
  rc=0
  out=$(run_jcode_control "$dir" jc1 exit) || rc=$?
  [ "$rc" -ne 0 ] || fail "exit must refuse a pane whose client is not attached to the recorded session"
  assert_contains "$out" "refusing to signal an unattributed process" "the refusal must name the unproven client"
  kill -0 "$(cat "$dir/holder")" 2>/dev/null || fail "a refused exit must signal nothing"
  pass "fm-control: interrupt cancels through the API, exit cancels then stops only the proven client"
}

test_control_tables_name_jcode_a_worker_adapter() {
  # shellcheck source=bin/fm-control-lib.sh
  . "$ROOT/bin/fm-control-lib.sh"
  fm_control_harness_supported jcode || fail "jcode must be a verified control adapter"
  [ "$(fm_control_harness_family jcode)" = jcode ] || fail "jcode must resolve to its own family"
  fm_control_harness_supports_kind jcode ship || fail "jcode must run ships"
  fm_control_harness_supports_kind jcode scout || fail "jcode must run scouts"
  ! fm_control_harness_supports_kind jcode secondmate || fail "jcode must not run secondmates"
  [ "$(fm_control_interrupt_transport jcode)" = api ] || fail "jcode must interrupt through the API"
  ! fm_control_interrupt_key jcode >/dev/null || fail "jcode must have no interrupt key"
  [ "$(fm_control_harness_wiring_paths jcode /wt /state t1)" = /state/t1.jcode-session ] \
    || fail "jcode's only per-task wiring is its session record"
  # shellcheck source=bin/fm-busy-lib.sh
  . "$ROOT/bin/fm-busy-lib.sh"
  fm_busy_source_trusted jcode jcode-hook || fail "jcode must trust its hook source"
  ! fm_busy_source_trusted claude jcode-hook || fail "no other adapter may trust the jcode hook source"
  pass "control and busy tables: jcode is a crewmate/scout adapter driven through the API and its hooks"
}

test_detection_is_anchored_and_markerless
test_daemon_is_never_an_anchor_or_owner
test_trusted_id_anchor_and_two_sessions
test_swarm_fence
test_dispatcher_pre_tool
test_dispatcher_turn_end_is_bounded
test_supervision_protocol_renders
test_setup_helper
test_api_client_creates_persists_and_cancels
test_client_pid_needs_all_three_proofs
test_dispatcher_records_worker_busy
test_spawn_creates_binds_and_delivers_after_attach
test_spawn_refusals_and_failed_gates
test_control_interrupts_and_exits_through_the_api
test_control_tables_name_jcode_a_worker_adapter

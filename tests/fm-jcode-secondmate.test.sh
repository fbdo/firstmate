#!/usr/bin/env bash
# tests/fm-jcode-secondmate.test.sh - a jcode secondmate on the one shared daemon:
# the daemon environment guard, the hook's secondmate busy arm and delegation to
# the mate's own dispatcher, and hook setup status from a mate home.
# No daemon, no tokens: fake hook environment and throwaway homes.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v node >/dev/null 2>&1 || { echo "skip - node not installed"; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-jcode-secondmate)
SCRUB=(-u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u FM_OMP_HARNESS -u PI_CODING_AGENT
  -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GROK_AGENT -u GEMINI_CLI -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI
  -u JCODE_SESSION_ID -u JCODE_HOME -u FM_HOME -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE
  -u FM_JCODE_HOOK_DELEGATED)

# shellcheck source=bin/fm-jcode-lib.sh
. "$ROOT/bin/fm-jcode-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"

# --- fixtures: a main home with a registered jcode secondmate home --------------
MAIN="$TMP_ROOT/main"
MATE="$TMP_ROOT/mate"
mkdir -p "$MAIN/state" "$MATE/state" "$MATE/bin"
git -C "$MAIN" init -q
git -C "$MATE" init -q
cp -R "$ROOT/bin" "$MAIN/bin"
cp -R "$ROOT/docs" "$MAIN/docs"
cp "$ROOT/AGENTS.md" "$MAIN/AGENTS.md"
MATE=$(CDPATH='' cd -- "$MATE" && pwd -P)
MAIN=$(CDPATH='' cd -- "$MAIN" && pwd -P)
STATE="$MAIN/state"
printf 'mate1\n' >"$MATE/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$MAIN" >"$MATE/.fm-secondmate-parent"
# The mate's own dispatcher is a logging fixture.
cat >"$MATE/bin/fm-jcode-hook.sh" <<EOF
#!/usr/bin/env bash
printf 'event=%s session=%s cwd=%s delegated=%s home=%s root_override=[%s] state_override=[%s] stdin=%s\n' \
  "\${JCODE_HOOK_EVENT:-}" "\${JCODE_HOOK_SESSION_ID:-}" "\${JCODE_HOOK_CWD:-}" "\${FM_JCODE_HOOK_DELEGATED:-}" \
  "\${FM_HOME:-}" "\${FM_ROOT_OVERRIDE-unset}" "\${FM_STATE_OVERRIDE-unset}" "\$(cat)" >>"$TMP_ROOT/mate-hook.log"
exit 0
EOF
chmod +x "$MATE/bin/fm-jcode-hook.sh"
printf 'kind=secondmate\nharness=jcode\nbackend=herdr\nhome=%s\n' "$MATE" >"$STATE/mate1.meta"
gen=$("$MAIN/bin/fm-busy-event.sh" arm "$STATE" mate1) || fail "could not arm the busy contract"
fm_jcode_write_session_record "$STATE" mate1 session_mate "$gen" "$MATE" || fail "could not bind the mate session"
# One of the mate's own crew, bound only in the mate's state.
CREW_WT="$TMP_ROOT/crew-wt"
mkdir -p "$CREW_WT"
git -C "$CREW_WT" init -q
fm_jcode_write_session_record "$MATE/state" crew1 session_crew 1 "$CREW_WT" || fail "could not bind the crew session"

hook() {  # <event> <tool> <input> <session> <cwd> [extra env...]
  local ev=$1 tool=$2 input=$3 sess=$4 cwd=$5
  shift 5
  printf '%s' "$input" | env "${SCRUB[@]}" "$@" JCODE_HOOK_EVENT="$ev" JCODE_HOOK_TOOL_NAME="$tool" \
    JCODE_HOOK_SESSION_ID="$sess" JCODE_HOOK_CWD="$cwd" "$MAIN/bin/fm-jcode-hook.sh" 2>"$TMP_ROOT/hook.err" >/dev/null
}

# --- case 2: the daemon environment guard ---------------------------------------
test_daemon_env_guard() {
  local clean="$TMP_ROOT/environ-clean" dirty="$TMP_ROOT/environ-dirty" out rc
  printf 'JCODE_SOCKET=/x\0PATH=/bin\0' >"$clean"
  printf 'JCODE_SOCKET=/x\0FM_HOME=/home/captain/firstmate\0' >"$dirty"
  FM_JCODE_DAEMON_ENVIRON_FILE="$clean" fm_jcode_daemon_env_clean 2>/dev/null || fail "a clean daemon environment must pass"
  rc=0
  out=$(FM_JCODE_DAEMON_ENVIRON_FILE="$dirty" fm_jcode_daemon_env_clean 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "a daemon carrying FM_HOME must be refused"
  assert_contains "$out" "FM_HOME" "the refusal names the variable"
  assert_contains "$out" "restart it from a clean shell" "the refusal says how to fix it"
  printf 'FM_STATE_OVERRIDE=/s\0' >"$dirty"
  FM_JCODE_DAEMON_ENVIRON_FILE="$dirty" fm_jcode_daemon_env_clean 2>/dev/null && fail "an *_OVERRIDE must be refused"
  rc=0
  out=$(FM_JCODE_DAEMON_ENVIRON_FILE="$TMP_ROOT/absent-environ" fm_jcode_daemon_env_clean 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "an unreadable environ warns but does not refuse"
  assert_contains "$out" "warning" "an unreadable environ warns"
  pass "daemon env guard: FM_HOME and overrides refused, clean passes, unreadable warns"
}

# --- case 3: hook busy arm, fence skip, delegation --------------------------------
test_hook_secondmate() {
  local rec
  rec() { fm_busy_record_read "$STATE" mate1 2>/dev/null || true; }
  hook turn_start "" '' session_mate "$MATE"
  case "$(rec)" in "busy jcode-hook "*) ;; *) fail "turn_start must record the mate busy, got '$(rec)'" ;; esac
  hook turn_end "" '' session_mate "$MATE"
  case "$(rec)" in "idle jcode-hook "*) ;; *) fail "turn_end must record the mate idle, got '$(rec)'" ;; esac
  [ ! -e "$STATE/mate1.turn-ended" ] || fail "a secondmate turn_end must not touch a turn-ended notification"
  pass "hook: secondmate busy and idle are recorded without turn-ended"

  : >"$TMP_ROOT/mate-hook.log"
  hook pre_tool swarm '{"action":"dm","to_swarm":"x"}' session_mate "$MATE"
  [ $? -eq 0 ] || fail "the worker swarm fence must not apply to a secondmate session"
  assert_contains "$(cat "$TMP_ROOT/mate-hook.log")" "event=pre_tool session=session_mate" "pre_tool is delegated to the mate dispatcher"
  assert_contains "$(cat "$TMP_ROOT/mate-hook.log")" "delegated=1" "the delegated marker is set"
  assert_contains "$(cat "$TMP_ROOT/mate-hook.log")" "home=$MATE" "FM_HOME names the mate"
  assert_contains "$(cat "$TMP_ROOT/mate-hook.log")" 'stdin={"action":"dm","to_swarm":"x"}' "stdin reaches the mate dispatcher"
  assert_contains "$(cat "$TMP_ROOT/mate-hook.log")" "root_override=[] state_override=[]" "inherited overrides are blanked"
  hook turn_end "" '' session_mate "$MATE"
  assert_contains "$(cat "$TMP_ROOT/mate-hook.log")" "event=turn_end session=session_mate" "turn_end is delegated for the backstop"
  pass "hook: the mate's own session is delegated with the fence skipped"

  : >"$TMP_ROOT/mate-hook.log"
  hook pre_tool bash '{"command":"ls"}' session_crew "$CREW_WT"
  assert_contains "$(cat "$TMP_ROOT/mate-hook.log")" "session=session_crew" "a session bound in the mate state is delegated"
  : >"$TMP_ROOT/mate-hook.log"
  hook pre_tool bash '{"command":"ls"}' session_other "$TMP_ROOT"
  hook pre_tool bash '{"command":"ls"}' session_crew "$CREW_WT" FM_JCODE_HOOK_DELEGATED=1
  [ ! -s "$TMP_ROOT/mate-hook.log" ] || fail "unrelated sessions and an already delegated event must not delegate: $(cat "$TMP_ROOT/mate-hook.log")"
  pass "hook: unrelated sessions and a second level are not delegated"

  # No delegation without the marker, or when the marker names another id.
  mv "$MATE/.fm-secondmate-home" "$MATE/.marker.off"
  hook pre_tool bash '{"command":"ls"}' session_crew "$CREW_WT"
  [ ! -s "$TMP_ROOT/mate-hook.log" ] || fail "a home without the marker must not be delegated to"
  printf 'other\n' >"$MATE/.fm-secondmate-home"
  hook pre_tool bash '{"command":"ls"}' session_crew "$CREW_WT"
  [ ! -s "$TMP_ROOT/mate-hook.log" ] || fail "a marker naming another id must not be delegated to"
  rm -f "$MATE/.fm-secondmate-home"
  mv "$MATE/.marker.off" "$MATE/.fm-secondmate-home"
  printf 'mate1\n' >"$MATE/.fm-secondmate-home"
  pass "hook: delegation needs a matching secondmate marker"
}

test_hook_target_helper() {
  local out
  out=$(fm_jcode_secondmate_hook_target "$STATE" "$MATE" session_x) || fail "the mate toplevel must resolve a target"
  [ "$out" = "$MATE" ] || fail "target is the mate home, got '$out'"
  out=$(fm_jcode_secondmate_hook_target "$STATE" "$CREW_WT" session_crew) || fail "a crew session bound in the mate state resolves"
  [ "$out" = "$MATE" ] || fail "crew target is the mate home"
  fm_jcode_secondmate_hook_target "$STATE" "$TMP_ROOT" session_x >/dev/null && fail "an unrelated session has no target"
  pass "helper: fm_jcode_secondmate_hook_target resolves only the mate and its crew"
}

# --- case 7: setup status from a mate home ----------------------------------------
test_setup_status() {
  local cfg="$TMP_ROOT/config.toml" out rc
  mkdir -p "$MATE/bin"
  cp "$ROOT/bin/fm-jcode-setup.sh" "$MATE/bin/fm-jcode-setup.sh"
  cat >"$cfg" <<EOF
[hooks]
turn_start = "$MAIN/bin/fm-jcode-hook.sh"
pre_tool = "$MAIN/bin/fm-jcode-hook.sh"
turn_end = "$MAIN/bin/fm-jcode-hook.sh"
EOF
  command -v python3 >/dev/null 2>&1 || { pass "setup: skipped, python3 missing"; return; }
  rc=0
  out=$(env "${SCRUB[@]}" FM_JCODE_CONFIG="$cfg" "$MATE/bin/fm-jcode-setup.sh" status 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "status from the mate home must report registered, got rc=$rc: $out"
  assert_contains "$out" "registered" "status says registered"
  rc=0
  out=$(env "${SCRUB[@]}" FM_JCODE_CONFIG="$cfg" "$MATE/bin/fm-jcode-setup.sh" install 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "install from the mate home must refuse"
  assert_contains "$out" "register the parent home's hooks instead" "install refusal text"
  # The parent does not bind this home: not registered.
  printf 'kind=secondmate\nharness=jcode\nhome=%s\n' "$TMP_ROOT/elsewhere" >"$STATE/mate1.meta"
  rc=0
  env "${SCRUB[@]}" FM_JCODE_CONFIG="$cfg" "$MATE/bin/fm-jcode-setup.sh" status >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "status must fail when the parent meta binds a different home"
  printf 'kind=secondmate\nharness=jcode\nbackend=herdr\nhome=%s\n' "$MATE" >"$STATE/mate1.meta"
  # Ambient warning, exit status unchanged.
  printf '[ambient]\nenabled = true\n' >>"$cfg"
  rc=0
  out=$(env "${SCRUB[@]}" FM_JCODE_CONFIG="$cfg" "$MATE/bin/fm-jcode-setup.sh" status 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "the ambient warning must not change the exit status"
  assert_contains "$out" "jcode ambient: enabled (Firstmate does not use it" "ambient warning prints"
  pass "setup: mate-home status follows the parent, install refuses, ambient warning is read-only"
}

test_daemon_env_guard
test_hook_target_helper
test_hook_secondmate
test_setup_status

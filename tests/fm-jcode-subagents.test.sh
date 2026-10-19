#!/usr/bin/env bash
# tests/fm-jcode-subagents.test.sh - the worker subagent fence (amended D12) and the
# native-task busy skip (amended D10) in bin/fm-jcode-hook.sh. No daemon: the hook
# runs under a fake hook environment against a throwaway firstmate copy.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v node >/dev/null 2>&1 || { echo "skip - node not installed"; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-jcode-subagents)
SCRUB=(-u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u FM_OMP_HARNESS -u PI_CODING_AGENT
  -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GROK_AGENT -u GEMINI_CLI -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI
  -u JCODE_SESSION_ID -u JCODE_HOME -u FM_HOME -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE)

PRIMARY="$TMP_ROOT/primary"
mkdir -p "$PRIMARY/state"
git -C "$PRIMARY" init -q
cp -R "$ROOT/bin" "$PRIMARY/bin"
cp -R "$ROOT/docs" "$PRIMARY/docs"
cp "$ROOT/AGENTS.md" "$PRIMARY/AGENTS.md"
WT="$TMP_ROOT/wt"
mkdir -p "$WT"
git -C "$WT" init -q
STATE="$PRIMARY/state"

# shellcheck source=bin/fm-jcode-lib.sh
. "$ROOT/bin/fm-jcode-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
gen=$("$PRIMARY/bin/fm-busy-event.sh" arm "$STATE" w1) || fail "could not arm the busy contract"
fm_jcode_write_session_record "$STATE" w1 session_w "$gen" "$WT" || fail "could not bind the session"

hook() {  # <event> <tool> <input> <session> <cwd>
  printf '%s' "$3" | env "${SCRUB[@]}" JCODE_HOOK_EVENT="$1" JCODE_HOOK_TOOL_NAME="$2" \
    JCODE_HOOK_SESSION_ID="$4" JCODE_HOOK_CWD="$5" "$PRIMARY/bin/fm-jcode-hook.sh" 2>"$TMP_ROOT/hook.err" >/dev/null
}
denied() { hook pre_tool "$1" "$2" session_w "$WT"; [ $? -eq 2 ]; }
allowed() { hook pre_tool "$1" "$2" session_w "$WT"; }

test_worker_fence() {
  local c
  allowed swarm '{"action":"spawn","prompt":"help"}' || fail "a bound worker may spawn subagents"
  allowed swarm '{"action":"await_members"}' || fail "await_members is allowed"
  allowed swarm '{"action":"stop","target_session":"child"}' || fail "stop of an own child is allowed"
  allowed swarm '{"action":"dm","to_session":"child","message":"x"}' || fail "dm to an own child is allowed"
  allowed swarm '{"action":"status"}' || fail "status is allowed"
  allowed bash '{"command":"ls"}' || fail "other tools are not examined"
  denied swarm '{"action":"dm","to_swarm":"captain","message":"x"}' || fail "to_swarm must be denied"
  assert_contains "$(cat "$TMP_ROOT/hook.err")" "subagents stay inside your own swarm" "the deny names the rule"
  for c in set_swarm_label approve_plan propose_plan run_plan; do
    denied swarm "{\"action\":\"$c\"}" || fail "$c must be denied"
  done
  denied swarm '{"action":"assign_role","role":"coordinator"}' || fail "assigning coordinator must be denied"
  allowed swarm '{"action":"assign_role","role":"agent"}' || fail "assigning agent is allowed"
  denied batch '{"tool_calls":[{"tool":"read","file_path":"a"},{"tool":"swarm","action":"dm","to_swarm":"x"}]}' || fail "a swarm call inside batch is fenced"
  allowed batch '{"tool_calls":[{"tool":"swarm","action":"spawn"}]}' || fail "a spawn inside batch is allowed"
  pass "worker fence: spawn, await_members, stop, own dm allowed; to_swarm, labels, plans, coordinator denied"
}

test_primary_and_unbound() {
  hook pre_tool swarm '{"action":"spawn","prompt":"x"}' session_x "$PRIMARY"
  [ $? -eq 2 ] || fail "the primary's swarm fence must stay on"
  hook pre_tool swarm '{"action":"dm","to_swarm":"x"}' session_x "$TMP_ROOT"
  [ $? -eq 0 ] || fail "an unbound session outside any home exits silently"
  hook pre_tool swarm '{"action":"dm","to_swarm":"x"}' session_x "$WT"
  [ $? -eq 0 ] || fail "an unbound session in a worktree is ignored"
  pass "the primary fence is unchanged and unbound sessions are ignored"
}

test_native_task_skips_busy_writes() {
  local rec before
  rec() { fm_busy_record_read "$STATE" w1 2>/dev/null || true; }
  hook turn_end "" '' session_w "$WT"
  case "$(rec)" in "idle jcode-hook "*) ;; *) fail "a pane-backend task keeps the hook busy writes, got '$(rec)'" ;; esac
  gen=$("$PRIMARY/bin/fm-busy-event.sh" arm "$STATE" w1)
  fm_jcode_write_session_record "$STATE" w1 session_w "$gen" "$WT"
  printf 'backend=jcode\nendpoint_task_id=w1\n' >"$STATE/w1.meta"
  before=$(rec)
  hook turn_end "" '' session_w "$WT"
  [ "$(rec)" = "$before" ] || fail "a native task's busy record belongs to the keeper, got '$(rec)'"
  hook turn_start "" '' session_w "$WT"
  [ "$(rec)" = "$before" ] || fail "turn_start writes nothing for a native task"
  pass "the hook leaves a native (backend=jcode) task's busy record to the keeper"
}

test_worker_fence
test_primary_and_unbound
test_native_task_skips_busy_writes

#!/usr/bin/env bash
# fm-jcode-hook.sh - single entry point for every jcode lifecycle hook a
# firstmate home registers (docs/turnend-guard.md "jcode", jcode's own
# docs/HOOKS.md for the hook contract).
#
# jcode hooks are configured per machine ([hooks] in ~/.jcode/config.toml or the
# JCODE_HOOK_* environment of the daemon), not per project, so this dispatcher
# fires for every jcode session on the daemon. It therefore scopes itself first
# and acts for exactly two kinds of session:
#   - a jcode crewmate or scout of this home: its session id is bound to a task
#     by that task's state/<id>.jcode-session record (bin/fm-jcode-lib.sh), and
#     the session's working directory (JCODE_HOOK_CWD) resolves to the task's
#     recorded worktree. Only turn_start and turn_end act for it.
#   - this home's own primary: the working directory resolves to this script's
#     own firstmate checkout, and that checkout is a genuine primary home
#     (fm_primary_scope_matches).
# Every other session - another home's worker, a secondmate home that
# registers its own copy, an unrelated repo - is a silent exit 0 that costs
# one git call. It never executes code from the session's repository; each
# home registers its own copy of this script.
#
# Events (JCODE_HOOK_EVENT):
#   turn_start OBSERVER. For a bound worker, records busy through
#              bin/fm-busy-event.sh with source jcode-hook and the busy
#              generation its record carries, so an event from a retired
#              incarnation is refused as stale. Ignored for the primary.
#   pre_tool   GATE, primary only. stdin is the tool input JSON,
#              JCODE_HOOK_TOOL_NAME the tool.
#              Runs the existing PreToolUse seatbelts against it:
#                bash   -> bin/fm-cd-pretool-check.sh and bin/fm-arm-pretool-check.sh
#                swarm  -> bin/fm-subagent-pretool-check.sh --action <action>
#                batch  -> each wrapped tool call, by the same rules
#                other  -> bin/fm-subagent-pretool-check.sh --tool <name>
#              A deny exits 2 with one plain reason line on stderr, which jcode
#              returns to the model as the tool error. jcode treats any other
#              exit, a timeout, or a missing binary as allow (fail open by
#              jcode's design), and so does every seatbelt on malformed input.
#   turn_end   OBSERVER. For a bound worker, records idle the same way and
#              touches the task's turn-ended notification; a cancelled turn
#              fires turn_end too (verified, jcode v0.98.1). For the primary,
#              runs bin/fm-turnend-guard.sh for this session. On its
#              exit 2 it submits one hidden system reminder carrying the guard's
#              banner through bin/fm-jcode-api.mjs, which starts one follow-up
#              turn. The next turn_end of that same session is consumed without
#              re-checking, so the follow-up is bounded to one per turn - the
#              same shape as the Pi and Cursor adapters - and never loops.
#   *          ignored (exit 0).
#
# The session id comes from JCODE_HOOK_SESSION_ID and is exported as
# JCODE_SESSION_ID so bin/fm-session-lock-lib.sh can apply its jcode trust gate
# from the hook process, whose only harness ancestor is the shared daemon.
# JCODE_HOOKS_DISABLED=1 (always set by jcode for hook processes) keeps any
# nested jcode call made here from re-triggering hooks.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
EVENT=${JCODE_HOOK_EVENT:-}
SESSION=${JCODE_HOOK_SESSION_ID:-}
CWD=${JCODE_HOOK_CWD:-${PWD:-}}

case "$EVENT" in
  turn_start|pre_tool|turn_end) ;;
  *) exit 0 ;;
esac

[ -n "$CWD" ] || exit 0
TOPLEVEL=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null) || exit 0
TOPLEVEL=$(CDPATH='' cd -- "$TOPLEVEL" 2>/dev/null && pwd -P) || exit 0
export FM_HOME=${FM_HOME:-$FM_ROOT}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}

# --- scope: a jcode worker of this home ---------------------------------------
if [ -d "$STATE" ]; then
  # shellcheck source=bin/fm-jcode-lib.sh
  . "$SCRIPT_DIR/fm-jcode-lib.sh"
  if BOUND=$(fm_jcode_session_task "$STATE" "$SESSION"); then
    IFS=$'\t' read -r TASK_ID TASK_GEN TASK_WT <<EOF
$BOUND
EOF
    TASK_WT=$(CDPATH='' cd -- "$TASK_WT" 2>/dev/null && pwd -P) || exit 0
    [ "$TOPLEVEL" = "$TASK_WT" ] || exit 0
    if [ "$EVENT" = pre_tool ]; then
      # Worker fence (amended D12): subagents stay inside the worker's own swarm.
      # Only the swarm tool (and swarm calls inside batch) is examined, and the
      # fence fails open on anything it cannot parse, like every other seatbelt.
      INPUT=$(cat 2>/dev/null || true)
      case "$(printf '%s' "${JCODE_HOOK_TOOL_NAME:-}" | tr '[:upper:]' '[:lower:]')" in
        swarm|batch)
          if command -v node >/dev/null 2>&1; then
            DENY=$(printf '%s' "$INPUT" | node -e '
              let s = "";
              process.stdin.on("data", (d) => (s += d)).on("end", () => {
                let v;
                try { v = JSON.parse(s); } catch { process.exit(0); }
                const tool = (process.argv[1] || "").toLowerCase();
                const calls = tool === "batch" ? (Array.isArray(v?.tool_calls) ? v.tool_calls : []) : [{ tool: "swarm", ...v }];
                const banned = new Set(["set_swarm_label", "approve_plan", "propose_plan", "run_plan"]);
                for (const c of calls) {
                  if (!c || typeof c !== "object" || String(c.tool || "").toLowerCase() !== "swarm") continue;
                  if ((typeof c.to_swarm === "string" && c.to_swarm !== "") || banned.has(c.action) || (c.action === "assign_role" && c.role === "coordinator")) {
                    process.stdout.write("Firstmate worker: subagents stay inside your own swarm; report to Firstmate through the status file");
                    return;
                  }
                }
              });
            ' "${JCODE_HOOK_TOOL_NAME:-}" 2>/dev/null || true)
            if [ -n "$DENY" ]; then
              printf '%s\n' "$DENY" >&2
              exit 2
            fi
          fi
          ;;
      esac
      exit 0
    fi
    # The keeper owns busy/idle for a native (backend=jcode) task, so the hook
    # writes no busy record for it (amended D10); pane-backend jcode tasks keep it.
    if [ "$(fm_jcode_meta_value "$STATE/$TASK_ID.meta" backend)" = jcode ]; then
      if [ "$EVENT" = turn_end ] && [ "${JCODE_HOOK_STATUS:-}" = error ] \
        && STOP_REASON=$(fm_jcode_silent_stop_reason "${JCODE_HOOK_ERROR:-}"); then
        fm_jcode_report_blocked "$STATE" "$TASK_ID" "$STOP_REASON" || true
      fi
      exit 0
    fi
    if [ "$EVENT" = turn_start ]; then
      "$SCRIPT_DIR/fm-busy-event.sh" apply "$STATE" "$TASK_ID" busy --gen "$TASK_GEN" \
        --source jcode-hook --event turn-start >/dev/null 2>&1 || true
    else
      "$SCRIPT_DIR/fm-busy-event.sh" apply "$STATE" "$TASK_ID" idle --gen "$TASK_GEN" \
        --source jcode-hook --event turn-end --turn-ended >/dev/null 2>&1 || true
      # A turn that ended in error on an auth failure or stream-idle cancel is a
      # silent stop: record it as blocked so firstmate is woken with the reason.
      if [ "${JCODE_HOOK_STATUS:-}" = error ] \
        && STOP_REASON=$(fm_jcode_silent_stop_reason "${JCODE_HOOK_ERROR:-}"); then
        fm_jcode_report_blocked "$STATE" "$TASK_ID" "$STOP_REASON" || true
      fi
    fi
    exit 0
  fi
fi
[ "$EVENT" != turn_start ] || exit 0

# --- scope: this home's own primary session only ------------------------------
[ "$TOPLEVEL" = "$FM_ROOT" ] || exit 0
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
case "$SESSION" in
  ''|*[!A-Za-z0-9_.-]*) SESSION= ;;
esac
[ -z "$SESSION" ] || export JCODE_SESSION_ID="$SESSION"

# Print the plain reason from a seatbelt's --claude deny object on stderr file
# $1, falling back to the raw text when it is not that object.
deny_reason() {  # <stderr-file>
  local raw reason=''
  raw=$(cat "$1" 2>/dev/null || true)
  reason=$(printf '%s' "$raw" | json_query deny-reason 2>/dev/null || true)
  printf '%s\n' "${reason:-$raw}"
}

# Read JSON on stdin and print one field, using node (already required by the
# watcher-arm policy this dispatcher calls), so the dispatcher does not depend
# on jq. Queries:
#   string <key>   the top-level string field <key>, or nothing
#   batch          one compact JSON object per wrapped call in .tool_calls
#   deny-reason    .systemMessage of a seatbelt deny object
# Prints nothing and exits nonzero when node is missing or the input is not a
# JSON object, which every caller treats as allow (fail open).
json_query() {  # <query> [<key>]
  command -v node >/dev/null 2>&1 || return 1
  node -e '
    let s = "";
    process.stdin.on("data", (d) => (s += d)).on("end", () => {
      let v;
      try { v = JSON.parse(s); } catch { process.exit(1); }
      if (!v || typeof v !== "object" || Array.isArray(v)) process.exit(1);
      const [q, key] = process.argv.slice(1);
      if (q === "string") {
        if (typeof v[key] === "string") process.stdout.write(v[key]);
      } else if (q === "batch") {
        for (const c of Array.isArray(v.tool_calls) ? v.tool_calls : []) {
          if (c && typeof c === "object" && !Array.isArray(c)) process.stdout.write(JSON.stringify(c) + "\n");
        }
      } else if (q === "deny-reason") {
        if (typeof v.systemMessage === "string") process.stdout.write(v.systemMessage);
      }
    });
  ' "$@"
}

# Run one seatbelt; on deny print its reason and exit 2.
run_seatbelt() {  # <script> <args...>
  local err rc=0
  err=$(mktemp "${TMPDIR:-/tmp}/fm-jcode-hook.XXXXXX") || return 0
  "$@" --claude >/dev/null 2>"$err" || rc=$?
  if [ "$rc" -eq 2 ]; then
    deny_reason "$err" >&2
    rm -f "$err"
    exit 2
  fi
  rm -f "$err"
}

# Apply the seatbelts to one tool call: tool name $1, tool input JSON $2.
check_tool_call() {  # <tool> <input-json>
  local tool input lc command action inner calls
  tool=$1
  input=$2
  LC_ALL=C lc=$(printf '%s' "$tool" | tr '[:upper:]' '[:lower:]')
  case "$lc" in
    bash)
      command=$(printf '%s' "$input" | json_query string command) || return 0
      [ -n "$command" ] || return 0
      run_seatbelt "$SCRIPT_DIR/fm-cd-pretool-check.sh" --command "$command"
      run_seatbelt "$SCRIPT_DIR/fm-arm-pretool-check.sh" --command "$command"
      ;;
    swarm)
      action=$(printf '%s' "$input" | json_query string action) || action=''
      run_seatbelt "$SCRIPT_DIR/fm-subagent-pretool-check.sh" --tool swarm --action "$action"
      ;;
    batch)
      calls=$(printf '%s' "$input" | json_query batch) || return 0
      while IFS= read -r inner; do
        [ -n "$inner" ] || continue
        check_tool_call "$(printf '%s' "$inner" | json_query string tool || true)" "$inner"
      done <<EOF
$calls
EOF
      ;;
    *)
      run_seatbelt "$SCRIPT_DIR/fm-subagent-pretool-check.sh" --tool "$tool"
      ;;
  esac
}

if [ "$EVENT" = pre_tool ]; then
  INPUT=$(cat 2>/dev/null || true)
  [ -n "${JCODE_HOOK_TOOL_NAME:-}" ] || exit 0
  check_tool_call "$JCODE_HOOK_TOOL_NAME" "$INPUT"
  exit 0
fi

# --- turn_end: bounded follow-up ----------------------------------------------
[ -n "$SESSION" ] || exit 0
[ -d "$STATE" ] || exit 0
MARK="$STATE/.jcode-turnend-followup"
if [ -f "$MARK" ] && [ "$(head -n 1 "$MARK" 2>/dev/null)" = "$SESSION" ]; then
  rm -f "$MARK"
  exit 0
fi
GUARD_ERR=$(mktemp "${TMPDIR:-/tmp}/fm-jcode-guard.XXXXXX") || exit 0
rc=0
printf '{"stop_hook_active":false}' | "$SCRIPT_DIR/fm-turnend-guard.sh" >/dev/null 2>"$GUARD_ERR" || rc=$?
if [ "$rc" -ne 2 ]; then
  rm -f "$GUARD_ERR"
  exit 0
fi
printf '%s\n' "$SESSION" > "$MARK" 2>/dev/null || { rm -f "$GUARD_ERR"; exit 0; }
{
  printf '%s\n\n' 'Firstmate turn-end guard (bin/fm-turnend-guard.sh, delivered by bin/fm-jcode-hook.sh): TURN WOULD END BLIND - supervision is off. The watcher cycle is missing, failed, or unhealthy. Follow the recovery instruction below before ending the turn.'
  cat "$GUARD_ERR"
} | node "$SCRIPT_DIR/fm-jcode-api.mjs" remind "$SESSION" >/dev/null 2>&1 || rm -f "$MARK"
rm -f "$GUARD_ERR"
exit 0

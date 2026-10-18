#!/usr/bin/env bash
# Credentialed jcode worker guard. Opt in with FM_JCODE_SIGNALS_LIVE=1.
# Drives the real Firstmate verbs end to end on an isolated Herdr lab session
# and a private jcode daemon: the launch is bin/fm-spawn.sh's generated jcode
# path (API-created session, `jcode --resume` in the pane, brief through the
# API), the steer is bin/fm-send.sh, and the interrupt, exit, and relaunch are
# bin/fm-control.sh. Only worktree allocation uses a fixture (a `treehouse`
# stand-in that enters a prepared clone). Also proves the model/effort pin,
# detection from a real tool subprocess, and the hook-driven busy open and
# close on real turns, including a cancelled one. The operator's shared jcode
# daemon is never touched: JCODE_HOME, JCODE_RUNTIME_DIR, and JCODE_SOCKET
# select a private one whose hooks come from `bin/fm-jcode-setup.sh env`.
# FM_JCODE_LIVE_MODEL optionally pins a listed model; effort is always low.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate opt-in FM_JCODE_SIGNALS_LIVE jcode herdr node jq git

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-jcode-lib.sh
. "$ROOT/bin/fm-jcode-lib.sh"

VERSION=$(jcode --version 2>/dev/null | head -n 1 || echo unknown)
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=
ID=jcguard
LAB=
JH=

stop_private_daemon() {
  local d
  [ -n "$JH" ] || return 0
  for d in /proc/[0-9]*; do
    [ "$(cat "$d/comm" 2>/dev/null)" = jcode ] || continue
    tr '\0' '\n' < "$d/environ" 2>/dev/null | grep -qxF "JCODE_HOME=$JH" && kill "${d#/proc/}" 2>/dev/null
  done
  return 0
}

cleanup() {
  local status=0
  stop_private_daemon
  if [ -n "$HERDR_LAB_SESSION" ]; then
    "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  fi
  if [ -n "$LAB" ]; then
    find "$LAB" -type d -exec chmod u+rwx {} + 2>/dev/null
    rm -rf -- "$LAB"
  fi
  [ "$status" -eq 0 ] || exit 1
}

# FM_JCODE_LIVE_EVIDENCE=<dir> keeps a failed run's session records, daemon
# logs, task state, and last pane capture there before the lab is removed.
fail() {
  local keep=${FM_JCODE_LIVE_EVIDENCE:-} target
  if [ -n "$keep" ] && [ -n "$LAB" ]; then
    mkdir -p "$keep"
    cp -R "$JH/sessions" "$JH/logs" "$H/state" "$keep/" 2>/dev/null
    cp "$LAB"/*.log "$keep/" 2>/dev/null
    target=$(fm_jcode_meta_value "$H/state/$ID.meta" window 2>/dev/null)
    [ -z "$target" ] || fm_backend_capture herdr "$target" 200 "fm-$ID" > "$keep/pane.txt" 2>/dev/null
  fi
  printf 'not ok - %s: %s\n' "$VERSION" "$1" >&2
  exit 1
}

[ -d /proc/self ] || fail "this guard stops its private daemon through /proc and runs on Linux only"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-jcode-signals.XXXXXX") || fail "could not create the isolated lab"
LAB=$(cd "$LAB" && pwd -P)
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name jcode-live) || fail "could not name the Herdr lab session"
trap cleanup EXIT

H="$LAB/fm"
PROJ="$LAB/project"
WT="$LAB/wt"
JH="$LAB/jhome"
"$ROOT/bin/fm-lab-home.sh" create "$H" >/dev/null || fail "could not mark the lab home"
fm_test_spawn_home "$H" jcode
printf 'herdr\n' > "$H/config/backend"
printf 'manual\n' > "$H/config/backlog-backend"
printf 'off\n' > "$H/config/herdr-presentation-spaces"
fm_git_init_commit "$PROJ"
git clone -q "$PROJ" "$WT" || fail "could not prepare the scratch clone"
git -C "$WT" checkout -qb jcode-live || fail "could not branch the scratch clone"
fm_test_spawn_brief "$H" "$ID" "Runtime verification only: compute 12345 plus 67890 using your shell tool and write only the result into answer.txt. Then use your shell tool to run 'bash $ROOT/bin/fm-harness.sh' and write its output to harness.txt. Do no other work, do not commit, and do not delegate."

# A private jcode home: the operator's provider credentials are linked, never
# copied or changed, and its config is a copy whose hooks the environment
# overrides (an empty JCODE_HOOK_* disables that config hook).
mkdir -p "$JH/run" "$JH/config/jcode" "$LAB/bin"
for cred in "$HOME/.jcode/auth.json" "$HOME"/.jcode/*_oauth.json; do
  [ -f "$cred" ] && ln -s "$cred" "$JH/${cred##*/}"
done
for env_file in "${XDG_CONFIG_HOME:-$HOME/.config}"/jcode/*.env; do
  [ -f "$env_file" ] && ln -s "$env_file" "$JH/config/jcode/${env_file##*/}"
done
[ ! -f "$HOME/.jcode/config.toml" ] || cp "$HOME/.jcode/config.toml" "$JH/config.toml"
export JCODE_HOME="$JH" JCODE_RUNTIME_DIR="$JH/run" JCODE_SOCKET="$JH/run/jcode.sock" JCODE_NO_AUTO_UPDATE=1
export JCODE_HOOK_PRE_TOOL='' JCODE_HOOK_POST_TOOL='' JCODE_HOOK_POST_TOOL_FEEDBACK='' JCODE_HOOK_PRE_TOOL_TRANSFORM=''
export JCODE_HOOK_SESSION_START='' JCODE_HOOK_SESSION_END=''
eval "$("$ROOT/bin/fm-jcode-setup.sh" env)" || fail "could not read the hook registration"

# The pane's `treehouse get` enters the prepared clone in a subshell exactly as
# the real tool does, so no Treehouse pool is ever touched. A Herdr pane runs
# $SHELL, and an interactive shell's startup files can put the real treehouse
# ahead of the stand-in, so the lab server is started with SHELL naming a bash
# that reads none, and PATH already carrying the stand-in.
# shellcheck disable=SC2016 # the single-quoted shim expands its own argument
printf '#!/bin/sh\n[ "${1:-}" = get ] || exit 0\ncd "%s" && exec /bin/bash --noprofile --norc\n' "$WT" > "$LAB/bin/treehouse"
printf '#!/bin/sh\nexec /bin/bash --noprofile --norc "$@"\n' > "$LAB/bin/lab-shell"
chmod +x "$LAB/bin/treehouse" "$LAB/bin/lab-shell"
export PATH="$LAB/bin:$PATH" SHELL="$LAB/bin/lab-shell" FM_HOME="$H"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null || fail "could not provision the isolated Herdr lab session"
export HERDR_SESSION="$HERDR_LAB_SESSION"
# Prove a lab pane resolves the stand-in before any spawn can type
# `treehouse get` into one.
probe=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create --cwd "$LAB" --label probe --no-focus \
  | jq -r '.result.root_pane.pane_id // empty') || probe=
[ -n "$probe" ] || fail "could not open a probe pane in the lab"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-text "$probe" 'command -v treehouse' >/dev/null \
  || fail "could not type into the probe pane"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$probe" Enter >/dev/null \
  || fail "could not submit in the probe pane"
resolved=
for _ in $(seq 1 20); do
  resolved=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$probe" 2>/dev/null | grep -F '/treehouse' | tail -n 1)
  [ -z "$resolved" ] || break
  sleep 0.5
done
[ "$resolved" = "$LAB/bin/treehouse" ] || fail "a lab pane resolves treehouse to '${resolved:-nothing}', not the stand-in; refusing to spawn into a real pool"

META="$H/state/$ID.meta"
meta_value() { fm_jcode_meta_value "$META" "$1"; }
record() { fm_busy_record_read "$H/state" "$ID" 2>/dev/null || true; }
api() { fm_jcode_with_meta_env "$META" node "$ROOT/bin/fm-jcode-api.mjs" "$@"; }
wait_file() {
  local path=$1 i
  for i in $(seq 1 480); do [ -s "$path" ] && return 0; sleep 0.5; done
  fail "timed out waiting for ${path##*/}"
}
wait_record() {  # <prefix> <what>
  local i
  for i in $(seq 1 360); do
    case "$(record)" in "$1"*) return 0 ;; esac
    sleep 0.5
  done
  fail "$2 (last record '$(record)')"
}

model_args=()
[ -z "${FM_JCODE_LIVE_MODEL:-}" ] || model_args=(--model "$FM_JCODE_LIVE_MODEL")
FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJ" --scout --harness jcode --backend herdr \
  ${model_args[@]+"${model_args[@]}"} --effort low > "$LAB/spawn.log" 2>&1 \
  || fail "fm-spawn's generated jcode launch failed: $(cat "$LAB/spawn.log")"
TARGET=$(meta_value window)
SESSION1=$(meta_value jcode_session)
[ -n "$TARGET" ] && [ -n "$SESSION1" ] || fail "the spawn did not record the endpoint and the jcode session"
[ "$(meta_value worktree)" = "$WT" ] || fail "the spawn recorded worktree '$(meta_value worktree)', not the prepared clone"
[ "$(meta_value jcode_home)" = "$JH" ] && [ "$(meta_value jcode_socket)" = "$JH/run/jcode.sock" ] \
  || fail "the spawn did not record the daemon selection that reaches the session"
[ "$(fm_backend_agent_state herdr "$TARGET")" = alive ] || fail "the herdr backend does not classify the spawned jcode worker alive"
CLIENT1=$(fm_jcode_client_pid "$SESSION1" "$JH") || fail "no jcode client is proven attached to the recorded session"
pass "$VERSION: the spawn creates the session through the API and attaches client $CLIENT1 in the pane"

wait_file "$WT/answer.txt"
wait_file "$WT/harness.txt"
[ "$(tr -d '[:space:]' < "$WT/answer.txt")" = 80235 ] || fail "the launch brief did not execute"
[ "$(tr -d '[:space:]' < "$WT/harness.txt")" = jcode ] \
  || fail "fm-harness.sh did not detect jcode from a real tool subprocess (got '$(cat "$WT/harness.txt")')"
pass "$VERSION: the API-delivered brief ran in the worktree and fm-harness.sh detects jcode from a tool subprocess"
wait_record "idle jcode-hook " "the finished brief turn never closed the busy record through turn_end"
[ -f "$H/state/$ID.turn-ended" ] || fail "turn_end never touched the turn-ended marker"
pass "$VERSION: turn_start opened and turn_end closed the busy record, and the turn-ended marker was touched"
# The brief turn saved the session with the effort and model it ran under. A
# second connection's attach-time report is not used here: while the pane's
# client holds the session it carries the daemon's default effort.
pinned=$(jq -r '"model=\(.model) effort=\(.reasoning_effort)"' "$JH/sessions/$SESSION1.json" 2>/dev/null) \
  || fail "the session record $JH/sessions/$SESSION1.json is unreadable"
case "$pinned" in *" effort=low") ;; *) fail "the brief turn did not run under the low effort pin (got '$pinned')" ;; esac
[ -z "${FM_JCODE_LIVE_MODEL:-}" ] || case "$pinned" in "model=$FM_JCODE_LIVE_MODEL "*) ;; *) fail "the brief turn did not run under the model pin (got '$pinned')" ;; esac
pass "$VERSION: the brief turn ran under the pinned $pinned"

"$ROOT/bin/fm-send.sh" "$ID" "Read the message in $H/state/$ID.inbox, acknowledge it by moving it into the handled/ subdirectory, then write steered into steer.txt. Complete that work and end the turn." \
  > "$LAB/send.log" 2>&1 || fail "fm-send could not steer the worker: $(cat "$LAB/send.log")"
wait_file "$WT/steer.txt"
wait_record "idle jcode-hook " "the acknowledgement turn did not finish"
handled=$(find "$H/state/$ID.inbox/handled" -name '*.msg' -print | wc -l | tr -d ' ')
[ "$handled" -gt 0 ] || fail "the durable steer was not acknowledged"
pass "$VERSION: fm-send's doorbell reaches the jcode TUI, and the durable message is read, acted on, and acknowledged"

"$ROOT/bin/fm-send.sh" "$ID" 'Runtime interrupt verification: run sleep 90 in your shell tool in the foreground and wait for it to finish. Do not respond before it finishes.' \
  > "$LAB/send-interrupt.log" 2>&1 || fail "fm-send could not start the interrupt turn"
wait_record "busy jcode-hook " "the interrupt turn never opened the busy record"
sleep 5
"$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/interrupt.log" 2>&1 \
  || fail "fm-control interrupt failed: $(cat "$LAB/interrupt.log")"
grep -q 'cancel=cancelled' "$LAB/interrupt.log" \
  || fail "fm-control interrupt did not report a finished cancel: $(cat "$LAB/interrupt.log")"
wait_record "idle jcode-hook " "the cancelled turn never closed the busy record"
[ "$(fm_backend_agent_state herdr "$TARGET")" = alive ] || fail "the interrupt stopped the worker instead of its turn"
pass "$VERSION: fm-control interrupt cancels the running turn through the API, turn_end closes it, and the worker stays up"

"$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/exit.log" 2>&1 || fail "fm-control exit failed: $(cat "$LAB/exit.log")"
grep -q 'stopped' "$LAB/exit.log" || fail "fm-control exit did not report the worker stopped: $(cat "$LAB/exit.log")"
[ "$(fm_backend_agent_state herdr "$TARGET")" = dead ] || fail "the pane still holds a jcode client after exit"
! fm_jcode_client_pid "$SESSION1" "$JH" >/dev/null || fail "a client is still attached to the session after exit"
api session-exists "$SESSION1" || fail "exit must leave the session in the daemon"
pass "$VERSION: fm-control exit stops the pane's client, leaving the endpoint, worktree, and session"

rm -f "$WT/answer.txt" "$WT/harness.txt"
"$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'Relaunch verification: redo the task in the brief exactly once.' \
  > "$LAB/relaunch.log" 2>&1 || fail "fm-control relaunch failed: $(cat "$LAB/relaunch.log")"
SESSION2=$(meta_value jcode_session)
[ -n "$SESSION2" ] && [ "$SESSION2" != "$SESSION1" ] || fail "relaunch did not record a fresh session (got '$SESSION2')"
[ "$(meta_value window)" = "$TARGET" ] || fail "relaunch moved the task off its endpoint"
wait_file "$WT/answer.txt"
[ "$(tr -d '[:space:]' < "$WT/answer.txt")" = 80235 ] || fail "the relaunched worker did not run the brief"
wait_record "idle jcode-hook " "the relaunched turn did not finish"
"$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/exit2.log" 2>&1 || fail "the final exit failed: $(cat "$LAB/exit2.log")"
pass "$VERSION: fm-control relaunch starts a fresh session in the same worktree and endpoint, and it runs the brief"

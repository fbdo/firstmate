#!/usr/bin/env bash
# Credentialed jcode secondmate guard. Opt in with FM_JCODE_SECONDMATE_LIVE=1 (spends tokens).
# Proves the Phase 4 shape end to end: a jcode secondmate is a pane-attached session on one
# daemon with the mate home as its working directory, its lock anchors on its own TUI
# client, the parent's hook dispatcher delegates the mate's events to the mate's own
# dispatcher (seatbelt deny reaches the mate), a marked request gets a correlated reply on
# the parent channel, and killing the mate's client leads to a fresh session with the old
# one archived. Also asserts the native-worker viewer (bin/fm-jcode-viewer.sh) attaches a
# real client and that closing it never affects the session.
#
# Lab only: a PRIVATE test daemon (JCODE_HOME/JCODE_RUNTIME_DIR/JCODE_SOCKET under a temp
# dir, credentials linked, hooks via `fm-jcode-setup.sh env`) stopped in the EXIT trap, and
# a named Herdr lab session through bin/fm-herdr-lab.sh (never `default`). The operational
# design stays one shared daemon. FM_JCODE_LIVE_MODEL pins a listed model (default
# claude-sonnet-5-5); effort is low. Each wait is under 5 minutes.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate opt-in FM_JCODE_SECONDMATE_LIVE jcode herdr node jq git

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-jcode-lib.sh
. "$ROOT/bin/fm-jcode-lib.sh"

MODEL=${FM_JCODE_LIVE_MODEL:-claude-sonnet-5-5}
VERSION=$(jcode --version 2>/dev/null | head -n 1 || echo unknown)
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=
LAB=
JH=
ID=jcmate

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

fail() {
  local keep=${FM_JCODE_LIVE_EVIDENCE:-}
  if [ -n "$keep" ] && [ -n "$LAB" ]; then
    mkdir -p "$keep"
    cp -R "$JH/sessions" "$JH/logs" "$H/state" "$MATE/state" "$keep/" 2>/dev/null
    cp "$LAB"/*.log "$keep/" 2>/dev/null
  fi
  printf 'not ok - %s: %s\n' "$VERSION" "$1" >&2
  exit 1
}
note() { printf 'ok - %s: %s\n' "$VERSION" "$1"; }

[ -d /proc/self ] || fail "this guard stops its private daemon through /proc and runs on Linux only"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-jcode-sm.XXXXXX") || fail "could not create the lab"
LAB=$(cd "$LAB" && pwd -P)
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name jcode-sm) || fail "could not name the Herdr lab session"
trap cleanup EXIT

H="$LAB/main"
MATE="$LAB/mate"
JH="$LAB/jhome"
git clone -q "$ROOT" "$H" || fail "could not clone the code under test"
git -C "$H" checkout -q -B lab HEAD 2>/dev/null
# The clone carries the committed tree only; overlay the working tree under test.
(cd "$ROOT" && git ls-files -z -m -o --exclude-standard | xargs -0 -I{} cp --parents {} "$H/" 2>/dev/null)
mkdir -p "$H/state" "$H/data" "$H/config" "$H/projects"
touch "$H/state/.last-watcher-beat"
printf 'herdr\n' > "$H/config/backend"
printf 'manual\n' > "$H/config/backlog-backend"
printf 'off\n' > "$H/config/herdr-presentation-spaces"
printf 'jcode %s low\n' "$MODEL" > "$H/config/secondmate-harness"

mkdir -p "$JH/run" "$JH/config/jcode" "$LAB/bin"
for cred in "$HOME/.jcode/auth.json" "$HOME"/.jcode/*_oauth.json; do
  [ -f "$cred" ] && ln -s "$cred" "$JH/${cred##*/}"
done
for env_file in "${XDG_CONFIG_HOME:-$HOME/.config}"/jcode/*.env; do
  [ -f "$env_file" ] && ln -s "$env_file" "$JH/config/jcode/${env_file##*/}"
done
[ ! -f "$HOME/.jcode/config.toml" ] || cp "$HOME/.jcode/config.toml" "$JH/config.toml"
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE JCODE_SESSION_ID
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH TMUX
export JCODE_HOME="$JH" JCODE_RUNTIME_DIR="$JH/run" JCODE_SOCKET="$JH/run/jcode.sock" JCODE_NO_AUTO_UPDATE=1
export JCODE_HOOK_PRE_TOOL='' JCODE_HOOK_POST_TOOL='' JCODE_HOOK_POST_TOOL_FEEDBACK='' JCODE_HOOK_PRE_TOOL_TRANSFORM=''
export JCODE_HOOK_SESSION_START='' JCODE_HOOK_SESSION_END=''
# The daemon's hooks name the MAIN lab home's dispatcher only; the mate is reached by delegation.
eval "$(FM_HOME="$H" "$H/bin/fm-jcode-setup.sh" env)" || fail "could not read the hook registration"
env -u FM_HOME nohup jcode --quiet --no-update serve --socket "$JCODE_SOCKET" > "$LAB/serve.log" 2>&1 &
for _ in $(seq 1 60); do [ -S "$JCODE_SOCKET" ] && break; sleep 0.25; done
[ -S "$JCODE_SOCKET" ] || fail "the private jcode daemon did not come up: $(tail -n 3 "$LAB/serve.log")"
note "private daemon is up"

"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null || fail "could not provision the isolated Herdr lab session"
export HERDR_SESSION="$HERDR_LAB_SESSION" FM_HOME="$H" FM_BACKEND=herdr

# --- 1. seed a local lab secondmate (no projects) ---------------------------------
FM_SECONDMATE_CHARTER='Lab charter. You are idle by default. When a marked request arrives, answer it with bin/fm-secondmate-report.sh on your parent channel.' \
  "$H/bin/fm-home-seed.sh" "$ID" "$MATE" --no-projects > "$LAB/seed.log" 2>&1 || fail "seed failed: $(cat "$LAB/seed.log")"
MATE=$(cd "$MATE" && pwd -P)
touch "$MATE/state/.last-watcher-beat"
[ -f "$MATE/.fm-secondmate-home" ] || fail "the mate home carries no marker"
note "seeded the lab secondmate home"

# --- 2. spawn ----------------------------------------------------------------------
FM_SPAWN_NO_GUARD=1 FM_JCODE_READY_POLLS=480 FM_JCODE_POLL_INTERVAL=0.5 \
  "$H/bin/fm-spawn.sh" "$ID" "$MATE" --secondmate > "$LAB/spawn.log" 2>&1 \
  || fail "fm-spawn --secondmate failed: $(tail -n 5 "$LAB/spawn.log")"
META="$H/state/$ID.meta"
meta_value() { fm_jcode_meta_value "$META" "$1"; }
SESSION1=$(meta_value jcode_session)
[ "$(meta_value kind)" = secondmate ] && [ "$(meta_value harness)" = jcode ] || fail "meta does not record a jcode secondmate"
[ -n "$SESSION1" ] || fail "no jcode session recorded"
[ "$(jq -r '.working_dir // empty' "$JH/sessions/$SESSION1.json" 2>/dev/null)" = "$MATE" ] || fail "the session's working directory is not the mate home"
CLIENT1=$(fm_jcode_client_pid "$SESSION1" "$JH") || fail "no TUI client is attached to the mate session"
case "$(fm_busy_record_read "$H/state" "$ID" 2>/dev/null)" in *" jcode-hook "*) ;; *) fail "no jcode-hook busy record for the mate" ;; esac
note "step 2: the mate session $SESSION1 runs in $MATE with client $CLIENT1 and a main busy record"

wait_for() {  # <what> <command...>
  local what=$1 i
  shift
  for i in $(seq 1 540); do "$@" 2>/dev/null && return 0; sleep 0.5; done
  fail "timed out waiting for $what"
}
transcript_has() { grep -rqF -- "$1" "$JH/sessions" 2>/dev/null; }

# --- 3. the mate's own lock -----------------------------------------------------------
lock_ok() {
  [ "$(tr -d '[:space:]' < "$MATE/state/.lock")" = "$CLIENT1" ] && [ "$(tr -d '[:space:]' < "$MATE/state/.lock-session")" = "$SESSION1" ]
}
wait_for "the mate to take its own session lock (state/.lock names its client pid and session)" lock_ok
note "step 3: the mate's lock anchors on its TUI client $CLIENT1 and session $SESSION1"
if transcript_has "primary harness: jcode"; then note "step 3: the mate's session start reported primary harness: jcode"; fi

# --- 4. delegated seatbelt --------------------------------------------------------------
mate_idle() { case "$(fm_busy_record_read "$H/state" "$ID" 2>/dev/null)" in "idle "*) return 0 ;; esac; return 1; }
wait_for "the mate's first turn to finish" mate_idle
sent=0
for _ in 1 2 3 4 5; do
  if printf 'Run this exact command with your bash tool once and report what happened: bash %s/bin/fm-watch.sh' "$MATE" \
    | node "$ROOT/bin/fm-jcode-api.mjs" send "$SESSION1" > /dev/null 2>&1; then sent=1; break; fi
  sleep 3
done
[ "$sent" = 1 ] || fail "could not send the seatbelt probe"
wait_for "the delegated seatbelt deny to reach the mate" transcript_has "[watcher-"
note "step 4: the mate's own dispatcher denied a watcher run through its delegated pre_tool seatbelt"

# --- 5. marked request and correlated reply ------------------------------------------------
"$H/bin/fm-send.sh" "$ID" "Please reply to this request: report the word PONG." > "$LAB/send.log" 2>&1 \
  || fail "fm-send to the mate failed: $(cat "$LAB/send.log")"
CORR=$(ls "$H/state/pending-replies" 2>/dev/null | head -n 1)
[ -n "$CORR" ] || fail "no pending-reply record was created"
reply_on_channel() { grep -q "corr=$CORR" "$H/state/$ID.status" 2>/dev/null; }
wait_for "the correlated reply on the parent channel" reply_on_channel
(
  # shellcheck source=bin/fm-pending-reply-lib.sh
  . "$ROOT/bin/fm-pending-reply-lib.sh"
  fm_pending_reply_try_resolve "$H/state" "$CORR"
) >/dev/null 2>&1
grep -q '^phase=resolved' "$H/state/pending-replies/$CORR" || fail "the pending-reply record is not resolved"
note "step 5: the marked request got a correlated reply on the parent channel and the record resolved"

# --- 6. kill the client; recovery gives a fresh session ----------------------------------------
kill "$CLIENT1" 2>/dev/null
for _ in $(seq 1 40); do kill -0 "$CLIENT1" 2>/dev/null || break; sleep 0.25; done
(
  cd "$H" || exit 1
  # shellcheck source=bin/fm-secondmate-liveness-lib.sh
  . "$H/bin/fm-secondmate-liveness-lib.sh"
  STATE="$H/state" FM_ROOT="$H"
  fm_secondmate_liveness_probe "$META" "$ID" full
  [ "$FM_SM_LIVE_STATUS" = relaunchable ] || { echo "probe: $FM_SM_LIVE_STATUS $FM_SM_LIVE_REASON" >&2; exit 1; }
  FM_SPAWN_NO_GUARD=1 FM_JCODE_READY_POLLS=480 FM_JCODE_POLL_INTERVAL=0.5 fm_secondmate_liveness_relaunch "$META" "$ID"
) > "$LAB/relaunch.log" 2>&1 || fail "liveness relaunch failed: $(tail -n 5 "$LAB/relaunch.log")"
SESSION2=$(meta_value jcode_session)
[ -n "$SESSION2" ] && [ "$SESSION2" != "$SESSION1" ] || fail "recovery did not bind a fresh session (got '$SESSION2')"
fm_jcode_client_pid "$SESSION2" "$JH" > /dev/null || fail "no client attached to the fresh session"
if node "$ROOT/bin/fm-jcode-api.mjs" session-exists "$SESSION1"; then fail "the previous session was not archived"; fi
grep -q 'relaunched' "$H/state/.secondmate-relaunch-$ID" || fail "the relaunch ledger has no relaunched line"
note "step 6: a killed client led to fresh session $SESSION2 and the old session was archived"

# --- viewer: a real client attaches, and closing it never affects the session ------------------
VWT="$LAB/vwt"
mkdir -p "$VWT"
git -C "$VWT" init -q
VSID=$(FM_JCODE_API_ALLOW_DEFAULT_MODEL=1 node "$ROOT/bin/fm-jcode-api.mjs" create "$VWT" --note "viewer live assertion") || fail "could not create the viewer probe session"
printf 'session=%s\ngen=1\nworktree=%s\n' "$VSID" "$VWT" > "$H/state/vw.jcode-session"
printf 'window=jcode:%s\nbackend=jcode\nharness=jcode\nworktree=%s\njcode_session=%s\njcode_socket=%s\n' "$VSID" "$VWT" "$VSID" "$JCODE_SOCKET" > "$H/state/vw.meta"
"$H/bin/fm-jcode-viewer.sh" open vw > "$LAB/viewer.log" 2>&1 || true
[ -f "$H/state/vw.jcode-viewer" ] || fail "the viewer was not opened: $(cat "$LAB/viewer.log")"
VCLIENT=
for _ in $(seq 1 60); do VCLIENT=$(fm_jcode_client_pid "$VSID" "$JH") && break; sleep 0.5; done
[ -n "$VCLIENT" ] || fail "no client attached through the viewer pane"
# P5-B1 build check: with a TUI client holding the session, memory off set over one
# API connection still reads off from a second one after the first has closed.
node "$ROOT/bin/fm-jcode-api.mjs" runtime "$VSID" memory off > /dev/null 2>&1 || fail "memory off was refused"
mem=$(node "$ROOT/bin/fm-jcode-api.mjs" runtime "$VSID" memory status 2>/dev/null) || mem=
case "$mem" in *'"enabled":false'*) note "pane memory: off persists across API connections while the TUI client holds the session" ;; *) fail "pane memory off did not persist (got '$mem')" ;; esac
"$H/bin/fm-jcode-viewer.sh" close vw || fail "viewer close failed"
for _ in $(seq 1 40); do kill -0 "$VCLIENT" 2>/dev/null || break; sleep 0.25; done
kill -0 "$VCLIENT" 2>/dev/null && fail "the viewer client survived its close"
node "$ROOT/bin/fm-jcode-api.mjs" session-exists "$VSID" || fail "closing the viewer affected the session"
node "$ROOT/bin/fm-jcode-api.mjs" archive "$VSID" > /dev/null 2>&1
note "viewer: pane client $VCLIENT attached to the session, close detached it, and the session was untouched"

# --- 7. cleanup ---------------------------------------------------------------------------------
for s in "$SESSION1" "$SESSION2"; do node "$ROOT/bin/fm-jcode-api.mjs" archive "$s" > /dev/null 2>&1; done
note "step 7: lab sessions archived; the private daemon and Herdr lab stop in the exit trap"

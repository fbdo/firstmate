#!/usr/bin/env bash
# Credentialed native jcode backend guard. Opt in with FM_JCODE_NATIVE_LIVE=1 (spends tokens).
# Drives the real Firstmate verbs on an isolated lab FM_HOME against the captain's SHARED
# jcode daemon: fm-spawn (backend=jcode), fm-send, fm-control, the keeper, and the
# teardown kill arm. It only ever creates sessions titled fm:fmlive-*, archives every
# one of them (and their children) in an EXIT trap, and never starts, stops, or reloads
# the daemon, sets swarm labels, or edits ~/.jcode/config.toml (the spawn's hook
# registration check reads a throwaway config through FM_JCODE_CONFIG instead).
# FM_JCODE_LIVE_MODEL optionally pins a listed model (default claude-sonnet-5-5); effort is low.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate opt-in FM_JCODE_NATIVE_LIVE jcode node git treehouse

MODEL=${FM_JCODE_LIVE_MODEL:-claude-sonnet-5-5}
VERSION=$(jcode --version 2>/dev/null | head -n 1 || echo unknown)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-jcode-native-live.XXXXXX") || fail "could not create the lab"
LAB=$(cd "$LAB" && pwd -P)
H="$LAB/fm"
PROJ="$LAB/project"
ID=fmlive-1
STATE="$H/state"
SIDS=()
WTS=()

api() { node "$ROOT/bin/fm-jcode-api.mjs" --socket "$(sed -n 's/^jcode_api_socket=//p' "$STATE/$ID.meta")" "$@"; }
note() { printf 'ok - %s: %s\n' "$VERSION" "$1"; }
fail() {
  printf 'not ok - %s: %s\n' "$VERSION" "$1" >&2
  [ -z "${FM_JCODE_LIVE_EVIDENCE:-}" ] || { mkdir -p "$FM_JCODE_LIVE_EVIDENCE"; cp -R "$STATE" "$FM_JCODE_LIVE_EVIDENCE/" 2>/dev/null; }
  exit 1
}

cleanup() {
  local sid kid wt sock
  sock=$(sed -n 's/^jcode_api_socket=//p' "$STATE/$ID.meta" 2>/dev/null)
  if [ -n "$sock" ] && [ -S "$sock" ]; then
    for sid in $(sed -n 's/^session=//p' "$STATE"/*.jcode-session 2>/dev/null) "${SIDS[@]}"; do
      case "$sid" in session_*) ;; *) continue ;; esac
      for kid in $(node "$ROOT/bin/fm-jcode-api.mjs" --socket "$sock" children "$sid" 2>/dev/null | cut -f1) \
        $(cut -f1 "$STATE"/*.jcode-children 2>/dev/null); do
        node "$ROOT/bin/fm-jcode-api.mjs" --socket "$sock" cancel "$kid" >/dev/null 2>&1
        node "$ROOT/bin/fm-jcode-api.mjs" --socket "$sock" archive "$kid" >/dev/null 2>&1
      done
      node "$ROOT/bin/fm-jcode-api.mjs" --socket "$sock" cancel "$sid" >/dev/null 2>&1
      node "$ROOT/bin/fm-jcode-api.mjs" --socket "$sock" archive "$sid" >/dev/null 2>&1
    done
  fi
  FM_HOME="$H" "$ROOT/bin/fm-jcode-keeper.sh" stop >/dev/null 2>&1
  for wt in "${WTS[@]}"; do [ -z "$wt" ] || (cd "$PROJ" && treehouse return --force "$wt" >/dev/null 2>&1); done
  find "$LAB" -type d -exec chmod u+rwx {} + 2>/dev/null
  rm -rf -- "$LAB"
}
trap cleanup EXIT

mkdir -p "$H/data/$ID" "$H/state" "$H/config" "$H/projects" "$PROJ"
git -C "$PROJ" init -q && git -C "$PROJ" -c user.email=a@b -c user.name=n commit -q --allow-empty -m init
printf 'jcode\n' >"$H/config/crew-harness"
printf 'native\n' >"$H/config/jcode-runtime"
touch "$STATE/.last-watcher-beat"
"$ROOT/bin/fm-jcode-setup.sh" print | grep -v '^#' >"$LAB/hooks.toml"
cat >"$H/data/$ID/brief.md" <<EOF
# Task
## Captain's intent
Live native backend guard.

## Firstmate spec
Run these steps with your shell tool, in order, and nothing else:
1. echo "working [at=\$(date +%s)]: started" >> '$STATE/$ID.status'
2. sleep 20
3. echo "done [at=\$(date +%s)]: finished" >> '$STATE/$ID.status'
Do not use any other tool. Do not start subagents.
EOF

run_fm() {  # <script> <args...>
  local s=$1
  shift
  env -u JCODE_SESSION_ID -u JCODE_HOME -u FM_BACKEND -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$H" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$H/data" FM_CONFIG_OVERRIDE="$H/config" \
    FM_PROJECTS_OVERRIDE="$H/projects" FM_SPAWN_NO_GUARD=1 FM_JCODE_CONFIG="$LAB/hooks.toml" \
    FM_JCODE_READY_POLLS=240 FM_CONTROL_EXIT_WAIT=60 \
    "$ROOT/bin/$s" "$@" 2>&1
}

out=$(run_fm fm-spawn.sh "$ID" "$PROJ" --harness jcode --mode local-only --yolo off --model "$MODEL" --effort low) \
  || fail "spawn failed: $out"
SID=$(sed -n 's/^jcode_session=//p' "$STATE/$ID.meta")
SIDS+=("$SID")
WT=$(sed -n 's/^worktree=//p' "$STATE/$ID.meta")
WTS+=("$WT")
grep -q '^backend=jcode' "$STATE/$ID.meta" || fail "meta must record backend=jcode"
[ -f "$STATE/jcode/live/$SID" ] || fail "the keeper must hold the session"
note "spawned $SID on the shared daemon and the keeper attached"
node "$ROOT/bin/fm-jcode-api.mjs" --socket "$(sed -n 's/^jcode_api_socket=//p' "$STATE/$ID.meta")" history "$SID" --lines 400 >/dev/null || fail "history must read"
mem=$(api runtime "$SID" memory status 2>/dev/null) && case "$mem" in *'"enabled":false'*) note "memory is off for the worker" ;; *) fail "memory must be off, got $mem" ;; esac

# Busy opens through the keeper.
for _ in $(seq 1 60); do grep -q '^busy' "$STATE/jcode/live/$SID" && break; sleep 2; done
grep -q '^busy' "$STATE/jcode/live/$SID" || grep -q . "$STATE/jcode/transitions" || fail "the keeper never recorded the brief turn"
note "the keeper recorded the brief turn"

# Steer while busy.
out=$(run_fm fm-send.sh "$ID" "Steering check: after your current step, append one working line saying steered to $STATE/$ID.status.") || fail "fm-send failed: $out"
for _ in $(seq 1 30); do grep -q " fm-$ID-" "$STATE/jcode/injected/$SID" 2>/dev/null && break; sleep 2; done
grep -q " fm-$ID-" "$STATE/jcode/injected/$SID" || fail "the keeper must record the injected steer"
note "fm-send steer was injected and recorded"

# Interrupt during the sleep.
sleep 5
out=$(run_fm fm-control.sh "$ID" interrupt) || fail "interrupt failed: $out"
note "fm-control interrupt: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)"

# Crash recovery: kill the keeper during a fresh turn, then ensure restarts it.
printf 'Run `sleep 15` with your shell tool, then append "done [at=1]: recovered" to %s/%s.status.' "$STATE" "$ID" | api send "$SID" || fail "send failed"
sleep 4
kill "$(cat "$STATE/jcode/keeper.pid")" 2>/dev/null
sleep 3
FM_HOME="$H" "$ROOT/bin/fm-jcode-keeper.sh" ensure >/dev/null || fail "ensure must restart the keeper"
for _ in $(seq 1 60); do [ -s "$STATE/jcode/recovered/$SID" ] && break; sleep 2; done
note "keeper restarted via ensure (recovery marker present: $([ -s "$STATE/jcode/recovered/$SID" ] && echo yes || echo no))"

# Bridge kill, then ensure restores it.
bpid=$(cat "$(FM_HOME="$H" "$ROOT/bin/fm-jcode-keeper.sh" env | sed -n 's/^export FM_JCODE_RUN=//p' | tr -d "'")/bridge.pid")
kill "$bpid" 2>/dev/null
sleep 1
FM_HOME="$H" "$ROOT/bin/fm-jcode-keeper.sh" ensure >/dev/null || fail "ensure must restore the bridge"
api exists "$SID" || fail "the session must still be reachable after the bridge restart"
note "bridge kill: ensure restored it"

# One subagent in the worker's own worktree.
printf 'Start exactly one subagent with your swarm tool whose task is to run `pwd` and report it. Wait for it with await_members, stop it, then append "working [at=1]: sub done" to %s/%s.status.' "$STATE" "$ID" | api send "$SID" || fail "send failed"
for _ in $(seq 1 90); do [ -s "$STATE/$ID.jcode-children" ] && break; sleep 2; done
if [ -s "$STATE/$ID.jcode-children" ]; then
  child_dir=$(cut -f3 "$STATE/$ID.jcode-children" | head -n 1)
  [ "$(readlink -f "$child_dir")" = "$(readlink -f "$WT")" ] || fail "the child must work in the worker's worktree, got $child_dir"
  note "a worker subagent was recorded inside the task worktree"
else
  note "the worker chose not to start a subagent in the allotted time (child record absent)"
fi

# Teardown kill arm: children first, then the worker.
( cd "$ROOT" && FM_HOME="$H" FM_STATE_OVERRIDE="$STATE" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_kill jcode "jcode:$1"' "$ROOT" "$SID" ) || fail "the teardown kill arm failed"
api session-exists "$SID" && fail "the worker must be archived after the kill arm"
note "teardown arm archived the worker and its children"

FM_HOME="$H" "$ROOT/bin/fm-jcode-keeper.sh" stop >/dev/null
run=$(FM_HOME="$H" "$ROOT/bin/fm-jcode-keeper.sh" env | sed -n 's/^export JCODE_API_SOCKET=//p' | tr -d "'")
if [ -n "$run" ] && pgrep -f -- "$run" >/dev/null 2>&1; then fail "no process may still carry the lab api socket"; fi
note "keeper stop left no lab process"

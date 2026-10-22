#!/usr/bin/env bash
# fm-jcode-keeper.sh - the single owner of this home's jcode bridge and keeper.
#
# The native jcode backend runs workers on the captain's one shared jcode
# daemon. Firstmate never starts, stops, or reloads that daemon. What each home
# owns is a small API bridge (`jcode api-bridge --api-socket`, forwarding to the
# shared daemon's socket) and one keeper client (bin/fm-jcode-keeper.mjs) that
# stays attached to every bound worker session, so a worker's turn is retained
# and its busy/idle events reach firstmate's records.
#
# Usage:
#   fm-jcode-keeper.sh env                  print `export` lines for the paths
#   fm-jcode-keeper.sh ensure [--no-keeper] [--from-keeper]
#                                           make the bridge (and keeper) ready;
#                                           print `ready` or exit 1 naming the
#                                           failed component. --from-keeper
#                                           restarts only the bridge.
#   fm-jcode-keeper.sh status               print daemon/bridge/keeper state;
#                                           exit 0 only when all three are up
#   fm-jcode-keeper.sh stop                 stop this home's keeper and bridge
#                                           only; never the daemon
#   fm-jcode-keeper.sh attach-cmd <task-id> print the command that opens a TUI
#                                           on the task's session
#
# Paths: FM_JCODE_RUN = ${XDG_RUNTIME_DIR:-/tmp}/fm-jcode-<12 hex of the sha256
# of the realpath of FM_HOME> (0700, short enough for a socket path), holding
# api.sock, bridge.pid and bridge.log. Keeper files live in
# $FM_HOME/state/jcode/. The shared daemon socket is JCODE_SOCKET, default
# ${XDG_RUNTIME_DIR:-/tmp}/jcode.sock. FM_JCODE_BIN names the jcode binary.
#
# Exit codes: 0 ok, 1 a component is not ready, 2 usage.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

die() {
  echo "fm-jcode-keeper: $*" >&2
  exit "${2:-1}"
}

[ -n "${FM_HOME:-}" ] && [ -d "$FM_HOME" ] || die "FM_HOME must name the firstmate home" 2
HOME_REAL=$(CDPATH='' cd -- "$FM_HOME" && pwd -P)
STATE_DIR="$HOME_REAL/state"
JSTATE="$STATE_DIR/jcode"
HASH=$(printf '%s' "$HOME_REAL" | sha256sum 2>/dev/null | cut -c1-12)
[ -n "$HASH" ] || HASH=$(printf '%s' "$HOME_REAL" | shasum -a 256 | cut -c1-12)
RUN_BASE=${XDG_RUNTIME_DIR:-/tmp}
FM_JCODE_RUN="$RUN_BASE/fm-jcode-$HASH"
API_SOCK="$FM_JCODE_RUN/api.sock"
DAEMON_SOCK=${JCODE_SOCKET:-$RUN_BASE/jcode.sock}
JCODE_BIN=${FM_JCODE_BIN:-jcode}
KEEPER_MJS="$SCRIPT_DIR/fm-jcode-keeper.mjs"

sock_accepts() {  # <path>
  [ -S "$1" ] || return 1
  node -e '
    const c = require("node:net").createConnection(process.argv[1]);
    const t = setTimeout(() => process.exit(1), 2000);
    c.on("connect", () => { clearTimeout(t); c.destroy(); process.exit(0); });
    c.on("error", () => process.exit(1));
  ' "$1" 2>/dev/null
}

# Whether <pid> is alive and one of its argv words is exactly <word>.
pid_has_word() {  # <pid> <word>
  local pid=$1 word=$2
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -r "/proc/$pid/cmdline" ] || return 1
  tr '\0' '\n' <"/proc/$pid/cmdline" 2>/dev/null | grep -Fxq -- "$word"
}

read_pid() {  # <file>
  local pid=''
  [ -f "$1" ] && IFS= read -r pid <"$1"
  printf '%s' "$pid"
}

bridge_pid() {
  local pid
  pid=$(read_pid "$FM_JCODE_RUN/bridge.pid")
  pid_has_word "$pid" "$API_SOCK" && printf '%s' "$pid"
}

keeper_pid() {
  local pid
  pid=$(read_pid "$JSTATE/keeper.pid")
  pid_has_word "$pid" "$KEEPER_MJS" && printf '%s' "$pid"
}

keeper_beat_fresh() {
  local m now
  m=$(stat -c %Y "$JSTATE/keeper.beat" 2>/dev/null) || return 1
  now=$(date +%s)
  [ $((now - m)) -le "${FM_JCODE_KEEPER_BEAT_MAX:-15}" ]
}

prepare_run_dir() {
  if [ -L "$FM_JCODE_RUN" ]; then die "$FM_JCODE_RUN is a symlink; refusing"; fi
  if ! { mkdir -p "$FM_JCODE_RUN" && chmod 700 "$FM_JCODE_RUN"; }; then die "cannot create $FM_JCODE_RUN"; fi
  mkdir -p "$JSTATE" || die "cannot create $JSTATE"
}

LOCK_DIR=
acquire_lock() {
  local i=0 holder
  LOCK_DIR="$JSTATE/ensure.lock.d"
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    holder=$(read_pid "$LOCK_DIR/pid")
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      rm -rf "$LOCK_DIR"
      continue
    fi
    i=$((i + 1))
    [ "$i" -le 300 ] || die "another ensure holds $LOCK_DIR"
    sleep 0.1
  done
  printf '%s\n' "$$" >"$LOCK_DIR/pid"
  trap 'rm -rf "$LOCK_DIR"' EXIT
}

# The environment the bridge and keeper run with: an allowlist, so a stray
# JCODE_ACTIVE_PROVIDER or JCODE_SESSION_ID from the caller never leaks in.
child_env() {
  local v
  printf '%s\0' "FM_HOME=$HOME_REAL" "JCODE_SOCKET=$DAEMON_SOCK" "JCODE_API_SOCKET=$API_SOCK"
  for v in HOME PATH USER LANG TERM XDG_RUNTIME_DIR; do
    [ -z "${!v:-}" ] || printf '%s\0' "$v=${!v}"
  done
  for v in ${FM_JCODE_CHILD_ENV_PASS:-}; do
    [ -z "${!v:-}" ] || printf '%s\0' "$v=${!v}"
  done
}

start_detached() {  # <logfile> <pidfile> <cmd...>
  local log=$1 pidfile=$2 pid
  shift 2
  local -a envs=()
  while IFS= read -r -d '' pid; do envs+=("$pid"); done < <(child_env)
  env -i "${envs[@]}" setsid "$@" >>"$log" 2>&1 </dev/null &
  pid=$!
  printf '%s\n' "$pid" >"$pidfile"
}

ensure_bridge() {
  local i
  sock_accepts "$API_SOCK" && return 0
  local old
  old=$(bridge_pid) && [ -n "$old" ] && kill "$old" 2>/dev/null
  rm -f "$API_SOCK"
  start_detached "$FM_JCODE_RUN/bridge.log" "$FM_JCODE_RUN/bridge.pid" \
    "$JCODE_BIN" --quiet --no-update api-bridge --api-socket "$API_SOCK"
  for i in $(seq 1 100); do
    sock_accepts "$API_SOCK" && return 0
    sleep 0.1
  done
  return 1
}

ensure_keeper() {
  local i
  keeper_pid >/dev/null && keeper_beat_fresh && return 0
  [ -f "$KEEPER_MJS" ] || return 1
  start_detached "$JSTATE/keeper.log" "$JSTATE/keeper.pid" \
    node "$KEEPER_MJS"
  for i in $(seq 1 100); do
    keeper_pid >/dev/null && keeper_beat_fresh && return 0
    sleep 0.1
  done
  return 1
}

cmd_ensure() {
  local with_keeper=1 arg
  for arg in "$@"; do
    case "$arg" in
      --no-keeper) with_keeper=0 ;;
      --from-keeper) with_keeper=0 ;;
      *) die "unknown ensure option $arg" 2 ;;
    esac
  done
  command -v node >/dev/null 2>&1 || die "node is required"
  prepare_run_dir
  sock_accepts "$DAEMON_SOCK" || die "shared jcode daemon is not running ($DAEMON_SOCK refuses connections)"
  acquire_lock
  ensure_bridge || die "jcode API bridge did not come up (see $FM_JCODE_RUN/bridge.log)"
  if [ "$with_keeper" -eq 1 ]; then
    ensure_keeper || die "jcode keeper did not come up (see $JSTATE/keeper.log)"
  fi
  echo ready
}

cmd_status() {
  local rc=0 pid
  if sock_accepts "$DAEMON_SOCK"; then echo "daemon: up ($DAEMON_SOCK)"; else echo "daemon: down ($DAEMON_SOCK)"; rc=1; fi
  if pid=$(bridge_pid) && sock_accepts "$API_SOCK"; then echo "bridge: up pid=$pid ($API_SOCK)"; else echo "bridge: down"; rc=1; fi
  if pid=$(keeper_pid) && keeper_beat_fresh; then echo "keeper: up pid=$pid"; else echo "keeper: down"; rc=1; fi
  return "$rc"
}

cmd_stop() {
  local pid i
  if pid=$(keeper_pid) && [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null
    for i in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  fi
  rm -f "$JSTATE/keeper.pid" "$JSTATE/keeper.beat"
  if pid=$(bridge_pid) && [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null
    for i in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  fi
  rm -f "$FM_JCODE_RUN/bridge.pid" "$API_SOCK"
  rmdir "$FM_JCODE_RUN" 2>/dev/null || true
  echo stopped
}

cmd_attach() {
  local id=${1:-} rec session
  case "$id" in ''|*[!A-Za-z0-9._-]*) die "attach-cmd needs a task id" 2 ;; esac
  rec="$STATE_DIR/$id.jcode-session"
  [ -f "$rec" ] || die "no jcode session is recorded for task $id"
  session=$(awk -F= '$1 == "session" { print substr($0, 9) }' "$rec")
  [ -n "$session" ] || die "the session record for $id is empty"
  printf 'jcode --resume %s --no-update --no-selfdev\n' "$session"
}

VERB=${1:-}
[ $# -eq 0 ] || shift
case "$VERB" in
  env)
    printf 'export FM_JCODE_RUN=%q\nexport JCODE_SOCKET=%q\nexport JCODE_API_SOCKET=%q\n' "$FM_JCODE_RUN" "$DAEMON_SOCK" "$API_SOCK"
    ;;
  ensure) cmd_ensure "$@" ;;
  status) cmd_status ;;
  stop) cmd_stop ;;
  attach-cmd) cmd_attach "$@" ;;
  *) die "usage: fm-jcode-keeper.sh env|ensure|status|stop|attach-cmd <task-id>" 2 ;;
esac

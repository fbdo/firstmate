#!/usr/bin/env bash
# fm-jcode-lib.sh - the jcode crewmate/scout worker adapter library.
#
# The one owner of the jcode worker facts shared by more than one consumer:
# bin/fm-spawn.sh (session creation, brief delivery, launch readiness),
# bin/fm-control.sh (interrupt and exit), bin/fm-jcode-hook.sh (the
# session-to-task lookup behind the jcode-hook busy source), and the tests.
# .agents/skills/harness-adapters/references/harness/jcode.md owns the
# knowledge record; docs/verification/jcode.md owns the live evidence.
#
# The worker is a daemon session; the pane is only an attached TUI view of it.
# Verified on jcode v0.98.1 (2026-10-18, private daemon, Herdr lab pane):
#   - A session created through the harness API exists only in the daemon's
#     memory until it holds a message: once its creating connection closes it
#     is gone, and `jcode --resume <id>` reports no such session. A no-reply
#     message persists it without starting a turn, which is why
#     `fm-jcode-api.mjs create` stores one.
#   - The jcode TUI takes no positional prompt. `jcode --resume <id>` attaches
#     a client and the daemon records it as $JCODE_HOME/client_sessions/<pid>
#     holding the session id; that record outlives its client, so a live
#     process check is part of every read.
#   - A turn whose only attached client disconnects is abandoned with no
#     turn_end. With the TUI attached, a turn submitted by a short-lived API
#     connection survives that connection closing (the daemon logs
#     "Retaining disconnected turn ... because another client is still
#     attached"), so the brief is sent only after the client is proven attached.
#   - The model and effort set at creation persist with the session and hold
#     through the TUI's resume (a turn run afterwards saves the pinned effort
#     back). While a client holds the session, a second connection's attach
#     reports the daemon's default effort instead, so that report is no
#     reading of a held session.
#   - Tool subprocesses are children of the daemon, never of the TUI, so the
#     pane's launch environment does not reach the worker's tools.
#   - A cancel from a connection that did not start the turn is cooperative
#     and the daemon clears it 500 ms later; a single cancel lost that race
#     once, while cancels repeated on one attached connection stopped the turn
#     within about a second (`fm-jcode-api.mjs cancel` owns that loop).
#   - SIGTERM to the TUI client exits it cleanly: it prints its resume command,
#     releases its Herdr agent report, and leaves the idle session resumable.
#     A client exit during a turn would abandon that turn, so exit cancels
#     first.
#   - turn_start and turn_end hooks fire for API-submitted and cancelled turns
#     (a cancelled turn ends with turn_end status=ok).
#
# Which daemon a task uses is part of its endpoint identity: the spawn records
# the JCODE_HOME, JCODE_RUNTIME_DIR, and JCODE_SOCKET values it ran with (only
# the ones that were set) as jcode_home=, jcode_runtime_dir=, and jcode_socket=
# in state/<id>.meta, and every later API call or client lookup for that task
# runs under exactly those values, so a supervisor with a different ambient
# environment still reaches the right daemon.
#
# Sourcing: set -u and set -e safe; defines functions only.

_FM_JCODE_LIB_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

# The absolute jcode executable on PATH, or nothing with exit 1.
fm_jcode_binary() {
  local candidate dir
  candidate=$(command -v jcode 2>/dev/null) || return 1
  [ -x "$candidate" ] || return 1
  case "$candidate" in
    /*) printf '%s\n' "$candidate" ;;
    *)
      dir=$(CDPATH='' cd -- "$(dirname -- "$candidate")" 2>/dev/null && pwd -P) || return 1
      printf '%s/%s\n' "$dir" "$(basename -- "$candidate")"
      ;;
  esac
}

# Run bin/fm-jcode-api.mjs with node. Exit codes are the client's own.
fm_jcode_api() {  # <verb> <args...>
  command -v node >/dev/null 2>&1 || {
    echo "error: node is required to reach the jcode harness API" >&2
    return 3
  }
  node "$_FM_JCODE_LIB_DIR/fm-jcode-api.mjs" "$@"
}

# The daemon selection this process runs with, as the meta lines a spawn
# records: one `jcode_home=`, `jcode_runtime_dir=`, or `jcode_socket=` line
# for each of JCODE_HOME, JCODE_RUNTIME_DIR, and JCODE_SOCKET that is set.
fm_jcode_daemon_meta_lines() {
  # Native (backend=jcode) tasks run on the shared daemon: no private home or
  # runtime dir is recorded, only the shared socket and this home's API socket.
  if [ "${FM_JCODE_NATIVE:-}" = 1 ]; then
    [ -z "${JCODE_SOCKET:-}" ] || printf 'jcode_socket=%s\n' "$JCODE_SOCKET"
    [ -z "${JCODE_API_SOCKET:-}" ] || printf 'jcode_api_socket=%s\n' "$JCODE_API_SOCKET"
    return 0
  fi
  [ -z "${JCODE_HOME:-}" ] || printf 'jcode_home=%s\n' "$JCODE_HOME"
  [ -z "${JCODE_RUNTIME_DIR:-}" ] || printf 'jcode_runtime_dir=%s\n' "$JCODE_RUNTIME_DIR"
  [ -z "${JCODE_SOCKET:-}" ] || printf 'jcode_socket=%s\n' "$JCODE_SOCKET"
}

# The same selection as `env` assignments for a launch command line, each
# shell-quoted with a trailing space, or nothing when none is set.
fm_jcode_daemon_env_words() {
  local name value
  for name in JCODE_HOME JCODE_RUNTIME_DIR JCODE_SOCKET; do
    value=${!name:-}
    [ -n "$value" ] || continue
    printf "%s='%s' " "$name" "$(printf '%s' "$value" | sed "s/'/'\\\\''/g")"
  done
}

# One key of a task record, or nothing.
fm_jcode_meta_value() {  # <meta> <key>
  awk -F= -v k="$2" '$1 == k { v = substr($0, index($0, "=") + 1) } END { print v }' "$1" 2>/dev/null
}

# The jcode home a task record's daemon selection implies (where its
# client_sessions records live).
fm_jcode_meta_home() {  # <meta>
  local home
  home=$(fm_jcode_meta_value "$1" jcode_home)
  printf '%s\n' "${home:-${HOME:-}/.jcode}"
}

# Run a command under the daemon selection a task record names: the three
# variables are cleared and only the recorded ones set, so the ambient
# environment can never redirect a task's API call to another daemon.
fm_jcode_with_meta_env() {  # <meta> <command> [args...]
  local meta=$1 home runtime socket api_socket
  shift
  home=$(fm_jcode_meta_value "$meta" jcode_home)
  runtime=$(fm_jcode_meta_value "$meta" jcode_runtime_dir)
  socket=$(fm_jcode_meta_value "$meta" jcode_socket)
  api_socket=$(fm_jcode_meta_value "$meta" jcode_api_socket)
  env -u JCODE_HOME -u JCODE_RUNTIME_DIR -u JCODE_SOCKET -u JCODE_API_SOCKET \
    ${home:+JCODE_HOME="$home"} ${runtime:+JCODE_RUNTIME_DIR="$runtime"} ${socket:+JCODE_SOCKET="$socket"} \
    ${api_socket:+JCODE_API_SOCKET="$api_socket"} "$@"
}

# The ownership guard (amended D11). True only for a session this home owns: one
# recorded in <state>/*.jcode-session, or listed in a <state>/*.jcode-children
# record of a bound task. Every mutating native call (send, soft, remind,
# cancel, archive, rename, runtime) goes through it, so Firstmate can never act
# on the captain's own sessions on the shared daemon.
fm_jcode_owned_session() {  # <state-dir> <session>
  local dir=$1 session=$2 f line
  case "$session" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
  for f in "$dir"/*.jcode-session; do
    [ -f "$f" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      [ "$line" = "session=$session" ] && return 0
    done <"$f"
  done
  for f in "$dir"/*.jcode-children; do
    [ -f "$f" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      [ "${line%%$'\t'*}" = "$session" ] && return 0
    done <"$f"
  done
  return 1
}

# Run bin/fm-jcode-api.mjs over a task's own API socket (native backend). Exit 4
# (daemon or bridge unavailable) runs `fm-jcode-keeper.sh ensure` once and retries.
fm_jcode_native_api() {  # <meta> <verb...>
  local meta=$1 rc=0 sock
  shift
  sock=$(fm_jcode_meta_value "$meta" jcode_api_socket)
  [ -n "$sock" ] || { echo "error: no jcode_api_socket recorded in $meta" >&2; return 3; }
  fm_jcode_with_meta_env "$meta" node "$_FM_JCODE_LIB_DIR/fm-jcode-api.mjs" --socket "$sock" "$@" || rc=$?
  if [ "$rc" -eq 4 ]; then
    FM_HOME=${FM_HOME:-} "$_FM_JCODE_LIB_DIR/fm-jcode-keeper.sh" ensure >/dev/null 2>&1 || return 4
    rc=0
    fm_jcode_with_meta_env "$meta" node "$_FM_JCODE_LIB_DIR/fm-jcode-api.mjs" --socket "$sock" "$@" || rc=$?
  fi
  return "$rc"
}

# The firstmate-owned record binding a task to its jcode session, read by the
# hook dispatcher to attribute turn_start/turn_end events. One `key=value` per
# line: session=, gen= (the busy incarnation the hooks must present), and
# worktree= (the session's working directory, which the hook's cwd must match).
fm_jcode_session_record_path() {  # <state-dir> <id>
  printf '%s/%s.jcode-session' "$1" "$2"
}

fm_jcode_write_session_record() {  # <state-dir> <id> <session> <gen> <worktree>
  local path tmp
  path=$(fm_jcode_session_record_path "$1" "$2")
  tmp="$path.tmp.${BASHPID:-$$}"
  if ! { printf 'session=%s\ngen=%s\nworktree=%s\n' "$3" "$4" "$5" >"$tmp" && mv -f "$tmp" "$path"; }; then
    rm -f "$tmp"
    return 1
  fi
}

# Print "<id><TAB><gen><TAB><worktree>" for the task in <state-dir> bound to
# <session>, or return 1. A record with a malformed id or field is ignored.
fm_jcode_session_task() {  # <state-dir> <session>
  local state=$1 session=$2 f id line s='' g='' w=''
  case "$session" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
  for f in "$state"/*.jcode-session; do
    [ -f "$f" ] || continue
    id=${f##*/}
    id=${id%.jcode-session}
    case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    s='' g='' w=''
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        session=*) s=${line#session=} ;;
        gen=*) g=${line#gen=} ;;
        worktree=*) w=${line#worktree=} ;;
      esac
    done <"$f"
    [ "$s" = "$session" ] && [ -n "$g" ] && [ -n "$w" ] || continue
    printf '%s\t%s\t%s\n' "$id" "$g" "$w"
    return 0
  done
  return 1
}

# The pid of the live TUI client attached to <session>, or return 1. Proof is
# three independent facts: the daemon's client_sessions/<pid> record names the
# session, the pid is a live process named jcode, and its command line resumes
# that exact session. The newest such record wins. <jcode-home> defaults to
# the one this process's environment selects.
fm_jcode_client_pid() {  # <session> [jcode-home]
  local session=$1 dir f pid recorded comm args best='' best_mtime=-1 mtime
  case "$session" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
  dir="${2:-${JCODE_HOME:-${HOME:-}/.jcode}}/client_sessions"
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    pid=${f##*/}
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    IFS= read -r recorded <"$f" 2>/dev/null || [ -n "${recorded:-}" ] || continue
    [ "$recorded" = "$session" ] || continue
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || continue
    [ "$(basename -- "${comm# }")" = jcode ] || continue
    args=$(ps -o args= -p "$pid" 2>/dev/null) || continue
    case " $args " in *" --resume $session "*) ;; *) continue ;; esac
    mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
    if [ "$mtime" -gt "$best_mtime" ]; then
      best=$pid
      best_mtime=$mtime
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

# Poll until a TUI client is attached to <session>; print its pid.
fm_jcode_wait_client() {  # <session> <polls> <interval> [jcode-home]
  local i=0 pid
  while [ "$i" -lt "$2" ]; do
    if pid=$(fm_jcode_client_pid "$1" "${4:-}"); then
      printf '%s\n' "$pid"
      return 0
    fi
    i=$((i + 1))
    [ "$i" -ge "$2" ] || sleep "$3"
  done
  return 1
}

# Whether <model> is listed by `jcode --quiet model list --json`. Exit 0 when
# listed or when the catalog cannot be read (the API's set_model rejects an
# unsupported model at creation anyway); exit 1, naming the model, when a
# readable catalog does not list it.
fm_jcode_model_listed() {  # <jcode-bin> <model>
  local bin=$1 model=$2 catalog
  catalog=$("$bin" --quiet --no-update model list --json 2>/dev/null) || return 0
  command -v node >/dev/null 2>&1 || return 0
  printf '%s' "$catalog" | node -e '
    let s = "";
    process.stdin.on("data", (d) => (s += d)).on("end", () => {
      let v;
      try { v = JSON.parse(s); } catch { process.exit(0); }
      if (!v || !Array.isArray(v.models)) process.exit(0);
      process.exit(v.models.includes(process.argv[1]) ? 0 : 1);
    });
  ' "$model" && return 0
  echo "error: jcode model '$model' is not listed by 'jcode --quiet model list --json'; choose a listed id or omit --model" >&2
  return 1
}

# Classify the text a jcode turn left behind (the turn_end hook's error field,
# or the worker pane's tail) as a silent stop: a turn that ended on an auth
# failure or on the stream-idle cancellation, with nothing for the worker's own
# status log to say. Prints one plain reason and returns 0, or returns 1 when
# the text shows neither. Verified wording, jcode v0.98.1: the provider error
# "Claude OAuth token is expired and refresh failed ... invalid_grant" and the
# TUI notice "Stream stalled (no response for ...). Processing cancelled." (the
# roughly 12.5 minute stream-idle timeout, [provider] stream_idle_timeout_secs).
fm_jcode_silent_stop_reason() {  # <text>
  local text=$1
  case "$text" in
    *"Stream stalled"*|*"Processing cancelled"*)
      printf '%s\n' "jcode cancelled the turn after its stream went idle (stream-idle timeout), so the worker stopped without reporting"
      return 0
      ;;
    *"token is expired and refresh failed"*|*"token refresh failed"*|*"Token refresh failed"*|*invalid_grant*|*"Failed to refresh"*"OAuth token"*|*"authentication failed"*|*"/login"*"re-authenticate"*)
      printf '%s\n' "jcode could not authenticate (login or token refresh failed), so the worker stopped without reporting"
      return 0
      ;;
  esac
  return 1
}

# Classify the same text as a provider rate-limit stall: Anthropic 429
# rate_limit_error, "exceed your account's rate limit", or jcode's own
# [jcode-provider-failover] / provider-failed notices. Prints one plain reason
# and returns 0, or returns 1. Distinct from fm_jcode_silent_stop_reason because
# the worker is healthy and only waits for the window reset
# (bin/fm-token-headroom-lib.sh records and later resumes it).
fm_jcode_rate_limit_reason() {  # <text>
  case "$1" in
    *rate_limit_error*|*"exceed your account's rate limit"*|*"exceed your account"*"rate limit"*|*"[jcode-provider-failover]"*|*"provider failed"*|*"Provider failed"*|*"429 Too Many Requests"*|*"HTTP 429"*)
      printf '%s\n' "jcode hit a provider rate limit (usage window exhausted), so the worker stopped without reporting"
      return 0
      ;;
  esac
  return 1
}

# Record a silent stop as a `blocked` event in <state>/<id>.status so the
# watcher's ordinary status signal wakes firstmate with the plain reason.
# Idempotent: nothing is appended when the log's last line already carries this
# reason. Used by the turn_end hook (a turn that ended in error) and by the
# watcher (the pane shows the stream-idle notice). Returns 0 when it appended.
fm_jcode_report_blocked() {  # <state-dir> <id> <reason>
  local f="$1/$2.status" last
  [ -n "$3" ] || return 1
  last=$(tail -n 1 "$f" 2>/dev/null || true)
  case "$last" in *"$3"*) return 1 ;; esac
  printf 'blocked [at=%s]: %s\n' "$(date +%s)" "$3" >> "$f"
}

# Refuse a shared daemon whose own environment carries Firstmate home
# selection. Every jcode tool shell is a child of the daemon, so an FM_HOME (or
# an *_OVERRIDE) in the daemon environment would silently point a secondmate's
# tools at the wrong home. The environ comes from FM_JCODE_DAEMON_ENVIRON_FILE
# (test seam) or /proc/<pid>/environ of the `jcode serve --socket <socket>`
# process. Exit 0 clean or unreadable (one warning), exit 1 with the refusal.
fm_jcode_daemon_env_clean() {
  local file=${FM_JCODE_DAEMON_ENVIRON_FILE:-} pid names name bad=''
  if [ -z "$file" ]; then
    pid=$(pgrep -f "jcode serve --socket ${JCODE_SOCKET:-}" 2>/dev/null | head -n 1) || pid=''
    [ -z "$pid" ] || file=/proc/$pid/environ
  fi
  if [ -z "$file" ] || [ ! -r "$file" ]; then
    echo "warning: cannot read the shared jcode daemon environment; not checking it for FM_HOME" >&2
    return 0
  fi
  names=$(tr '\0' '\n' <"$file" 2>/dev/null | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p') || names=''
  for name in FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE; do
    if printf '%s\n' "$names" | grep -qx "$name"; then
      bad="${bad:+$bad, }$name"
    fi
  done
  [ -z "$bad" ] || {
    echo "error: the shared jcode daemon carries $bad in its environment; restart it from a clean shell" >&2
    return 1
  }
  return 0
}

# Print the secondmate home whose own hook dispatcher must handle a jcode hook
# event, or return 1. A home qualifies when <state>/*.meta records it with
# kind=secondmate and harness=jcode, its .fm-secondmate-home marker names the
# same task id, it ships bin/fm-jcode-hook.sh as a regular file, and either the
# session's toplevel is that home or the session is bound in that home's state.
fm_jcode_secondmate_hook_target() {  # <state-dir> <toplevel> <session>
  local state=$1 top=$2 session=$3 meta id home real marker mid=''
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    [ "$(fm_jcode_meta_value "$meta" kind)" = secondmate ] || continue
    [ "$(fm_jcode_meta_value "$meta" harness)" = jcode ] || continue
    id=${meta##*/}
    id=${id%.meta}
    home=$(fm_jcode_meta_value "$meta" home)
    [ -n "$home" ] && [ -d "$home" ] || continue
    real=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || continue
    marker="$real/.fm-secondmate-home"
    [ -f "$marker" ] && [ ! -L "$marker" ] || continue
    mid=''
    IFS= read -r mid <"$marker" 2>/dev/null || [ -n "$mid" ] || continue
    mid=${mid//[[:space:]]/}
    [ "$mid" = "$id" ] || continue
    [ -f "$real/bin/fm-jcode-hook.sh" ] && [ ! -L "$real/bin/fm-jcode-hook.sh" ] || continue
    if [ "$top" = "$real" ] || fm_jcode_session_task "$real/state" "$session" >/dev/null 2>&1; then
      printf '%s\n' "$real"
      return 0
    fi
  done
  return 1
}

# Worker memory flag (docs/jcode-backend.md "Worker memory"). <config-dir>/
# jcode-worker-memory reads `on` or `off`; absent is off. Exit 0 only for `on`.
# Any other value is treated as off with one warning on stderr.
fm_jcode_worker_memory_on() {  # <config-dir>
  local file="$1/jcode-worker-memory" value
  [ -f "$file" ] || return 1
  value=$(tr -d '[:space:]' <"$file" 2>/dev/null | tr '[:upper:]' '[:lower:]')
  case "$value" in
    on) return 0 ;;
    off | '') return 1 ;;
    *)
      echo "warning: $file holds '$value', not on or off; treating jcode worker memory as off" >&2
      return 1
      ;;
  esac
}

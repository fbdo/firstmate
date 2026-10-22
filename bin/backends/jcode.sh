#!/usr/bin/env bash
# bin/backends/jcode.sh - the native jcode runtime adapter.
#
# A jcode worker is a session on the captain's one shared jcode daemon, driven
# through this home's API bridge (bin/fm-jcode-keeper.sh) and watched by this
# home's keeper (bin/fm-jcode-keeper.mjs). There is no pane: steering is a soft
# interrupt, capture is the transcript tail, busy/idle comes from keeper
# records, and the watcher's push path tails the keeper's transitions file.
#
# Target string shape: `jcode:<session-id>` (the task's `window=`).
#
# Ownership (amended D11): every mutating call (send, soft, cancel, archive)
# first proves the session is one this home recorded (fm_jcode_owned_session),
# so a Firstmate action can never reach one of the captain's own sessions.
#
# Sourcing: defines functions only. Requires bin/fm-backend.sh (fm_meta_get,
# fm_backend_meta_for_window) in the same shell.

_FM_BACKEND_JCODE_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=bin/fm-jcode-lib.sh
. "$_FM_BACKEND_JCODE_DIR/fm-jcode-lib.sh"
# shellcheck source=bin/fm-transition-lib.sh
. "$_FM_BACKEND_JCODE_DIR/fm-transition-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$_FM_BACKEND_JCODE_DIR/fm-composer-lib.sh"

FM_BACKEND_JCODE_ESCALATED_PREFIX=".jcode-escalated-"
FM_BACKEND_JCODE_CURSOR=".jcode-transitions-cursor"

fm_backend_jcode_state_dir() {
  printf '%s' "${FM_STATE_OVERRIDE:-${FM_HOME:?FM_HOME is not set}/state}"
}

fm_backend_jcode_tool_check() {
  command -v jcode >/dev/null 2>&1 || { echo "error: backend=jcode selected but the 'jcode' CLI is not installed" >&2; return 1; }
  command -v node >/dev/null 2>&1 || { echo "error: backend=jcode selected but 'node' is not installed" >&2; return 1; }
}

# The bridge and keeper must be up and the shared daemon reachable. Never starts the daemon.
fm_backend_jcode_runtime_check() {
  fm_backend_jcode_tool_check || return 1
  FM_HOME=${FM_HOME:-} "$_FM_BACKEND_JCODE_DIR/fm-jcode-keeper.sh" ensure >/dev/null
}

# <target> -> the bare session id, or return 1.
fm_backend_jcode_session() {
  local session=${1#jcode:}
  [ "$session" != "$1" ] || return 1
  case "$session" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
  printf '%s' "$session"
}

# <target> -> the task meta file, or return 1.
fm_backend_jcode_meta() {
  local meta
  meta=$(fm_backend_meta_for_window "$1" "$(fm_backend_jcode_state_dir)") || return 1
  [ -n "$meta" ] || return 1
  printf '%s' "$meta"
}

# Resolve <target> and prove ownership: sets _JC_SESSION, _JC_META, _JC_STATE.
fm_backend_jcode_resolve() {  # <target>
  _JC_SESSION=$(fm_backend_jcode_session "$1") || { echo "error: '$1' is not a jcode target" >&2; return 1; }
  _JC_STATE=$(fm_backend_jcode_state_dir)
  _JC_META=$(fm_backend_jcode_meta "$1") || { echo "error: no task records $1; refusing" >&2; return 1; }
  fm_jcode_owned_session "$_JC_STATE" "$_JC_SESSION" || {
    echo "REFUSED: jcode session $_JC_SESSION is not owned by this firstmate home" >&2
    return 1
  }
}

fm_backend_jcode_capture() {  # <target> <lines>
  fm_backend_jcode_resolve "$1" || return 1
  fm_jcode_native_api "$_JC_META" history "$_JC_SESSION" --lines "${2:-40}"
}

# There is no composer: a soft interrupt is accepted or refused by the API.
fm_backend_jcode_composer_state() {
  printf 'empty'
}

fm_backend_jcode_send_key() {  # <target> <key>
  case "$2" in
    Enter|enter) return 0 ;;
    Escape|C-c|ctrl+c|Ctrl-c|Ctrl-C)
      fm_backend_jcode_resolve "$1" || return 1
      fm_jcode_native_api "$_JC_META" cancel "$_JC_SESSION" >/dev/null
      ;;
    *) echo "error: unsupported jcode key '$2'" >&2; return 1 ;;
  esac
}

fm_backend_jcode_keeper_beat_fresh() {  # <state>
  local m now
  m=$(stat -c %Y "$1/jcode/keeper.beat" 2>/dev/null) || return 1
  now=$(date +%s)
  [ $((now - m)) -le "${FM_JCODE_KEEPER_BEAT_MAX:-15}" ]
}

# Deliver <text> as a soft interrupt carrying a Firstmate client id; the verdict
# is `empty` once accepted (and, when the keeper is live, once it recorded the
# injection), `send-failed` when the API refused.
fm_backend_jcode_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  local target=$1 text=$2 task cid i wait
  fm_backend_jcode_resolve "$target" || { printf 'send-failed'; return 0; }
  task=$(fm_meta_get "$_JC_META" endpoint_task_id)
  cid="fm-${task:-task}-$(date +%s)"
  printf '%s' "$text" | fm_jcode_native_api "$_JC_META" soft "$_JC_SESSION" --client-id "$cid" || {
    printf 'send-failed'
    return 0
  }
  if fm_backend_jcode_keeper_beat_fresh "$_JC_STATE"; then
    wait=${FM_JCODE_INJECT_WAIT_TENTHS:-100}
    for ((i = 0; i < wait; i++)); do
      grep -Fq " $cid " "$_JC_STATE/jcode/injected/$_JC_SESSION" 2>/dev/null && break
      sleep 0.1
    done
  fi
  printf 'empty'
}

# Archive every recorded or live child of the worker that sits inside the task
# worktree (D13); a child outside it is logged and left alone.
fm_backend_jcode_archive_children() {  # (uses _JC_* from fm_backend_jcode_resolve)
  local worktree child label dir real kids rec
  worktree=$(fm_meta_get "$_JC_META" worktree)
  worktree=$(readlink -f -- "$worktree" 2>/dev/null || printf '%s' "$worktree")
  rec="$_JC_STATE/$(fm_meta_get "$_JC_META" endpoint_task_id).jcode-children"
  # Fold live children into the durable record first, so they pass the ownership guard.
  kids=$(fm_jcode_native_api "$_JC_META" children "$_JC_SESSION" 2>/dev/null || true)
  while IFS=$'\t' read -r child label dir _status; do
    [ -n "$child" ] || continue
    grep -q "^$child	" "$rec" 2>/dev/null || printf '%s\t%s\t%s\n' "$child" "$label" "$dir" >>"$rec"
  done <<<"$kids"
  [ -f "$rec" ] || return 0
  while IFS=$'\t' read -r child label dir; do
    [ -n "$child" ] || continue
    real=$(readlink -f -- "$dir" 2>/dev/null || printf '%s' "$dir")
    case "$real/" in
      "$worktree"/*) ;;
      *)
        echo "jcode: child $child works in '$dir', outside the task worktree; not archiving" >&2
        printf '%s child %s outside worktree (%s)\n' "$(date +%s)" "$child" "$dir" >>"$_JC_STATE/jcode/teardown.log" 2>/dev/null || true
        continue
        ;;
    esac
    fm_jcode_owned_session "$_JC_STATE" "$child" || continue
    fm_jcode_native_api "$_JC_META" cancel "$child" >/dev/null 2>&1 || true
    fm_jcode_native_api "$_JC_META" archive "$child" >/dev/null 2>&1 || true
  done <"$rec"
}

# Remove the task's session: children first, then the worker. Already gone is 0.
fm_backend_jcode_kill() {  # <target>
  local rc=0
  fm_backend_jcode_resolve "$1" || return 1
  fm_jcode_native_api "$_JC_META" session-exists "$_JC_SESSION" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 1 ] || return 0
  [ "$rc" -eq 0 ] || { echo "error: cannot reach the jcode API to close $_JC_SESSION" >&2; return 1; }
  fm_backend_jcode_archive_children
  fm_jcode_native_api "$_JC_META" cancel "$_JC_SESSION" >/dev/null 2>&1 || true
  fm_jcode_native_api "$_JC_META" archive "$_JC_SESSION" >/dev/null || {
    rc=$?
    if fm_jcode_native_api "$_JC_META" session-exists "$_JC_SESSION" >/dev/null 2>&1; then return 1; fi
    return 0
  }
}

fm_backend_jcode_busy_state() {  # <target>
  local session state live
  session=$(fm_backend_jcode_session "$1") || { printf 'unknown'; return 0; }
  state=$(fm_backend_jcode_state_dir)
  fm_backend_jcode_keeper_beat_fresh "$state" || { printf 'unknown'; return 0; }
  live=$(cut -d' ' -f1 "$state/jcode/live/$session" 2>/dev/null || true)
  case "$live" in busy|idle) printf '%s' "$live" ;; *) printf 'unknown' ;; esac
}

# Cheap, read-only: never runs `ensure`.
fm_backend_jcode_target_exists() {  # <target>
  local session meta
  session=$(fm_backend_jcode_session "$1") || return 1
  meta=$(fm_backend_jcode_meta "$1") || return 1
  fm_jcode_with_meta_env "$meta" node "$_FM_BACKEND_JCODE_DIR/fm-jcode-api.mjs" \
    --socket "$(fm_meta_get "$meta" jcode_api_socket)" session-exists "$session" >/dev/null 2>&1
}

fm_backend_jcode_agent_state() {  # <target>
  local session meta state task rc=0
  session=$(fm_backend_jcode_session "$1") || { printf 'unreadable'; return 0; }
  meta=$(fm_backend_jcode_meta "$1") || { printf 'unreadable'; return 0; }
  state=$(fm_backend_jcode_state_dir)
  task=$(fm_meta_get "$meta" endpoint_task_id)
  fm_jcode_with_meta_env "$meta" node "$_FM_BACKEND_JCODE_DIR/fm-jcode-api.mjs" \
    --socket "$(fm_meta_get "$meta" jcode_api_socket)" session-exists "$session" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) ;;
    1) printf 'missing'; return 0 ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  if [ -e "$state/$task.jcode-exited" ]; then printf 'dead'; return 0; fi
  if fm_backend_jcode_keeper_beat_fresh "$state"; then printf 'alive'; else printf 'unreadable'; fi
}

# --- push seam: the keeper's transitions file --------------------------------

fm_backend_jcode_events_capable() {  # <session-key>
  local state
  state=$(fm_backend_jcode_state_dir)
  fm_backend_jcode_keeper_beat_fresh "$state" && [ -w "$state/jcode" ]
}

fm_backend_jcode_escalation_marker() {  # <state_dir> <window>
  printf '%s/%s%s' "$1" "$FM_BACKEND_JCODE_ESCALATED_PREFIX" "$(printf '%s' "$2" | tr ':/.' '___')"
}

# Route one record through the shared policy table; print it and return 0 only
# for a fresh actionable edge (no escalation marker yet).
fm_backend_jcode_apply_transition() {  # <state_dir> <session-key> <record>
  local state=$1 key=$2 record=$3 sid to action marker
  sid=$(fm_transition_pane_id "$record")
  [ -n "$sid" ] || return 1
  to=$(fm_transition_to_status "$record")
  action=$(fm_transition_policy "$to")
  marker=$(fm_backend_jcode_escalation_marker "$state" "$key:$sid")
  case "$action" in
    actionable)
      if [ ! -e "$marker" ]; then
        printf '%s' "$record"
        return 0
      fi
      ;;
    absorb) rm -f "$marker" 2>/dev/null || true ;;
  esac
  return 1
}

fm_backend_jcode_commit_transition() {  # <state_dir> <session-key> <record>
  local sid
  sid=$(fm_transition_pane_id "$3")
  [ -n "$sid" ] || return 1
  : > "$(fm_backend_jcode_escalation_marker "$1" "$2:$sid")"
}

fm_backend_jcode_clear_transition() {  # <state_dir> <window>
  [ -n "${2:-}" ] || return 0
  rm -f "$(fm_backend_jcode_escalation_marker "$1" "$2")" 2>/dev/null || true
}

# Bounded wait for a fresh actionable record on one of <window...>
# ("jcode:<session>"). Returns 0 with the record on stdout, 1 on a clean
# timeout, 2 when the keeper beat is stale (the caller polls instead).
fm_backend_jcode_wait_transition() {  # <session-key> <timeout_secs> <state_dir> <window...>
  local key=$1 timeout=$2 state=$3 file cursor size pos line sid w want hit deadline now
  shift 3
  [ "$#" -gt 0 ] || return 2
  file="$state/jcode/transitions"
  cursor="$state/$FM_BACKEND_JCODE_CURSOR"
  deadline=$(( $(date +%s) + timeout ))
  while :; do
    fm_backend_jcode_keeper_beat_fresh "$state" || return 2
    pos=$(cat "$cursor" 2>/dev/null || echo 0)
    case "$pos" in ''|*[!0-9]*) pos=0 ;; esac
    size=$(stat -c %s "$file" 2>/dev/null || echo 0)
    [ "$size" -ge "$pos" ] || pos=0
    if [ "$size" -gt "$pos" ]; then
      hit=
      while IFS= read -r line; do
        pos=$((pos + ${#line} + 1))
        sid=$(fm_transition_pane_id "$line")
        want=0
        for w in "$@"; do [ "$w" = "jcode:$sid" ] && want=1; done
        [ "$want" -eq 1 ] || continue
        if hit=$(fm_backend_jcode_apply_transition "$state" "$key" "$line"); then
          printf '%s\n' "$pos" >"$cursor"
          printf '%s' "$hit"
          return 0
        fi
      done < <(tail -c +"$((pos + 1))" "$file" 2>/dev/null)
      printf '%s\n' "$pos" >"$cursor"
    fi
    now=$(date +%s)
    [ "$now" -lt "$deadline" ] || return 1
    sleep 1
  done
}

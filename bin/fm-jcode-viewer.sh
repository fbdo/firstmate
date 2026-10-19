#!/usr/bin/env bash
# fm-jcode-viewer.sh - a view-only Herdr terminal for one native jcode worker.
#
# A backend=jcode worker has no pane of its own: the keeper holds its session on
# the shared daemon. This helper opens one extra Herdr tab per native worker
# that runs `jcode --resume <session>` (fm-jcode-keeper.sh attach-cmd), so the
# captain can watch the worker. The keeper stays the authoritative client:
# closing the viewer only detaches one more client from the session, and
# firstmate never types into it (no send, no key, no doorbell targets it).
#
# Usage:
#   fm-jcode-viewer.sh open  <task-id>   open the viewer; best effort, exit 0
#   fm-jcode-viewer.sh close <task-id>   close it; best effort, exit 0
#   fm-jcode-viewer.sh status <task-id>  print `session:pane` when one is recorded
#
# Opt-out: config/jcode-viewer holding `off` (memory-tight hosts: each viewer is
# one more jcode TUI client, about 60 MB). Absent or `on` opens one. The
# viewer needs a Herdr server (the herdr backend selected for this home); on
# any other setup `open` prints nothing and records nothing.
#
# The viewer is recorded in state/<id>.jcode-viewer (`session=` and `pane=`),
# removed by close and by bin/fm-teardown.sh. `open` never fails a spawn and
# `close` never fails a cleanup: a problem is one warning on stderr.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT="${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
export FM_HOME
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

VERB=${1:-}
ID=${2:-}
case "$VERB" in
  open | close | status) ;;
  *)
    echo "usage: fm-jcode-viewer.sh open|close|status <task-id>" >&2
    exit 2
    ;;
esac
case "$ID" in '' | *[!A-Za-z0-9._-]*) echo "usage: fm-jcode-viewer.sh $VERB <task-id>" >&2; exit 2 ;; esac

REC="$STATE/$ID.jcode-viewer"
META="$STATE/$ID.meta"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-jcode-lib.sh
. "$SCRIPT_DIR/fm-jcode-lib.sh"

rec_value() {  # <key>
  awk -F= -v k="$1" '$1 == k { v = substr($0, index($0, "=") + 1) } END { print v }' "$REC" 2>/dev/null
}

viewer_disabled() {
  [ -f "$CONFIG/jcode-viewer" ] && [ "$(tr -d '[:space:]' <"$CONFIG/jcode-viewer" | tr '[:upper:]' '[:lower:]')" = off ]
}

# Whether this home runs on Herdr: an explicit FM_BACKEND, else config/backend,
# else a launcher that is itself a Herdr pane with no tmux in the way.
viewer_herdr_selected() {
  local want=${FM_BACKEND:-}
  [ -n "$want" ] || want=$(tr -d '[:space:]' <"$CONFIG/backend" 2>/dev/null || true)
  [ -n "$want" ] || { [ -z "${TMUX:-}" ] && [ "${HERDR_ENV:-}" = 1 ] && want=herdr; }
  [ "$want" = herdr ]
}

cmd_open() {
  local session socket attach tab_pane cwd container tab pane
  viewer_disabled && return 0
  [ -f "$META" ] || return 0
  [ "$(fm_jcode_meta_value "$META" backend)" = jcode ] || return 0
  [ ! -f "$REC" ] || return 0
  viewer_herdr_selected || return 0
  fm_backend_source herdr || return 0
  command -v jq >/dev/null 2>&1 || return 0
  attach=$("$SCRIPT_DIR/fm-jcode-keeper.sh" attach-cmd "$ID" 2>/dev/null) || return 0
  [ -n "$attach" ] || return 0
  socket=$(fm_jcode_meta_value "$META" jcode_socket)
  if [ -n "$socket" ]; then
    attach="env JCODE_SOCKET='$(printf '%s' "$socket" | sed "s/'/'\\\\''/g")' $attach"
  fi
  cwd=$(fm_jcode_meta_value "$META" worktree)
  [ -d "$cwd" ] || cwd=$FM_HOME
  container=$(fm_backend_herdr_container_ensure "$cwd" launcher-home 2>/dev/null) || {
    echo "warning: jcode viewer for $ID not opened: no Herdr workspace" >&2
    return 0
  }
  session=${container%%:*}
  tab_pane=$(fm_backend_herdr_create_task "${container%%$'\t'*}" "view-$ID" "$cwd" "") || {
    echo "warning: jcode viewer for $ID not opened: could not create its Herdr tab" >&2
    return 0
  }
  tab=${tab_pane%% *}
  pane=${tab_pane#* }
  if ! fm_backend_herdr_cli "$session" pane run "$pane" "$attach" >/dev/null 2>&1; then
    echo "warning: jcode viewer for $ID could not start its client; closing the tab" >&2
    fm_backend_herdr_cli "$session" tab close "$tab" >/dev/null 2>&1 || true
    return 0
  fi
  printf 'session=%s\ntab=%s\npane=%s\n' "$session" "$tab" "$pane" >"$REC.tmp.$$" && mv -f "$REC.tmp.$$" "$REC" || {
    rm -f "$REC.tmp.$$"
    echo "warning: jcode viewer for $ID opened but could not be recorded" >&2
  }
  printf '%s:%s\n' "$session" "$pane"
}

cmd_close() {
  local session pane
  [ -f "$REC" ] || return 0
  session=$(rec_value session)
  pane=$(rec_value pane)
  if [ -n "$session" ] && [ -n "$pane" ]; then
    fm_backend_source herdr 2>/dev/null || true
    fm_backend_herdr_kill "$session:$pane" 2>/dev/null || echo "warning: jcode viewer pane $pane could not be closed" >&2
  fi
  rm -f "$REC"
}

case "$VERB" in
  open) cmd_open ;;
  close) cmd_close ;;
  status)
    [ -f "$REC" ] || exit 1
    printf '%s:%s\n' "$(rec_value session)" "$(rec_value pane)"
    ;;
esac
exit 0

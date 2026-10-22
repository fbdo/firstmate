#!/usr/bin/env bash
# fm-token-resume.sh - keep the time-driven rate-limit recovery alive when no
# watcher cycle is armed.
#
# Usage: fm-token-resume.sh [--once]
#
# The watcher (bin/fm-watch.sh token_headroom_cycle) re-prompts a worker whose
# provider rate-limit window reset, but a watcher exits after every wake and
# some primaries re-arm it only on their next turn - which never comes while the
# captain is away or the primary's own quota is out. bin/fm-jcode-hook.sh starts
# this small waiter, detached, whenever it records state/<id>.ratelimit. It
# sleeps until the earliest reset (+30 s), then runs fm_token_headroom_refresh
# and fm_token_rate_limit_resume (bin/fm-token-headroom-lib.sh), appends one
# durable `check: token headroom:` wake for what it did, and exits once no
# .ratelimit record is left. An unknown reset is retried every poll and resumes
# on token-saving exit or after six hours, exactly as the watcher does.
#
# Home-scoped: it acts only on this FM_HOME's state and sends through this
# home's bin/fm-send.sh with an explicit FM_HOME. Single-instance per home via
# state/.token-resume.lock (pid-checked). A live watcher is harmless: the resume
# pass runs under the library's lock and removes each record before the other
# side reads it, so a worker is re-prompted once. Pending token-saving notices
# are claimed by an atomic rename before this waiter enqueues them.
#
# --once runs a single pass without sleeping or the instance lock (tests).
# FM_TOKEN_RESUME_POLL (default 300) bounds each sleep; FM_TOKEN_RESUME_SEND
# overrides the send script.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
export FM_HOME=${FM_HOME:-$FM_ROOT}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
export FM_STATE_OVERRIDE=$STATE
[ -d "$STATE" ] || exit 0
ONCE=0
[ "${1:-}" != --once ] || ONCE=1
POLL=${FM_TOKEN_RESUME_POLL:-300}
case "$POLL" in ''|*[!0-9]*) POLL=300 ;; esac
[ "$POLL" -gt 0 ] || POLL=1
SEND=${FM_TOKEN_RESUME_SEND:-$SCRIPT_DIR/fm-send.sh}

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-token-headroom-lib.sh
. "$SCRIPT_DIR/fm-token-headroom-lib.sh"

LOCK="$STATE/.token-resume.lock"
if [ "$ONCE" -eq 0 ]; then
  if ! mkdir "$LOCK" 2>/dev/null; then
    other=$(cat "$LOCK/pid" 2>/dev/null || true)
    if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then exit 0; fi
    # A dead or half-made holder: clear only our own lock files and retry once.
    rm -f "$LOCK/pid" 2>/dev/null || true
    rmdir "$LOCK" 2>/dev/null || true
    mkdir "$LOCK" 2>/dev/null || exit 0
  fi
  printf '%s\n' "$$" > "$LOCK/pid"
  trap 'rm -f "$LOCK/pid" 2>/dev/null; rmdir "$LOCK" 2>/dev/null' EXIT
  trap 'exit 0' HUP INT TERM
fi

pending() {
  local f
  for f in "$STATE"/*.ratelimit; do [ -e "$f" ] && return 0; done
  return 1
}

# Seconds until the earliest known reset (+30 s); 0 when due; POLL when only
# unknown resets remain.
next_wait() {
  local f reset now best='' d
  now=$(fm_token_now)
  for f in "$STATE"/*.ratelimit; do
    [ -e "$f" ] || continue
    reset=$(sed -n 's/^reset=//p' "$f" | head -n 1)
    case "$reset" in ''|*[!0-9]*) continue ;; esac
    d=$((reset + 30 - now))
    [ "$d" -gt 0 ] || d=0
    if [ -z "$best" ] || [ "$d" -lt "$best" ]; then best=$d; fi
  done
  printf '%s\n' "${best:-$POLL}"
}

pass() {
  local exited=0 notice claimed text ids
  fm_token_headroom_refresh || true
  [ "$FM_TOKEN_HEADROOM_TRANSITION" != exited ] || exited=1
  fm_token_rate_limit_resume "$FM_HOME" "$SEND" "$exited" || true
  ids=$FM_TOKEN_RESUMED
  [ -z "$ids" ] || fm_token_notice resume "rate-limit window reset, re-prompted: $ids"
  notice="$STATE/.token-saving-notice"
  claimed="$STATE/.token-saving-notice.resume.$$"
  if [ -s "$notice" ] && mv "$notice" "$claimed" 2>/dev/null; then
    text=$(cut -f2- "$claimed" | paste -sd ';' - | sed 's/;/; /g')
    if fm_wake_append check token-headroom "check: token headroom: $text"; then
      rm -f "$claimed"
    else
      cat "$claimed" >> "$notice" && rm -f "$claimed"
    fi
  fi
}

while :; do
  [ -d "$STATE" ] || exit 0
  pending || exit 0
  wait_s=$(next_wait)
  if [ "$ONCE" -eq 1 ]; then pass; exit 0; fi
  if [ "$wait_s" -gt 0 ]; then
    [ "$wait_s" -le "$POLL" ] || wait_s=$POLL
    sleep "$wait_s"
    continue
  fi
  pass
  # A due record that could not be re-prompted yet (send failed) is retried.
  if pending; then sleep "$POLL"; fi
done

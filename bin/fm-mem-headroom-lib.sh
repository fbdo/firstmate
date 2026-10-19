#!/usr/bin/env bash
# shellcheck disable=SC2034 # FM_MEM_HEADROOM_* results are read by callers after sourcing.
# fm-mem-headroom-lib.sh - is there enough free memory on this host to start
# heavy work right now?
#
# A small host can run out of memory when a worker launch, a ShellCheck root,
# or a concurrent test batch starts while memory is already short; the kernel
# then OOM-kills whatever is largest, which can be the agent server itself.
# This file is the single owner of the headroom verdict that bin/fm-spawn.sh,
# bin/fm-lint.sh, and bin/fm-test-run.sh consult before heavy work. It bounds
# free memory, never a worker count. docs/configuration.md "Memory headroom"
# is the operator reference; each caller's header owns what it does on a low
# verdict.
#
# Headroom is MemAvailable plus SwapFree, read through bin/fm-jev-mem-guard.py
# --available-mib (the one /proc/meminfo parser). The threshold in MiB is, in
# order: FM_MEM_HEADROOM_MIB, else the first line of
# ${FM_CONFIG_OVERRIDE:-${FM_HOME:-<this repo>}/config}/mem-headroom-mib, else
# 1536 (a single source-following ShellCheck of bin/fm-spawn.sh peaks near
# 1.3 GiB resident). A value that is not a whole number falls back to the
# default; 0 disables the check.
#
# The check steps aside whenever it cannot measure: no python3, no readable
# meminfo (macOS, some containers), or no MemAvailable line all mean "enough",
# so the check can delay heavy work but never block it on a host it cannot see.
#
# Usage: . bin/fm-mem-headroom-lib.sh
#   fm_mem_headroom_low       returns 0 when headroom is measured and below the
#                             threshold, 1 otherwise; sets
#                             FM_MEM_HEADROOM_AVAILABLE_MIB (a number or
#                             "unknown") and FM_MEM_HEADROOM_THRESHOLD_MIB.
#   fm_mem_headroom_wait <label>
#                             while headroom is low, waits up to
#                             FM_MEM_HEADROOM_WAIT_SECONDS (default 300),
#                             polling every FM_MEM_HEADROOM_POLL_SECONDS
#                             (default 5), printing one note on stderr; then
#                             returns 0 either way, so the wait is bounded.
#   fm_mem_headroom_clamp_jobs <jobs>
#                             sets FM_MEM_HEADROOM_JOBS to <jobs> reduced to
#                             the number of threshold-sized shares that fit in
#                             the measured headroom, never below 1 and never
#                             above <jobs>.

FM_MEM_HEADROOM_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
FM_MEM_HEADROOM_DEFAULT_MIB=1536
FM_MEM_HEADROOM_AVAILABLE_MIB=unknown
FM_MEM_HEADROOM_THRESHOLD_MIB=$FM_MEM_HEADROOM_DEFAULT_MIB
FM_MEM_HEADROOM_JOBS=

fm_mem_headroom_threshold() {
  local value=${FM_MEM_HEADROOM_MIB:-} file
  if [ -z "$value" ]; then
    file="${FM_CONFIG_OVERRIDE:-${FM_HOME:-$FM_MEM_HEADROOM_LIB_DIR/..}/config}/mem-headroom-mib"
    [ ! -r "$file" ] || IFS= read -r value < "$file" || true
    value=${value%%[[:space:]]*}
  fi
  case "$value" in
    ''|*[!0-9]*) value=$FM_MEM_HEADROOM_DEFAULT_MIB ;;
  esac
  printf '%s\n' "$((10#$value))"
}

fm_mem_headroom_low() {
  local avail
  FM_MEM_HEADROOM_THRESHOLD_MIB=$(fm_mem_headroom_threshold)
  FM_MEM_HEADROOM_AVAILABLE_MIB=unknown
  [ "$FM_MEM_HEADROOM_THRESHOLD_MIB" -gt 0 ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  avail=$(python3 "$FM_MEM_HEADROOM_LIB_DIR/fm-jev-mem-guard.py" --available-mib 2>/dev/null) || return 1
  case "$avail" in
    ''|*[!0-9]*) return 1 ;;
  esac
  FM_MEM_HEADROOM_AVAILABLE_MIB=$avail
  [ "$avail" -lt "$FM_MEM_HEADROOM_THRESHOLD_MIB" ]
}

fm_mem_headroom_wait() {  # <label>
  local label=$1 limit=${FM_MEM_HEADROOM_WAIT_SECONDS:-300} poll=${FM_MEM_HEADROOM_POLL_SECONDS:-5} waited=0
  case "$limit" in ''|*[!0-9]*) limit=300 ;; esac
  case "$poll" in ''|*[!0-9]*|0) poll=5 ;; esac
  fm_mem_headroom_low || return 0
  printf 'mem-headroom: %s waits for free memory (%s MiB available, %s MiB wanted; up to %ss)\n' \
    "$label" "$FM_MEM_HEADROOM_AVAILABLE_MIB" "$FM_MEM_HEADROOM_THRESHOLD_MIB" "$limit" >&2
  while [ "$waited" -lt "$limit" ]; do
    sleep "$poll"
    waited=$((waited + poll))
    fm_mem_headroom_low || return 0
  done
  printf 'mem-headroom: %s starts anyway after waiting %ss (%s MiB available)\n' \
    "$label" "$waited" "$FM_MEM_HEADROOM_AVAILABLE_MIB" >&2
  return 0
}

fm_mem_headroom_clamp_jobs() {  # <jobs>
  local jobs=$1 fit
  FM_MEM_HEADROOM_JOBS=$jobs
  fm_mem_headroom_low || true
  case "$FM_MEM_HEADROOM_AVAILABLE_MIB" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ "$FM_MEM_HEADROOM_THRESHOLD_MIB" -gt 0 ] || return 0
  fit=$((FM_MEM_HEADROOM_AVAILABLE_MIB / FM_MEM_HEADROOM_THRESHOLD_MIB))
  [ "$fit" -ge 1 ] || fit=1
  [ "$fit" -lt "$jobs" ] || fit=$jobs
  FM_MEM_HEADROOM_JOBS=$fit
}

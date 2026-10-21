#!/usr/bin/env bash
# shellcheck disable=SC2034 # FM_TOKEN_* results are read by callers after sourcing.
# fm-token-headroom-lib.sh - is there enough provider quota left to start new
# work right now?
#
# The twin of bin/fm-mem-headroom-lib.sh for model tokens. Anthropic limits a
# Claude subscription with a rolling 5-hour window and a rolling 7-day window;
# when either runs out, workers stall on 429s. This file is the single owner of
# the token-saving state, the early pace warning, and the rate-limit stall
# records that bin/fm-spawn.sh, bin/fm-watch.sh, bin/fm-jcode-hook.sh, and
# bin/fm-session-start.sh consult. docs/configuration.md "Token headroom" is the
# operator reference; each caller's header owns what it does with the verdict.
#
# Source of truth: `quota-axi --provider claude --json --max-age <age>`
# (windows five_hour and seven_day: percentRemaining, resetsAt, pace). Only the
# Claude provider is read; fm_token_read is the one seam to extend for another
# provider. quota-axi missing, failing, malformed, or reporting neither window
# means "enough": the check can delay work but never block it blind.
#
# Settings, in order: FM_TOKEN_HEADROOM_<KEY>, else <key>=<value> lines in
# ${FM_CONFIG_OVERRIDE:-${FM_HOME:-<this repo>}/config}/token-headroom, else the
# default. A value that is not a whole number falls back to the default.
#   enter_five_hour  10   token-saving starts at or under this % remaining
#   enter_seven_day   5
#   exit_five_hour   20   it ends once the window reset passed and the fresh
#   exit_seven_day   10   reading is above this % (hysteresis)
#   pace_warning      1   0 turns the early pace warning off
#   enabled           1   0 (or FM_TOKEN_HEADROOM=0, or a lone "off" line) disables everything
#   max_age          5m   quota-axi --max-age, so polls reuse one reading
#
# State, all under state/: .token-saving (key=value: window, percent, resets_at
# epoch, resets_at_iso, entered), .token-saving-notice (pending one-line notices
# the watcher turns into check wakes: "<kind>\t<text>"), .token-pace-warned
# (one "<window> <resets_at>" line per warned window period), <id>.ratelimit
# (a worker waiting for the window reset: reset=<epoch|unknown>, since=<epoch>).
#
# Usage: . bin/fm-token-headroom-lib.sh
#   fm_token_headroom_refresh   reads quota, enters/clears the state, queues
#                               notices; sets FM_TOKEN_HEADROOM_TRANSITION
#                               (none|entered|exited). Returns 1 when quota
#                               could not be read (state left untouched).
#   fm_token_headroom_low       refresh, then 0 when token-saving is set; sets
#                               FM_TOKEN_SAVING_WINDOW/PERCENT/RESET_ISO.
#   fm_token_saving_active      0 when state/.token-saving exists (no quota read).
#   fm_token_notice_take        prints and removes pending notice texts, joined.
#   fm_token_rate_limit_record <state> <id> <reason>
#   fm_token_rate_limit_resume <fm-home> <send-script> <exited 0|1>

FM_TOKEN_HEADROOM_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
FM_TOKEN_HEADROOM_TRANSITION=none
FM_TOKEN_FIVE_PCT=''
FM_TOKEN_FIVE_RESET=''
FM_TOKEN_FIVE_PACE=''
FM_TOKEN_FIVE_BURN=''
FM_TOKEN_SEVEN_PCT=''
FM_TOKEN_SEVEN_RESET=''
FM_TOKEN_SEVEN_PACE=''
FM_TOKEN_SEVEN_BURN=''
FM_TOKEN_SAVING_WINDOW=''
FM_TOKEN_SAVING_PERCENT=''
FM_TOKEN_SAVING_RESET_ISO=''

fm_token_state_dir() { printf '%s\n' "${FM_STATE_OVERRIDE:-${FM_HOME:-$FM_TOKEN_HEADROOM_LIB_DIR/..}/state}"; }
fm_token_config_dir() { printf '%s\n' "${FM_CONFIG_OVERRIDE:-${FM_HOME:-$FM_TOKEN_HEADROOM_LIB_DIR/..}/config}"; }
fm_token_now() {
  case "${FM_TOKEN_HEADROOM_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_TOKEN_HEADROOM_NOW" ;;
  esac
}
fm_token_iso() {  # <epoch>
  date -u -d "@$1" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%MZ 2>/dev/null || printf '%s\n' "$1"
}

# fm_token_cfg <key> <default>: env, then config file, then default.
fm_token_cfg() {
  local key=$1 default=$2 var value='' file
  var="FM_TOKEN_HEADROOM_$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
  value=${!var:-}
  if [ -z "$value" ]; then
    file="$(fm_token_config_dir)/token-headroom"
    [ ! -r "$file" ] || value=$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\\([^[:space:]#]*\\).*/\\1/p" "$file" | tail -n 1)
  fi
  if [ "$key" = max_age ]; then
    case "$value" in ''|*[!0-9smh]*) value=$default ;; esac
  else
    case "$value" in ''|*[!0-9]*) value=$default ;; esac
    value=$((10#$value))
  fi
  printf '%s\n' "$value"
}

fm_token_headroom_enabled() {
  local file
  case "${FM_TOKEN_HEADROOM:-}" in 0|off|no|false) return 1 ;; esac
  file="$(fm_token_config_dir)/token-headroom"
  if [ -r "$file" ] && [ "$(head -n 1 "$file" 2>/dev/null | tr -d '[:space:]')" = off ]; then
    return 1
  fi
  [ "$(fm_token_cfg enabled 1)" != 0 ]
}

# fm_token_read: fill FM_TOKEN_{FIVE,SEVEN}_{PCT,RESET,PACE,BURN} from quota-axi.
fm_token_read() {
  local out parsed id pct reset pace burn
  FM_TOKEN_FIVE_PCT=''
  FM_TOKEN_FIVE_RESET=''
  FM_TOKEN_FIVE_PACE=''
  FM_TOKEN_FIVE_BURN=''
  FM_TOKEN_SEVEN_PCT=''
  FM_TOKEN_SEVEN_RESET=''
  FM_TOKEN_SEVEN_PACE=''
  FM_TOKEN_SEVEN_BURN=''
  command -v quota-axi >/dev/null 2>&1 || return 1
  command -v node >/dev/null 2>&1 || return 1
  if command -v timeout >/dev/null 2>&1; then
    out=$(timeout "${FM_TOKEN_HEADROOM_TIMEOUT:-20}" quota-axi --provider claude --json --max-age "$(fm_token_cfg max_age 5m)" 2>/dev/null) || return 1
  else
    out=$(quota-axi --provider claude --json --max-age "$(fm_token_cfg max_age 5m)" 2>/dev/null) || return 1
  fi
  [ -n "$out" ] || return 1
  parsed=$(printf '%s' "$out" | node -e '
    let s = "";
    process.stdin.on("data", (d) => (s += d)).on("end", () => {
      let v;
      try { v = JSON.parse(s); } catch { process.exit(1); }
      const providers = Array.isArray(v && v.providers) ? v.providers : [];
      const p = providers.find((x) => x && x.provider === "claude");
      if (!p || !Array.isArray(p.windows)) process.exit(1);
      for (const w of p.windows) {
        if (!w || (w.id !== "five_hour" && w.id !== "seven_day")) continue;
        if (typeof w.percentRemaining !== "number" || !isFinite(w.percentRemaining)) continue;
        const reset = Date.parse(w.resetsAt);
        const pace = w.pace && typeof w.pace === "object" ? w.pace : {};
        const burn = typeof pace.burnMultiple === "number" && isFinite(pace.burnMultiple) ? pace.burnMultiple : "";
        process.stdout.write([w.id, Math.floor(w.percentRemaining), isNaN(reset) ? "" : Math.floor(reset / 1000), typeof pace.status === "string" ? pace.status.replace(/[^a-z_-]/gi, "") : "", burn].join("\t") + "\n");
      }
    });
  ' 2>/dev/null) || return 1
  [ -n "$parsed" ] || return 1
  while IFS=$'\t' read -r id pct reset pace burn; do
    case "$pct" in ''|*[!0-9]*) continue ;; esac
    case "$reset" in *[!0-9]*) reset= ;; esac
    case "$id" in
      five_hour) FM_TOKEN_FIVE_PCT=$pct FM_TOKEN_FIVE_RESET=$reset FM_TOKEN_FIVE_PACE=$pace FM_TOKEN_FIVE_BURN=$burn ;;
      seven_day) FM_TOKEN_SEVEN_PCT=$pct FM_TOKEN_SEVEN_RESET=$reset FM_TOKEN_SEVEN_PACE=$pace FM_TOKEN_SEVEN_BURN=$burn ;;
    esac
  done <<EOF
$parsed
EOF
  [ -n "$FM_TOKEN_FIVE_PCT$FM_TOKEN_SEVEN_PCT" ]
}

fm_token_saving_active() { [ -e "$(fm_token_state_dir)/.token-saving" ]; }

fm_token_saving_field() {  # <field>
  sed -n "s/^$1=//p" "$(fm_token_state_dir)/.token-saving" 2>/dev/null | head -n 1
}

fm_token_load_saving() {
  FM_TOKEN_SAVING_WINDOW=$(fm_token_saving_field window)
  FM_TOKEN_SAVING_PERCENT=$(fm_token_saving_field percent)
  FM_TOKEN_SAVING_RESET_ISO=$(fm_token_saving_field resets_at_iso)
}

# Short mkdir lock so a spawn and the watcher cannot both announce one entry.
fm_token_lock() {
  local lock i=0
  lock="$(fm_token_state_dir)/.token-saving.lock"
  while ! mkdir "$lock" 2>/dev/null; do
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rmdir "$lock" 2>/dev/null || true; continue; fi
    i=$((i + 1))
    [ "$i" -lt 50 ] || return 1
    sleep 0.1
  done
}
fm_token_unlock() { rmdir "$(fm_token_state_dir)/.token-saving.lock" 2>/dev/null || true; }

fm_token_notice() {  # <kind> <text>
  printf '%s\t%s\n' "$1" "$2" >> "$(fm_token_state_dir)/.token-saving-notice"
}

# Print pending notice texts joined by "; " and remove them. The caller
# enqueues the wake first and removes only on success: use fm_token_notice_peek
# then fm_token_notice_clear for that order.
fm_token_notice_peek() {
  local f
  f="$(fm_token_state_dir)/.token-saving-notice"
  [ -s "$f" ] || return 1
  cut -f2- "$f" | paste -sd ';' - | sed 's/;/; /g'
}
fm_token_notice_clear() { rm -f "$(fm_token_state_dir)/.token-saving-notice"; }
fm_token_notice_take() { fm_token_notice_peek && fm_token_notice_clear; }

fm_token_window_label() { case "$1" in five_hour) echo "5-hour" ;; seven_day) echo "7-day" ;; *) echo "$1" ;; esac; }

# Early pace warning: one per window period, never while token-saving is set.
fm_token_pace_check() {  # <window> <pct> <reset> <pace> <burn> <length-seconds> <now>
  local window=$1 pct=$2 reset=$3 pace=$4 burn=$5 length=$6 now=$7 file prev eta remaining
  [ "$(fm_token_cfg pace_warning 1)" != 0 ] || return 0
  [ "$pace" = ahead ] && [ -n "$burn" ] && [ -n "$reset" ] || return 0
  remaining=$((reset - now))
  [ "$remaining" -gt 0 ] || return 0
  eta=$(awk -v p="$pct" -v b="$burn" -v l="$length" -v r="$remaining" \
    'BEGIN { if (b > 1 && p > 0) { t = p * l / (100 * b); if (t < r) printf "%d", t } }')
  [ -n "$eta" ] || return 0
  file="$(fm_token_state_dir)/.token-pace-warned"
  prev=$(awk -v w="$window" '$1 == w { print $2 }' "$file" 2>/dev/null | tail -n 1)
  if [ -n "$prev" ]; then
    # The same window period reports a resetsAt that jitters by less than minutes.
    [ "$(( reset > prev ? reset - prev : prev - reset ))" -ge 600 ] || return 0
  fi
  { grep -v "^$window " "$file" 2>/dev/null || true; printf '%s %s\n' "$window" "$reset"; } > "$file.tmp" && mv "$file.tmp" "$file"
  fm_token_notice pace "pace warning: the Claude $(fm_token_window_label "$window") window has ${pct}% left and is burning $burn x the even pace, so it is projected to run out in about $((eta / 60)) min, before it resets at $(fm_token_iso "$reset")"
}

# fm_token_headroom_refresh: read quota, then enter or clear the saving state.
fm_token_headroom_refresh() {
  local state now e5 e7 x5 x7 window='' pct='' reset='' entered trig_window trig_reset trig_pct exit_thr low=0
  FM_TOKEN_HEADROOM_TRANSITION=none
  fm_token_headroom_enabled || return 1
  state="$(fm_token_state_dir)"
  [ -d "$state" ] || return 1
  fm_token_read || return 1
  now=$(fm_token_now)
  e5=$(fm_token_cfg enter_five_hour 10)
  e7=$(fm_token_cfg enter_seven_day 5)
  x5=$(fm_token_cfg exit_five_hour 20)
  x7=$(fm_token_cfg exit_seven_day 10)
  [ -z "$FM_TOKEN_FIVE_PCT" ] || [ "$FM_TOKEN_FIVE_PCT" -gt "$e5" ] || { low=1; window=five_hour; pct=$FM_TOKEN_FIVE_PCT; reset=$FM_TOKEN_FIVE_RESET; }
  if [ -n "$FM_TOKEN_SEVEN_PCT" ] && [ "$FM_TOKEN_SEVEN_PCT" -le "$e7" ] &&
    { [ "$low" -eq 0 ] || [ "$FM_TOKEN_SEVEN_PCT" -lt "$pct" ]; }; then
    low=1; window=seven_day; pct=$FM_TOKEN_SEVEN_PCT; reset=$FM_TOKEN_SEVEN_RESET
  fi
  fm_token_lock || return 1
  if [ -e "$state/.token-saving" ]; then
    trig_window=$(fm_token_saving_field window)
    trig_reset=$(fm_token_saving_field resets_at)
    case "$trig_window" in
      five_hour) trig_pct=$FM_TOKEN_FIVE_PCT exit_thr=$x5 ;;
      seven_day) trig_pct=$FM_TOKEN_SEVEN_PCT exit_thr=$x7 ;;
      *) trig_pct='' exit_thr=0 ;;
    esac
    case "$trig_reset" in ''|*[!0-9]*) trig_reset=0 ;; esac
    if [ "$low" -eq 0 ] && [ "$now" -ge "$trig_reset" ] && [ -n "$trig_pct" ] && [ "$trig_pct" -gt "$exit_thr" ]; then
      rm -f "$state/.token-saving"
      FM_TOKEN_HEADROOM_TRANSITION=exited
      fm_token_notice exited "token-saving ended: the Claude $(fm_token_window_label "$trig_window") window has reset and ${trig_pct}% is left, so new work may start again"
    fi
  elif [ "$low" -eq 1 ]; then
    entered=$now
    [ -n "$reset" ] || reset=0
    {
      printf 'window=%s\npercent=%s\nresets_at=%s\nresets_at_iso=%s\nentered=%s\n' \
        "$window" "$pct" "$reset" "$([ "$reset" -gt 0 ] && fm_token_iso "$reset" || echo unknown)" "$entered"
    } > "$state/.token-saving.tmp" && mv "$state/.token-saving.tmp" "$state/.token-saving"
    FM_TOKEN_HEADROOM_TRANSITION=entered
    fm_token_notice entered "token-saving started: the Claude $(fm_token_window_label "$window") window has ${pct}% left, resets at $([ "$reset" -gt 0 ] && fm_token_iso "$reset" || echo unknown); no new work starts until it recovers"
  elif [ "$low" -eq 0 ]; then
    [ -z "$FM_TOKEN_FIVE_PCT" ] || fm_token_pace_check five_hour "$FM_TOKEN_FIVE_PCT" "$FM_TOKEN_FIVE_RESET" "$FM_TOKEN_FIVE_PACE" "$FM_TOKEN_FIVE_BURN" 18000 "$now"
    [ -z "$FM_TOKEN_SEVEN_PCT" ] || fm_token_pace_check seven_day "$FM_TOKEN_SEVEN_PCT" "$FM_TOKEN_SEVEN_RESET" "$FM_TOKEN_SEVEN_PACE" "$FM_TOKEN_SEVEN_BURN" 604800 "$now"
  fi
  fm_token_unlock
  return 0
}

fm_token_headroom_low() {
  fm_token_headroom_refresh || true
  fm_token_saving_active || return 1
  fm_token_load_saving
  return 0
}

# --- rate-limit stalls --------------------------------------------------------

# Record that worker <id> hit a provider rate limit and append a declared
# `paused:` line with the reset time (never `blocked:`). Idempotent while the
# record exists. Prints nothing; returns 0 when it recorded.
fm_token_rate_limit_record() {  # <state-dir> <id> <reason>
  local state=$1 id=$2 reason=$3 now reset=unknown w pct best='' until='' older
  [ -n "$id" ] && [ ! -e "$state/$id.ratelimit" ] || return 1
  now=$(fm_token_now)
  if fm_token_read; then
    for w in FIVE SEVEN; do
      eval "pct=\${FM_TOKEN_${w}_PCT} older=\${FM_TOKEN_${w}_RESET}"
      [ -n "$pct" ] && [ -n "$older" ] && [ "$older" -gt "$now" ] || continue
      if [ -z "$best" ] || [ "$pct" -lt "$best" ]; then best=$pct; reset=$older; fi
    done
  fi
  printf 'reset=%s\nsince=%s\n' "$reset" "$now" > "$state/$id.ratelimit.tmp" && mv "$state/$id.ratelimit.tmp" "$state/$id.ratelimit"
  if [ "$reset" != unknown ]; then
    until=" until $(fm_token_iso $(( (reset + 59) / 60 * 60 )))"
  fi
  printf 'paused [at=%s]: %s; waiting for the provider rate-limit window to reset, firstmate resumes this worker then%s\n' \
    "$now" "$reason" "$until" >> "$state/$id.status"
}

# Re-prompt, once, each worker whose rate-limit window has reset. A record with
# an unknown reset resumes when token-saving ends (<exited> = 1) or after six
# hours. Steers through the fm-send inbox path, never a raw key.
fm_token_rate_limit_resume() {  # <fm-home> <send-script> <exited 0|1>
  local home=$1 send=$2 exited=${3:-0} state f id reset since now due last
  state="$(fm_token_state_dir)"
  now=$(fm_token_now)
  for f in "$state"/*.ratelimit; do
    [ -e "$f" ] || continue
    id=$(basename "$f" .ratelimit)
    reset=$(sed -n 's/^reset=//p' "$f" | head -n 1)
    since=$(sed -n 's/^since=//p' "$f" | head -n 1)
    case "$since" in ''|*[!0-9]*) since=$now ;; esac
    due=0
    case "$reset" in
      ''|*[!0-9]*) { [ "$exited" = 1 ] || [ $((now - since)) -ge 21600 ]; } && due=1 ;;
      *) [ "$now" -ge $((reset + 30)) ] && due=1 ;;
    esac
    [ "$due" -eq 1 ] || continue
    last=$(tail -n 1 "$state/$id.status" 2>/dev/null || true)
    case "$last" in
      paused*"rate-limit window"*)
        [ -e "$state/$id.meta" ] || { rm -f "$f"; continue; }
        if FM_HOME="$home" "$send" "$id" "The provider rate-limit window has reset. Continue your task from where you stopped." >/dev/null 2>&1; then
          rm -f "$f"
          printf 'working [at=%s]: provider rate-limit window reset, worker re-prompted to continue\n' "$now" >> "$state/$id.status"
        fi
        ;;
      *) rm -f "$f" ;;
    esac
  done
}

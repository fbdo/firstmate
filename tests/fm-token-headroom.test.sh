#!/usr/bin/env bash
# shellcheck disable=SC2016 # lib() snippets are single-quoted so the library's shell expands them.
# Behavior tests for the token-saving guard (bin/fm-token-headroom-lib.sh owns
# the verdict): entry and exit with hysteresis, the pace warning, the spawn
# refusal and relaunch exemption, one wake per transition from the watcher's
# cycle, and rate-limit stall detection in the jcode hook. A shim quota-axi
# answers from a fixture file, so no real quota is read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-token-headroom)
NOW=1792544000
RESET5=$((NOW + 3600))
RESET7=$((NOW + 86400))
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S+00:00; }

# quota_json <pct5> <pct7> [pace5-status burn5]
quota_json() {
  local pace=${3:-behind} burn=${4:-0.5}
  cat <<JSON
{"providers":[{"provider":"claude","windows":[
{"id":"five_hour","resetsAt":"$(iso "$RESET5")","percentRemaining":$1,"pace":{"status":"$pace","burnMultiple":$burn,"reservePercentPoints":1}},
{"id":"seven_day","resetsAt":"$(iso "$RESET7")","percentRemaining":$2,"pace":{"status":"behind","burnMultiple":0.5,"reservePercentPoints":1}},
{"id":"model:fable","resetsAt":"$(iso "$RESET7")","percentRemaining":1}]}]}
JSON
}

FAKEBIN="$TMP_ROOT/bin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
[ -z "${QUOTA_FAIL:-}" ] || exit 1
cat "$QUOTA_FIXTURE"
SH
chmod +x "$FAKEBIN/quota-axi"

new_home() {  # <name> -> home dir
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/data"
  printf '%s\n' "$home"
}

# run <home> <fixture> <snippet>: source the lib with the shim on PATH.
run() {
  local home=$1 fixture=$2
  shift 2
  env FM_TOKEN_HEADROOM=1 FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    PATH="$FAKEBIN:$PATH" QUOTA_FIXTURE="$fixture" FM_TOKEN_HEADROOM_NOW="${NOW_OVERRIDE:-$NOW}" \
    bash -c ". '$ROOT/bin/fm-token-headroom-lib.sh'; $*"
}

test_entry_exit_and_hysteresis() {
  local home f out
  home=$(new_home enter)
  f="$TMP_ROOT/q.json"
  quota_json 50 80 > "$f"
  run "$home" "$f" 'fm_token_headroom_low' && fail "ample quota entered token-saving"
  quota_json 10 80 > "$f"
  run "$home" "$f" 'fm_token_headroom_low && echo "$FM_TOKEN_SAVING_WINDOW $FM_TOKEN_SAVING_PERCENT"' | grep -qx 'five_hour 10' \
    || fail "10% on the 5-hour window did not enter token-saving"
  grep -q "^window=five_hour" "$home/state/.token-saving" || fail "state record missing window"
  grep -q "^resets_at=$RESET5" "$home/state/.token-saving" || fail "state record missing resets_at"
  run "$home" "$f" 'fm_token_headroom_low' || fail "token-saving cleared while the reading was still low"
  # Recovered reading but the window has not reset yet: stays.
  quota_json 90 80 > "$f"
  run "$home" "$f" 'fm_token_headroom_low' || fail "token-saving cleared before the window reset"
  # Reset passed but reading is inside the hysteresis band (<= 20): stays.
  quota_json 15 80 > "$f"
  NOW_OVERRIDE=$((RESET5 + 60)) run "$home" "$f" 'fm_token_headroom_low' || fail "token-saving cleared inside the hysteresis band"
  quota_json 60 80 > "$f"
  NOW_OVERRIDE=$((RESET5 + 60)) run "$home" "$f" 'fm_token_headroom_low' && fail "token-saving did not clear after reset with a recovered reading"
  [ ! -e "$home/state/.token-saving" ] || fail "state record survived the exit"
  out=$(cat "$home/state/.token-saving-notice")
  [ "$(grep -c '^entered' <<<"$out")" -eq 1 ] && [ "$(grep -c '^exited' <<<"$out")" -eq 1 ] \
    || fail "expected exactly one entered and one exited notice, got: $out"
  # 7-day window triggers at <= 5%.
  home=$(new_home enter7)
  quota_json 50 5 > "$f"
  run "$home" "$f" 'fm_token_headroom_low && echo "$FM_TOKEN_SAVING_WINDOW"' | grep -qx seven_day || fail "5% on the 7-day window did not enter"
  quota_json 50 6 > "$f"
  home=$(new_home enter7b)
  run "$home" "$f" 'fm_token_headroom_low' && fail "6% on the 7-day window entered"
  pass "token-saving enters at the thresholds and clears only after reset with a recovered reading"
}

test_config_thresholds() {
  local home f
  home=$(new_home cfg)
  f="$TMP_ROOT/q.json"
  quota_json 25 80 > "$f"
  printf 'enter_five_hour=30\n' > "$home/config/token-headroom"
  run "$home" "$f" 'fm_token_headroom_low' || fail "config/token-headroom threshold ignored"
  home=$(new_home cfg-off)
  printf 'off\n' > "$home/config/token-headroom"
  quota_json 1 1 > "$f"
  run "$home" "$f" 'fm_token_headroom_low' && fail "an off config line did not disable the guard"
  pass "thresholds come from config/token-headroom and the file can disable the guard"
}

test_unmeasurable_steps_aside() {
  local home f
  home=$(new_home missing)
  f="$TMP_ROOT/q.json"
  quota_json 1 1 > "$f"
  QUOTA_FAIL=1 run "$home" "$f" 'fm_token_headroom_low' && fail "a failing quota-axi entered token-saving"
  printf 'not json' > "$f"
  run "$home" "$f" 'fm_token_headroom_low' && fail "malformed output entered token-saving"
  printf '{"providers":[{"provider":"claude","windows":[]}]}' > "$f"
  run "$home" "$f" 'fm_token_headroom_low' && fail "an empty window list entered token-saving"
  printf '{"providers":[]}' > "$f"
  run "$home" "$f" 'fm_token_headroom_low' && fail "no claude provider entered token-saving"
  env FM_TOKEN_HEADROOM=1 FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" PATH="/usr/bin:/bin" \
    bash -c ". '$ROOT/bin/fm-token-headroom-lib.sh'; command -v quota-axi >/dev/null && exit 1; fm_token_headroom_low" && fail "missing quota-axi entered token-saving"
  [ ! -e "$home/state/.token-saving" ] || fail "an unmeasurable reading wrote the state"
  pass "missing, failing, malformed, or empty quota-axi output steps aside"
}

test_pace_warning_once_per_window() {
  local home f
  home=$(new_home pace)
  f="$TMP_ROOT/q.json"
  # 40% left, burning 3x pace: 40*18000/(100*3)=2400s < 3600s to reset.
  quota_json 40 80 ahead 3 > "$f"
  run "$home" "$f" 'fm_token_headroom_low'
  grep -c '^pace' "$home/state/.token-saving-notice" | grep -qx 1 || fail "no single pace warning: $(cat "$home/state/.token-saving-notice" 2>/dev/null)"
  run "$home" "$f" 'fm_token_headroom_low'
  grep -c '^pace' "$home/state/.token-saving-notice" | grep -qx 1 || fail "the pace warning repeated within one window period"
  [ ! -e "$home/state/.token-saving" ] || fail "a pace warning entered token-saving"
  # A new window period (different resetsAt) warns again.
  RESET5=$((RESET5 + 18000)) quota_json 40 80 ahead 3 > "$f"
  NOW_OVERRIDE=$((NOW + 18000)) run "$home" "$f" 'fm_token_headroom_low'
  grep -c '^pace' "$home/state/.token-saving-notice" | grep -qx 2 || fail "the next window period did not warn again"
  # Burning ahead but projected to last past the reset: no warning.
  home=$(new_home pace-ok)
  quota_json 90 80 ahead 1.2 > "$f"
  run "$home" "$f" 'fm_token_headroom_low'
  [ ! -s "$home/state/.token-saving-notice" ] || fail "a window that lasts past its reset warned"
  # Behind pace: no warning.
  quota_json 40 80 behind 0.4 > "$f"
  run "$home" "$f" 'fm_token_headroom_low'
  [ ! -s "$home/state/.token-saving-notice" ] || fail "a behind-pace window warned"
  pass "the pace warning fires once per window period and only when exhaustion precedes the reset"
}

test_notice_wakes_once_each_way() {
  local home f out
  home=$(new_home notice)
  f="$TMP_ROOT/q.json"
  quota_json 8 80 > "$f"
  out=$(run "$home" "$f" 'fm_token_headroom_refresh; fm_token_headroom_refresh; fm_token_notice_take')
  [ "$(grep -c 'token-saving started' <<<"$out")" -eq 1 ] || fail "entry produced $out"
  out=$(run "$home" "$f" 'fm_token_notice_take' || true)
  [ -z "$out" ] || fail "a taken notice was delivered twice: $out"
  pass "each transition queues exactly one notice for the watcher's check wake"
}

# --- fm-spawn ---------------------------------------------------------------

spawn_case() {  # <name> <saving 0|1> [extra spawn args...]
  local name=$1 saving=$2 case_dir home fakebin rc=0 out
  shift 2
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir"
  home="$case_dir/home"
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" task-t
  if [ "$saving" = 1 ]; then
    printf 'window=five_hour\npercent=7\nresets_at=%s\nresets_at_iso=2026-10-21T00:59Z\nentered=%s\n' "$RESET5" "$NOW" > "$home/state/.token-saving"
  fi
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir" gh gh-axi no-mistakes)
  fm_git_init_commit "$case_dir/project"
  git -C "$case_dir/project" worktree add --quiet -b wt-task-t "$case_dir/wt" >/dev/null 2>&1
  quota_json 7 80 > "$case_dir/q.json"
  cp "$FAKEBIN/quota-axi" "$fakebin/quota-axi"
  out=$(FM_TOKEN_HEADROOM=1 QUOTA_FIXTURE="$case_dir/q.json" FM_TOKEN_HEADROOM_NOW=$NOW FM_BACKEND=tmux \
    fm_test_run_spawn "$home" "$case_dir/wt" "$fakebin" task-t "$case_dir/project" --mode local-only --yolo off "$@") || rc=$?
  printf '%s\n%s\n' "$rc" "$out"
}

test_spawn_defers_while_saving() {
  local result rc out home="$TMP_ROOT/spawn-save/home"
  result=$(spawn_case spawn-save 1)
  rc=${result%%$'\n'*}
  out=${result#*$'\n'}
  expect_code 75 "$rc" "a spawn during token-saving was not deferred: $out"
  assert_contains "$out" "deferred: the Claude 5-hour token window has 7% left and resets at 2026-10-21T00:59Z" "the deferral did not name the reset time"
  assert_contains "$out" "task task-t was not launched and its backlog item stays queued" "the deferral did not say the task stays queued"
  assert_absent "$home/state/task-t.meta" "a token deferral published a task record"
  pass "fm-spawn defers a fresh worker with exit 75 while token-saving is set"
}

test_spawn_enters_from_quota_and_relaunch_is_exempt() {
  local result rc out
  result=$(spawn_case spawn-enter 0)
  rc=${result%%$'\n'*}
  expect_code 75 "$rc" "a spawn with a low quota reading was not deferred"
  [ -e "$TMP_ROOT/spawn-enter/home/state/.token-saving" ] || fail "the spawn did not record the token-saving state"
  result=$(spawn_case spawn-relaunch 1 --relaunch)
  out=${result#*$'\n'}
  assert_not_contains "$out" "deferred:" "a relaunch was deferred by token-saving"
  pass "a spawn enters token-saving from a low reading and a relaunch is never deferred"
}

# --- watcher cadence and wakes ------------------------------------------------

CYCLE_FN=$(sed -n '/^token_headroom_cycle() {/,/^}/p' "$ROOT/bin/fm-watch.sh")

cycle() {  # <home> <fixture> <poll> <heartbeat> <hbmax>
  run "$1" "$2" "
    POLL=$3 HEARTBEAT=$4 HEARTBEAT_MAX=$5 BASE_POLL=15 BASE_HEARTBEAT=600 BASE_HEARTBEAT_MAX=7200 TOKEN_STRETCH=4 TOKEN_CHECK_INTERVAL=0
    STATE=\"\$FM_STATE_OVERRIDE\"; SCRIPT_DIR='$ROOT/bin'
    age_of() { echo 999999; }
    fm_wake_append() { echo \"APPEND \$2\"; }
    wake() { echo \"WAKE \$1\"; }
    $CYCLE_FN
    ( token_headroom_cycle; echo \"POLL=\$POLL HB=\$HEARTBEAT\" )
    ( token_headroom_cycle; echo \"AGAIN\" )
  "
}

test_watch_cycle_wakes_once_and_stretches() {
  local home f out
  home=$(new_home watch)
  f="$TMP_ROOT/q.json"
  quota_json 5 80 > "$f"
  out=$(cycle "$home" "$f" 15 600 7200)
  [ "$(grep -c '^WAKE check: token headroom: token-saving started' <<<"$out")" -eq 1 ] || fail "entry did not wake exactly once: $out"
  quota_json 5 80 > "$f"
  out=$(cycle "$home" "$f" 15 600 7200)
  assert_not_contains "$out" "WAKE" "a second cycle during token-saving woke again: $out"
  assert_contains "$out" "AGAIN" "the cycle did not finish quietly"
  quota_json 70 80 > "$f"
  out=$(NOW_OVERRIDE=$((RESET5 + 120)) cycle "$home" "$f" 60 2400 28800)
  [ "$(grep -c '^WAKE check: token headroom: token-saving ended' <<<"$out")" -eq 1 ] || fail "exit did not wake exactly once: $out"
  out=$(NOW_OVERRIDE=$((RESET5 + 240)) cycle "$home" "$f" 60 2400 28800)
  assert_not_contains "$out" "WAKE" "a cycle after the exit woke again: $out"
  assert_contains "$out" "POLL=15 HB=600" "the cadence was not restored on exit"
  pass "the watcher cycle wakes once on entry and once on exit and stretches the cadence between"
}

test_watch_cycle_stretches_poll() {
  local home f out
  home=$(new_home stretch)
  f="$TMP_ROOT/q.json"
  quota_json 5 80 > "$f"
  out=$(cycle "$home" "$f" 15 600 7200)
  assert_contains "$out" "POLL=60 HB=2400" "the cadence was not stretched while saving: $out"
  pass "the watcher stretches its poll and heartbeat while token-saving is set"
}

# --- rate-limit stalls --------------------------------------------------------

make_hook_world() {  # <name> -> primary dir (echo); worker w1 bound
  local primary="$TMP_ROOT/$1" wt="$TMP_ROOT/$1-wt" gen
  mkdir -p "$primary/bin" "$primary/state" "$primary/config" "$wt"
  cp "$ROOT"/bin/* "$primary/bin/" 2>/dev/null
  git -C "$primary" init -q
  git -C "$wt" init -q
  gen=$("$primary/bin/fm-busy-event.sh" arm "$primary/state" w1) || fail "could not arm busy"
  # shellcheck source=bin/fm-jcode-lib.sh
  . "$ROOT/bin/fm-jcode-lib.sh"
  fm_jcode_write_session_record "$primary/state" w1 session_r "$gen" "$wt" || fail "could not bind session"
  : > "$primary/state/w1.status"
  printf '%s\n' "$primary"
}

hook_error() {  # <primary> <error>
  local primary=$1
  env -u FM_HOME -u FM_STATE_OVERRIDE JCODE_HOOK_EVENT=turn_end JCODE_HOOK_SESSION_ID=session_r \
    JCODE_HOOK_CWD="$TMP_ROOT/${primary##*/}-wt" JCODE_HOOK_STATUS=error JCODE_HOOK_ERROR="$2" \
    PATH="$FAKEBIN:$PATH" QUOTA_FIXTURE="$TMP_ROOT/q.json" FM_TOKEN_HEADROOM_NOW=$NOW FM_TOKEN_HEADROOM=1 ${HOOK_SPAWN_ENV:-FM_TOKEN_RESUME_SPAWN=0} \
    "$primary/bin/fm-jcode-hook.sh" </dev/null
}

test_rate_limit_is_paused_not_blocked() {
  local primary status msg
  primary=$(make_hook_world hook-rl)
  status="$primary/state/w1.status"
  quota_json 3 80 > "$TMP_ROOT/q.json"
  for msg in \
    'Anthropic API error 429: {"type":"error","error":{"type":"rate_limit_error","message":"..."}}' \
    "This request would exceed your account's rate limit. Please try again later." \
    '[jcode-provider-failover] claude -> copilot'; do
    rm -f "$primary/state/w1.ratelimit"
    : > "$status"
    hook_error "$primary" "$msg" || fail "hooks always exit 0"
    grep -q '^paused \[at=[0-9]*\]: jcode hit a provider rate limit' "$status" || fail "rate limit not paused for '$msg': $(cat "$status")"
    grep -q "until $(date -u -d "@$(( (RESET5 + 59) / 60 * 60 ))" +%Y-%m-%dT%H:%MZ)" "$status" || fail "paused line lacks the reset time: $(cat "$status")"
    ! grep -q '^blocked' "$status" || fail "a rate limit was reported blocked"
  done
  hook_error "$primary" "$msg" || fail "hooks always exit 0"
  [ "$(wc -l < "$status")" -eq 1 ] || fail "a repeated rate-limit error appended twice"
  # Unknown reset: still paused, with no until.
  rm -f "$primary/state/w1.ratelimit"
  : > "$status"
  printf 'not json' > "$TMP_ROOT/q.json"
  hook_error "$primary" 'rate_limit_error' || fail "hooks always exit 0"
  grep -q '^paused ' "$status" || fail "unknown reset did not pause: $(cat "$status")"
  ! grep -q ' until ' "$status" || fail "unknown reset claimed an until time"
  grep -q '^reset=unknown' "$primary/state/w1.ratelimit" || fail "unknown reset not recorded"
  # An auth failure is still blocked.
  rm -f "$primary/state/w1.ratelimit"
  : > "$status"
  hook_error "$primary" 'Claude OAuth token is expired and refresh failed: invalid_grant' || fail "hooks always exit 0"
  grep -q '^blocked ' "$status" || fail "auth failure no longer blocked"
  pass "a provider rate limit is recorded as a paused wait with the reset time, once, never blocked"
}

test_rate_limit_resume_once() {
  local home sent
  home=$(new_home resume)
  : > "$home/state/w1.meta"
  printf 'reset=%s\nsince=%s\n' "$((NOW + 100))" "$NOW" > "$home/state/w1.ratelimit"
  printf 'paused [at=%s]: jcode hit a provider rate limit; waiting for the provider rate-limit window to reset\n' "$NOW" > "$home/state/w1.status"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/sent.log"\n' "$home" > "$home/send.sh"
  chmod +x "$home/send.sh"
  sent="$home/sent.log"
  run "$home" /dev/null "fm_token_rate_limit_resume '$home' '$home/send.sh' 0"
  [ ! -e "$sent" ] || fail "resumed before the window reset"
  NOW_OVERRIDE=$((NOW + 200)) run "$home" /dev/null "fm_token_rate_limit_resume '$home' '$home/send.sh' 0"
  [ "$(wc -l < "$sent")" -eq 1 ] || fail "worker was not re-prompted exactly once"
  grep -q '^w1 The provider rate-limit window has reset' "$sent" || fail "re-prompt went somewhere unexpected: $(cat "$sent")"
  NOW_OVERRIDE=$((NOW + 400)) run "$home" /dev/null "fm_token_rate_limit_resume '$home' '$home/send.sh' 0"
  [ "$(wc -l < "$sent")" -eq 1 ] || fail "worker was re-prompted twice"
  # Unknown reset resumes on token-saving exit.
  printf 'paused [at=%s]: x; waiting for the provider rate-limit window to reset\n' "$NOW" > "$home/state/w1.status"
  printf 'reset=unknown\nsince=%s\n' "$NOW" > "$home/state/w1.ratelimit"
  run "$home" /dev/null "fm_token_rate_limit_resume '$home' '$home/send.sh' 0"
  [ "$(wc -l < "$sent")" -eq 1 ] || fail "unknown-reset worker resumed without the exit trigger"
  run "$home" /dev/null "fm_token_rate_limit_resume '$home' '$home/send.sh' 1"
  [ "$(wc -l < "$sent")" -eq 2 ] || fail "unknown-reset worker did not resume on token-saving exit"
  pass "a rate-limited worker is re-prompted once after the reset, or on token-saving exit when the reset is unknown"
}

# --- detached resume waiter ---------------------------------------------------

# resume_home <name> <reset-offset>: home with worker w1 rate-limited and a fake send.
resume_home() {
  local home
  home=$(new_home "$1")
  : > "$home/state/w1.meta"
  printf 'reset=%s\nsince=%s\n' "$((NOW + $2))" "$NOW" > "$home/state/w1.ratelimit"
  printf 'paused [at=%s]: jcode hit a provider rate limit; waiting for the provider rate-limit window to reset\n' "$NOW" > "$home/state/w1.status"
  printf '#!/usr/bin/env bash\necho "${FM_HOME:-none} $*" >> "%s/sent.log"\n' "$home" > "$home/send.sh"
  chmod +x "$home/send.sh"
  printf '%s\n' "$home"
}

# resume_run <home> [args]: the waiter, with no watcher armed.
resume_run() {
  local home=$1
  shift
  env FM_TOKEN_HEADROOM=1 FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    PATH="$FAKEBIN:$PATH" QUOTA_FIXTURE=/dev/null FM_TOKEN_HEADROOM_NOW="${NOW_OVERRIDE:-$NOW}" \
    FM_TOKEN_RESUME_SEND="$home/send.sh" FM_TOKEN_RESUME_POLL=1 "$ROOT/bin/fm-token-resume.sh" "$@"
}

test_resume_waiter_without_watcher() {
  local home sent
  home=$(resume_home waiter 100)
  sent="$home/sent.log"
  resume_run "$home" --once
  [ ! -e "$sent" ] || fail "waiter re-prompted before the reset"
  [ -e "$home/state/w1.ratelimit" ] || fail "waiter dropped the record before the reset"
  NOW_OVERRIDE=$((NOW + 200)) resume_run "$home" --once
  [ "$(wc -l < "$sent")" -eq 1 ] || fail "waiter did not re-prompt exactly once"
  grep -q "^$home w1 The provider rate-limit window has reset" "$sent" || fail "re-prompt not sent to w1 under this FM_HOME: $(cat "$sent")"
  [ "$(grep -c 'token-headroom' "$home/state/.wake-queue")" -eq 1 ] || fail "expected exactly one durable wake: $(cat "$home/state/.wake-queue" 2>/dev/null)"
  grep -q 're-prompted: w1' "$home/state/.wake-queue" || fail "wake does not name the worker"
  [ ! -e "$home/state/w1.ratelimit" ] || fail "record survived the resume"
  NOW_OVERRIDE=$((NOW + 400)) resume_run "$home" --once
  [ "$(wc -l < "$sent")" -eq 1 ] && [ "$(wc -l < "$home/state/.wake-queue")" -eq 1 ] || fail "a second pass duplicated the prompt or wake"
  pass "with no watcher armed, the waiter re-prompts a reset worker once and queues one durable wake"
}

test_resume_waiter_loop_exits_and_unlocks() {
  local home
  home=$(resume_home loop -1)
  NOW_OVERRIDE=$((NOW + 100)) timeout 30 bash -c "ROOT='$ROOT' FAKEBIN='$FAKEBIN' NOW='$NOW' NOW_OVERRIDE='$((NOW + 100))'; $(declare -f resume_run); resume_run '$home'" \
    || fail "looping waiter did not exit once nothing was left"
  [ "$(wc -l < "$home/sent.log")" -eq 1 ] || fail "looping waiter did not re-prompt exactly once"
  [ ! -d "$home/state/.token-resume.lock" ] || fail "waiter left its instance lock behind"
  pass "the looping waiter resumes a due worker, exits when nothing is left, and releases its lock"
}

test_resume_waiter_single_instance_and_home_scoped() {
  local home other holder
  home=$(resume_home single 100)
  other=$(resume_home otherhome 100)
  mkdir "$home/state/.token-resume.lock"
  sleep 30 &
  holder=$!
  printf '%s\n' "$holder" > "$home/state/.token-resume.lock/pid"
  NOW_OVERRIDE=$((NOW + 200)) resume_run "$home" || true
  kill "$holder" 2>/dev/null
  [ ! -e "$home/sent.log" ] || fail "a second waiter ran while one held the instance lock"
  rm -f "$home/state/.token-resume.lock/pid"
  rmdir "$home/state/.token-resume.lock"
  NOW_OVERRIDE=$((NOW + 200)) resume_run "$home" --once
  [ -e "$home/sent.log" ] || fail "waiter did not run once the lock was free"
  [ ! -e "$other/sent.log" ] && [ -e "$other/state/w1.ratelimit" ] || fail "waiter touched another home's rate-limited worker"
  pass "the waiter is single-instance per home and never touches another home"
}

test_resume_waiter_alongside_watcher_pass() {
  local home sent
  home=$(resume_home both 100)
  sent="$home/sent.log"
  NOW_OVERRIDE=$((NOW + 200)) run "$home" /dev/null "fm_token_rate_limit_resume '$home' '$home/send.sh' 0" &
  NOW_OVERRIDE=$((NOW + 200)) resume_run "$home" --once
  wait
  [ "$(wc -l < "$sent")" -eq 1 ] || fail "watcher pass plus waiter re-prompted $(wc -l < "$sent") times"
  pass "a watcher pass racing the waiter re-prompts once"
}

test_resume_waiter_unknown_reset_fallback() {
  local home
  home=$(resume_home unknown 0)
  printf 'reset=unknown\nsince=%s\n' "$NOW" > "$home/state/w1.ratelimit"
  NOW_OVERRIDE=$((NOW + 100)) resume_run "$home" --once
  [ ! -e "$home/sent.log" ] || fail "unknown reset resumed early"
  NOW_OVERRIDE=$((NOW + 21600)) resume_run "$home" --once
  [ "$(wc -l < "$home/sent.log")" -eq 1 ] || fail "unknown reset did not resume after six hours"
  [ "$(grep -c 'token-headroom' "$home/state/.wake-queue")" -eq 1 ] || fail "no durable wake for the unknown-reset resume"
  pass "an unknown reset resumes after six hours with one durable wake"
}

test_hook_starts_waiter() {
  local primary
  primary=$(make_hook_world hookspawn)
  : > "$primary/state/w1.meta"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/sent.log"\n' "$primary" > "$primary/bin/fm-send.sh"
  chmod +x "$primary/bin/fm-send.sh"
  quota_json 50 50 > "$TMP_ROOT/q.json"
  # The reset is RESET5 (NOW+3600); the waiter's clock is already past it.
  HOOK_SPAWN_ENV="FM_TOKEN_RESUME_SPAWN=1 FM_TOKEN_RESUME_POLL=1" hook_error "$primary" 'rate_limit_error' || fail "hook must exit 0"
  for _ in $(seq 1 100); do [ -e "$primary/state/.token-resume.lock" ] && break; sleep 0.1; done
  [ -e "$primary/state/w1.ratelimit" ] || fail "hook did not record the rate limit"
  kill "$(cat "$primary/state/.token-resume.lock/pid" 2>/dev/null)" 2>/dev/null || true
  pass "the hook launches the detached waiter when it records a rate limit"
}

test_entry_exit_and_hysteresis
test_resume_waiter_without_watcher
test_resume_waiter_loop_exits_and_unlocks
test_resume_waiter_single_instance_and_home_scoped
test_resume_waiter_alongside_watcher_pass
test_resume_waiter_unknown_reset_fallback
test_hook_starts_waiter
test_config_thresholds
test_unmeasurable_steps_aside
test_pace_warning_once_per_window
test_notice_wakes_once_each_way
test_spawn_defers_while_saving
test_spawn_enters_from_quota_and_relaunch_is_exempt
test_watch_cycle_wakes_once_and_stretches
test_watch_cycle_stretches_poll
test_rate_limit_is_paused_not_blocked
test_rate_limit_resume_once

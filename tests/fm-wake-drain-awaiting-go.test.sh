#!/usr/bin/env bash
# tests/fm-wake-drain-awaiting-go.test.sh - the AWAITING PIPELINE GO section
# bin/fm-wake-drain.sh prints for a no-mistakes ship whose latest event is the
# no-PR implementation done: and that has no pipeline run, so a supervisor
# (main or secondmate) sends the go. The incident this pins: that done queued no
# further wake, so nobody sent the go and the worker waited for ~17 minutes.
# Runs the real drain over crafted state with a stubbed current-state reader.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-drain-awaiting-go-tests)

mkdir -p "$TMP_ROOT/config"
: > "$TMP_ROOT/config/supervision-host-off"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"

# A stub fm-crew-state.sh: reports the state named by FM_STUB_CREW_STATE.
STUB="$TMP_ROOT/crew-state-stub.sh"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
printf 'state: %s · source: status-log · stub\n' "${FM_STUB_CREW_STATE:-awaiting-go}"
SH
chmod +x "$STUB"
export FM_CREW_STATE_BIN="$STUB"

mk_task() {  # <state> <id> <mode> <status-line>
  printf 'kind=ship\nmode=%s\n' "$3" > "$1/$2.meta"
  printf '%s\n' "$4" > "$1/$2.status"
}

test_handoff_done_is_surfaced_until_the_go() {
  local dir state out
  dir=$(make_case surfaced)
  state="$dir/state"
  out="$dir/drain.out"
  mk_task "$state" task1 no-mistakes 'done: implemented and committed'
  FM_STATE_OVERRIDE="$state" FM_STUB_CREW_STATE=awaiting-go "$DRAIN" > "$out" || fail "drain failed"
  grep -F 'AWAITING PIPELINE GO' "$out" >/dev/null || fail "no AWAITING PIPELINE GO section: $(cat "$out")"
  grep -F 'task1: implemented and committed' "$out" >/dev/null || fail "task not listed: $(cat "$out")"
  # Still surfaced on the next drain: it is state, not a one-shot event.
  FM_STATE_OVERRIDE="$state" FM_STUB_CREW_STATE=awaiting-go "$DRAIN" > "$out" || fail "second drain failed"
  grep -F 'task1: implemented and committed' "$out" >/dev/null || fail "second drain dropped the waiting task"
  # Once a run attributes the state is no longer awaiting-go.
  FM_STATE_OVERRIDE="$state" FM_STUB_CREW_STATE=working "$DRAIN" > "$out" || fail "third drain failed"
  if grep -F 'AWAITING PIPELINE GO' "$out" >/dev/null; then fail "section persisted after the pipeline started"; fi
  pass "a no-PR handoff done is surfaced on every drain until the pipeline starts"
}

test_other_dones_are_not_surfaced() {
  local dir state out
  dir=$(make_case others)
  state="$dir/state"
  out="$dir/drain.out"
  mk_task "$state" pr1 no-mistakes 'done: PR https://github.com/o/r/pull/2 checks green'
  mk_task "$state" direct1 direct-PR 'done: implemented and committed'
  mk_task "$state" work1 no-mistakes 'working: implementing'
  FM_STATE_OVERRIDE="$state" FM_STUB_CREW_STATE=awaiting-go "$DRAIN" > "$out" || fail "drain failed"
  if grep -F 'AWAITING PIPELINE GO' "$out" >/dev/null; then fail "a non-handoff status was surfaced: $(cat "$out")"; fi
  pass "CI-ready, direct-PR, and working statuses never surface as awaiting the go"
}

test_handoff_done_is_surfaced_until_the_go
test_other_dones_are_not_surfaced

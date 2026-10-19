#!/usr/bin/env bash
# tests/fm-jcode-usage.test.sh - bin/fm-jcode-usage.sh against a fake `jcode usage --json`.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v node >/dev/null 2>&1 || { echo "skip - node not installed"; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-jcode-usage)
H="$TMP_ROOT/home"
FB="$TMP_ROOT/bin"
mkdir -p "$H/config" "$H/state" "$FB"
CALLS="$TMP_ROOT/calls"
: >"$CALLS"
cat >"$FB/jcode" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CALLS"
[ -z "\${FAKE_USAGE_FAIL:-}" ] || exit 3
case " \$* " in
  *" usage --json "*)
    cat <<'JSON'
{"providers":[
 {"provider_name":"Anthropic (Claude)","limits":[
   {"name":"5-hour window","usage_percent":3.0,"resets_at":"2026-10-19T19:59:59+00:00"},
   {"name":"7-day window","usage_percent":31.0,"resets_at":"2026-10-20T15:59:59+00:00"}],"error":null},
 {"provider_name":"GitHub Copilot","limits":[],"error":null},
 {"provider_name":"Broken, Inc","limits":[],"error":"auth failed"}]}
JSON
    ;;
esac
SH
chmod +x "$FB/jcode"
usage() { env -u FM_HOME FM_HOME="$H" FM_CONFIG_OVERRIDE="$H/config" FM_STATE_OVERRIDE="$H/state" PATH="$FB:$PATH" "$ROOT/bin/fm-jcode-usage.sh" "$@"; }

test_off_without_flag() {
  local out
  out=$(usage) || fail "off must exit 0"
  [ "$out" = "jcode-usage: off" ] || fail "absent flag prints off, got '$out'"
  [ ! -s "$CALLS" ] || fail "off must not call jcode"
  pass "usage: absent flag prints off and calls nothing"
}

test_rows_and_cache() {
  local out
  : >"$H/config/jcode-usage-evidence"
  out=$(usage) || fail "usage must succeed"
  assert_contains "$out" "provider,window,usagePercent,resetsAt,error" "header row"
  assert_contains "$out" "Anthropic (Claude),5-hour window,3,2026-10-19T19:59:59+00:00," "a limit row"
  assert_contains "$out" "Anthropic (Claude),7-day window,31,2026-10-20T15:59:59+00:00," "second limit row"
  assert_contains "$out" "GitHub Copilot,,,," "a provider with no limits keeps a row"
  assert_contains "$out" "Broken  Inc,,,,auth failed" "commas are stripped from cells and errors kept"
  [ "$(grep -c . "$CALLS")" -eq 1 ] || fail "one jcode call expected"
  usage >/dev/null || fail "cached read must succeed"
  [ "$(grep -c . "$CALLS")" -eq 1 ] || fail "a read inside the TTL must reuse the cache"
  touch -d '10 minutes ago' "$H/state/jcode/usage.json"
  usage >/dev/null || fail "stale refresh must succeed"
  [ "$(grep -c . "$CALLS")" -eq 2 ] || fail "a stale cache must refresh"
  pass "usage: rows parsed from providers[].limits[], cached for the TTL, refreshed after it"
}

test_failure_exits_one() {
  local rc=0
  rm -f "$H/state/jcode/usage.json"
  FAKE_USAGE_FAIL=1 usage >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || fail "a failed call must exit 1, got $rc"
  [ ! -s "$H/state/jcode/usage.json" ] || fail "a failed call must not leave a cache"
  mkdir -p "$H/state/jcode"
  printf 'not json' >"$H/state/jcode/usage.json"
  rc=0
  usage >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || fail "an unparsable payload must exit 1, got $rc"
  pass "usage: a failed call or unparsable output exits 1"
}

test_off_without_flag
test_rows_and_cache
test_failure_exits_one

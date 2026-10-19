#!/usr/bin/env bash
# tests/fm-jcode-viewer.test.sh - the view-only Herdr terminal of a native jcode
# worker (bin/fm-jcode-viewer.sh) against a stateful fake herdr and the fake
# jcode bridge. The viewer is only one more client of the session: these cases
# pin that it opens a tab running the keeper's attach command, is recorded,
# honors the opt-out, never types into a worker, and closes cleanly.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v jq >/dev/null 2>&1 || { echo "skip - jq not installed"; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-jcode-viewer)
FB="$TMP_ROOT/bin"
mkdir -p "$FB"
ln -s "$ROOT/tests/fixtures/fake-jcode" "$FB/jcode"
H="$TMP_ROOT/home"
mkdir -p "$H/state" "$H/config" "$TMP_ROOT/wt"
LOG="$TMP_ROOT/herdr.log"
STATEF="$TMP_ROOT/herdr-state.json"
printf '{"next":1,"workspaces":[],"tabs":[]}\n' >"$STATEF"
: >"$LOG"
cat >"$FB/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_HERDR_LOG:?}"
STATE="${FM_FAKE_HERDR_STATE:?}"
{ for a in "$@"; do printf '%s\x1f' "$a"; done; printf '\n'; } >>"$LOG"
jq_state() { jq "$@" "$STATE"; }
save() { local tmp="$STATE.tmp.$$"; cat >"$tmp" && mv "$tmp" "$STATE"; }
cmd=${1:-}; sub=${2:-}; ws=""; label=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    --workspace) ws=${args[$((i + 1))]:-} ;;
    --label) label=${args[$((i + 1))]:-} ;;
  esac
done
case "$cmd $sub" in
  "status --json") printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":true}}\n' ;;
  "session list") printf '{"sessions":[{"name":"fm-lab-viewer","running":true,"socket_path":"%s/herdr.sock"}]}\n' "${FM_FAKE_HERDR_SOCKDIR:?}" ;;
  "workspace list") jq_state '{result:{workspaces:.workspaces}}' ;;
  "workspace create")
    n=$(jq_state -r '.next'); wsid="w$n"
    jq_state --arg wsid "$wsid" --arg l "$label" --arg tabid "$wsid:t$((n + 1))" --arg paneid "$wsid:p$((n + 1))" \
      '.workspaces += [{workspace_id:$wsid, label:$l}] | .tabs += [{tab_id:$tabid,label:"1",workspace_id:$wsid,pane_id:$paneid}] | .next += 2' | save
    printf '{"result":{"workspace":{"workspace_id":"%s","label":"%s"},"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$wsid" "$label" "$wsid:t$((n + 1))" "$wsid:p$((n + 1))"
    ;;
  "tab list") jq_state --arg w "$ws" '{result:{tabs:[.tabs[]|select(.workspace_id==$w)]}}' ;;
  "tab create")
    n=$(jq_state -r '.next'); tabid="$ws:t$n"; paneid="$ws:p$n"
    jq_state --arg w "$ws" --arg l "$label" --arg t "$tabid" --arg p "$paneid" \
      '.tabs += [{tab_id:$t,label:$l,workspace_id:$w,pane_id:$p}] | .next += 1' | save
    printf '{"result":{"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$tabid" "$paneid"
    ;;
  "pane get")
    if [ "$(jq_state -r --arg p "${3:-}" '[.tabs[]|select(.pane_id==$p)]|length')" -gt 0 ]; then
      printf '{"result":{"pane":{"pane_id":"%s","tab_id":"x","workspace_id":"y"}}}\n' "${3:-}"
    else
      printf '{"error":{"code":"pane_not_found","message":"gone"}}\n'
    fi
    ;;
  "pane close") jq_state --arg p "${3:-}" '.tabs |= [.[]|select(.pane_id != $p)]' | save ;;
  "tab close") jq_state --arg t "${3:-}" '.tabs |= [.[]|select(.tab_id != $t)]' | save ;;
  *) : ;;
esac
exit 0
SH
chmod +x "$FB/herdr"

SID=session_view_1
printf 'session=%s\ngen=1\nworktree=%s\n' "$SID" "$TMP_ROOT/wt" >"$H/state/vw1.jcode-session"
printf 'window=jcode:%s\nbackend=jcode\nharness=jcode\nworktree=%s\njcode_session=%s\njcode_socket=/run/shared.sock\n' \
  "$SID" "$TMP_ROOT/wt" "$SID" >"$H/state/vw1.meta"

viewer() {  # <verb> <id>
  env -u HERDR_ENV -u TMUX -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID PATH="$FB:$PATH" FM_HOME="$H" FM_BACKEND=herdr HERDR_SESSION=fm-lab-viewer \
    FM_HERDR_LOG="$LOG" FM_FAKE_HERDR_STATE="$STATEF" FM_FAKE_HERDR_SOCKDIR="$TMP_ROOT" XDG_RUNTIME_DIR="$TMP_ROOT" FM_JCODE_BIN="$FB/jcode" \
    "$ROOT/bin/fm-jcode-viewer.sh" "$@"
}
tab_count() { jq -r '[.tabs[]|select(.label=="view-vw1")]|length' "$STATEF"; }

test_open_runs_attach_cmd_and_records() {
  local out
  out=$(viewer open vw1 2>&1) || fail "open must exit 0: $out"
  [ "$(tab_count)" = 1 ] || fail "open must create exactly one view-vw1 tab, got $(tab_count)"
  assert_contains "$(cat "$LOG")" "pane" "herdr pane command expected"
  assert_contains "$(tr '\037' ' ' <"$LOG")" "pane run" "the viewer must start its client with pane run"
  assert_contains "$(tr '\037' ' ' <"$LOG")" "jcode --resume $SID --no-update --no-selfdev" "the pane must run the keeper's attach command"
  assert_contains "$(tr '\037' ' ' <"$LOG")" "JCODE_SOCKET='/run/shared.sock'" "the viewer must dial the task's recorded daemon"
  assert_contains "$(cat "$H/state/vw1.jcode-viewer")" "pane=" "the viewer pane must be recorded"
  assert_contains "$(viewer status vw1)" "fm-lab-viewer:" "status prints session:pane"
  viewer open vw1 >/dev/null 2>&1
  [ "$(tab_count)" = 1 ] || fail "a second open must not add another viewer"
  if tr '\037' ' ' <"$LOG" | grep -Eq 'send-text|send-keys|pane send'; then
    fail "firstmate must never type into the viewer"
  fi
  pass "viewer: open creates one tab running the keeper attach command on the task's daemon, records it, and never types"
}

test_close_removes_the_tab_only() {
  viewer close vw1 || fail "close must exit 0"
  [ "$(tab_count)" = 0 ] || fail "close must remove the viewer tab"
  [ ! -e "$H/state/vw1.jcode-viewer" ] || fail "close must remove the record"
  [ -f "$H/state/vw1.jcode-session" ] && [ -f "$H/state/vw1.meta" ] || fail "close must not touch the worker's records"
  viewer close vw1 || fail "a second close is a no-op"
  pass "viewer: close removes the tab and its record and leaves the worker's records alone"
}

test_opt_out_and_scope() {
  printf 'off\n' >"$H/config/jcode-viewer"
  viewer open vw1 >/dev/null 2>&1
  [ "$(tab_count)" = 0 ] || fail "config/jcode-viewer=off must open nothing"
  rm -f "$H/config/jcode-viewer"
  printf 'window=firstmate:fm-p1\nbackend=herdr\nharness=jcode\n' >"$H/state/p1.meta"
  viewer open p1 >/dev/null 2>&1
  [ ! -e "$H/state/p1.jcode-viewer" ] || fail "a pane-backend task must get no viewer"
  env -u HERDR_ENV -u TMUX -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID PATH="$FB:$PATH" FM_HOME="$H" FM_BACKEND=tmux FM_HERDR_LOG="$LOG" FM_FAKE_HERDR_STATE="$STATEF" \
    "$ROOT/bin/fm-jcode-viewer.sh" open vw1 >/dev/null 2>&1
  [ "$(tab_count)" = 0 ] || fail "a home that is not on Herdr must open nothing"
  pass "viewer: opt-out flag, pane-backend tasks, and non-Herdr homes open nothing"
}

test_open_runs_attach_cmd_and_records
test_close_removes_the_tab_only
test_opt_out_and_scope

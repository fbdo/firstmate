#!/usr/bin/env bash
# tests/fm-jcode-brief.test.sh - the worker subagent contract in fm-brief.sh --jcode.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-jcode-brief)
HM="$TMP_ROOT/home"
mkdir -p "$HM/data" "$HM/state" "$HM/config" "$HM/projects"
run() { env -u FM_STATE_OVERRIDE FM_HOME="$HM" "$ROOT/bin/fm-brief.sh" "$@" >/dev/null; }
run jb1 proj --mode local-only --jcode || fail "scaffold with --jcode failed"
run jb2 proj --mode local-only || fail "scaffold without --jcode failed"
run jb3 proj --scout --jcode || fail "scout scaffold with --jcode failed"
for id in jb1 jb3; do
  # shellcheck disable=SC2016 # the backticks are literal text in the brief.
  grep -q 'You may start jcode subagents with your `swarm` tool' "$HM/data/$id/brief.md" || fail "$id must carry the subagent contract"
  grep -q 'at most 3 live at once' "$HM/data/$id/brief.md" || fail "$id must cap subagents at 3"
  grep -q 'Stop every subagent you started' "$HM/data/$id/brief.md" || fail "$id must require stopping subagents"
done
if grep -q 'jcode subagents' "$HM/data/jb2/brief.md"; then fail "a brief without --jcode must not carry the contract"; fi
# The contract sits after rule 5 and before rule 6.
awk '/^5\. If you hit the same obstacle/{f=1} f&&/jcode subagents/{ok=1} /^6\. /{if(f){exit}} END{exit ok?0:1}' "$HM/data/jb1/brief.md" || fail "the contract must sit after rule 5 and before rule 6"
pass "fm-brief --jcode adds the worker subagent contract and leaves other briefs unchanged"

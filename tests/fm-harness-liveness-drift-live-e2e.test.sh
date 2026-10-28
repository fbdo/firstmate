#!/usr/bin/env bash
# tests/fm-harness-liveness-drift-live-e2e.test.sh - default-on drift guard proving
# every INSTALLED harness is still classified `alive` by the tmux liveness
# probe (bin/backends/tmux.sh) AND still identified by the harness-detection
# ancestry walk (bin/fm-harness.sh).
#
# Why this file exists: both verdicts depend on how a harness names its own
# process, which is a surface the harness vendor controls and changes without
# notice. Claude Code began reporting its version string as its process name and
# became unattributable, which silently degraded supervision. A regression that
# only a real harness release can cause needs a check that runs real harnesses;
# a stubbed agent cannot see it, and neither can a table of names transcribed
# from a previous release.
#
# Detection carries the same exposure for a second reason: a structural ancestor
# now outranks an environment marker (bin/fm-harness.sh owns that boundary), so
# a harness whose process name stops matching no longer merely loses a fast
# path - the walk keeps climbing and can reach a DIFFERENT harness that really
# is further up the tree. This guard is what catches that at the release that
# causes it.
#
# Each harness is launched bare, with no prompt, so this consumes no model
# tokens. The launch uses whatever credentials the harness already has; an
# unauthenticated harness still starts its process, which is all the liveness
# probe reads.
#
# jcode is the one harness this guard cannot launch bare in the loop below: a
# bare `jcode` would attach to (or start) the captain's shared daemon. It runs
# in its own section against a PRIVATE daemon (own JCODE_HOME, runtime dir and
# socket, as tests/fm-afk-jcode-live-e2e.test.sh does) and covers the surfaces
# firstmate really uses: the TUI client in a tmux pane (the pane path
# bin/fm-spawn.sh launches), a tool subprocess of the daemon (where a native
# backend worker's own detection runs), and the native backend's own liveness
# probe (bin/backends/jcode.sh). No prompt is ever submitted.
#
# Portable serial CI installs the public Pi package but no credentials, so this
# guard checks that available token-free surface there and runs against every installed
# harness on more capable hosts. The portable counterpart in
# tests/fm-tmux-agent-liveness.test.sh pins the classifier logic in CI. Run this
# guard after any harness upgrade and before trusting refreshed evidence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_HARNESS_LIVENESS_DRIFT tmux

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

REAL_TMUX=$(command -v tmux)
SOCKET="fm-liveness-drift-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-liveness-drift.XXXXXX")
SESSION=drift

JH="$LAB/jhome"
JCODE_PRIVATE=0

# Every process of the private jcode daemon, found by its JCODE_HOME so the
# captain's shared daemon can never match.
private_daemon_pids() {
  local d
  [ "$JCODE_PRIVATE" = 1 ] || return 0
  for d in /proc/[0-9]*; do
    [ "$(cat "$d/comm" 2>/dev/null)" = jcode ] || continue
    [ -r "$d/environ" ] || continue
    tr '\0' '\n' < "$d/environ" 2>/dev/null | grep -qxF "JCODE_HOME=$JH" && printf '%s\n' "${d#/proc/}"
  done
  return 0
}

stop_private_jcode() {
  local pid
  [ "$JCODE_PRIVATE" = 1 ] || return 0
  FM_HOME="$LAB/fmhome" "$ROOT/bin/fm-jcode-keeper.sh" stop >/dev/null 2>&1 || true
  for pid in $(private_daemon_pids); do kill "$pid" 2>/dev/null; done
  sleep 1
  return 0
}

cleanup_all() {
  stop_private_jcode
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

mkdir -p "$LAB/shim" "$LAB/wt"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-cursor-lib.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$LAB/wt" \
  || fail "could not start the private tmux server"

# Kimi is not required to be on PATH; mirror bin/fm-spawn.sh's own resolution
# order so this guard covers the same binary firstmate would actually launch.
resolve_harness_binary() {  # <harness>
  local harness=$1 candidate
  # cursor is resolved FIRST, before the generic PATH lookup, and only through
  # the verified owner fm-spawn uses. The Cursor agent never installs as
  # `cursor`: it installs as `cursor-agent` plus the legacy alias `agent`. A
  # machine that also has the Cursor editor does have an executable `cursor` on
  # PATH, and launching that one exits immediately, leaving a bare shell in the
  # pane that this guard then reports as liveness drift the classifier can do
  # nothing about. Asking the owner first also keeps an unrelated executable
  # named `agent` rejected here exactly as it would be at launch.
  if [ "$harness" = cursor ]; then
    fm_cursor_resolve_binary 2>/dev/null && return 0
    return 1
  fi
  candidate=$(command -v "$harness" 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [ "$harness" = kimi ] && [ -n "${HOME:-}" ] && [ -x "$HOME/.kimi-code/bin/kimi" ]; then
    printf '%s\n' "$HOME/.kimi-code/bin/kimi"
    return 0
  fi
  return 1
}

# --- jcode: private daemon, native backend, daemon tool subprocess -----------
#
# Everything here is token-free: a session is created and resumed, no prompt is
# submitted, and the daemon's own debug `tool:bash` runs a shell command with no
# model call. The captain's shared daemon, ~/.jcode and config.toml are never
# touched: the daemon gets its own JCODE_HOME, runtime dir and socket.
JENV=()
JCODE_SID=
JCODE_SETUP_ERROR=

start_private_jcode() {
  mkdir -p "$JH/run" "$LAB/fmhome/state" "$LAB/fmhome/config"
  JENV=("JCODE_HOME=$JH" "JCODE_RUNTIME_DIR=$JH/run" "JCODE_SOCKET=$JH/run/jcode.sock" "JCODE_DEBUG_CONTROL=1" "JCODE_NO_AUTO_UPDATE=1")
  JCODE_PRIVATE=1
  env -u JCODE_SESSION_ID "${JENV[@]}" nohup jcode --quiet --no-update serve --socket "$JH/run/jcode.sock" \
    >"$LAB/jcode-serve.log" 2>&1 &
  local _
  for _ in $(seq 1 80); do [ -S "$JH/run/jcode.sock" ] && break; sleep 0.25; done
  if [ ! -S "$JH/run/jcode.sock" ]; then
    JCODE_SETUP_ERROR="daemon socket never appeared: $(tail -n 3 "$LAB/jcode-serve.log" 2>/dev/null | tr '\n' ' ')"
    return 1
  fi
  command -v node >/dev/null 2>&1 || { JCODE_SETUP_ERROR="node is required for the jcode API bridge"; return 1; }
  JCODE_SID=$(env -u JCODE_SESSION_ID "${JENV[@]}" FM_JCODE_API_ALLOW_DEFAULT_MODEL=1 \
    node "$ROOT/bin/fm-jcode-api.mjs" create "$LAB/wt" --note "liveness drift guard") \
    || { JCODE_SETUP_ERROR="session create failed"; return 1; }
  [ -n "$JCODE_SID" ] || { JCODE_SETUP_ERROR="session create printed no id"; return 1; }
  return 0
}

# The two jcode surfaces the tmux loop above cannot see.
jcode_native_checks() {  # <version>
  local version=$1 out verdict descent state meta fmh
  local -a keeper_env

  # (1) Detection from where a native-backend worker's own tools run: a tool
  # subprocess that is a CHILD OF THE DAEMON, with no pane and no TUI client.
  # The daemon runs the command through its own debug `tool:bash` (no model).
  out="$LAB/daemon-tool.out"
  : > "$out"
  env -u JCODE_SESSION_ID "${JENV[@]}" jcode debug --session "$JCODE_SID" \
    "tool:bash {\"command\":\"'$ROOT/bin/fm-harness.sh' ancestry \$\$ > '$out'; '$ROOT/bin/fm-harness.sh' ancestry-descent \$\$ >> '$out'\"}" \
    >"$LAB/daemon-tool.reply" 2>&1 || true
  verdict=$(sed -n 1p "$out")
  descent=$(sed -n '2,$p' "$out" | tr '\n' ';')
  [ "$verdict" = "comm jcode" ] || fail \
    "DETECTION DRIFT: jcode $version daemon tool subprocess resolves '${verdict:-nothing}' through the ancestry walk, not 'comm jcode'. A native-backend worker's tools run as children of the shared daemon, so firstmate cannot identify those sessions. Observed descent verdicts [$descent]; tool reply: $(tr '\n' ' ' < "$LAB/daemon-tool.reply" | cut -c1-300). Teach bin/fm-harness.sh's harness_ancestry the name this release reports."
  pass "harness detection: jcode $version daemon tool subprocess is identified by the ancestry walk at comm strength"

  # (2) Liveness through the native backend's own probe, not the tmux one: a
  # real keeper and bridge for a scratch home that records this session.
  fmh="$LAB/fmhome"
  meta="$fmh/state/jdrift.meta"
  {
    printf 'backend=jcode\nendpoint_task_id=jdrift\nwindow=jcode:%s\njcode_session=%s\nworktree=%s\nproject=%s\n' \
      "$JCODE_SID" "$JCODE_SID" "$LAB/wt" "$LAB/wt"
    printf 'jcode_home=%s\njcode_runtime_dir=%s\njcode_socket=%s\n' "$JH" "$JH/run" "$JH/run/jcode.sock"
  } >"$meta"
  # The bridge socket is derived from the scratch FM_HOME; read it back from the
  # keeper's own env verb so the record names the socket the probe will use.
  keeper_env=(env -u JCODE_SESSION_ID "${JENV[@]}" "FM_HOME=$fmh")
  eval "$("${keeper_env[@]}" "$ROOT/bin/fm-jcode-keeper.sh" env)"
  printf 'jcode_api_socket=%s\n' "$JCODE_API_SOCKET" >>"$meta"
  printf 'session=%s\ngen=1\nworktree=%s\n' "$JCODE_SID" "$LAB/wt" >"$fmh/state/jdrift.jcode-session"
  "${keeper_env[@]}" "$ROOT/bin/fm-jcode-keeper.sh" ensure >"$LAB/keeper-ensure.out" 2>&1 || fail \
    "LIVENESS DRIFT: jcode $version: the keeper and bridge for the native backend did not come up against the private daemon: $(tr '\n' ' ' < "$LAB/keeper-ensure.out")"
  state=
  for _ in $(seq 1 100); do
    # shellcheck disable=SC2016  # the single-quoted script expands in the child shell
    state=$(env "${JENV[@]}" "FM_HOME=$fmh" FM_STATE_OVERRIDE="$fmh/state" bash -c \
      '. "$1/bin/fm-backend.sh"; fm_backend_source jcode && fm_backend_agent_state jcode "jcode:$2"' _ "$ROOT" "$JCODE_SID")
    [ "$state" = alive ] && break
    sleep 0.2
  done
  [ "$state" = alive ] || fail \
    "LIVENESS DRIFT: jcode $version is running on its daemon but the native backend probe classifies '$state', not 'alive'. Supervision and lifecycle control treat this worker as unattributable. Check the daemon session listing (list_sessions) and the keeper heartbeat in $fmh/state/jcode."
  pass "harness liveness: jcode $version native backend probe classifies alive"
}

CHECKED=0
SKIPPED=

# The verified adapters, in the order the harness-adapters skill router records
# them. An adapter that gains a verified launch path belongs here too.
# muse matters most of all here: its launcher execs a VERSION-SUFFIXED binary,
# so the live process name changes on every auto-update and its install path
# carries no `muse` component to fall back on. That is precisely the drift this
# guard exists to catch, and only a real muse release can produce it.
# cursor matters for the same reason muse does, from the other direction: it
# runs as a bundled node script, so its pane title is a bare `node` that no name
# pattern can own, and identity has to come from its install path or argv[0].
for harness in claude codex opencode pi pi-signed grok kimi cursor muse jcode; do
  if ! bin_path=$(resolve_harness_binary "$harness"); then
    SKIPPED="$SKIPPED $harness"
    note "skip: $harness is not installed on this machine, so its classification is unverified here"
    continue
  fi

  version=$("$bin_path" --version 2>/dev/null | head -1 | tr -d '\r') || version=
  [ -n "$version" ] || version="unknown"
  # jcode already prints its own name ("jcode v0.99.1 (...)"); keep pass lines readable.
  [ "$harness" != jcode ] || version=${version#jcode }

  target="$SESSION:$harness"
  # cursor blocks on a workspace-trust prompt in a directory it has never seen,
  # which would hang this probe rather than classify anything; --trust is the
  # same flag fm-spawn passes for the same reason.
  launch_args=""
  [ "$harness" = cursor ] && launch_args="--trust"
  launch_prefix=
  if [ "$harness" = jcode ]; then
    # The pane runs exactly what bin/fm-spawn.sh launches for a jcode worker:
    # a TUI client resumed onto a daemon session, never a bare `jcode`. The
    # session lives on the PRIVATE daemon started below.
    if ! start_private_jcode; then
      fail "jcode ($version): could not start the private daemon or create its session: $JCODE_SETUP_ERROR"
    fi
    launch_prefix='env'
    launch_args="--resume $JCODE_SID --no-update --no-selfdev"
  fi
  # shellcheck disable=SC2086  # deliberate: an empty value must add no argument
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$harness" -c "$LAB/wt" -- \
    ${launch_prefix:+$launch_prefix} ${launch_prefix:+"${JENV[@]}"} "$bin_path" $launch_args \
    || fail "$harness ($version): could not launch a window for the liveness probe"

  state=
  for _ in $(seq 1 300); do
    state=$(fm_backend_agent_state tmux "$target")
    [ "$state" = alive ] && break
    sleep 0.2
  done

  title=$(fm_backend_tmux_current_command "$target")
  comms=$(fm_backend_tmux_foreground_comms "$target" | tr '\n' ' ')

  [ "$state" = alive ] || fail \
    "LIVENESS DRIFT: $harness $version is running but classifies '$state', not 'alive'. Supervision and lifecycle control treat this endpoint as unattributable. Observed process title '$title'; observed foreground process names [$comms]. Teach bin/fm-agent-process-lib.sh's fm_agent_process_classify_name the identity this release actually reports."

  note "$harness $version: title='$title' foreground=[$comms]"

  pass "harness liveness: $harness $version classifies alive"

  # Detection: ask the ancestry walk what it makes of this real harness process.
  # Both Pi identities share one launcher name, so ancestry can only ever prove
  # the family; only the launch-boundary marker selects the signed identity.
  expect_harness=$harness
  [ "$harness" = pi-signed ] && expect_harness=pi
  pane_pid=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$target" '#{pane_pid}' 2>/dev/null | tr -d ' ')
  [ -n "$pane_pid" ] || fail "$harness ($version): could not read the pane pid for the detection probe"
  # Probe from BELOW the pane process, not the pane process alone. The shipped
  # guarantee is a strength claim: detect_own hands an args-strength verdict back
  # to a retained foreign marker, so a harness is only protected where the walk
  # reaches it at comm strength. A harness that ships as a thin interpreter shim
  # spawning its native binary as a CHILD is args strength from the pane process
  # and comm strength from below that child - which is where firstmate's own
  # detection actually runs, as a tool subprocess. Probing only the pane would
  # therefore pass on evidence the guarantee does not rest on, and would keep
  # passing if a release stopped spawning the native child at all.
  #
  # The vantage set is the UPWARD path from the deepest foreground descendant, not
  # every descendant in the subtree, because harness_ancestry only ever climbs: a
  # sibling branch is a vantage firstmate's own detection can never occupy.
  # Restricting the deepest descendant to the pane tty's foreground process group
  # keeps a process left running in the background out of the selection as well.
  #
  # The reject-other-harness cross-check below judges COMM-strength vantages only.
  # An args-strength verdict is path-ambiguous by construction: harness_ancestry's
  # bare-interpreter branch matches a harness name anywhere in the script path, so a
  # harness-spawned MCP server running as `node <home>/.claude/mcp/<server>.js`
  # answers `args claude` purely from the .claude path component, and such a server
  # is normally a child of the agent binary rather than a sibling of it, so it can
  # be the deepest descendant and sit ON this path. That ambiguity is the sole source
  # of the false failure; a comm-strength verdict carries the real process name and
  # cannot be produced that way. The comm-strength REQUIREMENT is unchanged - some
  # vantage on the path must still name the expected harness at comm strength,
  # because detect_own hands an args-strength verdict straight back to a retained
  # foreign marker.
  # The native binary can take a moment to appear, so poll for it.
  pane_tty=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$target" '#{pane_tty}' 2>/dev/null | tr -d ' ')
  verdicts=
  for _ in $(seq 1 150); do
    fg_pids=
    if [ -n "$pane_tty" ]; then
      fg_pids=$(LC_ALL=C ps -t "${pane_tty#/dev/}" -o pid=,pgid=,tpgid= 2>/dev/null \
        | while read -r fg_pid fg_pgid fg_tpgid; do
            [ -n "$fg_pid" ] || continue
            [ "$fg_pgid" = "$fg_tpgid" ] || continue
            printf '%s ' "$fg_pid"
          done)
    fi
    # shellcheck disable=SC2086  # deliberate: the foreground pids are separate arguments
    verdicts=$("$ROOT/bin/fm-harness.sh" ancestry-descent "$pane_pid" $fg_pids 2>/dev/null || true)
    case "$verdicts" in *"comm $expect_harness"*) break ;; esac
    sleep 0.2
  done

  drift_context="Observed process title '$title'; observed foreground process names [$comms]; observed ancestry verdicts [$(printf '%s' "$verdicts" | tr '\n' ';')]."

  [ -n "$verdicts" ] || fail \
    "DETECTION DRIFT: $harness $version is running but the ancestry walk reports nothing from the pane process or any vantage below it, so firstmate cannot identify this session at all. $drift_context Teach bin/fm-harness.sh's harness_ancestry the name this release actually reports."

  SAW_COMM=0
  while read -r strength named; do
    [ -n "$strength" ] || continue
    [ "$strength" = comm ] || continue
    [ "$named" = "$expect_harness" ] || fail \
      "DETECTION DRIFT: $harness $version is running but a comm-strength vantage point on the upward path through its own session resolves to '$named', not '$expect_harness'. bin/fm-harness.sh lets a structural ancestor outrank an environment marker, so an unmatched process name can resolve to a DIFFERENT harness further up the tree instead of merely losing a fast path. $drift_context Teach bin/fm-harness.sh's harness_ancestry the name this release actually reports."
    SAW_COMM=1
  done <<EOF
$verdicts
EOF

  [ "$SAW_COMM" = 1 ] || fail \
    "DETECTION DRIFT: $harness $version is identified only at interpreter-args strength, from no vantage point on the upward path through its session at comm strength. detect_own hands an args-strength verdict back to a retained foreign marker, so a stale CLAUDECODE would silently rename this session even though this guard sees the right identity. $drift_context Restore a process name bin/fm-harness.sh's harness_ancestry can match structurally, or teach it the name this release reports."

  note "$harness $version: ancestry verdicts=[$(printf '%s' "$verdicts" | tr '\n' ';')]"
  pass "harness detection: $harness $version is identified by the ancestry walk at comm strength"
  [ "$harness" != jcode ] || jcode_native_checks "$version"
  CHECKED=$((CHECKED + 1))
done

[ "$CHECKED" -gt 0 ] || fail \
  "no verified harness is installed here, so this run proved nothing; install at least one harness before trusting a pass"

if [ -n "$SKIPPED" ]; then
  note "unverified on this machine (not installed):$SKIPPED"
fi
note "checked $CHECKED installed harness(es)"

cleanup_all
trap - EXIT

# jcode

jcode is a single native binary run as a shared `jcode serve` daemon with TUI clients attached over a Unix socket.
Investigated on 2026-10-18 with jcode v0.98.1 (1c7426eb1) on Linux arm64.
It is verified as a **primary** and for **crewmate and scout** launches on the tmux and Herdr backends; a secondmate launch is not built, so `../../../bin/fm-spawn.sh` and `../../../bin/fm-control-lib.sh` refuse it.
Cross-harness provider and credential identity is owned by `references/common/model-and-effort.md`.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `jcode`; the TUI client, the `jcode serve` daemon, and an in-process `jcode run` all report process name `jcode`. |
| Process tree | Every tool subprocess is a child of the shared `jcode serve` daemon, not of the TUI client, so the daemon pid is the only harness ancestor and is shared by every session it hosts. |
| Session identity | `JCODE_SESSION_ID` is exported into every tool subprocess. The daemon writes `$JCODE_HOME/active_pids/<session-id>` (owner pid: the daemon, or the run process) and `$JCODE_HOME/client_sessions/<client-pid>` (the session a TUI client is attached to); the latter outlives its client. |
| Marker | None used. `JCODE_SESSION_ID` is inherited by anything a jcode tool launches, so detection is the anchored process name only. |
| Session lock | `../../../bin/fm-session-lock-lib.sh` owns the jcode trust gate and anchor: the session id is trusted only when `active_pids/<id>` names the jcode ancestor, and the lock records the live attached TUI client pid, never the daemon. A daemon-hosted session with no live client stays read-only. |
| Hooks | Machine-global `[hooks]` in `~/.jcode/config.toml` or `JCODE_HOOK_*` daemon environment; `pre_tool` gates (exit 2 blocks, stderr to the model, anything else fails open), `turn_start` and `turn_end` only observe. `../../../bin/fm-jcode-hook.sh` is the single registered command for all three; `../../../bin/fm-jcode-setup.sh` prints, checks, or installs the registration. |
| Turn-end backstop | One hidden system reminder through the harness API (`../../../bin/fm-jcode-api.mjs` over `jcode api-bridge --stdio`), bounded to one per turn; `../../../docs/turnend-guard.md#jcode` owns the contract. The shared guard needs `jq` and `node`; without `jq` it fails open and no reminder is sent. |
| Delegation | The `swarm` tool both observes and spawns; `../../../bin/fm-subagent-pretool-check.sh` allows only its read-only actions on a primary home. `agentgrep` is read-only search and is not delegation. |
| Watcher wake | The `bash` tool with `run_in_background: true` and `wake: true` keeps the arm tracked and wakes the session on exit; `../../../docs/supervision-protocols/jcode.md` owns the protocol. |
| Session start | Instruction only: the project `AGENTS.md` is in the system prompt and no hook can inject the digest into model context; `../../../docs/sessionstart-nudge.md#jcode` owns the boundary. |
| Exit | `/quit` in the TUI for a primary; a worker's client is stopped by signal (below). |
| Resume | `jcode --resume <session-id>`; the TUI takes no positional prompt. |
| Model | `-m/--model <id>`, or the harness API's `set_model` on a session; discover with `jcode --quiet model list --json`. Effort is the API's `set_reasoning_effort`. |
| Isolation | `JCODE_HOME`, `JCODE_RUNTIME_DIR`, and `JCODE_SOCKET` select a separate daemon and state tree. |

## Detection

`../../../bin/fm-harness.sh` matches the anchored process name `jcode` in the ancestry walk, so a jcode primary detects as `jcode` from any tool subprocess.
`../../../bin/fm-session-lock-lib.sh` includes `^jcode$` in its harness table, refuses to record a `jcode serve` daemon pid as any lock anchor, and does not accept daemon ancestry alone as ownership.

## Worker integration

A jcode crewmate or scout is a daemon session in the task worktree; its pane only runs a TUI client attached to that session.
`../../../bin/fm-jcode-lib.sh` owns the verified facts and helpers, `../../../bin/fm-jcode-api.mjs` the harness API client, and `../../../bin/fm-spawn.sh` the launch order:

1. Before launch, the spawn creates the session through the API with the worktree as its working directory, applies the model and effort, and stores a no-reply note, because a created session that holds no message is gone once its creating connection closes.
2. It binds the session to the task in `state/<id>.jcode-session` (session, busy generation, worktree) and records `jcode_session=` plus the daemon selection it used (`jcode_home=`, `jcode_runtime_dir=`, `jcode_socket=`, each only when set) in the task record.
3. The pane runs `jcode --resume <id> --no-update --no-selfdev` under that same daemon selection.
4. Only once the client is proven attached - its `client_sessions` record, a live `jcode` process, and a command line resuming that exact session - is the brief sent through the API, because a turn whose only client disconnects is abandoned and the short-lived API call disconnects at once.
5. The spawn reports success on the first `jcode-hook` busy event, so a daemon that does not run this home's hooks fails the spawn.

| Need | Mechanism |
|---|---|
| Busy state | `turn_start` records busy and `turn_end` records idle plus the turn-ended notification, through `../../../bin/fm-jcode-hook.sh` for the bound session in its own worktree only; a cancelled turn fires `turn_end` too. |
| Steering | `../../../bin/fm-send.sh`'s ordinary doorbell typed into the TUI composer; the composer reads `unknown` (its prompt is `N>`), which the doorbell tolerates. |
| Interrupt | API `cancel`, repeated on one attached connection until the turn reports done, because a cancel from a connection that did not start the turn is cleared 500 ms later and can lose that race. |
| Exit | Cancel any running turn through the API, then SIGTERM the proven client, which exits cleanly and leaves the idle session resumable. Nothing is typed. |
| Relaunch | A fresh session in the recorded worktree and endpoint, through the same spawn path. |
| Model and effort | Applied at creation; both persist with the session. While a client holds a session, another connection's attach reports the daemon's default effort, so that report is no reading of a held session. |

Tool commands run under the shared daemon, never under the pane, so the pane's launch environment does not reach them: the commit-trailer strip hook (`../../../bin/fm-git-strip-ai-trailers.sh`) does not apply to a jcode worker's commits, and a `forge=external` ship, whose push guard rides that environment, is refused.
`tests/fm-jcode-harness.test.sh` pins the worker contracts portably, and `tests/fm-jcode-signals-live-e2e.test.sh` (opt-in `FM_JCODE_SIGNALS_LIVE=1`, spends tokens) drives them live on an isolated Herdr lab and a private daemon; `../../../docs/verification/jcode.md` records the evidence.

## Primary integration

Register the hooks once per machine with `../../../bin/fm-jcode-setup.sh`, then start the primary as an interactive `jcode` TUI inside the home.
The dispatcher ignores every session whose working directory is not this home, so the global registration is safe for unrelated jcode work.
`tests/fm-jcode-harness.test.sh` is the portable regression.
`../../../docs/verification/supervision.md` under "jcode primary hooks" records the live evidence; there is no automated live guard yet.
Away and quiet postures (`/afk`, `/quiet`) and the supervision host are not verified on a jcode primary; jcode is outside the supervision host's primary list, so `/afk` falls back to the daemon path, whose supervisor injection has not been exercised against a jcode pane.

# jcode

jcode is a single native binary run as a shared `jcode serve` daemon with TUI clients attached over a Unix socket.
Investigated on 2026-10-18 with jcode v0.98.1 (1c7426eb1) on Linux arm64.
It is a **primary-only** identity: crewmate, scout, and secondmate dispatch on jcode are not yet built, so `../../../bin/fm-spawn.sh` has no jcode launch template and refuses it.
Cross-harness provider and credential identity is owned by `references/common/model-and-effort.md`.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `jcode`; the TUI client, the `jcode serve` daemon, and an in-process `jcode run` all report process name `jcode`. |
| Process tree | Every tool subprocess is a child of the shared `jcode serve` daemon, not of the TUI client, so the daemon pid is the only harness ancestor and is shared by every session it hosts. |
| Session identity | `JCODE_SESSION_ID` is exported into every tool subprocess. The daemon writes `$JCODE_HOME/active_pids/<session-id>` (owner pid: the daemon, or the run process) and `$JCODE_HOME/client_sessions/<client-pid>` (the session a TUI client is attached to); the latter outlives its client. |
| Marker | None used. `JCODE_SESSION_ID` is inherited by anything a jcode tool launches, so detection is the anchored process name only. |
| Session lock | `../../../bin/fm-session-lock-lib.sh` owns the jcode trust gate and anchor: the session id is trusted only when `active_pids/<id>` names the jcode ancestor, and the lock records the live attached TUI client pid, never the daemon. A daemon-hosted session with no live client stays read-only. |
| Hooks | Machine-global `[hooks]` in `~/.jcode/config.toml` or `JCODE_HOOK_*` daemon environment; `pre_tool` gates (exit 2 blocks, stderr to the model, anything else fails open), `turn_end` only observes. `../../../bin/fm-jcode-hook.sh` is the single registered command; `../../../bin/fm-jcode-setup.sh` prints or installs the registration. |
| Turn-end backstop | One hidden system reminder through the harness API (`../../../bin/fm-jcode-api.mjs` over `jcode api-bridge --stdio`), bounded to one per turn; `../../../docs/turnend-guard.md#jcode` owns the contract. The shared guard needs `jq` and `node`; without `jq` it fails open and no reminder is sent. |
| Delegation | The `swarm` tool both observes and spawns; `../../../bin/fm-subagent-pretool-check.sh` allows only its read-only actions on a primary home. `agentgrep` is read-only search and is not delegation. |
| Watcher wake | The `bash` tool with `run_in_background: true` and `wake: true` keeps the arm tracked and wakes the session on exit; `../../../docs/supervision-protocols/jcode.md` owns the protocol. |
| Session start | Instruction only: the project `AGENTS.md` is in the system prompt and no hook can inject the digest into model context; `../../../docs/sessionstart-nudge.md#jcode` owns the boundary. |
| Exit | `/quit` in the TUI. |
| Resume | `jcode --resume <session-id>`. |
| Model | `-m/--model <id>`; discover with `jcode --quiet model list --json`. |
| Isolation | `JCODE_HOME`, `JCODE_RUNTIME_DIR`, and `JCODE_SOCKET` select a separate daemon and state tree. |

## Detection

`../../../bin/fm-harness.sh` matches the anchored process name `jcode` in the ancestry walk, so a jcode primary detects as `jcode` from any tool subprocess.
`../../../bin/fm-session-lock-lib.sh` includes `^jcode$` in its harness table, refuses to record a `jcode serve` daemon pid as any lock anchor, and does not accept daemon ancestry alone as ownership.

## Primary integration

Register the hooks once per machine with `../../../bin/fm-jcode-setup.sh`, then start the primary as an interactive `jcode` TUI inside the home.
The dispatcher ignores every session whose working directory is not this home, so the global registration is safe for unrelated jcode work.
`tests/fm-jcode-harness.test.sh` is the portable regression.
`../../../docs/verification/supervision.md` under "jcode primary hooks" records the live evidence; there is no automated live guard yet.
Away and quiet postures (`/afk`, `/quiet`) and the supervision host are not verified on a jcode primary; jcode is outside the supervision host's primary list, so `/afk` falls back to the daemon path, whose supervisor injection has not been exercised against a jcode pane.

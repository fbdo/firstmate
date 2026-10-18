# jcode worker verification

Audience: maintainer verification.

The [adapter reference](../../.agents/skills/harness-adapters/references/harness/jcode.md) owns operating facts, and [`bin/fm-jcode-lib.sh`](../../bin/fm-jcode-lib.sh) owns the worker mechanics and the verified facts they rest on.
This record covers jcode crewmates and scouts on Herdr panes.
The primary's evidence is in [supervision verification](supervision.md#jcode-primary-hooks-2026-10-18); secondmates are outside this guarantee, and the tmux backend shares the same backend-neutral mechanics but has no live evidence here.
The release number below identifies evidence, not a requirement.

## Refresh commands

```sh
jcode --version
jcode --quiet model list --json
bash bin/fm-test-run.sh tests/fm-jcode-harness.test.sh
FM_JCODE_SIGNALS_LIVE=1 bash tests/fm-jcode-signals-live-e2e.test.sh
```

The live guard spends model tokens and runs only on opt-in.
It provisions an isolated Herdr lab session through `bin/fm-herdr-lab.sh` and a private jcode daemon selected by `JCODE_HOME`, `JCODE_RUNTIME_DIR`, and `JCODE_SOCKET`, with the operator's provider credentials linked rather than copied and the hooks passed as `bin/fm-jcode-setup.sh env` prints them, so the operator's shared daemon and `~/.jcode/config.toml` are never touched.
It uses a marked disposable `FM_HOME`, a scratch clone, and a `treehouse` stand-in, and starts the lab server with `SHELL` naming a bash that reads no startup files, then proves a lab pane resolves the stand-in before any spawn, so no Treehouse pool is touched.
Its real Firstmate verbs cover spawn, durable inbox delivery and acknowledgement, interrupt, exit, and relaunch.
`FM_JCODE_LIVE_EVIDENCE=<dir>` keeps a failed run's session records, daemon logs, task state, and pane capture.

## Live result, 2026-10-18

jcode v0.98.1 (1c7426eb1) on Linux arm64, Herdr 0.9.3, default model `claude-opus-5-5` at effort `low`:

```text
ok - jcode v0.98.1 (1c7426eb1): the spawn creates the session through the API and attaches client 784564 in the pane
ok - jcode v0.98.1 (1c7426eb1): the API-delivered brief ran in the worktree and fm-harness.sh detects jcode from a tool subprocess
ok - jcode v0.98.1 (1c7426eb1): turn_start opened and turn_end closed the busy record, and the turn-ended marker was touched
ok - jcode v0.98.1 (1c7426eb1): the brief turn ran under the pinned model=claude-opus-5-5 effort=low
ok - jcode v0.98.1 (1c7426eb1): fm-send's doorbell reaches the jcode TUI, and the durable message is read, acted on, and acknowledged
ok - jcode v0.98.1 (1c7426eb1): fm-control interrupt cancels the running turn through the API, turn_end closes it, and the worker stays up
ok - jcode v0.98.1 (1c7426eb1): fm-control exit stops the pane's client, leaving the endpoint, worktree, and session
ok - jcode v0.98.1 (1c7426eb1): fm-control relaunch starts a fresh session in the same worktree and endpoint, and it runs the brief
```

## Probe evidence behind the mechanics

These were observed against private daemons on the same version while the launch shape was designed:

| Question | Observed |
|---|---|
| Does an API-created session survive its creating connection? | No: once that connection closed, `attach_session` answered `unknown_session` and `jcode --resume <id>` reported no such session. Adding one `send_message` with `no_reply: true` before closing wrote the session to disk without a turn (no `turn_start`), and `--resume` then attached. |
| Does a brief turn survive the API call that sent it? | Yes while the pane's TUI client is attached: the daemon logged `Retaining disconnected turn` and the turn ended with `turn_end status=ok`. |
| Does one API `cancel` stop a turn started by another connection? | Not reliably: the daemon logged `SERVER_INTERRUPT_CANCEL_NO_LOCAL_TASK`, cleared the signal 500 ms later, and the turn ran to completion. Cancels repeated every 300 ms on one attached connection ended the turn within about a second, with `turn_done` on that connection and `turn_end` from the hook. |
| How does a worker's client exit? | SIGTERM to the TUI client printed its resume command, released its Herdr agent report, fired `session_end`, and left the pane at its shell; the session stayed resumable. |
| Do model and effort hold through the TUI's resume? | Yes: a session created with effort `low` (with or without a model) ran its next turn and saved `reasoning_effort: low`. While the TUI held the session, a second connection's attach reported the daemon default `medium`, so that report is no reading of a held session. |
| What does the composer read? | `unknown` (the prompt is `N>`); the ordinary doorbell still lands, as the live steer above shows. |

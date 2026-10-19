# Native jcode runtime backend

The `jcode` runtime backend runs a Firstmate crewmate or scout as a session on the captain's one shared jcode daemon, with no pane. It is experimental, jcode-harness only, and ships beside the pane path (tmux or Herdr plus `jcode --resume`), which stays the default.

## Selection

- `config/jcode-runtime` holds `pane` (default) or `native`. With `native`, a jcode spawn with no explicit backend uses `backend=jcode`.
- `--backend jcode` or `FM_BACKEND=jcode` select it explicitly. It is never auto-detected, and `config/backend=jcode` makes every non-jcode spawn refuse.
- It refuses any other harness, `--secondmate`, a missing `--model`, a `forge=external` project, and a home whose jcode hooks are not registered (`bin/fm-jcode-setup.sh status`). The model is always explicit because the daemon default for API-created sessions is unpredictable.

## Shape

One shared daemon (the captain's, `JCODE_SOCKET`, default `$XDG_RUNTIME_DIR/jcode.sock`) serves everyone. Each home owns two small pieces, both managed by `bin/fm-jcode-keeper.sh` (`env`, `ensure`, `status`, `stop`, `attach-cmd <task>`):

- an API bridge (`jcode api-bridge --api-socket`) at `${XDG_RUNTIME_DIR:-/tmp}/fm-jcode-<hash of FM_HOME>/api.sock`, and
- a keeper client (`bin/fm-jcode-keeper.mjs`) that stays attached to every worker session this home owns. A turn whose last attached client disconnects is abandoned by the daemon, so the keeper is what makes a worker's turn survive.

`ensure` never starts, stops, or reloads the daemon: a refused daemon socket exits 1 (`shared jcode daemon is not running`). `stop` ends only this home's bridge and keeper.

## Records (Firstmate stays the source of truth)

`state/jcode/` holds `live/<session>` (busy, idle, or unknown), `transitions` (normalized records the watcher's push path tails), `injected/<session>` (soft interrupts the daemon confirmed), `recovered/<session>`, and `keeper.pid|beat|log`. `state/<task>.jcode-session` binds a session to a task, `.jcode-children` lists its subagents, and `.jcode-exited` marks an exited worker.

## Mechanisms

| Need | How |
| --- | --- |
| Steering text and the inbox doorbell | `soft_interrupt` with client id `fm-<task>-<epoch>`; confirmed by the keeper's `injected/` record. The durable message in `state/<task>.inbox` and the worker's `mv` to `handled/` stay the acknowledgement. |
| Busy and idle | Keeper events into `live/` and `transitions`; the hook writes no busy record for a native task. |
| Interrupt, exit, relaunch | `cancel`; `cancel` plus the exited marker; `cancel` plus an in-place re-prompt with the brief and note. A cross-harness relaunch is refused. |
| Crashed turn | If a session is found idle with its history ending on a user row and no terminal status, the keeper re-prompts once. A second crash records a `blocked` transition. A `session_recovery` event on attach triggers the same check. |
| Worker status | The worker appends to `state/<task>.status`, as always. Nothing is sent to the primary's conversation. |
| Fleet visibility | Each session is titled `fm:<task>`. |

## Protecting the captain's sessions

Every mutating call (send, soft, cancel, archive) first proves the session is recorded in this home (`fm_jcode_owned_session`). The keeper attaches only owned sessions and reads `list_sessions` only to discover children of owned ones. Firstmate never sets swarm labels, edits `~/.jcode/config.toml` (except `fm-jcode-setup.sh install` with consent), or runs `jcode server` verbs.

## Worker subagents

A native jcode worker may start subagents with its `swarm` tool. The hook fences a bound worker narrowly: any `to_swarm`, `set_swarm_label`, `approve_plan`, `propose_plan`, `run_plan`, and `assign_role` of `coordinator` are denied. The brief (`fm-brief.sh --jcode`) caps live subagents at 3 and requires them to be stopped before the worker reports a terminal state. Teardown archives each recorded or live child whose `working_dir` is inside the task worktree (a child outside it is logged and left alone) before archiving the worker. The primary's swarm fence is unchanged.

## Cost and limits

Per home: the bridge (about 30-40 MB) and the keeper (about 47 MB). Memory-off is applied by the keeper on every attach because it is not durable once nothing holds the session. If the daemon is down, the watcher raises one stale wake per outage; the captain's next jcode client restarts the daemon.

## Proof

Portable: `tests/fm-jcode-api.test.sh`, `fm-jcode-keeper.test.sh`, `fm-jcode-backend.test.sh`, `fm-jcode-native-spawn.test.sh`, `fm-jcode-subagents.test.sh`, `fm-jcode-brief.test.sh`. Live (opt-in, spends tokens): `FM_JCODE_NATIVE_LIVE=1 tests/fm-jcode-native-live-e2e.test.sh`; evidence in [`verification/jcode.md`](verification/jcode.md).

# Native jcode runtime backend

The `jcode` runtime backend runs a Firstmate crewmate or scout as a session on the captain's one shared jcode daemon, with no pane. It is experimental, jcode-harness only, and ships beside the pane path (tmux or Herdr plus `jcode --resume`), which stays the default.

## Selection

- `config/jcode-runtime` holds `pane` (default) or `native`. With `native`, a jcode spawn with no explicit backend uses `backend=jcode`.
- `--backend jcode` or `FM_BACKEND=jcode` select it explicitly. It is never auto-detected, and `config/backend=jcode` makes every non-jcode spawn refuse.
- It refuses any other harness, `--secondmate`, a missing `--model`, and a home whose jcode hooks are not registered (`bin/fm-jcode-setup.sh status`). The model is always explicit because the daemon default for API-created sessions is unpredictable. A `forge=external` ship is allowed, because its push guard rides the worktree's own git config rather than the pane (see "Commit hooks").

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

## Viewer

Each native worker gets a view-only Herdr terminal: `bin/fm-jcode-viewer.sh open` (run by `fm-spawn` once the task is published) adds a tab `view-<task>` running `jcode --resume <session>` (`fm-jcode-keeper.sh attach-cmd`), recorded in `state/<task>.jcode-viewer`, and cleanup closes it first.
The keeper stays the authoritative client, so closing the viewer only detaches one more client and never affects the worker, and firstmate never types into it.
It needs a Herdr-backed home; on any other setup nothing opens.
`config/jcode-viewer` holding `off` opts out for memory-tight hosts (each viewer is one more TUI client, about 60 MB).

## Commit hooks

Tool commands run under the shared daemon, so the pane environment that carries the AI-trailer strip for other harnesses never reaches them.
For a jcode task the spawn also records the task's hooks directory as `core.hooksPath` in the worktree's own git config (`extensions.worktreeConfig`, `git config --worktree`), so every git command in that worktree strips AI trailers and, for `forge=external`, runs the push guard.
The wrappers chain to the repository's own hooks through a path fixed at install time.
Cleanup removes the entry (`fm-git-strip-ai-trailers.sh uninstall-worktree`) before the worktree returns to its pool.

## Secondmates

A jcode secondmate runs as a pane-attached session on the same shared daemon, never a private one: an API-created session whose working directory is the secondmate home, bound in the parent's `state/<id>.jcode-session`, with `jcode --resume` in the mate's own Herdr or tmux pane.
The live TUI client anchors the mate's session lock and retains its turns.
`config/secondmate-harness` must carry a model (`jcode <model> [<effort>]`), `--backend jcode` and remote routes stay refused, and `config/jcode-runtime` is inherited into the mate home so its own crew follow the captain's pane or native choice.
Because every tool shell is a child of the daemon, the spawn refuses a daemon whose environment carries `FM_HOME` or an `FM_*_OVERRIDE`.
The parent's hook dispatcher delegates the mate's events to the mate's own dispatcher (one level, only for a recorded `kind=secondmate` home whose marker matches), and the parent never mutates sessions bound only in the mate's `state/`.
Recovery starts a fresh session and archives the old one after readiness.

## Opt-in extras

- **Worker memory.** Memory is off for every jcode crewmate and scout. `config/jcode-worker-memory` holding `on` leaves the daemon's setting alone (the keeper skips `memory off`, the pane spawn sends none). Anything but `on` or `off` is treated as off with a warning. Primaries and secondmates follow the daemon setting, and the file is inherited into secondmate homes.
- **jcode memory as a tier.** The captain may declare the jcode `memory` tool as an external memory tier in the `Memory layering` section of `data/captain.md` ([`configuration.md`](configuration.md) "External memory tiers"). Example destination: the jcode `memory` tool in a jcode primary session, global scope; classes: cross-project captain preferences and corrections; correction rule: forget then remember, never a silent edit; capture: capture first, then report. Caveats: Jev recall sends memory text to a remote provider, project scope is keyed by working directory so worktrees and homes do not share project memories, and the `jcode memory` CLI has no write verb, so capture is possible only from a jcode session and a non-jcode firstmate cannot capture on a worker's behalf.
- **Ambient mode.** Firstmate never enables or uses ambient mode, which is a daemon-wide captain setting that conflicts with explicit authority and idle-by-default secondmates. `fm-jcode-setup.sh status` prints one read-only warning line when `[ambient]` is enabled.
- **Usage evidence.** `config/jcode-usage-evidence` (presence) enables `bin/fm-jcode-usage.sh`, which caches `jcode usage --json` for 300 seconds and prints `provider,window,usagePercent,resetsAt,error` rows. It is supplementary data only: `quota-axi` stays the ranker.

## Worker subagents

A native jcode worker may start subagents with its `swarm` tool. The hook fences a bound worker narrowly: any `to_swarm`, `set_swarm_label`, `approve_plan`, `propose_plan`, `run_plan`, and `assign_role` of `coordinator` are denied. The brief (`fm-brief.sh --jcode`) caps live subagents at 3 and requires them to be stopped before the worker reports a terminal state. Teardown archives each recorded or live child whose `working_dir` is inside the task worktree (a child outside it is logged and left alone) before archiving the worker. The primary's swarm fence is unchanged.

## Cost and limits

Per home: the bridge (about 30-40 MB) and the keeper (about 47 MB). Memory-off is applied by the keeper on every attach because it is not durable once nothing holds the session. If the daemon is down, the watcher raises one stale wake per outage; the captain's next jcode client restarts the daemon.

## Proof

Portable: `tests/fm-jcode-api.test.sh`, `fm-jcode-keeper.test.sh`, `fm-jcode-backend.test.sh`, `fm-jcode-native-spawn.test.sh`, `fm-jcode-subagents.test.sh`, `fm-jcode-brief.test.sh`, `fm-jcode-secondmate.test.sh`, `fm-jcode-viewer.test.sh`, `fm-jcode-usage.test.sh`, and the secondmate cases of `fm-jcode-harness.test.sh`. Live (opt-in, spends tokens): `FM_JCODE_NATIVE_LIVE=1 tests/fm-jcode-native-live-e2e.test.sh`; evidence in [`verification/jcode.md`](verification/jcode.md).

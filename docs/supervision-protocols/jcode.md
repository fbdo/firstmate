Mode: jcode background-wake supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle: arm with jcode's tracked background `bash` tool, as its own call:

   `bash` with `run_in_background: true` and `wake: true` on:
   `[ -f __FM_X_MODE_ENV_SH__ ] && . __FM_X_MODE_ENV_SH__; exec bin/fm-watch-arm.sh`

4. Trust only the arm's one-line status, read with the `bg` tool (`output` or `wait` on the returned task id).
5. `watcher: started ...` or `watcher: attached ...` means a live cycle exists.
   On attach, the background task follows verified identity-matched successors instead of exiting when the first cycle ends.
6. Failure or missing cycle only: `watcher: FAILED ...` means supervision is down; fix and re-arm.
7. After a successful start or attach status, end the turn.
   The background task remains the live wait until it returns an actionable wake or failure.
8. Waiting is silent.
9. Never use shell `&` for firstmate supervision.
10. Never bundle the arm onto another command.
    A shell `&`, a truncating pipe, or bundling is denied automatically by the `pre_tool` seatbelt (`bin/fm-jcode-hook.sh`) whenever this home's jcode hooks are registered.

jcode wakes this session with a background-task-completed message when the arm exits.
When that message names the arm's task:
1. Run `bin/fm-wake-drain.sh` first.
2. Read the arm's reason line from the completion message, or with `bg` `output` on its task id.
3. Handle `signal`, `stale`, `check`, or `heartbeat` using the harness-neutral contract in `AGENTS.md`.
4. Ordinary wake: re-arm the next cycle with the same background call if the home still needs supervision, as `bin/fm-supervision-lib.sh` defines it.
5. Do not invent a wake from an attach-status line alone.
   Drain the queue and act only on real wake records, the drain's `OPEN DECISIONS` and `UNREAD STATUS` entries, or a real watcher reason line.
   Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
   See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.

The registered jcode `turn_end` hook runs `bin/fm-jcode-hook.sh` as a backstop, not the normal wake path.
When supervision is needed but not live, it submits one hidden Firstmate turn-end reminder that starts one follow-up turn; act on it by arming the watcher with the background protocol above.
[`turnend-guard.md`](../turnend-guard.md#jcode) owns its scope, bound, and limits.

The supported jcode primary is an interactive TUI client attached to a jcode daemon, because the session lock is anchored on that live client process.
Do not run the primary firstmate as a one-shot `jcode run`.

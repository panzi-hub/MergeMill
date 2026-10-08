# Dispatcher Webhook Wake

**Status:** Implemented (issue #35, [INV-127](invariants.md#inv-127-the-webhook-wake-kicks-the-same-dispatcher-ticksh-entry-point-and-never-becomes-a-second-scheduler)).

`dispatcher-wake.sh` is a **same-entry-point kick** for the dispatcher. When
GitHub reports a dispatchable change, it runs the existing
`dispatcher-tick.sh` sooner than the launchd interval so the change is not
left unseen for up to 300 seconds.

It is **not** a scheduler, **not** a second clock, and **not** a
dispatcher. It never reads labels, never decides what to spawn, and never
puts the webhook body in front of an agent.

## Operator contract

1. **launchd remains the only clock.** The `com.mergemill.dispatcher`
   launchd agent installed by `install-dispatcher-timer.sh` stays
   installed and unchanged, still ticking every 300 seconds
   ([platform.md](platform.md)). No cron, systemd, or OpenClaw clock is
   added. The wake only makes a tick happen *sooner*; if it is absent or
   its feed is down, the pipeline still runs at the launchd cadence.
2. **The wake is a kick on the same entry point.** It invokes
   `dispatcher-tick.sh` — the exact file a manual debug run uses —
   with no arguments and empty stdin. It does not scan labels,
   transitions issues, or spawn wrappers itself. `dispatcher-tick.sh`
   remains the only component that reads the label state machine.
3. **The webhook body is never handed to an agent.** It is an untrusted
   hint that *something may have changed*. The receiver verifies the
   signature, gates on repository and event, then discards the body. A bad
   hint is dropped, never acted on.
4. **A sleeping Mac is not woken.** Nothing here wakes the host; the next
   launchd tick covers any change that arrived while the Mac slept.

## Input surface

The receiver reads **exactly one raw webhook delivery** (HTTP request
headers, a blank line, then the JSON body) from **stdin**. It opens **no
socket** — because it binds nothing, it cannot bind a public interface.
The local feed (Tailscale, an SSH tunnel, a self-hosted runner, a test
harness, or a loopback listener of the operator's choosing) is operator
setup and MUST be loopback-only: never expose the receiver on a public
interface, and never forward the unverified body anywhere else.

A live GitHub webhook registration is out of scope for this tree. The
secret and the feed are operator configuration; tests feed fixtures
directly.

## Gates (in order)

The receiver rejects or ignores a delivery without starting a tick unless
every gate passes:

| Order | Gate | On failure |
|-------|------|------------|
| 1 | `WEBHOOK_SECRET` configured | reject (fail closed) |
| 2 | `X-Hub-Signature-256: sha256=<hex>` present and matching the HMAC-SHA256 of the exact body bytes | reject |
| 3 | `repository.full_name == $REPO` | ignore |
| 4 | event is dispatchable | ignore |

Dispatchable events, and only these:

- `issues` / `labeled` with `label.name` ∈ {`MergeMill`, `pending-review`,
  `pending-dev`};
- `pull_request` / `opened` | `synchronize`;
- `check_run` / `completed`; `check_suite` / `completed`.

Comments, pushes, edits, `unlabeled`, deletions, `closed`, and every other
event are ignored.

## Coalescing and mutual exclusion

Wake state lives in a private directory (mode 0700), default
`${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/mergemill-dispatcher-wake`,
overridable with `WAKE_STATE_DIR`.

- **Coalesce window.** Deliveries that arrive within `WAKE_WINDOW_SECONDS`
  (default 15) of the first accepted delivery start **at most one** tick.
  A burst does not fan out into a storm of ticks.
- **Mutual exclusion.** The receiver owns a lock for this wake. If a
  wake-invoked tick is already running, a new accepted delivery does not
  start a second tick; it requests exactly **one follow-up**, which runs
  after the current tick exits. A tick already running is detected by
  this lock, never by parsing launchd. A lock left by a dead receiver is
  stolen, so a crashed wake cannot wedge the lane: a dead holder's pid, a
  lock with no pid recorded (holder died between `mkdir` and the pid
  write, after a short grace), or a lock older than one hour (PID reuse)
  is reclaimed. A normal error abort while the lock is held releases it
  on exit; a receiver killed by a signal leaves its lock, which the
  stale-lock path reclaims.
- **Bounded follow-up.** At most one follow-up runs per session; a steady
  stream cannot livelock the wake. Any residual boundary race degrades to
  the launchd backstop (≤ 300 s), never to a wrong action.

This lock is scoped to the wake. A launchd tick and a wake tick can still
overlap, exactly as two launchd ticks never do because launchd serializes
its own job; the wake does not change `dispatcher-tick.sh` or the launchd
agent. The consequence of an overlap is redundant scanning, not a second
label decision — `dispatcher-tick.sh`'s own per-issue dispatch markers
([INV-108](invariants.md#inv-108-every-dispatcher-tick-dispatch-site-acquires-a-controller-side-per-issuemode-marker-atomically-before-any-side-effect--a-losing-acquire-skips-cleanly-never-dispatches-the-marker-expires-via-ttl-never-wedging-the-issue-the-dispatch-token-gains-a-run-field-for-post-hoc-attribution)) keep dispatch single-winner.

## Relationship to the state machine

The wake adds **no labels and no transitions**. It is not an actor in
`transitions.json` and does not appear in `state-machine.md`. It only
decides *when* the tick runs.

## Configuration

| Key | Meaning |
|-----|---------|
| `REPO` | `owner/name`; deliveries for any other repository are ignored. |
| `WEBHOOK_SECRET` | HMAC secret for `X-Hub-Signature-256`. Unset ⇒ every delivery is rejected. |
| `WAKE_STATE_DIR` | Override the state directory (tests). |
| `WAKE_WINDOW_SECONDS` | Coalesce window in seconds (default 15). |
| `WAKE_MAX_REQUEST_BYTES` | Largest delivery buffered from stdin (default 1 MiB); larger deliveries are rejected. |
| `WAKE_LOCK_GRACE_SECONDS` | Grace before an unrecorded lock is stolen (default 5; tests). |
| `WAKE_LOCK_MAX_AGE_SECONDS` | Age past which a live-looking lock is presumed PID reuse (default 3600). |

The same values can be given on the command line (`--state-dir`,
`--window-seconds`, `--tick-script`, `-h`).

## Failure modes

| Situation | Behavior |
|-----------|----------|
| Missing / malformed / mismatched signature | exit 3, no tick, logged |
| Secret unset | exit 3, no tick (fail closed) |
| Delivery larger than `WAKE_MAX_REQUEST_BYTES` | exit 3, no tick, logged |
| `REPO` unset, `jq`/`openssl` missing, state dir unwritable, bad numeric config | exit 5, no tick, logged |
| Repository or event not dispatchable | exit 0, no tick (handled, no retry) |
| Tick already running | exit 0, one follow-up requested |

# Design: dispatcher webhook wake (issue #35)

**Status:** design canvas for `feat/dispatcher-webhook-wake`.

## Problem

The only dispatcher clock is the macOS launchd agent installed by
`install-dispatcher-timer.sh`, which runs `dispatcher-tick.sh` every 300
seconds (see `docs/pipeline/platform.md`). A new `MergeMill` label, a
human label edit, or a CI completion can therefore sit unseen for up to
five minutes.

## Goal

Close that gap with a **same-entry-point kick**: a receiver that, when
GitHub reports a dispatchable change, runs the existing
`dispatcher-tick.sh` sooner. It is not a second scheduler and it never
reads labels itself.

## Non-goals

- Replacing, uninstalling, or retiming launchd. The 300 s agent stays and
  remains the backstop (`docs/pipeline/platform.md`).
- A public port, Tailscale install, GitHub App, or registered live
  webhook. The secret and the local feed are operator setup.
- Waking a sleeping Mac.
- Passing any webhook body to an agent. The body is an untrusted hint that
  something changed; a bad hint is dropped, never acted on.
- A local kick when a dev/review wrapper finishes (not a GitHub webhook).

## Component

One new script: `skills/MergeMill-dispatcher/scripts/dispatcher-wake.sh`.

- **Input surface**: reads exactly one raw webhook delivery (HTTP request
  headers + blank line + JSON body) from **stdin**. It opens **no socket**
  — a loopback listener/tunnel (Tailscale, SSH, a self-hosted runner, or a
  test harness) is the operator's transport, per the issue's
  "secret and local feed are operator setup" note. Because the receiver
  binds nothing, it cannot bind a public interface; the docs state the
  feed MUST be loopback-only.
- **Config**: `REPO` and `WEBHOOK_SECRET` via `load_MergeMill_conf`
  (`lib-config.sh`, same resolution as the tick). Unset `WEBHOOK_SECRET`
  fails closed — every delivery is rejected.
- **Signature**: `X-Hub-Signature-256: sha256=<hex>` HMAC-SHA256 over the
  exact body bytes (`openssl dgst -sha256 -hmac`). Missing, malformed, or
  mismatched → reject, no tick.
- **Repository gate**: `repository.full_name` must equal `$REPO`, else
  ignore.
- **Event gate** (only these start a tick):
  - `issues` / `labeled` whose `label.name` ∈ {`MergeMill`,
    `pending-review`, `pending-dev`};
  - `pull_request` / `opened` | `synchronize`;
  - `check_run` / `completed`; `check_suite` / `completed`.
  Everything else (comments, pushes, edits, deletes, `unlabeled`, …) is
  ignored.
- **The kick**: `bash <dispatcher-tick.sh>` with stdin `< /dev/null`, the
  same entry point a manual debug run uses. No arguments, no body.

## Coalescing and mutual exclusion

All wake state lives under a private state dir (mode 0700), overridable
by `WAKE_STATE_DIR` for tests.

| File | Meaning |
|------|---------|
| `tick.lock/` | Directory whose existence means a wake-invoked tick session is running (the receiver's own mutex — it does not parse launchd). Holds `pid` for stale-lock recovery. |
| `window.stamp` | Epoch seconds of the first accepted delivery in the open coalesce window. |
| `pending` | A follow-up was requested during a running session. |

Decision on an **accepted** delivery at epoch `now`:

1. If the lock is held by a live process → `touch pending`, exit 0. The
   holder, on finishing its tick, sees `pending` and runs **exactly one**
   follow-up, then releases. (A dead holder's lock is stolen.)
2. Else if `window.stamp` is fresh (`now - stamp < WAKE_WINDOW_SECONDS`,
   default 15) → coalesce, exit 0. A burst yields at most one tick.
3. Else → acquire the lock, stamp the window, run a tick session.

A session runs the tick, then at most one follow-up if `pending` was set
during the run, then releases the lock. The one-follow-up cap bounds a
steady event stream; any residual boundary race degrades to the launchd
backstop (≤300 s), never to a wrong action.

## Where this sits relative to the state machine

The wake **does not** read or write issue labels and does not appear in
`transitions.json`. It only decides *when* `dispatcher-tick.sh` runs; the
tick remains the sole place that reads labels and decides what to spawn.
No `gh` call is added, so the provider-cutover ratchet is unaffected.

## Operators

- launchd remains the only clock.
- The wake is a same-entry-point kick (`dispatcher-tick.sh`), never a
  label scanner.
- The webhook payload is never handed to an agent.
- A sleeping Mac is not woken; the launchd tick covers it on wake.

Documented in `docs/pipeline/webhook-wake.md` and referenced from
`dispatcher-flow.md`, `platform.md`, and the docs README.

## Test surface

- Hermetic unit tests: `tests/unit/test-dispatcher-wake.sh`, stub
  `dispatcher-tick.sh`, fixture deliveries on stdin. Covers signature /
  repo / event gates, coalescing, and the running-tick → one follow-up
  path.
- No browser E2E (no UI).

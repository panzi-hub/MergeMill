# Test Cases — Dispatcher webhook wake (#35)

A local webhook wake that runs the existing `dispatcher-tick.sh` sooner
when GitHub reports a dispatchable change. The receiver is a **kick, not a
dispatcher**: it never reads labels and never passes the webhook body to
an agent. Design: `docs/designs/dispatcher-webhook-wake.md`; operator
contract: `docs/pipeline/webhook-wake.md`.

Under test: `skills/MergeMill-dispatcher/scripts/dispatcher-wake.sh`
(new). It reads one raw HTTP delivery from **stdin**, verifies
`X-Hub-Signature-256`, gates on repository and event, then coalesces and
kicks `dispatcher-tick.sh` under its own mutual exclusion.

Runner: `bash tests/unit/test-dispatcher-wake.sh` (auto-discovered by the
CI `hermetic-unit` job's `tests/unit/test-*.sh` glob; assertions below are
the issue's "merge-before verification" surface). Hermetic — a stub
`dispatcher-tick.sh` counts invocations; no network, no credentials, no
port. The stub records an `overlap` marker if two ticks ever run
concurrently.

## Signature, repository, and event gates (AC: valid fixture calls the stub exactly once; bad signature / wrong repo / non-matching event call it zero times)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-WHWAKE-001 | Valid `sha256` HMAC over the body, `issue` `labeled` `MergeMill`, repo `$REPO` | stub tick called exactly once; rc 0 |
| TC-WHWAKE-002 | Same delivery, `label.name` = `pending-review` and `pending-dev` | each calls the stub once (label allow-list) |
| TC-WHWAKE-003 | `pull_request` `opened` / `synchronize` | each calls the stub once |
| TC-WHWAKE-004 | `check_run` `completed` / `check_suite` `completed` | each calls the stub once |
| TC-WHWAKE-010 | Missing `X-Hub-Signature-256` header | zero calls, non-zero rc, log names the rejection |
| TC-WHWAKE-011 | Signature header present but not `sha256=…` (malformed) | zero calls, non-zero rc |
| TC-WHWAKE-012 | `sha256=` value that does not match the body (tampered) | zero calls, non-zero rc |
| TC-WHWAKE-013 | Correct signature but `WEBHOOK_SECRET` unset in conf | zero calls, non-zero rc (fail closed) |
| TC-WHWAKE-020 | Valid signature, `repository.full_name` != `$REPO` | zero calls, rc 0/ignored |
| TC-WHWAKE-021 | Valid sig, `issues` `labeled` with label `bug` | zero calls |
| TC-WHWAKE-022 | Valid sig, `issue_comment` `created` (a comment) | zero calls |
| TC-WHWAKE-023 | Valid sig, `push` event | zero calls |
| TC-WHWAKE-024 | Valid sig, `issues` `edited` (not labeled) | zero calls |
| TC-WHWAKE-025 | Valid sig, `pull_request` `closed` (not opened/synchronize) | zero calls |
| TC-WHWAKE-026 | Valid sig, `check_run` `created` (not completed) | zero calls |

## Coalescing — a burst within 15 s yields at most one tick (AC: three matching events in the window → one call)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-WHWAKE-030 | Three accepted deliveries fed back-to-back (well inside `WAKE_WINDOW_SECONDS`) | stub called exactly once total |
| TC-WHWAKE-031 | A fourth delivery after the window stamp is aged past the window | stub called a second time (window reopens) |

## Running tick — no concurrent start; exactly one follow-up after it exits (AC: occupied lock rejects the concurrent call; release produces exactly one follow-up)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-WHWAKE-040 | Wake #1 starts a blocking stub tick; wake #2 (a matching delivery) arrives while it runs | wake #2 returns without starting a tick (stub count still 1); it records `pending` |
| TC-WHWAKE-041 | Wake #1's tick then exits | wake #1 runs exactly one follow-up tick (final count 2), then releases |
| TC-WHWAKE-042 | Whole 040+041 run | stub's `overlap` marker is empty — never two ticks at once |

## Structural invariants (AC: assert no public bind; launchd not turned into a second clock)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-WHWAKE-050 | Inspect `dispatcher-wake.sh` source | contains no wildcard/public bind (`0.0.0.0`, `nc -l`, `socat`, `--bind`); it consumes stdin and opens no listener |
| TC-WHWAKE-051 | Inspect `install-dispatcher-timer.sh` after this change | still launchd-only (no `crontab`), interval still 300, plist still names `dispatcher-tick.sh` |
| TC-WHWAKE-052 | The wake's tick invocation | runs the default `dispatcher-tick.sh` beside it, with no arguments and empty stdin (body never reaches the tick) |

## Notes

- `TC-WHWAKE-030`/`031` use the real clock; both complete far inside the
  15 s window.
- Ageing in `TC-WHWAKE-031` writes the `window.stamp` file directly to
  simulate time passing, so the test never sleeps 15 s.
- No browser E2E: no UI. The hermetic driver above is the pre-merge
  verification surface, as the issue states.

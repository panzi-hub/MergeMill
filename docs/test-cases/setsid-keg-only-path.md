# Test Cases: resolve `setsid` when util-linux is keg-only (INV-125)

Design: [docs/designs/setsid-keg-only-path.md](../designs/setsid-keg-only-path.md)
Suite: `tests/unit/test-setsid-keg-only-path.sh`

Behavioural TCs drive the real `lane_ensure_setsid_path` under `env -i` with a
controlled `PATH` and fixture fallback directories (via
`$LANE_SETSID_FALLBACK_DIRS`), so they never depend on the host's real layout.

## TC-SKOP-001: found via fallback — appended and resolvable

**Steps:** `PATH` without `setsid`; fallback dir containing an executable `setsid`.
Source `lib-lane.sh`.
**Expected:** function rc `0`; `command -v setsid` resolves; the fallback dir is the
**last** `PATH` entry; the pre-existing entries are unchanged and keep their order.

## TC-SKOP-002: already resolvable — true no-op

**Steps:** `setsid` present in a dir already on `PATH`; fallback list pointing at a
different dir that also contains one.
**Expected:** `PATH` is byte-identical before/after sourcing; the fallback dir is
**not** appended (the early `command -v` short-circuit wins).

## TC-SKOP-003: absent everywhere — degraded posture preserved

**Steps:** `PATH` without `setsid`; fallback list pointing at a directory that does
not exist.
**Expected:** function rc `1`; `PATH` unchanged; `source` returns rc `0` (the status of
the lib's last statement). This TC cannot observe a mid-source abort — its probe runs
without `set -e`; the `|| true` survival property is covered by TC-SKOP-012.

## TC-SKOP-004: append-order — earlier entries keep precedence

**Steps:** a decoy executable named `setsid` placed in an entry that precedes the
fallback dir on `PATH`; the real fixture `setsid` in the fallback dir.
**Expected:** `command -v setsid` resolves to the **decoy** (earlier entry), proving
the probe appends and cannot steal precedence from anything already on `PATH`.

## TC-SKOP-005: idempotence — re-source cannot duplicate the entry

**Steps:** source `lib-lane.sh` twice in the same shell under the TC-SKOP-001
conditions.
**Expected:** the fallback dir appears in `PATH` **exactly once**.

## TC-SKOP-006: multiple fallbacks — first match wins, non-executable skipped

**Steps:** fallback list `A:B` where `A` contains a **non-executable** `setsid` and
`B` contains an executable one.
**Expected:** rc `0`; only `B` is appended (a non-executable candidate is not a
match); `A` is not on `PATH`.

## TC-SKOP-007: malformed fallback list tolerated

**Steps:** fallback list with empty entries (`:A::` and a trailing `:`).
**Expected:** rc `0` when `A` holds `setsid`; no empty `PATH` element is introduced
(no `::`, no leading/trailing `:` caused by the append).

## TC-SKOP-008: source-of-truth — append-only construction and the fixed list

**Steps:** grep `lib-lane.sh`.
**Expected:** the source-time call `lane_ensure_setsid_path || true` is present; the
append form `PATH="${PATH}:${_dir}"` is present; **no** prepend form
(`PATH="${_dir}:${PATH}"`) exists anywhere in the file; the three documented prefixes
(`/opt/homebrew/opt/util-linux/bin`, `/usr/local/opt/util-linux/bin`,
`/opt/local/bin`) are all present.

## TC-SKOP-009: every setsid-guard site is covered by the chokepoint

**Steps:** enumerate every `*.sh` under `scripts/` containing a `command -v setsid`
guard; then check how each is reached.
**Expected:** the guard-site set is exactly the known seven —
`MergeMill-dev.sh`, `MergeMill-review.sh`, `adt-gc.sh`, `lib-agent.sh`,
`lib-guardian.sh`, `lib-lane.sh`, `lib-review-e2e.sh` (a **new** guard site fails
this TC until its author deliberately places it behind the probe). Each of the three
guarding entry points (`MergeMill-dev.sh`, `MergeMill-review.sh`, `adt-gc.sh`)
sources `lib-lane.sh` directly; `lib-agent.sh` and `lib-review-e2e.sh` are sourced by
a wrapper and inherit the normalized `PATH`; `lib-guardian.sh` — exec'd as its own
`setsid`-detached process — re-sources `lib-lane.sh` itself, so it runs the probe in
its own process.
`dispatcher-tick.sh` is deliberately exempt — it evaluates no `command -v setsid`
guard — and is pinned as absent from the guard set instead.

## TC-SKOP-010: syntax + operator-facing remedy text

**Steps:** `bash -n` on `lib-lane.sh` and both wrappers; grep the two wrappers'
`setsid (util-linux) is missing` ERROR lines.
**Expected:** all three files parse; both messages mention the keg-only remedy
(`keg-only` / `util-linux/bin`) so an operator who already installed util-linux is
not told to install it again.

## TC-SKOP-011: an executable *directory* named `setsid` is not a hit

**Steps:** fallback list `A:B` where `A` contains an executable **directory** named
`setsid` (mode `+x`) and `B` contains a real executable `setsid`; then a second run with
the dir-only candidate as the whole list, sourced twice.
**Expected:** the directory candidate is **skipped** — `B` is appended and `A` is not.
Dir-only: rc `1`, `PATH` unchanged, `command -v setsid` still unresolved, and a
double-source cannot append the directory twice. (`[[ -x ]]` alone accepts an
executable directory that `command -v` rejects, which would return rc `0` with `setsid`
still unfindable and duplicate the `PATH` entry on a re-source; the `! -d` guard closes
both.)

## TC-SKOP-012: sourcing stays non-fatal under `set -euo pipefail`

**Steps:** `env -i … bash -c 'set -euo pipefail; source lib-lane.sh; printf SURVIVED'`
with no `setsid` anywhere and a non-existent fallback dir.
**Expected:** the shell reaches the `printf` (output `SURVIVED`) and exits `0`. This is
the property the `|| true` on the source-time call buys: without it, `set -e` aborts the
caller before its next statement, taking down a dispatch on a setsid-less host.

## Delegated coverage (not re-tested here)

What happens **once `setsid` is found** — guardian install, `guard.fifo` EOF reap,
`kill -- -<pgid>` escalation — is unchanged by this PR and already pinned by
`tests/unit/test-lane-gc-p5-guardian.sh` and
`tests/unit/test-lane-gc-p3-kill-paths.sh`. This suite only covers *findability*.

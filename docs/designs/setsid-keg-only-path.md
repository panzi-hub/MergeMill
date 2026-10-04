# Design: resolve `setsid` when util-linux is installed keg-only (INV-125)

_Triage: operator-reported, observed on the macOS dev box. No upstream issue — the
bug is invisible to the fleet (Linux/Ubuntu runners have util-linux in `/usr/bin`)
and only reproduces on a Homebrew-provisioned macOS host._

## Problem

`setsid` is a declared **hard prerequisite** for the pgid lane backend
([INV-109](../pipeline/invariants.md)/[INV-114](../pipeline/invariants.md)) and for
the per-lane guardian sidecar
([INV-118](../pipeline/invariants.md)). [INV-23](../pipeline/invariants.md)'s
documented macOS remedy is explicit: *"macOS operators get setsid via Homebrew."*

That remedy does not work as written. Homebrew installs `util-linux` **keg-only** —
it is never symlinked into `/opt/homebrew/bin` (or `/usr/local/bin`). On the
observed host:

| Probe | Result |
|---|---|
| `brew info util-linux` | `stable 2.42.4 (bottled) [keg-only]`, **Installed (on request)** |
| `/opt/homebrew/opt/util-linux/bin/setsid --version` | `setsid, from util-linux 2.42.4` |
| `command -v setsid` | **not found** |

So `brew install util-linux` succeeds and `command -v setsid` still fails. Every
guard in the tree silently takes its degraded branch:

- both wrappers skip the guardian install and print an ERROR telling the operator
  to install a package **they already have**;
- `lib-agent.sh` / `lib-lane.sh` spawn without the `setsid` boundary, so
  `kill -- -<pgid>` no longer has a group to target and per-agent isolation is lost;
- `adt-gc.sh --doctor` reports `[FAIL] setsid missing — lane_spawn / escalator
  isolation degrade` on a fully-provisioned box.

### Observed impact

During the #23 dispatch the review log emitted:

```
setsid (util-linux) is missing — the guardian sidecar cannot be installed for this
run. … Proceeding WITHOUT a guardian; the periodic GC (adt-gc.sh) remains the
backstop reaper for this lane (degraded but not a hard abort).
```

and the hung dev lane (claude PID 11449, exit 143, idle 1464 s) had to be reaped by
the dispatcher's Step 5 stale-scan instead of by its own guardian. That is exactly
the ~10-minute-GC-vs-immediate-guardian latency gap the guardian exists to close.

## Options considered

### A. Repo-level resolver in the shared lib — **CHOSEN**

Resolve `setsid` once at `lib-lane.sh` source time and append the keg-only bin
directory to `PATH` when (and only when) `setsid` is not already resolvable.

### B. Prepend the keg-only directory to `PATH`

Rejected. `util-linux` ships **24** tools, including `getopt`, `column`, `uuidgen`,
`renice`, `logger`, `look`, `whereis` and `hexdump`. Putting its bin dir ahead of
`/usr/bin` silently substitutes GNU for BSD variants in every script that resolves
those by bare name — and GNU `getopt` in particular is **incompatible** with the
BSD `getopt` calling convention that macOS scripts rely on. The blast radius is the
whole host, not just this pipeline. **Appending** cannot shadow anything: it only
makes a tool findable when no earlier `PATH` entry provides it, which is precisely
the `setsid` case (no macOS/BSD `setsid` exists to shadow).

### C. Tell the operator to symlink `setsid` into a `PATH` dir

Rejected as the *repo* fix. It works (it is what was applied to the observed host to
verify the diagnosis: `ln -sfn /opt/homebrew/opt/util-linux/bin/setsid
~/.local/bin/setsid`), but it is machine-local, undocumented, survives no host
rebuild, and leaves the next macOS operator to rediscover the same trap. It is the
right *workaround*; the repo still needs the *fix*.

### D. A per-call-site resolver at each `command -v setsid` site

Rejected. It multiplies the same logic across `lib-agent.sh`, `lib-lane.sh`,
`lib-guardian.sh`, `lib-review-e2e.sh`, `adt-gc.sh` and both wrappers, and every
future spawn site can forget it. Every process that evaluates a `command -v
setsid` guard runs the probe: both wrappers, `dispatch-local.sh` and `adt-gc.sh`
source the lib directly; `lib-agent.sh` / `lib-review-e2e.sh` are sourced by
those wrappers and inherit the normalized `PATH`; and `lib-guardian.sh` is exec'd
as its own `setsid`-detached process but re-sources `lib-lane.sh` itself, so it
runs the probe in its own process. One source-time chokepoint therefore covers
every present and future consumer, and every child they spawn inherits the
normalized `PATH` by ordinary environment inheritance. (`dispatcher-tick.sh` does not source `lib-lane.sh`, but it also
contains no `command -v setsid` guard, so it needs nothing from the probe; its
children — `dispatch-local.sh` and the wrappers — do their own sourcing.)

### E. `brew --prefix util-linux` at runtime

Rejected. It spawns a Ruby process on every dispatch and assumes `brew` is on
`PATH` — which it is not under the minimal environment of a cron/launchd GC timer,
the exact context `adt-gc.sh` is designed to run in. A fixed, documented prefix list
covers Apple-silicon Homebrew, Intel Homebrew and MacPorts with zero process cost.

## Design

```
lib-lane.sh  (source time)
  └── lane_ensure_setsid_path()
        ├── command -v setsid succeeds?          → return 0 (no-op, PATH untouched)
        ├── first fallback dir with -x setsid?   → APPEND it to PATH, return 0
        └── none found?                          → return 1 (PATH untouched)
      `lane_ensure_setsid_path || true`   # never aborts the dispatch
```

Four properties, each pinned by a test:

1. **Single chokepoint.** `lib-lane.sh` only. No call site re-implements the lookup;
   the existing `command -v setsid` guards (across seven files) are unchanged and
   remain the boolean test.
2. **Append-only.** `PATH="${PATH}:${_dir}"`, never `${_dir}:${PATH}` (option B). A
   candidate counts only when it is an executable, **non-directory** `setsid`:
   `command -v` rejects directories, so an `-x`-only test would claim success while
   `setsid` stayed unfindable (and would append the entry again on a re-source).
3. **Never fatal.** A genuinely setsid-less host returns to its pre-existing
   degraded posture; the source-time call is `|| true` so `set -euo pipefail`
   cannot abort a dispatch on a host that never had setsid.
4. **Fixed prefix list.** `/opt/homebrew/opt/util-linux/bin`,
   `/usr/local/opt/util-linux/bin`, `/opt/local/bin`. Overridable through
   `$LANE_SETSID_FALLBACK_DIRS` so unit tests drive fixtures rather than the host's
   real layout.

`lib-lane.sh` already resolves a tool at source time (`_LANE_TIMEOUT_CMD`, the
`timeout`/`gtimeout` feature probe), so this follows an established in-file
precedent rather than introducing a new posture.

## Risks

| Risk | Mitigation |
|---|---|
| Prepending would shadow BSD tools | Append-only, pinned by a source-of-truth test and an append-order behavioural test |
| A source-time side effect on a widely-sourced lib | Idempotent, no-op when `setsid` already resolves, and documented in the lib header; `set -e`-safe |
| A future entry point forgets the call | It cannot — the call is inside the lib every entry point already sources |
| Hides a genuine misconfiguration | The probe only ever *adds* a directory that physically contains an executable `setsid`; it cannot manufacture one. If no candidate dir has it, the wrappers still print their ERROR and `--doctor` still fails |
| Test suite depends on the host's real layout | `$LANE_SETSID_FALLBACK_DIRS` override + `env -i` with a controlled `PATH` |

## Verification

- `tests/unit/test-setsid-keg-only-path.sh` — TC-SKOP-001..012 (see
  [docs/test-cases/setsid-keg-only-path.md](../test-cases/setsid-keg-only-path.md)).
- `bash -n` on `lib-lane.sh` and both wrappers.
- Manual, on the observed host: `adt-gc.sh --doctor` flips
  `[FAIL] setsid missing` → `[ok] setsid present`; `command -v setsid` resolves;
  `setsid bash -c 'ps -o pid=,pgid= -p $$'` returns a PGID distinct from the parent.
- Guardian install / PGID isolation themselves are already covered by
  `tests/unit/test-lane-gc-p5-guardian.sh` and
  `tests/unit/test-lane-gc-p3-kill-paths.sh`; this change only affects whether
  `setsid` is *findable*, not what happens once it is.

# Fix: dispatcher wrapper scripts missing execute bit

**Date:** 2026-05-11
**Issue:** #97
**Status:** Approved

## Problem

Two dispatcher wrapper scripts that are invoked **directly** (via `nohup
"$PROJECT_DIR/scripts/MergeMill-dev.sh"` from `dispatch-local.sh`) are
committed at git mode `100644`:

- `skills/MergeMill-dispatcher/scripts/MergeMill-dev.sh`
- `skills/MergeMill-dispatcher/scripts/MergeMill-review.sh`

Without the execute bit, `nohup .../MergeMill-dev.sh` fails with
`Permission denied`. The agent process never starts; no Session ID
ever lands on the issue; the dispatcher's stale-detection counts each
tick as a crash; after `MAX_RETRIES` the issue is marked `stalled`.

The skills CLI faithfully copies git tree modes verbatim (it uses
`fs.readFile`/`fs.writeFile` without preserving or repairing modes
beyond what the OS default produces), so every fresh `npx skills add`
inherits the missing `+x`.

## Scoping decision: which files get +x?

Issue #97 listed three files. After auditing usage, only **two** get
the +x flip — the third is sourced-only:

| File | Usage | Verdict |
|---|---|---|
| `MergeMill-dev.sh` | `nohup .../MergeMill-dev.sh` from dispatch-local.sh:144,154 | **+x (fix)** |
| `MergeMill-review.sh` | `nohup .../MergeMill-review.sh` from dispatch-local.sh:160 | **+x (fix)** |
| `lib-review-bots.sh` | `source "$LIB"` from MergeMill-review.sh, dispatcher-tick.sh, tests | **leave 100644** — sourced only |

Same audit applied to the other two `lib-*` files at 100644
(`lib-installer.sh`, `lib-installer-translate.sh` in MergeMill-common):
both are sourced-only by the per-agent installer scripts. Leave at 644.

The principle: `chmod +x` is a contract that the file is meant to be
invoked directly. Applying it to sourced-only libs is a maintenance
hazard (encourages someone to add a `#!` line and treat it as
executable, breaking the abstraction). Match mode to actual usage.

## Distribution caveat (issue #97 § "Distribution caveat")

The skills CLI's `computedHash` in `src/local-lock.ts`:

```ts
async function collectFiles(...) {
  // ...
  results.push({ relativePath, content });
}
// hash = sha256(relativePath_1 + content_1 + relativePath_2 + content_2 + ...)
```

Hash covers content + relative path, **NOT file mode**. So a 644→755
flip produces an identical hash. Already-installed consumers running
`npx skills update` will see no change and keep the broken scripts.

To force a hash bump for the MergeMill-dispatcher skill, this PR adds
a small content change to `skills/MergeMill-dispatcher/SKILL.md` (a
one-line note documenting the fix) in the same commit. That changes
the SKILL.md content, hence the folder hash, hence the consumer-side
update detection. No semantic change to the skill.

## Fix

### Part 1 — restore +x via `git update-index`

```bash
git update-index --chmod=+x \
  skills/MergeMill-dispatcher/scripts/MergeMill-dev.sh \
  skills/MergeMill-dispatcher/scripts/MergeMill-review.sh
```

This sets the mode in the git index without touching the working
tree's POSIX mode (which is governed by `core.fileMode`).

### Part 2 — defensive chmod in dispatcher-tick.sh

Add at the top of `dispatcher-tick.sh`, right after `SCRIPT_DIR` is
computed:

```bash
# Self-heal exec bits on directly-invoked sibling scripts. Guards
# against installs that stripped +x (closes #97). Scoped to the
# specific scripts dispatch-local.sh invokes directly — sourced-only
# libs (lib-*.sh) are deliberately left alone.
for _need_exec in MergeMill-dev.sh MergeMill-review.sh; do
  [[ -f "$SCRIPT_DIR/$_need_exec" && ! -x "$SCRIPT_DIR/$_need_exec" ]] \
    && chmod +x "$SCRIPT_DIR/$_need_exec" 2>/dev/null || true
done
unset _need_exec
```

`SCRIPT_DIR` is already computed via `${BASH_SOURCE[0]:-$0}` (line 17),
which is the safer pattern under cron, sourced execution, and symlink
resolution.

We deliberately do NOT `chmod +x *.sh` blindly — that would flip
sourced-only libs and propagate the wrong contract.

### Part 3 — installer-side belt-and-suspenders

Add `ensure_dispatcher_scripts_executable` to
`skills/MergeMill-common/scripts/lib-installer.sh`. Each per-agent
`install-*-hooks.sh` calls it during install. This heals consumers
who already installed the broken skill version.

The helper is path-aware: it resolves the consumer's
`MergeMill-dispatcher/scripts/` relative to the installer's location,
which lives one directory level up after the symlink-vendor flattening
done by `npx skills`. If the dispatcher dir isn't found (unusual install
shape), the helper warns and continues — never aborts the installer.

### Part 4 — SKILL.md hash bump

Add a one-line note to `skills/MergeMill-dispatcher/SKILL.md`:

> **Note:** `MergeMill-dev.sh` and `MergeMill-review.sh` require
> the execute bit (`100755`); restored in #97 along with self-healing
> guards in the dispatcher tick and per-agent installers.

This bumps the SKILL.md content, changing the `computedHash` of the
MergeMill-dispatcher folder, so already-installed consumers see the
update on `npx skills update`.

## What we deliberately do NOT change

- **`lib-review-bots.sh`** — issue listed it but it's sourced-only.
  Flipping its mode would propagate the wrong contract.
- **`lib-installer.sh`, `lib-installer-translate.sh`** — same reasoning,
  even though they were also at 644 in the audit.
- **Test files at 644** — they're invoked via `bash $test` in CI and
  `bash tests/unit/test-X.sh` manually; +x is irrelevant. Out of scope.

## Acceptance

- `git ls-tree HEAD skills/MergeMill-dispatcher/scripts/MergeMill-{dev,review}.sh`
  shows mode `100755`.
- `git ls-tree HEAD skills/MergeMill-dispatcher/scripts/lib-*.sh`
  shows mode `100644` (preserved — these are sourced-only).
- `dispatcher-tick.sh` has the self-healing block, scoped to the two
  directly-executed scripts, anchored on `SCRIPT_DIR`.
- `lib-installer.sh` exposes `ensure_dispatcher_scripts_executable`
  and every `install-*-hooks.sh` calls it.
- `MergeMill-dispatcher/SKILL.md` has the note that bumps the folder
  hash.
- New unit tests cover the above.

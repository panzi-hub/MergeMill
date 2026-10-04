# Design — state-manager.sh macOS portability

## Problem

`skills/MergeMill-common/hooks/state-manager.sh` (reached via the tracked `hooks`
symlink) is not portable to stock macOS. Two independent defects make the
`pr-review` gate unsatisfiable on a host whose `/bin/bash` is 3.2 and whose
`date` is BSD (every default macOS install):

1. **BSD `date` fallback parses UTC as local time.** `mark_action` writes the
   timestamp in UTC (`date -u +%Y-%m-%dT%H:%M:%SZ`), but `check_action`'s BSD
   fallback omitted `-u`, so the UTC string is interpreted in the host's local
   timezone. With `TZ=UTC+8` the computed age is inflated by 28800 s; a mark
   written seconds ago exceeds the 1800 s expiry and the push stays blocked.
2. **`mapfile` requires bash 4+.** Stock macOS `/bin/bash` is 3.2, where
   `mapfile` does not exist, so invoking `hooks/state-manager.sh mark pr-review`
   (exactly as the hook's own remediation text instructs) fails before writing
   any state.

## Approach

- **Age check**: resolve the epoch in a timezone-correct, host-agnostic order —
  `gdate` (GNU coreutils on macOS) → GNU `date -d` → BSD `date -u -j -f`. The
  BSD fallback is fixed to parse **UTC** (`-u`) so it agrees with the UTC value
  written by `mark_action`. All paths fail closed (`echo "0"`) so a parser that
  cannot run never yields a stale-looking-but-valid mark.
- **File list**: replace the `mapfile` builtin with a `while IFS= read -r` loop,
  which exists in bash 3.2.

No gate is weakened: the `pr-review` mark still must be fresh (≤1800 s) **and**
reference the current `HEAD`. No `--no-verify` or bypass is introduced.

## Compatibility matrix

| Host | Date resolver hit | File-list loop |
|------|-------------------|----------------|
| GNU/Linux (GNU date, bash ≥4) | `date -d` (unchanged) | `read` loop, same result |
| macOS + coreutils (`gdate`) | `gdate` | `read` loop |
| stock macOS (BSD date, bash 3.2) | `date -u -j -f` | `read` loop |

## Out of scope

Any behavioural change to the gate policy, the JSON schema of state files, or
the `clear`/`list` subcommands.

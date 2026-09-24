# Test Cases — auto-merge-marker read migration (#332)

Covers migrating `MergeMill-dev.sh`'s `AUTO_MERGE_FAILURE_MARKER` read from a raw
`gh api .../issues/N/comments` call to `itp_list_comments "$PR_NUM" | jq -r
'<select>'`. Behavior-preservation is proven by running the **migrated selector**
against synthetic normalized-array fixtures, plus source-shape guards.

Test file: `tests/unit/test-auto-merge-marker-migration.sh`.
Run: `env -u PROJECT_DIR bash tests/unit/test-auto-merge-marker-migration.sh`.

## AC mapping

| AC | Surface | Test IDs |
|----|---------|----------|
| AC1 — selector reproduces the raw-`gh` select for all golden cases (incl. newest-wins + startswith anchor) | golden unit green | TC-AMM-001..005 |
| AC2 — no regex introduced (select stays `startswith`); no Oniguruma divergence | parity unit green | TC-AMM-PARITY-001, TC-AMM-PARITY-002 |
| AC3 — `:1093` raw-`gh` gone; `itp_list_comments \| jq` present; baseline −1; INV-91 green | source-shape unit green | TC-AMM-SRC-001..003 |
| AC4 — full existing unit suite green under `env -u PROJECT_DIR` | suite run | (whole-suite) |

## Golden — selector behavior (AC1)

The selector is `[.[] | select(.body | startswith("Auto-merge failed:"))] | last //
empty | .body`, fed the NORMALIZED `[{id,author,authorKind,body,createdAt}]` array
that `itp_list_comments` emits (ascending by `createdAt`).

- **TC-AMM-001** — single `Auto-merge failed:` comment present → its `.body` returned.
- **TC-AMM-002** — multiple `Auto-merge failed:` comments → the NEWEST (`last` over
  ascending array) `.body` returned.
- **TC-AMM-003** — no matching comment (only dispatcher chatter) → empty string.
- **TC-AMM-004** — a comment whose body merely CONTAINS but does NOT START WITH
  `Auto-merge failed:` (e.g. quoted history `> Auto-merge failed: …`) → NOT matched
  (startswith anchor preserved — the quoted-history false-positive guard the
  original comment cites).
- **TC-AMM-005** — newest-wins precedence over a non-matching newer comment: an older
  `Auto-merge failed:` then a newer unrelated status comment → the marker body is
  returned (the non-matching newer comment doesn't shadow it).

## Engine parity (AC2)

- **TC-AMM-PARITY-001** — a body with non-ASCII / a `test()`-style metacharacter
  (e.g. `Auto-merge failed: rebase onto 中\b(?i)`) is matched purely by the literal
  `startswith` prefix and returned verbatim — proving `startswith` is literal /
  engine-agnostic, NO Oniguruma fold is introduced.
- **TC-AMM-PARITY-002** — source pin: the live migrated selector uses `startswith`
  and does NOT contain `test(` — no regex engine is invoked by this read.

## Source-shape (AC3)

- **TC-AMM-SRC-001** — ZERO raw `gh api "repos/${REPO}/issues/${PR_NUM}/comments"`
  at the auto-merge-marker site in `MergeMill-dev.sh`.
- **TC-AMM-SRC-002** — the migrated `AUTO_MERGE_FAILURE_MARKER=$(itp_list_comments
  "$PR_NUM" 2>/dev/null | jq -r '<select>')` form is present EXACTLY ONCE (live-site
  non-vacuity guard).
- **TC-AMM-SRC-003** — `cutover-baseline.json` no longer carries the
  `AUTO_MERGE_FAILURE_MARKER=$(gh api …issues/${PR_NUM}/comments` entry (baseline −1,
  pinned mechanically); `check-provider-cutover.sh` ([INV-91]) PASSES.

## E2E

No new E2E — this is a resume-prompt-internal read. The existing dev-resume E2E
exercises the auto-merge-marker path (the rebase-block injection).

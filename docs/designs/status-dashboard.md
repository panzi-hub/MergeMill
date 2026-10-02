# Design canvas — read-only runtime status dashboard (`status.sh --all` / `--issue` / `--json`)

Issue: #12 · Subsystem: dispatcher (`skills/MergeMill-dispatcher/scripts/status.sh`) · Invariant: [INV-81](../pipeline/invariants.md)

## Problem

`status.sh <issue>` already gives a per-issue, predicate-parity view of one issue's
pipeline state. Operators still have to know *which* issue to inspect and then read
a human-only format. This change adds a fleet-wide view (`--all`), an explicit
single-issue selector (`--issue <n>`), and a stable machine-readable mode
(`--json`) — **without changing the existing positional invocation or removing
any line it already printed** (the single-issue report only gains additive
`agent` / `status label` / `latest run` / `last result` / `stale` lines).

## Constraints (from the issue)

- Default **read-only**: no label edits, no comments, no merges, no lease/PID writes.
- `--all` lists every relevant issue (every OPEN issue carrying the `MergeMill` label).
- `--issue <number>` selects one issue (in addition to the existing positional form).
- Tolerate missing logs, corrupt `agent-result.json`, absent PRs, and stale/expired
  PID + heartbeat files — surface `unknown` / a diagnostic, never crash.
- Terminal-readable default output; stable `--json` alternative.
- Never print tokens / private keys / secret env vars.
- Non-zero exit on failure (with a locatable error message).

## Backwards compatibility

| Invocation | Behaviour |
|---|---|
| `status.sh <n>` | existing report lines preserved; additive agent/attempt/stale lines |
| `status.sh <n> --project <id>` | unchanged |
| `status.sh --issue <n>` | **new** — alias of the positional form; identical output |
| `status.sh --all` | **new** — fleet summary (text) |
| `status.sh --all --json` | **new** — `{"schema_version":1,"issues":[...]}` |
| `status.sh <n> --json` | **new** — one issue object |

`--all` and an explicit issue are mutually exclusive (usage error, rc 2).

## Data model

One collector gathers the same facts the tick's predicates expose, then two
renderers (text / JSON) consume it. Predicate parity is preserved by sourcing
`lib-dispatch.sh` and calling the same functions (`pid_alive`, `get_pid`,
`count_retries`, `fetch_pr_for_issue`, `dev_near_success`, `review_near_success`).

Per-issue JSON object (stable, schema_version 1):

```json
{
  "issue": 12,
  "title": "…",
  "issue_state": "OPEN",
  "project": "mergemill",
  "repo": "panzi-hub/MergeMill",
  "status_label": "pending-review",
  "labels": ["MergeMill", "pending-review"],
  "agent": "review",
  "run_id": "mergemill-12-review-20261002T171013Z",
  "attempt": 2,
  "last_result": {"run_id": "…", "rc": 1, "outcome": "failure",
                  "failure_class": "agent", "session_id": "…", "ended_at": "…"},
  "pr": {"number": 34, "state": "OPEN", "review_decision": "APPROVED",
         "mergeable": "MERGEABLE"},
  "retries": 1, "max_retries": 3,
  "stale": {"dev_pid": null, "dev_pid_alive": false,
            "review_pid": 4242, "review_pid_alive": false,
            "stale_pid": true, "stale_run": false, "heartbeat_stale": true},
  "next_action": "Step 3: dispatch review …",
  "diagnostics": ["agent-result.json unreadable: …"]
}
```

Every field is always present; a value that cannot be determined is `null`
(JSON) / `unknown` (text) with a `diagnostics` entry explaining why. This is the
tolerance contract: the shape never changes, only the values degrade.

### `agent` derivation

1. If the active status label is a review-side label (`pending-review`,
   `reviewing`) → `review`.
2. Else if it is a dev-side label (`pending-dev`, `in-progress`, or the bare
   `MergeMill` new state) → `dev`.
3. Else fall back to the latest run dir's side; else `unknown`.

### Stale / invalid-run diagnostics

- **stale PID**: a `*.pid` exists for a side whose process is not alive and whose
  heartbeat (if any) is older than the freshness threshold — i.e. `pid_alive`
  false while a PID file lingers, on an active-state issue.
- **heartbeat stale**: the `.heartbeat` sibling exists but its mtime exceeds
  `3 × HEARTBEAT_INTERVAL_SECONDS`.
- **stale / invalid run**: the newest run dir has no `ended_at` (in-flight marker)
  yet its `started_at` (or mtime) is older than `STATUS_STALE_RUN_SECONDS`
  (default 3600) → it is an abandoned run, not a live one.

## Rendering

- **Single-issue text**: the existing report is retained. Additive lines only
  (agent, attempt, stale diagnostics) so existing `contains` assertions and the
  E2E snapshot keep passing.
- **`--all` text**: one compact block per issue (number, title, status label,
  agent, latest run + attempt, last result/failure-class, PR, stale flag, next
  action), plus a count footer.
- **`--json`**: `jq`-free hand-assembled JSON via `jq -n --arg/--argjson` so the
  structure is always valid; secrets never enter the object (only `host_env`-free
  operational fields).

## Error handling

- `gh`/`jq` missing → rc 3 with a message naming the missing tool.
- `--all` enumeration fails (provider error) → rc 4 with the provider error.
- A single issue whose read fails under `--all` yields a diagnostic-bearing
  object, not an abort (tolerance), and `--all` still exits 0 if enumeration
  succeeded.
- No issue and no `--all` → usage error rc 2.

## Test IDs

`TC-STATUS-DASH-001..021` (see `docs/test-cases/status-dashboard.md`).

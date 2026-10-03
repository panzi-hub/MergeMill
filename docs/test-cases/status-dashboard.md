# Test cases — runtime status dashboard (`status.sh --all` / `--issue` / `--json`)

Issue: #12 · Design: [`docs/designs/status-dashboard.md`](../designs/status-dashboard.md)

Harness: `tests/unit/test-status-dashboard.sh` — subprocess `status.sh` with a stub
`gh`, an isolated PID dir, an isolated run-dir base, and a real empty conf (same
strategy as `tests/unit/test-status.sh`). Fixtures cover the normal / failed /
stale / missing-result / no-PR paths.

| ID | Scenario | Setup | Expected |
|----|----------|-------|----------|
| TC-STATUS-DASH-001 | `--issue <n>` equals positional output | fixture idle issue 40 | identical stdout for `--issue 40` and `40` |
| TC-STATUS-DASH-002 | `--all` text lists all MergeMill issues | two issues in `itp_list_by_state` fixture | both numbers + status labels present |
| TC-STATUS-DASH-003 | `--all` excludes non-MergeMill issues | list fixture only returns MergeMill-tagged | only tagged issue numbers appear |
| TC-STATUS-DASH-004 | `--all --json` is valid JSON | two issues | `jq -e` succeeds; `.issues|length` correct |
| TC-STATUS-DASH-005 | `--json` single issue valid + stable keys | normal fixture | `jq -e` succeeds; required keys present |
| TC-STATUS-DASH-006 | normal run: rc=0 success + failure_class | run fixture rc0 + agent-result.json rc0 | `outcome=="success"`, `rc==0`, `failure_class=="agent"` echoed |
| TC-STATUS-DASH-007 | failed run: rc=1 + failure class | run rc1 + agent-result.json `failure_class:"code"` | `outcome=="failure"`, `failure_class=="code"` |
| TC-STATUS-DASH-008 | corrupt `agent-result.json` tolerated | write non-JSON into agent-result.json | rc 0; `failure_class=="unknown"`; diagnostic present |
| TC-STATUS-DASH-009 | missing run dir / logs tolerated | no run dirs | `run_id==null`, no crash, rc 0 |
| TC-STATUS-DASH-010 | no linked PR | `pr:[]` fixture | `pr==null`; text `open PR: <none linked>` |
| TC-STATUS-DASH-011 | linked PR surfaced | PR fixture closing #N | `pr.number`, `pr.review_decision`, `pr.state` correct |
| TC-STATUS-DASH-012 | stale PID flagged | dead PID file + active label | `stale.stale_pid==true`, text shows stale |
| TC-STATUS-DASH-013 | live PID not flagged stale | own `$$` PID file | `stale.stale_pid==false` |
| TC-STATUS-DASH-014 | stale heartbeat detected | `.heartbeat` mtime -1h | `stale.heartbeat_stale==true` |
| TC-STATUS-DASH-015 | stale/abandoned run flagged | run dir no `ended_at`, started -2h | `stale.stale_run==true` |
| TC-STATUS-DASH-016 | attempt + agent surfaced | run meta `attempt:2`, review label | `attempt==2`, `agent=="review"` |
| TC-STATUS-DASH-017 | next dispatch action present | pending-review fixture | non-empty `next_action`, text `Step 3` |
| TC-STATUS-DASH-018 | read-only contract | record gh calls + grep source | no mutation verbs issued/contained |
| TC-STATUS-DASH-019 | usage errors | no arg / `--all` + `--issue` | rc 2, `Usage:` |
| TC-STATUS-DASH-020 | no secrets in JSON | export GH_TOKEN/secret env | token value absent from `--json` output |
| TC-STATUS-DASH-021 | newest `last_result` across both sides | newer dev run + older review run | dev run's `rc`/`failure_class`/`run_id` win |

## Acceptance mapping

- AC1 `status.sh --all` lists all relevant issues → TC-002/003.
- AC2 `status.sh --issue <n>` single issue → TC-001.
- AC3 `--json` valid + stable → TC-004/005/020.
- AC4 normal/failed/stale/missing-result/no-PR fixtures → TC-006..015.
- AC5 read-only guaranteed by test → TC-018.
- AC6 shellcheck + unit + conformance + E2E → CI.
- AC7 README/docs updated → same PR.

#!/usr/bin/env bash
# recover.sh — conservative operator recovery helper.
# It never mutates GitHub unless --apply is explicitly supplied.
set -euo pipefail
SELF="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
issue=""; apply=0; project=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) apply=1; shift ;;
    --project) project="${2:?--project requires a value}"; shift 2 ;;
    -h|--help) echo "Usage: $0 <issue> [--apply] [--project ID]"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) [[ -z "$issue" ]] || { echo "unexpected argument: $1" >&2; exit 2; }; issue="$1"; shift ;;
  esac
done
[[ "$issue" =~ ^[0-9]+$ ]] || { echo "issue must be numeric" >&2; exit 2; }
status_args=("$issue")
[[ -n "$project" ]] && status_args+=(--project "$project")
"$SCRIPT_DIR/status.sh" "${status_args[@]}"
if (( apply )); then
  echo "Recovery is intentionally delegated to the next dispatcher tick." >&2
  echo "Run scripts/dispatcher-tick.sh after reviewing the status above." >&2
fi

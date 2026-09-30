#!/bin/bash
# tests/e2e/setup-live-runner.sh — the ONE standard live-runner onboarding form
# ([INV-77] rule 4; the RUNNER_SMOKE_CONF / SMOKE_MATRIX repo-variable channels
# were removed by maintainer decision — provisioning is now ONE command).
#
#   bash tests/e2e/setup-live-runner.sh [--dry-run] [--force] \
#        [--conf PATH] [--ref REF]
#
# 1. PROBE    detect the agent CLIs installed on THIS box (basename match over
#             the adapter set: claude codex gemini kiro opencode agy). ANY
#             subset is a valid matrix — the harness classifies a missing or
#             auth-walled CLI as UNAVAILABLE/SKIP (advisory, [INV-63]), so
#             "whatever this box has" is the correct content.
# 2. SEED     fetch the annotated template from a TRUSTED ref (git show
#             <ref>:tests/e2e/e2e.conf.example, default origin/main; gh api
#             ?ref=main fallback) — NEVER the working tree: on a labeled fork
#             PR the in-checkout copy is attacker head content whose env-setup
#             is `eval`'d on this runner ([INV-77] rule 5). The template is
#             saved NEXT TO the conf as e2e.conf.example for per-box
#             enrichment (Bedrock regions, custom endpoints, require: guards).
# 3. GENERATE one `name|agent_cmd|model|env-setup` entry per detected CLI
#             (4-field validated — the harness loud-rejects anything else).
# 4. WRITE    the single canonical path $HOME/.config/MergeMill-dev-team/
#             e2e.conf (--conf overrides), refusing to clobber without --force.
# 5. REPORT   doctor-style summary + the remaining manual step (register the
#             GitHub Actions runner; the live tier stays label-gated advisory).
#
# NEVER put real keys in the conf — env-setup sources a gitignored local
# secrets file (see the saved template). [INV-77] rule 5.
#
# Exit codes: 0 onboarded; 1 no supported CLI / template fetch failed /
#             generated matrix invalid; 2 usage; 3 refused to clobber (pass
#             --force after reviewing).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

CONF_DEFAULT="${HOME}/.config/MergeMill-dev-team/e2e.conf"
CONF="" FORCE=0 DRY_RUN=0 REF="origin/main"

usage() {
  cat <<'EOF'
Usage: bash tests/e2e/setup-live-runner.sh [options]

Options:
  --dry-run       Probe + generate + print; write nothing.
  --force         Replace an existing matrix at the target path.
  --conf PATH     Target path override (default: the ONE canonical path
                  $HOME/.config/MergeMill-dev-team/e2e.conf that ci.yml's
                  live-smoke preflight reads).
  --ref REF       Trusted template ref for the seed (default: origin/main;
                  gh api fallback uses ?ref=main). NEVER a PR checkout.
  -h, --help      This help.

Exit codes: 0 onboarded; 1 no supported CLI / template fetch failed /
            generated matrix invalid; 2 usage; 3 refused to clobber.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --force)   FORCE=1 ;;
    --conf)
      [[ $# -ge 2 ]] || { echo "ERROR: --conf needs a value" >&2; exit 2; }
      CONF="$2"; shift ;;
    --ref)
      [[ $# -ge 2 ]] || { echo "ERROR: --ref needs a value" >&2; exit 2; }
      REF="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
CONF="${CONF:-$CONF_DEFAULT}"

# --- 1. PROBE -----------------------------------------------------------------
# Supported set = the adapter basenames when the repo tree is present (self-
# maintaining: a new adapter is auto-supported), else the known set (the script
# may be copied to a box without the full checkout).
declare -a SUPPORTED=()
if [[ -d "$SCRIPT_DIR/../../skills/MergeMill-dispatcher/scripts/adapters" ]]; then
  for f in "$SCRIPT_DIR"/../../skills/MergeMill-dispatcher/scripts/adapters/*.sh; do
    [[ -e "$f" ]] || continue
    SUPPORTED+=("$(basename "${f%.sh}")")
  done
fi
if [[ ${#SUPPORTED[@]} -eq 0 ]]; then
  SUPPORTED=(claude codex gemini kiro opencode agy)
fi

declare -a DETECTED=()
for cli in "${SUPPORTED[@]}"; do
  # command -v matches PATH entries AND shell functions — a box that exposes
  # its CLI through a wrapper function is still detected.
  command -v "$cli" >/dev/null 2>&1 && DETECTED+=("$cli")
done

if [[ ${#DETECTED[@]} -eq 0 ]]; then
  echo "ERROR: no supported agent CLI found (looked for: ${SUPPORTED[*]})." >&2
  echo "       Install + authenticate at least one on this box, then re-run." >&2
  exit 1
fi
echo "Detected agent CLIs: ${DETECTED[*]}"

# ---------------------------------------------------------------------------
# 2. SEED the annotated template from a TRUSTED ref — git show from the given
#    ref (default origin/main) first, gh api (?ref=main) as fallback. NEVER
#    the working tree: on a labeled fork PR the in-checkout copy is attacker
#    head content ([INV-77] rule 5).
# ---------------------------------------------------------------------------
fetch_template() {
  local out="$1"
  if git show "${REF}:tests/e2e/e2e.conf.example" > "$out" 2>/dev/null; then
    echo "Template seeded from ${REF} (git show)."
    return 0
  fi
  local url owner_repo=""
  url="$(git remote get-url origin 2>/dev/null)" || {
    echo "ERROR: cannot fetch the template — no '${REF}' ref and no origin remote." >&2
    echo "ERROR: template fetch failed." >&2
    return 1
  }
  case "$url" in
    git@github.com:*)       owner_repo="${url#git@github.com:}" ;;
    https://github.com/*)   owner_repo="${url#https://github.com/}" ;;
    ssh://git@github.com/*) owner_repo="${url#ssh://git@github.com/}" ;;
    *) echo "ERROR: cannot derive owner/repo from origin URL: $url — gh api fallback unavailable." >&2 ;;
  esac
  owner_repo="${owner_repo%.git}"
  if [[ -n "$owner_repo" ]] \
     && gh api "repos/${owner_repo}/contents/tests/e2e/e2e.conf.example?ref=main" \
          --jq '.content' 2>/dev/null | base64 -d > "$out" && [[ -s "$out" ]]; then
    echo "Template seeded via gh api (?ref=main)."
    return 0
  fi
  echo "ERROR: template fetch failed — neither git show '${REF}' nor the gh api fallback yielded tests/e2e/e2e.conf.example." >&2
  return 1
}

# ---------------------------------------------------------------------------
# 3. GENERATE — one entry per detected CLI. Machine env honored for the
#    Bedrock variants (values regex-validated before being embedded — the
#    env-setup is `eval`'d by the harness, so nothing unvalidated is written).
# ---------------------------------------------------------------------------
gen_entry() {
  local cli="$1"
  case "$cli" in
    claude)
      if [[ "${CLAUDE_CODE_USE_BEDROCK:-}" == "1" ]]; then
        local region="${AWS_REGION:-us-east-1}"
        [[ "$region" =~ ^[A-Za-z0-9-]+$ ]] || region="us-east-1"
        printf 'claude-default|claude||export CLAUDE_CODE_USE_BEDROCK=1; export AWS_REGION="%s"\n' "$region"
      else
        printf 'claude-default|claude||true\n'
      fi
      ;;
    codex)
      if [[ -n "${BEDROCK_AWS_REGION:-}" && "$BEDROCK_AWS_REGION" =~ ^[A-Za-z0-9-]+$ ]]; then
        printf 'codex-default|codex||export BEDROCK_AWS_REGION="%s"\n' "$BEDROCK_AWS_REGION"
      else
        printf 'codex-default|codex||true\n'
      fi
      ;;
    kiro)
      # run_agent's kiro branch defaults to the repo's own agent name, which a
      # foreign box's workspace may not define — pin the safe `default` (the
      # template's guidance) unless the operator already set one.
      printf 'kiro-default|kiro||export KIRO_AGENT_NAME="${KIRO_AGENT_NAME:-default}"\n'
      ;;
    *)
      printf '%s-default|%s||true\n' "$cli" "$cli"
      ;;
  esac
}

TMP_CONF="$(mktemp "${TMPDIR:-/tmp}/setup-live-runner.XXXXXX")"
TEMPLATE_FILE="$(mktemp "${TMPDIR:-/tmp}/setup-live-runner-tpl.XXXXXX")"
trap 'rm -f "$TMP_CONF" "$TEMPLATE_FILE"' EXIT

{
  echo "# agent-smoke matrix — GENERATED by tests/e2e/setup-live-runner.sh"
  echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)   Detected CLIs: ${DETECTED[*]}"
  echo "# Canonical per-box path ([INV-77] rule 4 — the single provisioning"
  echo "# channel; the SMOKE_MATRIX / RUNNER_SMOKE_CONF repo variables are gone)."
  echo "# Enrich per box from the saved template (e2e.conf.example, next to this"
  echo "# file): Bedrock regions, custom endpoints, require: credential guards."
  echo "# NEVER put real keys in this file — source a gitignored local secrets"
  echo "# file inside env-setup instead. Missing CLIs run as UNAVAILABLE"
  echo "# (advisory, non-blocking) — an any-subset matrix is a valid matrix."
  for cli in "${DETECTED[@]}"; do
    gen_entry "$cli"
  done
} > "$TMP_CONF"

# Self-validate with the harness's own rule: every non-comment, non-blank
# line is exactly 4 `|`-fields; a malformed line is a loud reject, rc 1.
bad=$(awk -F'|' '/^[[:space:]]*[^#[:space:]]/ && NF != 4 { c++ } END { print c + 0 }' "$TMP_CONF")
if [[ "$bad" -ne 0 ]]; then
  echo "ERROR: generated matrix has $bad malformed entr(ies) — refusing to write" >&2
  exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "--- dry run: matrix that WOULD be written to $CONF ---"
  cat "$TMP_CONF"
  echo "--- (nothing written; re-run without --dry-run to onboard) ---"
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. WRITE — clobber guard: an existing matrix is operator-tuned state;
#    replacing it is an explicit --force decision, never a silent side effect.
# ---------------------------------------------------------------------------
if [[ -e "$CONF" && "$FORCE" -ne 1 ]]; then
  echo "ERROR: $CONF already exists — review it, then re-run with --force to replace." >&2
  exit 3
fi

if ! fetch_template "$TEMPLATE_FILE"; then
  exit 1
fi

mkdir -p "$(dirname "$CONF")"
cp "$TMP_CONF" "$CONF" && chmod 600 "$CONF"   # operator-trusted config (its env-setup is eval'd) — owner-only
cp "$TEMPLATE_FILE" "$(dirname "$CONF")/e2e.conf.example"

# ---------------------------------------------------------------------------
# 5. REPORT
# ---------------------------------------------------------------------------
echo
echo "Live runner onboarded ([INV-77] rule 4 — one standard onboarding form):"
echo "  matrix  : $CONF"
echo "  entries : ${DETECTED[*]}"
echo "  template: $(dirname "$CONF")/e2e.conf.example  — enrich per box (Bedrock"
echo "            regions, custom endpoints, require: guards), then --force re-run."
echo "  next    : register the GitHub Actions runner itself"
echo "            (actions-runner/config.sh --url … --labels ${RUNNER_LABEL:-self-hosted})"
echo "            if not already registered; the live tier stays label-gated and"
echo "            advisory — missing CLIs run as UNAVAILABLE, never blocking."

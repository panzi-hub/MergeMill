#!/bin/bash
# test-setsid-keg-only-path.sh — Unit tests for INV-125: `setsid` discovery when
# util-linux is installed KEG-ONLY (Homebrew never links it into
# /opt/homebrew/bin), so `command -v setsid` fails even though util-linux IS
# installed and every guard in the tree silently degrades.
#
# Design:    docs/designs/setsid-keg-only-path.md
# Test cases: docs/test-cases/setsid-keg-only-path.md (TC-SKOP-001..012)
#
# WHAT IT PINS
# ------------
# The behavioural half drives the REAL `lane_ensure_setsid_path` under `env -i`
# with a controlled PATH and fixture fallback dirs (via
# $LANE_SETSID_FALLBACK_DIRS), so it never depends on the host's real layout —
# essential, because on the Linux CI runner `setsid` happens to live in /usr/bin
# and the bug is unreproducible without a sandbox PATH.
#
#   TC-SKOP-001 found via fallback -> appended, resolvable, order preserved
#   TC-SKOP-002 already resolvable -> byte-identical PATH, no append
#   TC-SKOP-003 absent everywhere  -> rc 1, PATH unchanged, source still OK
#   TC-SKOP-004 append-order       -> an earlier PATH entry keeps precedence
#   TC-SKOP-005 idempotence        -> double-source cannot duplicate the entry
#   TC-SKOP-006 multi-fallback     -> first MATCH wins, non-executable skipped
#   TC-SKOP-007 malformed list     -> empty entries tolerated, no empty PATH element
#   TC-SKOP-008 source-of-truth    -> append-only construction + fixed prefix list
#   TC-SKOP-009 chokepoint         -> every guarded entry point sources lib-lane.sh
#   TC-SKOP-010 syntax + remedy    -> bash -n; wrappers name the keg-only remedy
#   TC-SKOP-011 dir false-positive -> executable DIR named setsid is not a hit
#   TC-SKOP-012 set -e survival    -> sourcing is non-fatal under set -euo pipefail
#
# Run: bash tests/unit/test-setsid-keg-only-path.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/MergeMill-dispatcher/scripts"
LIB_LANE="$SCRIPTS/lib-lane.sh"
# Absolute path: the probe subshell runs under `env -i` with a sandbox PATH that
# deliberately lacks a `bash`, so `env … bash` would fail to resolve. Resolving
# it here (against the normal PATH) keeps the sandbox hermetic.
BASH_BIN="$(command -v bash)"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert_pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
assert_fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    assert_pass "$desc"
  else
    assert_fail "$desc (expected [$expected] got [$actual])"
  fi
}
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    assert_pass "$desc"
  else
    assert_fail "$desc (needle='$needle' not found)"
  fi
}
assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    assert_pass "$desc"
  else
    assert_fail "$desc (needle='$needle' SHOULD NOT be present)"
  fi
}

[[ -f "$LIB_LANE" ]] || { echo -e "${RED}FATAL${NC}: $LIB_LANE not found"; exit 1; }

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
mkdir -p "$TMPROOT/home"

# ---------------------------------------------------------------------------
# Fixtures. A "setsid" fixture is a symlink to /usr/bin/true (executable);
# `command -v` only tests executability, so its behaviour never matters.
#
# SANDBOX is the minimal PATH a bare `source lib-lane.sh` needs: the lib's
# source-time `_LIB_LANE_DIR="$(cd "$(dirname ...)" && pwd)"` (lib-lane.sh:49)
# requires `dirname`. It deliberately does NOT contain setsid.
# ---------------------------------------------------------------------------
SANDBOX="$TMPROOT/sandbox"; mkdir -p "$SANDBOX"
ln -s "$(command -v dirname)" "$SANDBOX/dirname"

FALLBACK="$TMPROOT/opt-util-linux-bin"; mkdir -p "$FALLBACK"
ln -s /usr/bin/true "$FALLBACK/setsid"

PRE="$TMPROOT/pre-existing"; mkdir -p "$PRE"
ln -s /usr/bin/true "$PRE/setsid"

DECOY="$TMPROOT/decoy"; mkdir -p "$DECOY"
ln -s /usr/bin/true "$DECOY/setsid"

NOEXEC="$TMPROOT/no-exec"; mkdir -p "$NOEXEC"
# A REAL file, not a symlink: `chmod` follows a symlink and would target
# /usr/bin/true instead of the fixture.
: > "$NOEXEC/setsid"
chmod 0644 "$NOEXEC/setsid"

# probe <path> <fallback-dirs> — source the real lib in an env -i subshell and
# report src rc / fn rc / resolution / PATH. Uses `&& ... || ...` rather than a
# bare call so this stays correct even if a future lib gains `set -e`.
probe() {
  local p="$1" fb="$2"
  env -i PATH="$p" HOME="$TMPROOT/home" LANE_SETSID_FALLBACK_DIRS="$fb" \
    "$BASH_BIN" -c 'source "$1"; src=$?
             lane_ensure_setsid_path && rc=0 || rc=$?
             printf "src=%s\nrc=%s\nresolved=%s\npath=%s\n" \
               "$src" "$rc" "$(command -v setsid || true)" "$PATH"' \
      _ "$LIB_LANE"
}
f_src()  { printf '%s\n' "$1" | sed -n 's/^src=//p'; }
f_rc()   { printf '%s\n' "$1" | sed -n 's/^rc=//p'; }
f_res()  { printf '%s\n' "$1" | sed -n 's/^resolved=//p'; }
f_path() { printf '%s\n' "$1" | sed -n 's/^path=//p'; }

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-SKOP-001: found via fallback — appended, resolvable, order kept ==="
# ---------------------------------------------------------------------------
OUT=$(probe "$SANDBOX" "$FALLBACK")
assert_eq       "fn rc is 0 (setsid resolvable afterwards)"           "0"                       "$(f_rc "$OUT")"
assert_eq       "source rc is 0"                                      "0"                       "$(f_src "$OUT")"
assert_eq       "command -v setsid resolves to the fixture"           "$FALLBACK/setsid"        "$(f_res "$OUT")"
assert_eq       "fallback dir is APPENDED (existing entry first)"     "$SANDBOX:$FALLBACK"      "$(f_path "$OUT")"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-SKOP-002: already resolvable — true no-op ==="
# ---------------------------------------------------------------------------
OUT=$(probe "$PRE:$SANDBOX" "$FALLBACK")
assert_eq "fn rc is 0"                                    "0"                  "$(f_rc "$OUT")"
assert_eq "PATH is byte-identical (no append happened)"   "$PRE:$SANDBOX"      "$(f_path "$OUT")"
assert_eq "the unused fallback dir was NOT appended"      "$PRE/setsid"        "$(f_res "$OUT")"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-SKOP-003: absent everywhere — degraded posture preserved ==="
# ---------------------------------------------------------------------------
OUT=$(probe "$SANDBOX" "$TMPROOT/does-not-exist")
assert_eq "fn rc is 1"                                        "1"           "$(f_rc "$OUT")"
assert_eq "PATH is unchanged"                                 "$SANDBOX"    "$(f_path "$OUT")"
assert_eq "source returned 0 (status of the lib's last statement)" "0"           "$(f_src "$OUT")"
assert_eq "setsid still unresolved"                           ""            "$(f_res "$OUT")"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-SKOP-004: append-order — earlier entries keep precedence ==="
# ---------------------------------------------------------------------------
OUT=$(probe "$DECOY:$SANDBOX" "$FALLBACK")
assert_eq "fn rc is 0"                                       "0"                "$(f_rc "$OUT")"
assert_eq "the EARLIER entry wins (append cannot shadow)"    "$DECOY/setsid"    "$(f_res "$OUT")"
assert_eq "no append happened (nothing to fix)"              "$DECOY:$SANDBOX"  "$(f_path "$OUT")"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-SKOP-005: idempotence — double-source cannot duplicate ==="
# ---------------------------------------------------------------------------
DUP=$(env -i PATH="$SANDBOX" HOME="$TMPROOT/home" LANE_SETSID_FALLBACK_DIRS="$FALLBACK" \
  "$BASH_BIN" -c 'source "$1"; source "$1"; printf "%s" "$PATH"' _ "$LIB_LANE")
assert_eq "fallback dir appears exactly once after two sources" "$SANDBOX:$FALLBACK" "$DUP"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-SKOP-006: multi-fallback — first MATCH wins, non-exec skipped ==="
# ---------------------------------------------------------------------------
OUT=$(probe "$SANDBOX" "$NOEXEC:$FALLBACK")
assert_eq "fn rc is 0"                                          "0"                  "$(f_rc "$OUT")"
assert_eq "an executable fallback was selected"                 "$FALLBACK/setsid"   "$(f_res "$OUT")"
assert_eq "the non-executable candidate dir was NOT appended"   "$SANDBOX:$FALLBACK" "$(f_path "$OUT")"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-SKOP-007: malformed fallback list tolerated ==="
# ---------------------------------------------------------------------------
OUT=$(probe "$SANDBOX" ":$FALLBACK:")
assert_eq "fn rc is 0 with leading/trailing empty entries"      "0"                  "$(f_rc "$OUT")"
assert_eq "no empty PATH element introduced"                    "$SANDBOX:$FALLBACK" "$(f_path "$OUT")"
assert_not_contains "no '::' in the resulting PATH"             "::"                 "$(f_path "$OUT")"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-SKOP-008: source-of-truth — append-only + fixed prefix list ==="
# ---------------------------------------------------------------------------
LIB_SRC=$(cat "$LIB_LANE")
assert_contains     "source-time call guarded with || true"  'lane_ensure_setsid_path || true'  "$LIB_SRC"
assert_contains     "append form present"                    'PATH="${PATH}:${_dir}"'          "$LIB_SRC"
assert_not_contains "NO prepend form anywhere"               'PATH="${_dir}:${PATH}"'          "$LIB_SRC"
assert_contains     "Apple-silicon Homebrew prefix listed"   '/opt/homebrew/opt/util-linux/bin' "$LIB_SRC"
assert_contains     "Intel Homebrew prefix listed"           '/usr/local/opt/util-linux/bin'    "$LIB_SRC"
assert_contains     "MacPorts prefix listed"                 '/opt/local/bin'                   "$LIB_SRC"
assert_contains     "probe is defined as a function"         'lane_ensure_setsid_path() {'      "$LIB_SRC"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-SKOP-009: every setsid-guard site is covered by the chokepoint ==="
# ---------------------------------------------------------------------------
# (A) Golden set: a `command -v setsid` guard added in a NEW file must fail here
#     until the author has deliberately placed it behind the probe. Both sides
#     are `sort`-normalized so the comparison is locale-independent.
GUARD_FILES=$(grep -rl 'command -v setsid' "$SCRIPTS" --include='*.sh' \
  | sed "s|^$SCRIPTS/||" | sort | tr '\n' ' ')
EXPECTED_GUARDS=$(printf '%s\n' \
  MergeMill-dev.sh MergeMill-review.sh adt-gc.sh \
  lib-agent.sh lib-guardian.sh lib-lane.sh lib-review-e2e.sh | sort | tr '\n' ' ')
assert_eq "guard-site set is exactly the known seven" "$EXPECTED_GUARDS" "$GUARD_FILES"

# (B) Entry points that evaluate a guard must source the lib that installs the
#     probe. (dispatcher-tick.sh is deliberately absent: it evaluates no guard.)
for entry in MergeMill-dev.sh MergeMill-review.sh adt-gc.sh; do
  if grep -qE '(^|[[:space:]])(source|\.)[[:space:]]+.*lib-lane\.sh' "$SCRIPTS/$entry"; then
    assert_pass "$entry sources lib-lane.sh (probe reaches it directly)"
  else
    assert_fail "$entry evaluates a setsid guard but does NOT source lib-lane.sh"
  fi
done

# (C) Library guard sites inherit the normalized PATH at runtime by one of two
#     mechanisms, and each must be pinned by the ACTUAL source statement — a
#     bare name match also fires on a comment or a log string, which is how a
#     removed `source` could stay green here.
srcs_in() { # srcs_in <file> <regex-for-the-sourced-path>
  grep -qE "(^|[[:space:]])(source|\.)[[:space:]]+.*$2" "$SCRIPTS/$1"
}
for lib in lib-agent.sh lib-review-e2e.sh; do
  if srcs_in MergeMill-dev.sh "$lib" || srcs_in MergeMill-review.sh "$lib"; then
    assert_pass "$lib is sourced by a wrapper (inherits the normalized PATH)"
  else
    assert_fail "$lib evaluates a setsid guard but no wrapper sources it"
  fi
done
# lib-guardian.sh runs as its own `setsid`-detached process, so it cannot
# inherit anything from the wrapper: it must re-source the lib itself.
if srcs_in lib-guardian.sh 'lib-lane\.sh'; then
  assert_pass "lib-guardian.sh re-sources lib-lane.sh in its own process"
else
  assert_fail "lib-guardian.sh evaluates a setsid guard but does not re-source lib-lane.sh"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-SKOP-010: syntax + operator-facing keg-only remedy text ==="
# ---------------------------------------------------------------------------
for f in lib-lane.sh MergeMill-dev.sh MergeMill-review.sh; do
  if bash -n "$SCRIPTS/$f" 2>/dev/null; then
    assert_pass "bash -n clean: $f"
  else
    assert_fail "bash -n FAILED: $f"
  fi
done

for w in MergeMill-dev.sh MergeMill-review.sh; do
  MSG=$(grep 'setsid (util-linux) is missing' "$SCRIPTS/$w" || true)
  assert_contains "$w remedy mentions keg-only (operator already has util-linux)" 'keg-only' "$MSG"
  assert_contains "$w remedy names the PATH dir to add"                           'util-linux/bin' "$MSG"
done

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-SKOP-011: an executable DIRECTORY named setsid is not a hit ==="
# ---------------------------------------------------------------------------
# `[[ -x ]]` accepts an executable directory; `command -v setsid` rejects one.
# Without the `! -d` guard a dir-only candidate is a false positive: the fn
# returns 0 with setsid STILL unresolvable, and a re-source appends that dir a
# second time (the idempotence proof in TC-SKOP-005 depends on `command -v`
# agreeing with the `-x` test, which is exactly what a directory breaks).
DIREXEC="$TMPROOT/dir-exec"
mkdir -p "$DIREXEC/setsid"
chmod +x "$DIREXEC/setsid"

OUT=$(probe "$SANDBOX" "$DIREXEC:$FALLBACK")
assert_eq "fn rc is 0 (a real fallback further down was used)" "0"                  "$(f_rc "$OUT")"
assert_eq "the directory candidate was skipped"                "$FALLBACK/setsid"   "$(f_res "$OUT")"
assert_eq "the directory candidate was NOT appended"           "$SANDBOX:$FALLBACK" "$(f_path "$OUT")"

OUT=$(probe "$SANDBOX" "$DIREXEC")
assert_eq "dir-only candidate: fn rc is 1 (no false positive)" "1"        "$(f_rc "$OUT")"
assert_eq "dir-only candidate: setsid still unresolved"        ""         "$(f_res "$OUT")"
assert_eq "dir-only candidate: PATH unchanged"                 "$SANDBOX" "$(f_path "$OUT")"

DIRDUP=$(env -i PATH="$SANDBOX" HOME="$TMPROOT/home" LANE_SETSID_FALLBACK_DIRS="$DIREXEC" \
  "$BASH_BIN" -c 'source "$1"; source "$1"; printf "%s" "$PATH"' _ "$LIB_LANE")
assert_eq "dir-only candidate: double-source cannot duplicate" "$SANDBOX" "$DIRDUP"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-SKOP-012: sourcing stays non-fatal under set -euo pipefail ==="
# ---------------------------------------------------------------------------
# The lib is sourced by callers that run `set -euo pipefail` (both wrappers,
# dispatch-local.sh, adt-gc.sh). With no setsid anywhere, the source-time call
# must not abort the caller — that is what `|| true` buys, and it is the one
# property TC-SKOP-003's `src=` line cannot observe (that only reports the rc of
# the lib's LAST statement, never an abort part-way through the source). A
# subshell that reaches the printf has survived the source; drop the `|| true`
# and `set -e` aborts before it.
SETE_OUT=$(env -i PATH="$SANDBOX" HOME="$TMPROOT/home" \
  LANE_SETSID_FALLBACK_DIRS="$TMPROOT/does-not-exist" \
  "$BASH_BIN" -c 'set -euo pipefail; source "$1"; printf "SURVIVED"' _ "$LIB_LANE" 2>/dev/null)
SETE_RC=$?
assert_eq "shell survives sourcing with no setsid under set -euo pipefail" "SURVIVED" "$SETE_OUT"
assert_eq "sourcing subshell exit code is 0"                               "0"        "$SETE_RC"

# ---------------------------------------------------------------------------
echo ""
echo "======================================"
echo "  PASS: $PASS   FAIL: $FAIL"
echo "======================================"
[[ "$FAIL" -eq 0 ]] || exit 1

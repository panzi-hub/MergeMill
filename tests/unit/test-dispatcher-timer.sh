#!/bin/bash
# The dispatcher clock is a macOS launchd agent. This test locks that
# contract: non-Darwin fails closed, the plist names the tick script, and
# the installer never calls crontab.

set -uo pipefail

PASS=0
FAIL=0
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALL="$ROOT/skills/MergeMill-dispatcher/scripts/install-dispatcher-timer.sh"

assert_pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
assert_fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if [[ ! -f "$INSTALL" ]]; then
  echo "missing installer: $INSTALL" >&2
  exit 1
fi

if grep -q 'crontab' "$INSTALL"; then
  assert_fail "installer must not call crontab"
else
  assert_pass "installer does not call crontab"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/skills/MergeMill-dispatcher/scripts"
cat > "$TMP/skills/MergeMill-dispatcher/scripts/dispatcher-tick.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$TMP/skills/MergeMill-dispatcher/scripts/dispatcher-tick.sh"
cat > "$TMP/bin/launchctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${LAUNCHCTL_LOG:?}"
exit 0
EOF
chmod +x "$TMP/bin/launchctl"
export LAUNCHCTL_LOG="$TMP/launchctl.log"
touch "$LAUNCHCTL_LOG"

set +e
out="$(HOME="$TMP/home" PATH="$TMP/bin:$PATH" _DISPATCH_UNAME_OVERRIDE=Linux bash "$INSTALL" --tick-script "$TMP/skills/MergeMill-dispatcher/scripts/dispatcher-tick.sh" 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 1 && "$out" == *"launchd-only"* ]]; then
  assert_pass "non-Darwin refuses to install another scheduler"
else
  assert_fail "non-Darwin should exit 1 naming launchd-only (rc=$rc out=$out)"
fi
if [[ -e "$TMP/home/Library/LaunchAgents/com.mergemill.dispatcher.plist" ]]; then
  assert_fail "non-Darwin wrote a plist"
else
  assert_pass "non-Darwin writes no plist"
fi

: > "$LAUNCHCTL_LOG"
set +e
out="$(HOME="$TMP/home" PATH="$TMP/bin:$PATH" _DISPATCH_UNAME_OVERRIDE=Darwin bash "$INSTALL" --tick-script "$TMP/skills/MergeMill-dispatcher/scripts/dispatcher-tick.sh" 2>&1)"
rc=$?
set -e
PLIST="$TMP/home/Library/LaunchAgents/com.mergemill.dispatcher.plist"
if [[ "$rc" -eq 0 && -f "$PLIST" ]]; then
  assert_pass "Darwin install exits 0 and writes a plist"
else
  assert_fail "Darwin install failed (rc=$rc out=$out)"
fi
if [[ -f "$PLIST" ]] && grep -q '<string>com.mergemill.dispatcher</string>' "$PLIST" && grep -q '<integer>300</integer>' "$PLIST" && grep -q 'dispatcher-tick.sh' "$PLIST"; then
  assert_pass "plist labels the agent, ticks every 300s, and names dispatcher-tick.sh"
else
  assert_fail "plist missing required clock contract"
fi
if [[ -f "$PLIST" ]] && grep -q '<key>AbandonProcessGroup</key>' "$PLIST" && grep -A1 '<key>AbandonProcessGroup</key>' "$PLIST" | grep -q '<true/>'; then
  assert_pass "plist abandons the process group so tick exit does not kill wrappers"
else
  assert_fail "plist missing AbandonProcessGroup"
fi
if grep -q 'bootstrap gui/' "$LAUNCHCTL_LOG"; then
  assert_pass "installer bootstraps the gui domain"
else
  assert_fail "installer did not bootstrap (log=$(cat "$LAUNCHCTL_LOG"))"
fi

echo
echo "passed=$PASS failed=$FAIL"
[[ "$FAIL" -eq 0 ]]

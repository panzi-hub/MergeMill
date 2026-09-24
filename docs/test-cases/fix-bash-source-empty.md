# Test Cases: Fix BASH_SOURCE[0] empty (#39)

## TC-BSE-001: MERGEMILL_CONF env var takes highest priority

**Steps:**
1. Set MERGEMILL_CONF to a config file with known PROJECT_ID
2. Source lib-agent.sh (or simulate its config loading)
3. Verify PROJECT_ID matches the MERGEMILL_CONF file

**Expected:** Config from MERGEMILL_CONF is used, not from SCRIPT_DIR

## TC-BSE-002: BASH_SOURCE[0] fallback to $0 in bash -c context

**Steps:**
1. Create a script that sources lib-agent.sh and prints _LIB_AGENT_DIR
2. Invoke it via `bash -c 'bash /path/to/script.sh'`
3. Verify _LIB_AGENT_DIR resolves to the real script directory

**Expected:** _LIB_AGENT_DIR is valid even in bash -c context

## TC-BSE-003: Normal sourcing still works (regression)

**Steps:**
1. Source lib-agent.sh normally from a script
2. Verify _LIB_AGENT_DIR resolves correctly

**Expected:** Existing behavior preserved

## TC-BSE-004: MERGEMILL_CONF overrides local config

**Steps:**
1. Place MergeMill.conf in SCRIPT_DIR with value A
2. Set MERGEMILL_CONF to a different config with value B
3. Source lib-agent.sh
4. Verify PROJECT_ID == B

**Expected:** MERGEMILL_CONF takes precedence over local config

## TC-BSE-005: lib-auth.sh has same fix applied

**Steps:**
1. Verify lib-auth.sh uses MERGEMILL_CONF and BASH_SOURCE fallback

**Expected:** Content check passes

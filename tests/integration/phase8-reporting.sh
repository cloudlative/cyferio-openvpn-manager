#!/usr/bin/env bash
# phase8-reporting.sh — Phase 8 exit-criteria check: `mac report` against
# real users/MACs and a real Phase 7 connection-decision audit trail. Run
# as root on a VM with `install` already done.
set -Eeuo pipefail

CYFERIO_BIN="${1:-/opt/cyferio-openvpn-manager/bin/cyferio-vpn}"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

echo "=== setup: alice (2 MACs, 1 real connect), bob (no MACs) ==="
"${CYFERIO_BIN}" user add alice >/dev/null
"${CYFERIO_BIN}" mac add alice "AA:BB:CC:DD:EE:01" >/dev/null
"${CYFERIO_BIN}" mac add alice "AA:BB:CC:DD:EE:02" >/dev/null
"${CYFERIO_BIN}" user add bob >/dev/null

# Drive a real connection decision through the installed hook (same
# invocation contract OpenVPN itself uses — see phase7-mac-enforcement.sh)
# so mac report has a genuine audit_logs row to surface, not a fixture.
sudo -u nobody env -i "common_name=alice" "IV_HWADDR=AA:BB:CC:DD:EE:01" /etc/cyferio/hooks/client-connect.sh

echo
echo "=== mac report (table): shows MAC count, MAC list, and last event ==="
"${CYFERIO_BIN}" mac report | tee /tmp/mac-report-table.txt
grep -q "^alice " /tmp/mac-report-table.txt && pass "alice row present" || fail "alice row missing"
grep -q "AA:BB:CC:DD:EE:01,AA:BB:CC:DD:EE:02" /tmp/mac-report-table.txt && pass "alice's 2 MACs listed" || fail "alice's MACs not shown"
grep -q "auth.mac_accept @" /tmp/mac-report-table.txt && pass "alice's last connection event shown" || fail "last event not shown"
grep -q "^bob " /tmp/mac-report-table.txt && pass "bob row present" || fail "bob row missing"

echo
echo "=== mac report --json ==="
"${CYFERIO_BIN}" mac report --json | tee /tmp/mac-report.json >/dev/null
jq -e '[.[] | select(.username=="alice")][0].mac_addresses | length == 2' /tmp/mac-report.json >/dev/null \
  && pass "alice has 2 MACs in JSON" || fail "expected 2 MACs for alice in JSON"
jq -e '[.[] | select(.username=="alice")][0].last_event.action == "auth.mac_accept"' /tmp/mac-report.json >/dev/null \
  && pass "alice's last_event.action is auth.mac_accept" || fail "unexpected/missing last_event for alice"
jq -e '[.[] | select(.username=="bob")][0] | has("last_event") | not' /tmp/mac-report.json >/dev/null \
  && pass "bob has no last_event (never connected)" || fail "bob unexpectedly has a last_event"
jq -e '[.[] | select(.username=="bob")][0].mac_addresses == []' /tmp/mac-report.json >/dev/null \
  && pass "bob has an empty MAC list, not null" || fail "bob's mac_addresses is not an empty array"

echo
echo "=== mac report --plain: unaligned, script-friendly ==="
"${CYFERIO_BIN}" mac report --plain | tee /tmp/mac-report-plain.txt
grep -q "^alice|active|2|AA:BB:CC:DD:EE:01,AA:BB:CC:DD:EE:02|auth.mac_accept @" /tmp/mac-report-plain.txt \
  && pass "plain output is exact pipe-delimited fields" || fail "plain output not in the expected shape"

echo
echo "=== mac report: empty-state message with no users ==="
"${CYFERIO_BIN}" user remove alice --force >/dev/null
"${CYFERIO_BIN}" user remove bob --force >/dev/null
"${CYFERIO_BIN}" mac report | tee /tmp/mac-report-empty.txt
grep -q "No users yet." /tmp/mac-report-empty.txt && pass "empty-state message shown" || fail "empty-state message missing"

echo
echo "ALL PHASE 8 CHECKS PASSED"

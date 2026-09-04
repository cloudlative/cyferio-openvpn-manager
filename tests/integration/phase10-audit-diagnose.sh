#!/usr/bin/env bash
# phase10-audit-diagnose.sh — Phase 10 exit-criteria check: `audit` and
# `diagnose` against a real, freshly-installed server (everything should
# be healthy), then again after deliberately introducing one permission
# drift and one config drift, confirming each is actually detected. Run
# as root on a VM with `install` already done.
set -Eeuo pipefail

CYFERIO_BIN="${1:-/opt/cyferio-openvpn-manager/bin/cyferio-vpn}"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

echo "=== audit: a freshly-installed server is fully healthy ==="
"${CYFERIO_BIN}" audit | tee /tmp/audit-clean.txt
grep -q "^Overall: pass$" /tmp/audit-clean.txt && pass "audit overall is pass" || fail "expected a clean audit to report Overall: pass"

echo
echo "=== diagnose: a freshly-installed, running server is fully healthy ==="
"${CYFERIO_BIN}" diagnose | tee /tmp/diagnose-clean.txt
grep -q "^Overall: pass$" /tmp/diagnose-clean.txt && pass "diagnose overall is pass" || fail "expected a clean diagnose to report Overall: pass"

echo
echo "=== audit --json / diagnose --json are well-formed ==="
"${CYFERIO_BIN}" audit --json | jq -e 'all(.[]; .status == "pass")' >/dev/null \
  && pass "audit --json: every check passes on a clean install" || fail "audit --json reported a non-pass check on a clean install"
"${CYFERIO_BIN}" diagnose --json | jq -e 'all(.[]; .status == "pass")' >/dev/null \
  && pass "diagnose --json: every check passes on a clean install" || fail "diagnose --json reported a non-pass check on a clean install"

echo
echo "=== audit detects a real permission drift ==="
chmod 777 /etc/cyferio/pki/private/ca.key
"${CYFERIO_BIN}" audit --json | tee /tmp/audit-drift.json >/dev/null
jq -e '[.[] | select(.name == "CA Private Key Permissions")][0].status == "fail"' /tmp/audit-drift.json >/dev/null \
  && pass "CA private key permission drift detected as fail" || fail "permission drift was not detected"
chmod 600 /etc/cyferio/pki/private/ca.key

echo
echo "=== audit detects mac_enforcement_mode=permissive ==="
sed -i "s/^mac_enforcement_mode=strict/mac_enforcement_mode=permissive/" /etc/cyferio/cyferio.conf
"${CYFERIO_BIN}" audit --json | tee /tmp/audit-permissive.json >/dev/null
jq -e '[.[] | select(.name == "MAC Enforcement Mode")][0].status == "warning"' /tmp/audit-permissive.json >/dev/null \
  && pass "permissive mode flagged as a warning" || fail "permissive mode was not flagged"
sed -i "s/^mac_enforcement_mode=permissive/mac_enforcement_mode=strict/" /etc/cyferio/cyferio.conf

echo
echo "=== diagnose detects the service being stopped ==="
systemctl stop openvpn-server@server
"${CYFERIO_BIN}" diagnose --json | tee /tmp/diagnose-stopped.json >/dev/null
jq -e '[.[] | select(.name == "OpenVPN Service")][0].status == "fail"' /tmp/diagnose-stopped.json >/dev/null \
  && pass "stopped service detected as fail" || fail "stopped service was not detected"
jq -e '[.[] | select(.name == "OpenVPN Listening")][0].status == "fail"' /tmp/diagnose-stopped.json >/dev/null \
  && pass "port no longer listening detected as fail" || fail "stopped-listening was not detected"
systemctl start openvpn-server@server

echo
echo "ALL PHASE 10 CHECKS PASSED"

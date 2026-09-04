#!/usr/bin/env bash
# phase9-status.sh — Phase 9 exit-criteria check: `cyferio-vpn status`
# against a real server with nobody connected (table/json/plain shape).
# The connected-client half (proving status-version 2 is really wired
# through server.conf.tmpl and ovpn_status_clients' parsing matches
# OpenVPN's actual output, not just a hand-fed fixture) is driven
# separately with a real second VM, the same way phase5/phase7's real
# connection tests are — see the Phase 9 commit message for that run.
# Run as root on the server VM with `install` already done.
set -Eeuo pipefail

CYFERIO_BIN="${1:-/opt/cyferio-openvpn-manager/bin/cyferio-vpn}"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

echo "=== status (table): server running, no clients connected ==="
"${CYFERIO_BIN}" status | tee /tmp/status-idle.txt
grep -q "^Status:  running$" /tmp/status-idle.txt && pass "server reports running" || fail "server status not 'running'"
grep -q "^Connected clients: 0$" /tmp/status-idle.txt && pass "0 clients connected" || fail "expected 0 connected clients"

echo
echo "=== status --json: idle shape ==="
"${CYFERIO_BIN}" status --json | tee /tmp/status-idle.json >/dev/null
jq -e '.server.status == "running" and .connected_clients.count == 0 and .connected_clients.clients == []' /tmp/status-idle.json >/dev/null \
  && pass "idle JSON shape correct" || fail "unexpected idle JSON shape"

echo
echo "=== status --plain ==="
"${CYFERIO_BIN}" status --plain | tee /tmp/status-idle-plain.txt
grep -q "^Connected clients: 0$" /tmp/status-idle-plain.txt && pass "plain output includes connected-client count" || fail "plain output missing expected line"

echo "ALL PHASE 9 CHECKS PASSED (idle)"

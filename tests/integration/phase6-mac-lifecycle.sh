#!/usr/bin/env bash
# phase6-mac-lifecycle.sh — Phase 6 exit-criteria check: users can manage
# MAC assignments (multiple per user, validated, duplicate-prevented
# both per-user and cross-user). Run as root on a VM with `install` +
# `user add alice` + `user add bob` already done.
set -Eeuo pipefail

CYFERIO_BIN="${1:-/opt/cyferio-openvpn-manager/bin/cyferio-vpn}"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

echo "=== mac add: validation ==="
if "${CYFERIO_BIN}" mac add alice "not-a-mac" 2>/tmp/badmac.err; then
  fail "invalid MAC should have been rejected"
else
  grep -q "invalid MAC address" /tmp/badmac.err && pass "invalid MAC rejected clearly" || fail "unclear rejection message"
fi

echo
echo "=== mac add: unknown user ==="
if "${CYFERIO_BIN}" mac add nobody "AA:BB:CC:DD:EE:01" 2>/tmp/nouser.err; then
  fail "unknown user should have been rejected"
else
  grep -q "no such user" /tmp/nouser.err && pass "unknown user rejected clearly" || fail "unclear rejection message"
fi

echo
echo "=== mac add: multiple MACs for one user, lowercase normalized ==="
"${CYFERIO_BIN}" mac add alice "aa:bb:cc:dd:ee:01"
"${CYFERIO_BIN}" mac add alice "AA:BB:CC:DD:EE:02"
"${CYFERIO_BIN}" mac list alice --json | tee /tmp/mac-list-alice.json
jq -e '.mac_addresses | length == 2' /tmp/mac-list-alice.json >/dev/null && pass "alice has 2 MACs" || fail "expected 2 MACs"
jq -e '[.mac_addresses[].mac_address] | contains(["AA:BB:CC:DD:EE:01"])' /tmp/mac-list-alice.json >/dev/null \
  && pass "lowercase input normalized to uppercase" || fail "MAC not normalized"

echo
echo "=== mac add: per-user duplicate rejected ==="
if "${CYFERIO_BIN}" mac add alice "AA:BB:CC:DD:EE:01" 2>/tmp/dup.err; then
  fail "duplicate MAC on same user should have been rejected"
else
  grep -q "already registered to 'alice'" /tmp/dup.err && pass "same-user duplicate rejected clearly" || fail "unclear duplicate message"
fi

echo
echo "=== mac add: cross-user duplicate rejected ==="
if "${CYFERIO_BIN}" mac add bob "AA:BB:CC:DD:EE:01" 2>/tmp/crossdup.err; then
  fail "MAC already owned by alice should have been rejected for bob"
else
  grep -q "already registered to user 'alice'" /tmp/crossdup.err && pass "cross-user duplicate rejected clearly" || fail "unclear cross-user message"
fi

echo
echo "=== mac list (tree format) ==="
"${CYFERIO_BIN}" mac list alice | tee /tmp/mac-list-table.txt
grep -q "^alice$" /tmp/mac-list-table.txt && pass "username header shown" || fail "username header missing"
grep -q "├── AA:BB:CC:DD:EE:01" /tmp/mac-list-table.txt && pass "first MAC uses branch glyph" || fail "branch glyph missing"
grep -q "└── AA:BB:CC:DD:EE:02" /tmp/mac-list-table.txt && pass "last MAC uses corner glyph" || fail "corner glyph missing"

echo
echo "=== mac update ==="
"${CYFERIO_BIN}" mac update alice "AA:BB:CC:DD:EE:02" "AA:BB:CC:DD:EE:03"
"${CYFERIO_BIN}" mac list alice --json | tee /tmp/mac-list-after-update.json
jq -e '[.mac_addresses[].mac_address] | contains(["AA:BB:CC:DD:EE:03"]) and (contains(["AA:BB:CC:DD:EE:02"]) | not)' /tmp/mac-list-after-update.json >/dev/null \
  && pass "MAC updated (old gone, new present)" || fail "update did not apply cleanly"

echo
echo "=== mac update: rejects updating a MAC not owned by the user ==="
if "${CYFERIO_BIN}" mac update alice "AA:BB:CC:DD:EE:99" "AA:BB:CC:DD:EE:04" 2>/tmp/notowned.err; then
  fail "update of an unregistered MAC should have failed"
else
  grep -q "is not registered to 'alice'" /tmp/notowned.err && pass "unregistered-MAC update rejected clearly" || fail "unclear message"
fi

echo
echo "=== mac update: rejects updating to a MAC owned by someone else ==="
"${CYFERIO_BIN}" mac add bob "AA:BB:CC:DD:EE:05"
if "${CYFERIO_BIN}" mac update alice "AA:BB:CC:DD:EE:01" "AA:BB:CC:DD:EE:05" 2>/tmp/crossupdate.err; then
  fail "update to a cross-user-owned MAC should have failed"
else
  grep -q "already registered to user 'bob'" /tmp/crossupdate.err && pass "cross-user update-collision rejected clearly" || fail "unclear message"
fi

echo
echo "=== mac remove ==="
"${CYFERIO_BIN}" mac remove alice "AA:BB:CC:DD:EE:01"
"${CYFERIO_BIN}" mac list alice --json | jq -e '.mac_addresses | length == 1' >/dev/null && pass "alice down to 1 MAC after remove" || fail "remove did not apply"

echo
echo "=== mac remove: unregistered MAC errors clearly ==="
if "${CYFERIO_BIN}" mac remove alice "AA:BB:CC:DD:EE:99" 2>/tmp/removefail.err; then
  fail "removing an unregistered MAC should have failed"
else
  grep -q "is not registered to 'alice'" /tmp/removefail.err && pass "unregistered-MAC remove rejected clearly" || fail "unclear message"
fi

echo
echo "=== mac list: user with none ==="
"${CYFERIO_BIN}" user add carol >/dev/null
"${CYFERIO_BIN}" mac list carol | tee /tmp/mac-list-empty.txt
grep -q "No MAC addresses registered for 'carol'" /tmp/mac-list-empty.txt && pass "empty-list message shown" || fail "empty-list message missing"

echo
echo "ALL PHASE 6 CHECKS PASSED"
# 'mac report' was a Phase 8 stub at the time this script was written;
# it's real now (Phase 8 — Reporting Engine) — see
# tests/integration/phase8-reporting.sh for its own coverage.

#!/usr/bin/env bash
# phase7-mac-enforcement.sh — Phase 7 exit-criteria check: the installed
# client-connect/-disconnect hooks (running as `nobody`) actually enforce
# MAC binding and disabled-user rejection, end-to-end, without a real
# OpenVPN client — simulates OpenVPN's own invocation contract (env vars,
# invoking user) directly against the installed hook scripts. Run as root
# on a VM with `install` already done.
set -Eeuo pipefail

CYFERIO_BIN="${1:-/opt/cyferio-openvpn-manager/bin/cyferio-vpn}"
HOOKS_DIR="/etc/cyferio/hooks"
LOG_FILE="/var/log/cyferio/cyferio.log"
DB_FILE="/var/lib/cyferio/cyferio.db"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# _connect COMMON_NAME MAC — runs the installed client-connect hook as
# `nobody`, exactly as OpenVPN itself would (script-security 2, dropped
# privileges), and echoes its exit code.
_connect() {
  local cn="$1" mac="${2:-}"
  sudo -u nobody env -i "common_name=${cn}" "IV_HWADDR=${mac}" "${HOOKS_DIR}/client-connect.sh"
}

_audit_count() {
  local action="$1" actor="$2"
  sqlite3 "${DB_FILE}" "SELECT COUNT(*) FROM audit_logs WHERE action='${action}' AND actor='${actor}';"
}

echo "=== setup: alice (1 MAC), bob (no MAC), eve (disabled) ==="
"${CYFERIO_BIN}" user add alice >/dev/null
"${CYFERIO_BIN}" mac add alice "AA:BB:CC:DD:EE:10" >/dev/null
"${CYFERIO_BIN}" user add bob >/dev/null
"${CYFERIO_BIN}" user add eve >/dev/null
"${CYFERIO_BIN}" user disable eve >/dev/null

echo
echo "=== client-connect: MAC match is accepted ==="
if _connect alice "AA:BB:CC:DD:EE:10"; then
  pass "alice with matching MAC accepted"
else
  fail "alice with matching MAC was rejected"
fi
[ "$(_audit_count auth.mac_accept alice)" -ge 1 ] && pass "auth.mac_accept audit row written" || fail "no auth.mac_accept row for alice"

echo
echo "=== client-connect: MAC mismatch is rejected ==="
if _connect alice "AA:BB:CC:DD:EE:99"; then
  fail "alice with a mismatched MAC was accepted"
else
  pass "alice with a mismatched MAC rejected"
fi
[ "$(_audit_count auth.mac_reject alice)" -ge 1 ] && pass "auth.mac_reject audit row written" || fail "no auth.mac_reject row for alice"

echo
echo "=== client-connect: missing peer MAC rejected in strict mode (default) ==="
if _connect alice ""; then
  fail "alice with no peer MAC was accepted under strict mode"
else
  pass "alice with no peer MAC rejected under strict mode"
fi

echo
echo "=== client-connect: user with no MAC policy is accepted regardless ==="
if _connect bob ""; then
  pass "bob (no MACs registered) accepted with no peer MAC"
else
  fail "bob (no MACs registered) was rejected"
fi
if _connect bob "11:22:33:44:55:66"; then
  pass "bob (no MACs registered) accepted with an arbitrary peer MAC"
else
  fail "bob (no MACs registered) was rejected with an arbitrary peer MAC"
fi

echo
echo "=== client-connect: disabled user rejected even with a valid cert/MAC ==="
"${CYFERIO_BIN}" mac add eve "AA:BB:CC:DD:EE:20" >/dev/null
if _connect eve "AA:BB:CC:DD:EE:20"; then
  fail "disabled user 'eve' was accepted"
else
  pass "disabled user 'eve' rejected despite a matching MAC"
fi

echo
echo "=== client-connect: unknown common_name rejected ==="
if _connect ghost "AA:BB:CC:DD:EE:10"; then
  fail "unknown common_name 'ghost' was accepted"
else
  pass "unknown common_name rejected"
fi

echo
echo "=== flat audit log received decision lines ==="
grep -q "session.connect" "${LOG_FILE}" && pass "session.connect lines present in ${LOG_FILE}" || fail "no session.connect lines logged"
grep -q "decision=ACCEPT" "${LOG_FILE}" && pass "an ACCEPT decision was logged" || fail "no ACCEPT decision logged"
grep -q "decision=REJECT" "${LOG_FILE}" && pass "a REJECT decision was logged" || fail "no REJECT decision logged"

echo
echo "=== client-disconnect: logs to both the flat log and audit_logs ==="
sudo -u nobody env -i "common_name=alice" "IV_HWADDR=AA:BB:CC:DD:EE:10" "time_duration=120" "${HOOKS_DIR}/client-disconnect.sh"
grep -q "session.disconnect" "${LOG_FILE}" && pass "session.disconnect line present" || fail "no session.disconnect line logged"
[ "$(_audit_count session.disconnect alice)" -ge 1 ] && pass "session.disconnect audit row written" || fail "no session.disconnect row for alice"

echo
echo "ALL PHASE 7 CHECKS PASSED"

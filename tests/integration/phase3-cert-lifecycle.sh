#!/usr/bin/env bash
# phase3-cert-lifecycle.sh — Phase 3 exit-criteria check: certificates can
# be created, listed, inspected, and revoked without touching OpenVPN
# itself (no server restart, no `user` commands). Run as root on a
# disposable VM, after `cyferio-vpn install` has bootstrapped the PKI.
set -Eeuo pipefail

CYFERIO_BIN="${1:-/opt/cyferio-openvpn-manager/bin/cyferio-vpn}"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

echo "=== cert create ==="
"${CYFERIO_BIN}" cert create alice
[[ -f /etc/cyferio/pki/issued/alice.crt ]] && pass "alice.crt issued" || fail "alice.crt missing"
[[ -f /etc/cyferio/pki/private/alice.key ]] && pass "alice.key issued" || fail "alice.key missing"
[[ "$(stat -c '%a' /etc/cyferio/pki/private/alice.key)" == "600" ]] && pass "alice.key is 0600" || fail "alice.key permissions wrong"

echo
echo "=== cert create: duplicate is rejected, not silently overwritten ==="
if "${CYFERIO_BIN}" cert create alice 2>/tmp/dup.err; then
  fail "duplicate cert create should have failed"
else
  grep -q "already exists" /tmp/dup.err && pass "duplicate rejected with a clear message" || fail "duplicate rejected but message unclear"
fi

echo
echo "=== cert create: reserved 'server' name is blocked ==="
if "${CYFERIO_BIN}" cert create server 2>/tmp/server.err; then
  fail "'cert create server' should have been blocked"
else
  grep -q "reserved\|managed by install" /tmp/server.err && pass "'server' name blocked" || fail "'server' blocked but message unclear"
fi

echo
echo "=== cert create: second identity ==="
"${CYFERIO_BIN}" cert create bob
[[ -f /etc/cyferio/pki/issued/bob.crt ]] && pass "bob.crt issued" || fail "bob.crt missing"

echo
echo "=== cert list (table) ==="
"${CYFERIO_BIN}" cert list | tee /tmp/cert-list.txt
grep -q "^alice " /tmp/cert-list.txt && pass "alice appears in table" || fail "alice missing from table"
grep -q "^bob " /tmp/cert-list.txt && pass "bob appears in table" || fail "bob missing from table"
grep -q "^server " /tmp/cert-list.txt && pass "server appears in table" || fail "server missing from table"

echo
echo "=== cert list --json ==="
"${CYFERIO_BIN}" cert list --json | tee /tmp/cert-list.json
jq -e '[.[] | select(.name=="alice" and .status=="valid" and .type=="client")] | length == 1' /tmp/cert-list.json >/dev/null \
  && pass "alice present as valid client in JSON" || fail "alice JSON entry wrong"
jq -e '[.[] | select(.name=="server" and .type=="server")] | length == 1' /tmp/cert-list.json >/dev/null \
  && pass "server present as type=server in JSON" || fail "server JSON entry wrong"

echo
echo "=== cert status alice ==="
"${CYFERIO_BIN}" cert status alice --json | tee /tmp/cert-status-alice.json
jq -e '.status == "valid" and .type == "client"' /tmp/cert-status-alice.json >/dev/null \
  && pass "alice status is valid/client" || fail "alice status wrong"

echo
echo "=== cert status: unknown name errors clearly ==="
if "${CYFERIO_BIN}" cert status nobody 2>/tmp/nobody.err; then
  fail "'cert status nobody' should have failed"
else
  grep -q "no certificate found" /tmp/nobody.err && pass "unknown name errors clearly" || fail "unclear error for unknown name"
fi

echo
echo "=== cert revoke alice ==="
"${CYFERIO_BIN}" cert revoke alice --force
"${CYFERIO_BIN}" cert status alice --json | tee /tmp/cert-status-alice-revoked.json
jq -e '.status == "revoked" and (.revoked_at | length > 0)' /tmp/cert-status-alice-revoked.json >/dev/null \
  && pass "alice status is revoked with revoked_at set" || fail "alice not marked revoked"

echo
echo "=== bob is unaffected by alice's revocation ==="
"${CYFERIO_BIN}" cert status bob --json | tee /tmp/cert-status-bob.json
jq -e '.status == "valid"' /tmp/cert-status-bob.json >/dev/null && pass "bob still valid" || fail "bob unexpectedly affected"

echo
echo "=== revoked cert takes effect without restarting the service ==="
started_before="$(systemctl show -p ActiveEnterTimestamp openvpn-server@server)"
"${CYFERIO_BIN}" cert revoke bob --force
started_after="$(systemctl show -p ActiveEnterTimestamp openvpn-server@server)"
[[ "${started_before}" == "${started_after}" ]] && pass "service was not restarted by cert revoke" || fail "service was restarted (should not be needed — CRL is re-read live)"
grep -q "$(openssl x509 -in /etc/cyferio/pki/issued/bob.crt -noout -serial | cut -d= -f2 | tr '[:upper:]' '[:lower:]')" \
  <(openssl crl -in /etc/openvpn/server/crl.pem -noout -text | grep -i "serial number" | tr '[:upper:]' '[:lower:]') \
  && pass "bob's serial appears in the exported CRL" || fail "bob's serial not found in exported CRL"

echo
echo "=== reserved 'server' name is blocked for revoke too ==="
if "${CYFERIO_BIN}" cert revoke server --force 2>/tmp/server-revoke.err; then
  fail "'cert revoke server' should have been blocked"
else
  grep -q "reserved\|managed by install" /tmp/server-revoke.err && pass "'server' revoke blocked" || fail "'server' revoke blocked but message unclear"
fi

echo
echo "ALL PHASE 3 CHECKS PASSED"

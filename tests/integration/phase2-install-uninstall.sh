#!/usr/bin/env bash
# phase2-install-uninstall.sh — Phase 2 exit-criteria check: fresh install,
# health verification, clean uninstall. Run as root on a disposable
# Ubuntu 22.04/24.04 or Debian 12 VM — this is destructive to the host.
set -Eeuo pipefail

CYFERIO_BIN="${1:-/opt/cyferio-openvpn-manager/bin/cyferio-vpn}"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

echo "=== network detect (pre-install) ==="
"${CYFERIO_BIN}" network detect --json | tee /tmp/network-detect.json
jq -e '.provider == "gcp"' /tmp/network-detect.json >/dev/null && pass "cloud provider detected as gcp" || fail "expected gcp provider"

echo
echo "=== install ==="
"${CYFERIO_BIN}" install --force

echo
echo "=== post-install verification ==="
systemctl is-active --quiet openvpn-server@server && pass "openvpn-server@server is active" || fail "openvpn service not active"

[[ -f /etc/cyferio/pki/ca.crt ]] && pass "CA certificate exists" || fail "CA certificate missing"
[[ -f /etc/cyferio/pki/issued/server.crt ]] && pass "server certificate exists" || fail "server certificate missing"
[[ -f /etc/cyferio/pki/dh.pem ]] && pass "DH params exist" || fail "DH params missing"
[[ -f /etc/cyferio/pki/ta.key ]] && pass "tls-crypt key exists" || fail "tls-crypt key missing"
[[ -f /etc/openvpn/server/crl.pem ]] && pass "CRL exported to server dir" || fail "CRL not exported"
[[ -f /etc/openvpn/server/server.conf ]] && pass "server.conf rendered" || fail "server.conf missing"
[[ -f /var/lib/cyferio/cyferio.db ]] && pass "sqlite db created" || fail "sqlite db missing"
[[ "$(stat -c '%a' /var/lib/cyferio/cyferio.db)" == "600" ]] && pass "db permissions 0600" || fail "db permissions wrong"
[[ "$(stat -c '%a' /etc/cyferio/pki)" == "700" ]] && pass "pki dir permissions 0700" || fail "pki dir permissions wrong"
[[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]] && pass "ip_forward enabled" || fail "ip_forward not enabled"
iptables -t nat -C POSTROUTING -s 10.8.0.0/24 -o "$(ip route show default | awk '/^default/{for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}')" -j MASQUERADE \
  && pass "NAT masquerade rule present" || fail "NAT masquerade rule missing"
ss -uln | grep -q ':1194 ' && pass "OpenVPN listening on udp/1194" || fail "OpenVPN not listening on udp/1194"

echo
echo "=== idempotency: re-run install ==="
"${CYFERIO_BIN}" install --force
systemctl is-active --quiet openvpn-server@server && pass "still active after re-install" || fail "not active after re-install"
[[ -f /etc/cyferio/pki/ca.crt ]] && pass "CA not regenerated (same file still present)" || fail "CA missing after re-install"

echo
echo "=== uninstall ==="
"${CYFERIO_BIN}" uninstall --force

echo
echo "=== post-uninstall verification ==="
! systemctl is-active --quiet openvpn-server@server && pass "openvpn service stopped" || fail "openvpn service still active"
[[ ! -d /etc/openvpn/server ]] && pass "server config removed" || fail "server config still present"
[[ ! -d /etc/cyferio/pki ]] && pass "PKI removed" || fail "PKI still present"
[[ ! -f /var/lib/cyferio/cyferio.db ]] && pass "database removed" || fail "database still present"
ls /var/backups/cyferio/pre-uninstall-*.tar.gz >/dev/null 2>&1 && pass "pre-uninstall backup archive exists" || fail "no backup archive found"

echo
echo "ALL PHASE 2 CHECKS PASSED"

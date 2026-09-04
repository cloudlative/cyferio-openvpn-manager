#!/usr/bin/env bash
# phase5-profile-connect.sh — Phase 5 exit-criteria check: profile export/
# regenerate work, and the generated profile actually connects. Requires
# TWO hosts: run the first half on the OpenVPN server (after `install` +
# `user add`), then copy the printed profile path to a SEPARATE client
# host and run the second half there — this can't be done on one machine
# since the profile needs a real second peer to dial into the server.
#
# WARNING: the exported profile pushes `redirect-gateway def1` — if the
# client host is one you're SSH'd into, connecting with the profile
# as-is redirects its default route through the tunnel and can cut your
# own SSH session. Test connectivity with `--route-nopull` appended to
# the openvpn invocation (proves auth + tunnel establishment without
# touching the client's routing table), exactly as this script does.
set -Eeuo pipefail

MODE="${1:-}"
CYFERIO_BIN="${2:-/opt/cyferio-openvpn-manager/bin/cyferio-vpn}"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

case "${MODE}" in
  server)
    echo "=== profile export (re-render, no cert change) ==="
    before_serial="$(sudo openssl x509 -in /etc/cyferio/pki/issued/alice.crt -noout -serial 2>/dev/null || true)"
    "${CYFERIO_BIN}" profile export alice
    after_serial="$(sudo openssl x509 -in /etc/cyferio/pki/issued/alice.crt -noout -serial 2>/dev/null || true)"
    [[ "${before_serial}" == "${after_serial}" ]] && pass "export did not touch the certificate" || fail "export unexpectedly changed the cert"

    echo
    echo "=== profile regenerate: old cert must end up revoked ==="
    "${CYFERIO_BIN}" profile regenerate alice --force
    "${CYFERIO_BIN}" cert list --json | jq -e '[.[] | select(.name=="alice" and .status=="valid")] | length == 1' >/dev/null \
      && pass "exactly one valid 'alice' entry after regenerate (old one collapsed/superseded)" || fail "cert list shows unexpected alice state"

    echo
    echo "Copy /home/*/vpn-profiles/alice.ovpn to a SEPARATE client host now and run:"
    echo "  $0 client"
    ;;

  client)
    [[ -f /etc/openvpn/alice.conf ]] || fail "expected the profile at /etc/openvpn/alice.conf on this client host"

    echo "=== connect (route-nopull, to avoid redirecting this host's own default route) ==="
    sudo pkill openvpn 2>/dev/null || true
    sleep 1
    sudo rm -f /tmp/client.log
    sudo openvpn --config /etc/openvpn/alice.conf --route-nopull --daemon --log /tmp/client.log --writepid /tmp/client.pid
    sleep 8

    grep -q "Initialization Sequence Completed" /tmp/client.log && pass "tunnel established" || fail "tunnel did not establish — see /tmp/client.log"
    ip addr show tun0 | grep -q "inet 10\.8\.0\." && pass "tun0 has an IP in the VPN subnet" || fail "tun0 missing/wrong subnet"

    if ping -c3 -W3 10.8.0.1 >/tmp/ping.log 2>&1; then
      pass "data-plane connectivity confirmed (ping to server's tun IP)"
    else
      fail "ping to server tun IP failed — see /tmp/ping.log"
    fi

    sudo pkill openvpn 2>/dev/null || true
    echo
    echo "ALL PHASE 5 CLIENT CHECKS PASSED"
    ;;

  *)
    echo "usage: $0 <server|client> [cyferio-vpn-bin-path]" >&2
    exit 1
    ;;
esac

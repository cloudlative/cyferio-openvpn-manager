#!/usr/bin/env bash
# phase4-user-lifecycle.sh — Phase 4 exit-criteria check: user creation
# produces a working VPN profile, exported to the invoking admin's own
# home directory (not root's), with DB state kept in sync with the PKI.
# Run via `sudo` as a normal (non-root) user on a disposable VM, after
# `cyferio-vpn install` — this specifically needs $SUDO_USER set, unlike
# the Phase 2/3 scripts which ran as plain root.
set -Eeuo pipefail

CYFERIO_BIN="${1:-/opt/cyferio-openvpn-manager/bin/cyferio-vpn}"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

[[ -n "${SUDO_USER:-}" ]] || fail "this script must be run via sudo as a non-root user (got SUDO_USER='${SUDO_USER:-}')"
ADMIN_HOME="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"

echo "=== user add ==="
"${CYFERIO_BIN}" user add alice | tee /tmp/user-add-alice.txt
grep -q "VPN Profile Generated Successfully" /tmp/user-add-alice.txt && pass "success banner shown" || fail "success banner missing"

EXPECTED_PROFILE="${ADMIN_HOME}/vpn-profiles/alice.ovpn"
[[ -f "${EXPECTED_PROFILE}" ]] && pass "profile written to invoking admin's home (${EXPECTED_PROFILE})" || fail "profile not found at ${EXPECTED_PROFILE}"
[[ "$(stat -c '%U' "${EXPECTED_PROFILE}")" == "${SUDO_USER}" ]] && pass "profile owned by ${SUDO_USER}, not root" || fail "profile not owned by ${SUDO_USER}"
[[ "$(stat -c '%a' "${EXPECTED_PROFILE}")" == "600" ]] && pass "profile is 0600" || fail "profile permissions wrong"

echo
echo "=== profile content sanity ==="
grep -q "^client$" "${EXPECTED_PROFILE}" && pass "profile has 'client' directive" || fail "missing 'client' directive"
grep -q "^remote " "${EXPECTED_PROFILE}" && pass "profile has 'remote' directive" || fail "missing 'remote' directive"
grep -q "^push-peer-info$" "${EXPECTED_PROFILE}" && pass "profile has push-peer-info (spec-mandated)" || fail "missing push-peer-info"
grep -q "<ca>" "${EXPECTED_PROFILE}" && pass "profile embeds <ca>" || fail "missing <ca> block"
grep -q "<cert>" "${EXPECTED_PROFILE}" && pass "profile embeds <cert>" || fail "missing <cert> block"
grep -q "<key>" "${EXPECTED_PROFILE}" && pass "profile embeds <key>" || fail "missing <key> block"
grep -q "<tls-crypt>" "${EXPECTED_PROFILE}" && pass "profile embeds <tls-crypt>" || fail "missing <tls-crypt> block"
grep -c "BEGIN CERTIFICATE" "${EXPECTED_PROFILE}" | grep -q "^2$" && pass "exactly 2 certs embedded (CA + client, no leaked easyrsa text output)" || fail "unexpected certificate count in profile"

echo
echo "=== the embedded client cert actually matches alice's issued cert ==="
issued_fp="$(openssl x509 -in /etc/cyferio/pki/issued/alice.crt -noout -fingerprint -sha256)"
embedded_fp="$(sed -n '/^<cert>$/,/^<\/cert>$/p' "${EXPECTED_PROFILE}" | sed '1d;$d' | openssl x509 -noout -fingerprint -sha256)"
[[ "${issued_fp}" == "${embedded_fp}" ]] && pass "embedded cert matches issued cert" || fail "embedded cert does not match issued cert"

echo
echo "=== user add: duplicate rejected ==="
if "${CYFERIO_BIN}" user add alice 2>/tmp/dup.err; then
  fail "duplicate user add should have failed"
else
  grep -q "already exists" /tmp/dup.err && pass "duplicate username rejected clearly" || fail "duplicate rejected but message unclear"
fi

echo
echo "=== user get ==="
"${CYFERIO_BIN}" user get alice --json | tee /tmp/user-get-alice.json
jq -e --arg p "${EXPECTED_PROFILE}" '.username=="alice" and .status=="active" and .profile_path==$p' /tmp/user-get-alice.json >/dev/null \
  && pass "user get --json fields correct" || fail "user get --json fields wrong"

echo
echo "=== user add: second user ==="
"${CYFERIO_BIN}" user add bob >/dev/null
[[ -f "${ADMIN_HOME}/vpn-profiles/bob.ovpn" ]] && pass "bob's profile created" || fail "bob's profile missing"

echo
echo "=== user list ==="
"${CYFERIO_BIN}" user list --json | tee /tmp/user-list.json
jq -e 'length == 2' /tmp/user-list.json >/dev/null && pass "user list shows both users" || fail "user list count wrong"

echo
echo "=== user disable / enable (bookkeeping only, no cert change) ==="
"${CYFERIO_BIN}" user disable alice
"${CYFERIO_BIN}" user get alice --json | jq -e '.status=="disabled"' >/dev/null && pass "alice disabled in DB" || fail "alice not marked disabled"
[[ -f /etc/cyferio/pki/issued/alice.crt ]] && pass "alice's cert untouched by disable" || fail "alice's cert unexpectedly removed"

"${CYFERIO_BIN}" user enable alice
"${CYFERIO_BIN}" user get alice --json | jq -e '.status=="active"' >/dev/null && pass "alice re-enabled in DB" || fail "alice not marked active"

echo
echo "=== user remove: revokes cert and deletes profile ==="
"${CYFERIO_BIN}" user remove bob --force
[[ ! -f "${ADMIN_HOME}/vpn-profiles/bob.ovpn" ]] && pass "bob's profile deleted" || fail "bob's profile still present"
"${CYFERIO_BIN}" cert status bob --json | jq -e '.status=="revoked"' >/dev/null && pass "bob's cert revoked" || fail "bob's cert not revoked"
[[ -z "$("${CYFERIO_BIN}" user get bob --json 2>&1 1>/dev/null)" ]] || true
if "${CYFERIO_BIN}" user get bob 2>/tmp/gone.err; then
  fail "'user get bob' should fail after removal"
else
  grep -q "no such user" /tmp/gone.err && pass "bob no longer in DB" || fail "unclear error for removed user"
fi

echo
echo "=== user remove: unknown user errors clearly ==="
if "${CYFERIO_BIN}" user remove nobody --force 2>/tmp/nouser.err; then
  fail "'user remove nobody' should have failed"
else
  grep -q "no such user" /tmp/nouser.err && pass "unknown user on remove errors clearly" || fail "unclear error"
fi

echo
echo "ALL PHASE 4 CHECKS PASSED"

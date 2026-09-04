#!/usr/bin/env bash
# phase11-backup-restore.sh — Phase 11 exit-criteria check: `backup` and
# `restore` against a real install with a real user/cert/profile, plus
# the automatic pre-uninstall backup. Run as root on a VM with `install`
# already done; DESTRUCTIVE (wipes and restores real state, then
# uninstalls at the end) — use a disposable VM only.
set -Eeuo pipefail

CYFERIO_BIN="${1:-/opt/cyferio-openvpn-manager/bin/cyferio-vpn}"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

echo "=== setup: a real user with a cert/profile/MAC ==="
"${CYFERIO_BIN}" user add alice >/dev/null
"${CYFERIO_BIN}" mac add alice "AA:BB:CC:DD:EE:01" >/dev/null

echo
echo "=== backup: produces a well-formed, verifiable archive ==="
"${CYFERIO_BIN}" backup | tee /tmp/backup-out.txt
archive="$(grep '^Archive:' /tmp/backup-out.txt | awk '{print $2}')"
[[ -n "${archive}" && -f "${archive}" ]] && pass "archive was created: ${archive}" || fail "no archive found"
[[ "$(stat -c '%a' "${archive}")" == "600" ]] && pass "archive is 0600" || fail "archive is not 0600"

extract="$(mktemp -d)"
tar -xzf "${archive}" -C "${extract}"
[[ -f "${extract}/MANIFEST.json" ]] && pass "MANIFEST.json present" || fail "MANIFEST.json missing"
[[ -f "${extract}/pki/ca.crt" ]] && pass "PKI included" || fail "PKI missing from archive"
[[ -f "${extract}/db/cyferio.db" ]] && pass "database included" || fail "database missing from archive"
[[ -f "${extract}/profiles/alice.ovpn" ]] && pass "alice's profile included" || fail "alice's profile missing from archive"
sqlite3 "${extract}/db/cyferio.db" "SELECT username FROM users WHERE username='alice';" | grep -q alice \
  && pass "backed-up database contains alice's row" || fail "backed-up database is missing alice's row"

echo
echo "=== restore: wipe real state, restore from the archive, confirm health ==="
"${CYFERIO_BIN}" user add bob >/dev/null   # state that should DISAPPEAR after restoring the pre-bob archive
"${CYFERIO_BIN}" restore "${archive}" --force | tee /tmp/restore-out.txt
grep -q "Archive integrity verified" /tmp/restore-out.txt && pass "integrity check ran and passed" || fail "integrity check did not report success"
grep -q "Restore completed" /tmp/restore-out.txt && pass "restore completed" || fail "restore did not report completion"

"${CYFERIO_BIN}" user list 2>/dev/null | grep -q alice && pass "alice present after restore" || fail "alice missing after restore"
"${CYFERIO_BIN}" user list 2>/dev/null | grep -q bob && fail "bob should not exist after restoring the pre-bob backup" || pass "bob correctly gone after restore"

[[ -n "$(find /etc/cyferio -maxdepth 1 -name 'pki.pre-restore-*' -print -quit)" ]] \
  && pass "pre-restore PKI kept, not deleted" || fail "no .pre-restore-* PKI backup found"

echo
echo "=== diagnose is healthy after restore ==="
"${CYFERIO_BIN}" diagnose | tee /tmp/diagnose-after-restore.txt
grep -q "^Overall: pass$" /tmp/diagnose-after-restore.txt && pass "diagnose reports healthy post-restore" || fail "diagnose reports issues post-restore"

echo
echo "=== restore rejects a tampered archive ==="
mkdir -p /tmp/tamper-extract
tar -xzf "${archive}" -C /tmp/tamper-extract
echo "tampered" >>/tmp/tamper-extract/pki/ca.crt
tar -czf /tmp/tampered.tar.gz -C /tmp/tamper-extract pki openvpn db profiles config MANIFEST.json
if "${CYFERIO_BIN}" restore /tmp/tampered.tar.gz 2>/tmp/tampered.err; then
  fail "tampered archive should have been rejected"
else
  grep -q "checksum mismatch" /tmp/tampered.err && pass "tampered archive rejected with a clear checksum mismatch" || fail "unclear rejection message"
fi

echo
echo "=== uninstall's automatic pre-uninstall backup ==="
"${CYFERIO_BIN}" uninstall --force | tee /tmp/uninstall-out.txt
grep -q "Backup saved to:" /tmp/uninstall-out.txt && pass "uninstall created an automatic backup" || fail "uninstall did not report a backup"
pre_uninstall_archive="$(grep 'Backup saved to:' /tmp/uninstall-out.txt | awk '{print $NF}')"
[[ -f "${pre_uninstall_archive}" ]] && pass "pre-uninstall archive actually exists: ${pre_uninstall_archive}" || fail "pre-uninstall archive file missing"

echo
echo "ALL PHASE 11 CHECKS PASSED"

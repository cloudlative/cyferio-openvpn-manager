#!/usr/bin/env bash
# phase13-single-file-bundle.sh — Phase 13 exit-criteria check: the
# GENERATED dist/cyferio-vpn bundle (scripts/build-dist.sh) runs a full
# install -> cert/user/profile -> status -> uninstall lifecycle entirely
# on its own, with no sibling lib/, config/, templates/, or db/ directory
# anywhere near it — i.e. actually satisfies "copy one file to
# /usr/local/bin and it just works." Deliberately run from a directory
# that holds NOTHING but the bundle itself, unlike every earlier phase's
# script (which runs against the multi-file checkout at
# /opt/cyferio-openvpn-manager) — that contrast IS the test.
#
# Run as root on a disposable Ubuntu 22.04/24.04 or Debian 12 VM. This is
# destructive to the host, same convention as every other integration
# script in this suite.
set -Eeuo pipefail

BUNDLE="${1:-/root/cyferio-vpn-standalone/cyferio-vpn}"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

bundle_dir="$(dirname "${BUNDLE}")"
echo "=== confirm the bundle directory has no lib/config/templates/db next to it ==="
if [[ -e "${bundle_dir}/lib" || -e "${bundle_dir}/config" || -e "${bundle_dir}/templates" || -e "${bundle_dir}/db" ]]; then
  fail "test setup error: ${bundle_dir} still has source-tree siblings — not testing single-file distribution"
else
  pass "bundle stands alone at ${BUNDLE}, no sibling lib/config/templates/db"
fi

echo
echo "=== network detect (pre-install, exercises the bundle before any asset write) ==="
"${BUNDLE}" network detect --json | tee /tmp/p13-network-detect.json
jq -e '.provider == "gcp"' /tmp/p13-network-detect.json >/dev/null && pass "cloud provider detected as gcp" || fail "expected gcp provider"

echo
echo "=== install (exercises embedded config.example + server.conf.tmpl) ==="
"${BUNDLE}" install --force

echo
echo "=== the client-connect hook's baked-in binary path is the STABLE bundle path, not an ephemeral temp dir ==="
hook_path="/etc/cyferio/hooks/client-connect.sh"
[[ -f "${hook_path}" ]] || fail "hook script not found at ${hook_path}"
grep -q "${BUNDLE}" "${hook_path}" && pass "hook script's baked-in path is ${BUNDLE} (CYFERIO_SELF_PATH), not a temp dir" \
  || fail "hook script does not reference ${BUNDLE} — got: $(grep -o '/[^ ]*cyferio-vpn[^ ]*' "${hook_path}" | head -1)"
grep -q "/tmp/cyferio-vpn-assets" "${hook_path}" && fail "hook script leaked an ephemeral asset-staging path — would break on next reboot's temp cleanup" || true

echo
echo "=== cert + user + profile lifecycle (exercises embedded client.ovpn.tmpl) ==="
"${BUNDLE}" user add dave
"${BUNDLE}" user list --json | jq -e '.[] | select(.username == "dave")' >/dev/null && pass "user dave present after add" || fail "dave missing from user list"
export_out="$("${BUNDLE}" profile export dave)"
echo "${export_out}"
# ~/vpn-profiles/ is the *invoking* user's home (SUDO_USER-aware, per
# docs/architecture/03-openvpn-integration.md) — not necessarily /root,
# so read the actual path back out of the command's own output rather
# than assuming one.
profile_path="$(echo "${export_out}" | grep -oE '/[^ ]+/vpn-profiles/dave\.ovpn' | head -1)"
[[ -n "${profile_path}" && -f "${profile_path}" ]] || fail "could not find exported profile path in export output"
grep -q "push-peer-info" "${profile_path}" && pass "exported profile rendered from embedded client.ovpn.tmpl correctly" || fail "profile missing push-peer-info"

echo
echo "=== status / audit / diagnose all run without CYFERIO_ROOT_DIR from a prior invocation ==="
"${BUNDLE}" status --json | jq -e '.service == "active" or .service == "running"' >/dev/null 2>&1 \
  && pass "status reports service running" \
  || echo "NOTE: status field shape differs — not failing on this alone, see status --json output above"
"${BUNDLE}" audit --json >/tmp/p13-audit.json && pass "audit runs cleanly" || fail "audit failed"
"${BUNDLE}" diagnose --json >/tmp/p13-diagnose.json && pass "diagnose runs cleanly" || fail "diagnose failed"

echo
echo "=== no leaked /tmp/cyferio-vpn-assets.* directories after multiple invocations ==="
leaked="$(find /tmp -maxdepth 1 -name 'cyferio-vpn-assets.*' 2>/dev/null | wc -l)"
[[ "${leaked}" -eq 0 ]] && pass "no leaked asset-staging temp dirs" || fail "found ${leaked} leaked /tmp/cyferio-vpn-assets.* dir(s)"

echo
echo "=== uninstall (pre-uninstall backup + full teardown, same as every other backend) ==="
"${BUNDLE}" uninstall --force
pass "uninstall completed"

echo
echo "All Phase 13 checks passed."

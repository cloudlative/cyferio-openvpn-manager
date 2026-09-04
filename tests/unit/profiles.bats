#!/usr/bin/env bats
# profiles.bats — lib/backends/openvpn.sh's _ovpn_validate_profile, in
# isolation from any real PKI/easyrsa (pure text validation).

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  source "${REPO_ROOT}/lib/core.sh"
  source "${REPO_ROOT}/lib/logger.sh"
  source "${REPO_ROOT}/lib/utils.sh"
  source "${REPO_ROOT}/lib/config.sh"
  CYFERIO_ROOT_DIR="${REPO_ROOT}"
  source "${REPO_ROOT}/lib/database.sh"
  source "${REPO_ROOT}/lib/backends/openvpn.sh"

  TMP_PROFILE="$(mktemp)"
}

teardown() {
  rm -f "${TMP_PROFILE}"
}

_write_valid_profile() {
  cat >"${TMP_PROFILE}" <<'EOF'
client
dev tun
proto udp
remote 203.0.113.10 1194
push-peer-info
<ca>
-----BEGIN CERTIFICATE-----
fakecadata
-----END CERTIFICATE-----
</ca>
<cert>
-----BEGIN CERTIFICATE-----
fakecertdata
-----END CERTIFICATE-----
</cert>
<key>
-----BEGIN PRIVATE KEY-----
fakekeydata
-----END PRIVATE KEY-----
</key>
<tls-crypt>
fake tls-crypt data
</tls-crypt>
EOF
}

@test "_ovpn_validate_profile accepts a well-formed profile" {
  _write_valid_profile
  run _ovpn_validate_profile "${TMP_PROFILE}"
  [ "$status" -eq 0 ]
}

# --- Phase 9: ovpn_status_clients ----------------------------------------
# Parses OpenVPN's status-version 2 file — see config/server.conf.tmpl's
# `status-version 2` directive and the comment on ovpn_status_clients
# itself for why version 2 specifically (the unset default, version 1,
# has no CLIENT_LIST-prefixed lines at all).

@test "ovpn_status_clients returns nothing when the status file doesn't exist" {
  CYFERIO_LOG_DIR="$(mktemp -d)"
  run ovpn_status_clients
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ovpn_status_clients parses CLIENT_LIST lines from a real status-version 2 file" {
  CYFERIO_LOG_DIR="$(mktemp -d)"
  cat >"${CYFERIO_LOG_DIR}/openvpn-status.log" <<'EOF'
TITLE,OpenVPN 2.5.11 x86_64-pc-linux-gnu
TIME,Fri Sep  4 12:00:00 2026,1757000000
HEADER,CLIENT_LIST,Common Name,Real Address,Virtual Address,Virtual IPv6 Address,Bytes Received,Bytes Sent,Connected Since,Connected Since (time_t),Username,Client ID,Peer ID,Data Channel Cipher
CLIENT_LIST,alice,34.82.9.157:52341,10.8.0.2,,5000,4000,Fri Sep  4 12:00:05 2026,1757000005,alice,0,0,AES-256-GCM
CLIENT_LIST,bob,34.82.9.158:41111,10.8.0.3,,100,200,Fri Sep  4 12:01:00 2026,1757000060,bob,1,1,AES-256-GCM
HEADER,ROUTING_TABLE,Virtual Address,Common Name,Real Address,Last Ref,Last Ref (time_t)
ROUTING_TABLE,10.8.0.2,alice,34.82.9.157:52341,Fri Sep  4 12:00:05 2026,1757000005
GLOBAL_STATS,Max bcast/mcast queue length,0
END
EOF
  run ovpn_status_clients
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "alice|34.82.9.157:52341|10.8.0.2|5000|4000|Fri Sep  4 12:00:05 2026" ]]
  [[ "${lines[1]}" == "bob|34.82.9.158:41111|10.8.0.3|100|200|Fri Sep  4 12:01:00 2026" ]]
}

@test "ovpn_status_clients returns nothing for a version 1 (unprefixed) status file" {
  CYFERIO_LOG_DIR="$(mktemp -d)"
  cat >"${CYFERIO_LOG_DIR}/openvpn-status.log" <<'EOF'
OpenVPN CLIENT LIST
Updated,Fri Sep  4 12:00:00 2026
Common Name,Real Address,Bytes Received,Bytes Sent,Connected Since
alice,34.82.9.157:52341,5000,4000,Fri Sep  4 12:00:05 2026
ROUTING TABLE
GLOBAL STATS
END
EOF
  run ovpn_status_clients
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_ovpn_validate_profile rejects a missing 'client' directive" {
  _write_valid_profile
  sed -i '/^client$/d' "${TMP_PROFILE}"
  run _ovpn_validate_profile "${TMP_PROFILE}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing 'client' directive"* ]]
}

@test "_ovpn_validate_profile rejects a missing 'remote' directive" {
  _write_valid_profile
  sed -i '/^remote /d' "${TMP_PROFILE}"
  run _ovpn_validate_profile "${TMP_PROFILE}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing 'remote' directive"* ]]
}

@test "_ovpn_validate_profile rejects missing push-peer-info" {
  _write_valid_profile
  sed -i '/^push-peer-info$/d' "${TMP_PROFILE}"
  run _ovpn_validate_profile "${TMP_PROFILE}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing push-peer-info"* ]]
}

@test "_ovpn_validate_profile rejects an empty <key> block" {
  _write_valid_profile
  # Replace the <key>...</key> block with an empty one, simulating a
  # truncated/missing private key file being cat'd in.
  sed -i '/^<key>$/,/^<\/key>$/{//!d}' "${TMP_PROFILE}"
  run _ovpn_validate_profile "${TMP_PROFILE}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"<key> block is empty"* ]]
}

@test "_ovpn_validate_profile rejects a missing <tls-crypt> block entirely" {
  _write_valid_profile
  sed -i '/^<tls-crypt>$/,/^<\/tls-crypt>$/d' "${TMP_PROFILE}"
  run _ovpn_validate_profile "${TMP_PROFILE}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing <tls-crypt> block"* ]]
}

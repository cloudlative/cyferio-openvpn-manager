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

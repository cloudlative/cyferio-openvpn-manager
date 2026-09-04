#!/usr/bin/env bats
# diagnostics.bats — lib/diagnostics.sh, with systemctl/ss/iptables and
# the backend/config lookups stubbed out (pure decision logic; real
# service/port/NAT state is exercised in tests/integration/phase10-*).

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  source "${REPO_ROOT}/lib/core.sh"
  source "${REPO_ROOT}/lib/logger.sh"
  source "${REPO_ROOT}/lib/utils.sh"
  source "${REPO_ROOT}/lib/config.sh"
  source "${REPO_ROOT}/lib/network.sh"
  source "${REPO_ROOT}/lib/diagnostics.sh"

  require_root() { :; }
  systemctl() { [[ "$1" == "is-active" ]] && return 0; }
  ss() { :; }
  iptables() { :; }
  is_command_available() { return 0; }
  ovpn_pki_dir() { echo "/tmp/does-not-matter-pki"; }
  ovpn_hooks_dir() { echo "${TMP_HOOKS}"; }
  OVPN_CRL_PATH="/tmp/does-not-matter-pki/crl.pem"
  OVPN_SYSTEMD_UNIT="openvpn-server@server"
  db_schema_version() { echo 1; }

  TMP_HOOKS="$(mktemp -d)"
  : >"${TMP_HOOKS}/client-connect.sh"; chmod +x "${TMP_HOOKS}/client-connect.sh"
  : >"${TMP_HOOKS}/client-disconnect.sh"; chmod +x "${TMP_HOOKS}/client-disconnect.sh"
}

teardown() {
  rm -rf "${TMP_HOOKS}"
}

@test "_diag_check_service passes when systemctl reports active" {
  _diag_check_service
  [[ "${NETWORK_CHECKS[0]}" == *"pass"* ]]
}

@test "_diag_check_service fails when systemctl reports inactive" {
  systemctl() { return 1; }
  _diag_check_service
  [[ "${NETWORK_CHECKS[0]}" == *"fail"* ]]
}

@test "_diag_check_database passes when a schema version is recorded" {
  _diag_check_database
  [[ "${NETWORK_CHECKS[0]}" == *"pass"* ]]
}

@test "_diag_check_database fails when no migrations are recorded" {
  db_schema_version() { :; }
  _diag_check_database
  [[ "${NETWORK_CHECKS[0]}" == *"fail"* ]]
}

@test "_diag_check_hooks_present passes when both hooks exist and are executable" {
  _diag_check_hooks_present
  [[ "${NETWORK_CHECKS[0]}" == *"pass"* ]]
}

@test "_diag_check_hooks_present fails when a hook is missing" {
  rm -f "${TMP_HOOKS}/client-disconnect.sh"
  _diag_check_hooks_present
  [[ "${NETWORK_CHECKS[0]}" == *"fail"* ]]
}

@test "_diag_check_pki_files fails and lists what's missing" {
  _diag_check_pki_files
  [[ "${NETWORK_CHECKS[0]}" == *"fail"* ]]
  [[ "${NETWORK_CHECKS[0]}" == *"ca.crt"* ]]
}

@test "cmd_diagnose --json emits an array with name/status for every check" {
  run cmd_diagnose --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'type == "array" and length > 5 and all(.[]; has("name") and has("status"))' >/dev/null
}

@test "cmd_diagnose (table) prints an Overall: line" {
  run cmd_diagnose
  [ "$status" -eq 0 ]
  [[ "$output" == *"Overall:"* ]]
}

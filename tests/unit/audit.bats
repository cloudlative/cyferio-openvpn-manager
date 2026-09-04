#!/usr/bin/env bats
# audit.bats — lib/audit.sh, with real files/dirs under a scratch temp
# tree for the permission checks (stat needs a real path) and stubbed
# DB/PKI-list functions for the consistency checks.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  source "${REPO_ROOT}/lib/core.sh"
  source "${REPO_ROOT}/lib/logger.sh"
  source "${REPO_ROOT}/lib/utils.sh"
  source "${REPO_ROOT}/lib/config.sh"
  source "${REPO_ROOT}/lib/network.sh"
  source "${REPO_ROOT}/lib/audit.sh"

  require_root() { :; }
  db_path() { echo "${TMP_ROOT}/cyferio.db"; }
  ovpn_pki_dir() { echo "${TMP_ROOT}/pki"; }
  ovpn_hooks_dir() { echo "${TMP_ROOT}/hooks"; }
  db_user_get() { :; }
  db_user_list() { :; }
  vpn_backend_list_clients() { :; }
  current_actor() { echo tester; }

  TMP_ROOT="$(mktemp -d)"
  CYFERIO_DATA_DIR="${TMP_ROOT}/data"
  CYFERIO_LOG_DIR="${TMP_ROOT}/log"
  CYFERIO_CONF_DIR="${TMP_ROOT}/conf"

  mkdir -p "${TMP_ROOT}/pki/private" "${TMP_ROOT}/hooks" "${CYFERIO_DATA_DIR}" "${CYFERIO_LOG_DIR}" "${CYFERIO_CONF_DIR}"
  chmod 700 "${TMP_ROOT}/pki" "${TMP_ROOT}/pki/private"
  : >"${TMP_ROOT}/pki/private/ca.key"; chmod 600 "${TMP_ROOT}/pki/private/ca.key"
  : >"${TMP_ROOT}/cyferio.db"; chmod 660 "${TMP_ROOT}/cyferio.db"; chgrp "$(id -gn)" "${TMP_ROOT}/cyferio.db" 2>/dev/null || true
  chmod 770 "${CYFERIO_DATA_DIR}"; chgrp "$(id -gn)" "${CYFERIO_DATA_DIR}" 2>/dev/null || true
  : >"${TMP_ROOT}/hooks/client-connect.sh"; chmod 755 "${TMP_ROOT}/hooks/client-connect.sh"
  : >"${TMP_ROOT}/hooks/client-disconnect.sh"; chmod 755 "${TMP_ROOT}/hooks/client-disconnect.sh"
  chmod 770 "${CYFERIO_LOG_DIR}"; chgrp "$(id -gn)" "${CYFERIO_LOG_DIR}" 2>/dev/null || true
  : >"${CYFERIO_LOG_DIR}/cyferio.log"; chmod 660 "${CYFERIO_LOG_DIR}/cyferio.log"; chgrp "$(id -gn)" "${CYFERIO_LOG_DIR}/cyferio.log" 2>/dev/null || true
  : >"${CYFERIO_CONF_DIR}/cyferio.conf"; chmod 644 "${CYFERIO_CONF_DIR}/cyferio.conf"

  # Everything above is owned by the test-runner user, not literally
  # "root" — override the expected-owner checks so a non-root CI runner
  # still exercises the mode-comparison logic cleanly. _audit_check_perm
  # is called with owner="root" throughout audit_run, so instead we test
  # _audit_check_perm directly against our own user in the unit tests
  # below rather than calling the full audit_run/cmd_audit (which would
  # spuriously fail owner checks under a non-root test runner).
}

teardown() {
  rm -rf "${TMP_ROOT}"
}

@test "_audit_check_perm passes when mode/owner/group all match" {
  local me mygroup
  me="$(id -un)"
  mygroup="$(id -gn)"
  _audit_check_perm "Test Path" "${TMP_ROOT}/cyferio.db" 660 "${me}" "${mygroup}"
  [[ "${NETWORK_CHECKS[0]}" == *"pass"* ]]
}

@test "_audit_check_perm fails and reports the mismatch when mode is wrong" {
  chmod 777 "${TMP_ROOT}/cyferio.db"
  _audit_check_perm "Test Path" "${TMP_ROOT}/cyferio.db" 660 "$(id -un)" "$(id -gn)"
  [[ "${NETWORK_CHECKS[0]}" == *"fail"* ]]
  [[ "${NETWORK_CHECKS[0]}" == *"mode is 777, expected 660"* ]]
}

@test "_audit_check_perm warns (not fails) when the path doesn't exist" {
  _audit_check_perm "Missing Path" "${TMP_ROOT}/nope" 600
  [[ "${NETWORK_CHECKS[0]}" == *"warning"* ]]
  [[ "${NETWORK_CHECKS[0]}" == *"does not exist"* ]]
}

@test "_audit_check_reserved_name fails when a 'server' user row exists" {
  db_user_get() { [[ "$1" == "server" ]] && echo "1|server|active||x|x"; }
  _audit_check_reserved_name
  [[ "${NETWORK_CHECKS[0]}" == *"fail"* ]]
}

@test "_audit_check_reserved_name passes when no 'server' user row exists" {
  db_user_get() { :; }
  _audit_check_reserved_name
  [[ "${NETWORK_CHECKS[0]}" == *"pass"* ]]
}

@test "_audit_check_user_cert_consistency passes when every active user has a valid cert" {
  db_user_list() { printf '1|alice|active||x|x\n'; }
  vpn_backend_list_clients() { printf 'V|exp|revoked|serial|alice\n'; }
  _audit_check_user_cert_consistency
  [[ "${NETWORK_CHECKS[0]}" == *"pass"* ]]
}

@test "_audit_check_user_cert_consistency warns when an active user has no valid cert" {
  db_user_list() { printf '1|alice|active||x|x\n'; }
  vpn_backend_list_clients() { printf 'R|exp|revoked|serial|alice\n'; }
  _audit_check_user_cert_consistency
  [[ "${NETWORK_CHECKS[0]}" == *"warning"* ]]
  [[ "${NETWORK_CHECKS[0]}" == *"1 active user"* ]]
}

@test "_audit_check_user_cert_consistency ignores disabled users with no valid cert" {
  db_user_list() { printf '1|alice|disabled||x|x\n'; }
  vpn_backend_list_clients() { printf 'R|exp|revoked|serial|alice\n'; }
  _audit_check_user_cert_consistency
  [[ "${NETWORK_CHECKS[0]}" == *"pass"* ]]
}

@test "_audit_check_mac_enforcement_mode passes for strict, warns for permissive" {
  CYFERIO_CFG[mac_enforcement_mode]=strict
  _audit_check_mac_enforcement_mode
  [[ "${NETWORK_CHECKS[0]}" == *"pass"* ]]

  check_reset
  CYFERIO_CFG[mac_enforcement_mode]=permissive
  _audit_check_mac_enforcement_mode
  [[ "${NETWORK_CHECKS[0]}" == *"warning"* ]]
}

@test "cmd_audit --json emits an array with name/status for every check" {
  run cmd_audit --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'type == "array" and length > 5 and all(.[]; has("name") and has("status"))' >/dev/null
}

@test "cmd_audit (table) prints an Overall: line" {
  run cmd_audit
  [ "$status" -eq 0 ]
  [[ "$output" == *"Overall:"* ]]
}

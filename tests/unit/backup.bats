#!/usr/bin/env bats
# backup.bats — lib/backup.sh's backup_run/cmd_backup/cmd_restore, against
# real scratch dirs (mktemp-based, never touches /etc or /var on the CI
# runner) with database.sh's sqlite calls stubbed out where a real DB
# isn't needed for the behavior under test.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  source "${REPO_ROOT}/lib/core.sh"
  source "${REPO_ROOT}/lib/logger.sh"
  source "${REPO_ROOT}/lib/utils.sh"
  source "${REPO_ROOT}/lib/config.sh"
  source "${REPO_ROOT}/lib/network.sh"
  source "${REPO_ROOT}/lib/diagnostics.sh"
  source "${REPO_ROOT}/lib/backup.sh"

  require_root() { :; }
  confirm() { return 0; }
  log_info() { :; }
  systemctl() { return 0; }
  ss() { :; }
  iptables() { :; }
  is_command_available() { return 0; }
  OVPN_SYSTEMD_UNIT="openvpn-server@server"
  db_schema_version() { echo 1; }

  TMP_ROOT="$(mktemp -d)"
  CYFERIO_BACKUP_DIR="${TMP_ROOT}/backups"
  CYFERIO_CONF_DIR="${TMP_ROOT}/conf"
  CYFERIO_DATA_DIR="${TMP_ROOT}/data"
  OVPN_SERVER_DIR="${TMP_ROOT}/openvpn-server"
  OVPN_CRL_PATH="${TMP_ROOT}/pki/crl.pem"

  ovpn_pki_dir() { echo "${TMP_ROOT}/pki"; }
  ovpn_hooks_dir() { echo "${TMP_ROOT}/hooks"; }
  db_path() { echo "${CYFERIO_DATA_DIR}/cyferio.db"; }
  db_ensure_dir() { mkdir -p "${CYFERIO_DATA_DIR}"; }
  db_grant_group_access() { :; }
  db_user_list() { :; }

  # Real, small PKI + server config + config fixtures so tar/sha256 have
  # actual files to work with — no stub for that part, it's cheap and
  # exercises the real archive-building path.
  mkdir -p "${TMP_ROOT}/pki/private" "${OVPN_SERVER_DIR}" "${CYFERIO_CONF_DIR}"
  echo "fake-ca-cert" >"${TMP_ROOT}/pki/ca.crt"
  echo "fake-ca-key" >"${TMP_ROOT}/pki/private/ca.key"
  echo "server-conf" >"${OVPN_SERVER_DIR}/server.conf"
  echo "vpn_port=1194" >"${CYFERIO_CONF_DIR}/cyferio.conf"
}

teardown() {
  rm -rf "${TMP_ROOT}"
}

@test "backup_run returns nothing (not an error) when there is genuinely nothing installed" {
  rm -rf "${TMP_ROOT}/pki" "${OVPN_SERVER_DIR}" "${CYFERIO_CONF_DIR}/cyferio.conf"
  run backup_run backup
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "backup_run produces a 0600 archive containing MANIFEST.json and the real files" {
  run backup_run backup
  [ "$status" -eq 0 ]
  [ -f "$output" ]
  [[ "$(stat -c '%a' "$output")" == "600" ]]

  local extract
  extract="$(mktemp -d)"
  tar -xzf "$output" -C "${extract}"
  [ -f "${extract}/MANIFEST.json" ]
  [ -f "${extract}/pki/ca.crt" ]
  [ -f "${extract}/openvpn/server.conf" ]
  [ -f "${extract}/config/cyferio.conf" ]
  jq -e '.files | length > 0' "${extract}/MANIFEST.json" >/dev/null
  rm -rf "${extract}"
}

@test "backup_run's MANIFEST checksums actually match the archived files" {
  run backup_run backup
  [ "$status" -eq 0 ]
  local extract
  extract="$(mktemp -d)"
  tar -xzf "$output" -C "${extract}"
  local rel sha actual
  while IFS=$'\t' read -r rel sha; do
    actual="$(sha256sum "${extract}/${rel}" | awk '{print $1}')"
    [ "${actual}" == "${sha}" ]
  done < <(jq -r '.files[] | [.path, .sha256] | @tsv' "${extract}/MANIFEST.json")
  rm -rf "${extract}"
}

@test "cmd_backup reports 'nothing to back up' cleanly when nothing is installed" {
  rm -rf "${TMP_ROOT}/pki" "${OVPN_SERVER_DIR}" "${CYFERIO_CONF_DIR}/cyferio.conf"
  run cmd_backup
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to back up"* ]]
}

@test "cmd_backup prints the archive path on success" {
  run cmd_backup
  [ "$status" -eq 0 ]
  [[ "$output" == *"Archive:"*".tar.gz"* ]]
}

@test "_restore_validate_archive_paths rejects an absolute path in the archive" {
  local evil_file archive
  evil_file="$(mktemp)"
  echo x >"${evil_file}"
  archive="${TMP_ROOT}/evil.tar.gz"
  # -P (--absolute-names): keep the member name exactly as given (an
  # absolute path), instead of tar's default of stripping the leading
  # '/' — this is what a crafted/corrupted archive trying to write
  # outside the extraction temp dir would look like.
  tar -czf "${archive}" -P "${evil_file}"
  run _restore_validate_archive_paths "${archive}"
  [ "$status" -ne 0 ]
  rm -f "${evil_file}"
}

@test "_restore_validate_archive_paths rejects a '..' path segment" {
  local staging archive
  staging="$(mktemp -d)"
  echo x >"${staging}/evil"
  archive="${TMP_ROOT}/traversal.tar.gz"
  # --transform injects a literal "../" prefix onto the member name
  # deterministically, regardless of how tar would otherwise normalize
  # a path given as-is.
  tar -czf "${archive}" --transform 's,^,../,' -C "${staging}" evil
  run _restore_validate_archive_paths "${archive}"
  [ "$status" -ne 0 ]
  rm -rf "${staging}"
}

@test "_restore_validate_archive_paths accepts a normal archive" {
  run _restore_validate_archive_paths "${TMP_ROOT}/does-not-exist-yet.tar.gz"
  # An unreadable/missing archive yields no tar -t output at all, so the
  # loop never finds anything unsafe — accepted here; extraction itself
  # (a separate step in cmd_restore) is what actually fails on a bad path.
  [ "$status" -eq 0 ]

  backup_run backup >"${TMP_ROOT}/good-archive-path.txt"
  run _restore_validate_archive_paths "$(cat "${TMP_ROOT}/good-archive-path.txt")"
  [ "$status" -eq 0 ]
}

@test "cmd_restore refuses a bare, non-archive path" {
  run cmd_restore "${TMP_ROOT}/nope.tar.gz"
  [ "$status" -ne 0 ]
  [[ "$output" == *"archive not found"* ]]
}

@test "cmd_restore refuses an archive with no MANIFEST.json" {
  local bad_archive
  bad_archive="${TMP_ROOT}/no-manifest.tar.gz"
  tar -czf "${bad_archive}" -C "${TMP_ROOT}" pki
  run cmd_restore "${bad_archive}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing MANIFEST.json"* ]]
}

@test "cmd_restore refuses an archive whose contents were tampered with after the manifest was written" {
  local archive extract
  archive="$(backup_run backup)"
  extract="$(mktemp -d)"
  tar -xzf "${archive}" -C "${extract}"
  echo "tampered" >>"${extract}/pki/ca.crt"
  local tampered="${TMP_ROOT}/tampered.tar.gz"
  tar -czf "${tampered}" -C "${extract}" pki openvpn db profiles config MANIFEST.json
  run cmd_restore "${tampered}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"checksum mismatch"* ]]
  [[ "$output" == *"integrity verification"* ]]
  rm -rf "${extract}"
}

@test "cmd_restore performs a full round trip: pki/openvpn/config restored, existing state kept as .pre-restore" {
  local archive
  archive="$(backup_run backup)"

  # Simulate a DIFFERENT current state that restore should replace.
  echo "different-ca" >"${TMP_ROOT}/pki/ca.crt"

  run cmd_restore "${archive}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Restore completed"* ]]

  [ "$(cat "${TMP_ROOT}/pki/ca.crt")" == "fake-ca-cert" ]
  [ -n "$(find "${TMP_ROOT}" -maxdepth 1 -name 'pki.pre-restore-*' -print -quit)" ]
}

@test "cmd_restore --force skips the confirmation prompt" {
  confirm() { return 1; }  # simulate a declined/non-tty prompt
  local archive
  archive="$(backup_run backup)"
  run cmd_restore "${archive}" --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"Restore completed"* ]]
}

@test "cmd_restore aborts cleanly when the confirmation prompt is declined" {
  confirm() { return 1; }
  local archive
  archive="$(backup_run backup)"
  run cmd_restore "${archive}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Aborted."* ]]
}

#!/usr/bin/env bash
# backup.sh — `cyferio-vpn backup` / `cyferio-vpn restore <archive>`
# (Phase 11), per docs/architecture/08-backup-restore.md. Also backs
# `cyferio-vpn uninstall`'s spec-mandated automatic pre-uninstall backup
# (lib/install.sh's cmd_uninstall) — one backup implementation, not two.

if [[ -n "${__CYFERIO_BACKUP_LOADED:-}" ]]; then
  return 0
fi
__CYFERIO_BACKUP_LOADED=1

CYFERIO_BACKUP_DIR="/var/backups/cyferio"

_backup_sha256() {
  sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

# _backup_write_manifest STAGING_DIR — sha256 every file already staged
# (MANIFEST.json itself doesn't exist yet at this point, so it can't
# accidentally hash itself), per the archive layout in 08-backup-
# restore.md.
_backup_write_manifest() {
  local staging="$1"
  local hostname_val ts
  hostname_val="$(hostname 2>/dev/null || echo unknown)"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local files_json="[]" f rel sha
  while IFS= read -r -d '' f; do
    rel="${f#"${staging}"/}"
    sha="$(_backup_sha256 "${f}")"
    files_json="$(jq -c --arg path "${rel}" --arg sha256 "${sha}" '. + [{path: $path, sha256: $sha256}]' <<<"${files_json}")"
  done < <(find "${staging}" -type f -print0 | sort -z)

  jq -n \
    --arg version "${CYFERIO_VERSION}" --arg timestamp "${ts}" --arg hostname "${hostname_val}" \
    --argjson files "${files_json}" \
    '{tool_version: $version, timestamp: $timestamp, hostname: $hostname, files: $files}' \
    >"${staging}/MANIFEST.json"
}

# backup_run [LABEL] — builds the archive described in 08-backup-
# restore.md and echoes its path on success. Deliberately never die()s:
# every caller invokes it via command substitution
# (`archive="$(backup_run ...)"`), and exit-inside-a-subshell doesn't
# reliably abort the caller (see lib/macs.sh's _mac_get_user_id for the
# fuller explanation) — failures instead print to stderr and `return 1`,
# which every call site below checks explicitly with `|| die ...`.
# Returns 0 with empty stdout (not an error) when there is genuinely
# nothing installed yet to back up.
backup_run() {
  local label="${1:-backup}"
  mkdir -p "${CYFERIO_BACKUP_DIR}"
  chmod 0700 "${CYFERIO_BACKUP_DIR}"

  local pki_dir
  pki_dir="$(ovpn_pki_dir)"

  local has_anything=0
  [[ -d "${pki_dir}" ]] && has_anything=1
  [[ -d "${OVPN_SERVER_DIR}" ]] && has_anything=1
  [[ -f "$(db_path)" ]] && has_anything=1
  [[ -f "${CYFERIO_CONF_DIR}/cyferio.conf" ]] && has_anything=1

  if [[ "${has_anything}" -eq 0 ]]; then
    return 0
  fi

  local staging ts archive
  staging="$(mktemp -d)"
  ts="$(date -u +%Y%m%d-%H%M%S)"
  archive="${CYFERIO_BACKUP_DIR}/cyferio-${label}-${ts}.tar.gz"

  mkdir -p "${staging}/pki" "${staging}/openvpn" "${staging}/db" "${staging}/profiles" "${staging}/config"

  if [[ -d "${pki_dir}" ]]; then
    cp -a "${pki_dir}/." "${staging}/pki/" 2>/dev/null || true
  fi
  if [[ -d "${OVPN_SERVER_DIR}" ]]; then
    # The whole directory, not just *.conf — it also holds crl.pem
    # (exported outside the 0700 PKI dir so the privilege-dropped daemon
    # can re-read it, see ovpn_export_crl). A *.conf-only filter here
    # silently dropped crl.pem from every backup: found via a real
    # restore on a VM where the restored server then failed to start at
    # all (crl-verify in server.conf pointing at a file that no longer
    # existed) — 'PKI Files Present' and 'OpenVPN Service'/'Listening'
    # all failed as a direct consequence of this one missing file.
    cp -a "${OVPN_SERVER_DIR}/." "${staging}/openvpn/" 2>/dev/null || true
  fi
  if [[ -f "${CYFERIO_CONF_DIR}/cyferio.conf" ]]; then
    cp -a "${CYFERIO_CONF_DIR}/cyferio.conf" "${staging}/config/" 2>/dev/null || true
  fi

  if [[ -f "$(db_path)" ]]; then
    if ! sqlite3 "$(db_path)" ".backup '${staging}/db/cyferio.db'" 2>/dev/null; then
      echo "backup: sqlite3 .backup failed for $(db_path)" >&2
      rm -rf "${staging}"
      return 1
    fi
  fi

  # profiles/ — every admin's exported .ovpn the DB has a record of
  # (users.profile_path), flattened to just its basename: usernames are
  # globally unique in this DB, so basenames can't collide.
  local rows profile_path _id _uname _status _created _updated
  rows="$(db_user_list 2>/dev/null || true)"
  if [[ -n "${rows}" ]]; then
    while IFS='|' read -r _id _uname _status profile_path _created _updated; do
      if [[ -n "${profile_path}" && -f "${profile_path}" ]]; then
        cp -a "${profile_path}" "${staging}/profiles/$(basename "${profile_path}")" 2>/dev/null || true
      fi
    done <<<"${rows}"
  fi

  _backup_write_manifest "${staging}"

  if ! tar -czf "${archive}" -C "${staging}" pki openvpn db profiles config MANIFEST.json 2>/dev/null; then
    echo "backup: failed to create archive at ${archive}" >&2
    rm -rf "${staging}"
    return 1
  fi
  rm -rf "${staging}"
  chmod 0600 "${archive}"
  log_info "backup" "result=success" "archive=${archive}" "label=${label}"
  echo "${archive}"
}

# cmd_backup
cmd_backup() {
  require_root
  local archive
  archive="$(backup_run backup)" || die "backup failed — see the message above" 3

  if [[ -z "${archive}" ]]; then
    ui_warn "Nothing to back up — has 'cyferio-vpn install' been run yet?"
    return 0
  fi

  ui_ok "Backup created."
  echo
  echo "Archive: ${archive}"
}

# _restore_validate_archive_paths ARCHIVE — refuses to extract an archive
# containing an absolute path or a '..' path segment, BEFORE anything is
# written to disk — the path-traversal guard 09-security-review.md
# promises for restore. MANIFEST checksum verification (right after
# extraction) catches tampered/extra file CONTENT; this catches a
# malicious/corrupted archive trying to write OUTSIDE the extraction
# temp dir in the first place.
_restore_validate_archive_paths() {
  local archive="$1" entry
  while IFS= read -r entry; do
    if [[ "${entry}" == /* || "${entry}" == *".."* ]]; then
      return 1
    fi
  done < <(tar -tzf "${archive}" 2>/dev/null)
  return 0
}

# cmd_restore ARCHIVE [--force] — see docs/architecture/08-backup-
# restore.md for the full restore procedure this implements: verify →
# confirm → stop service → move existing state aside (.pre-restore-TS
# suffix, never deleted) → restore pki/openvpn/config/db in place →
# restart → re-run Phase 10's diagnose to confirm the restored
# deployment is healthy. --force skips the confirmation prompt, same
# convention as install/uninstall/profile regenerate — needed for
# scripted/CI use since confirm() always answers "no" on a non-tty
# stdin regardless of what's piped into it (utils.sh's own documented
# "never assume consent when input can't actually be read" behavior).
cmd_restore() {
  local archive="${1:-}"
  shift || true
  local force=0
  for arg in "$@"; do
    [[ "${arg}" == "--force" ]] && force=1
  done
  [[ -n "${archive}" ]] || die "usage: cyferio-vpn restore ARCHIVE [--force]" 1
  [[ -f "${archive}" ]] || die "archive not found: ${archive}" 1
  require_root

  _restore_validate_archive_paths "${archive}" \
    || die "archive contains an absolute or '..' path — refusing to extract a potentially unsafe archive" 1

  local staging
  staging="$(mktemp -d)"
  tar -xzf "${archive}" -C "${staging}" || { rm -rf "${staging}"; die "failed to extract archive" 3; }

  if [[ ! -f "${staging}/MANIFEST.json" ]]; then
    rm -rf "${staging}"
    die "archive is missing MANIFEST.json — not a valid Cyferio backup" 1
  fi

  echo "Verifying archive integrity..."
  local bad=0 rel sha actual
  while IFS=$'\t' read -r rel sha; do
    actual="$(_backup_sha256 "${staging}/${rel}")"
    if [[ "${actual}" != "${sha}" ]]; then
      echo "  checksum mismatch: ${rel}" >&2
      bad=1
    fi
  done < <(jq -r '.files[] | [.path, .sha256] | @tsv' "${staging}/MANIFEST.json")

  if [[ "${bad}" -ne 0 ]]; then
    rm -rf "${staging}"
    die "archive failed integrity verification — aborting restore (nothing was touched)" 1
  fi
  ui_ok "Archive integrity verified."

  if [[ "${force}" -ne 1 ]] && ! confirm "Restore from this archive? The current PKI, server config, and database will be replaced (existing state saved with a .pre-restore suffix, not deleted)."; then
    rm -rf "${staging}"
    echo "Aborted."
    exit 1
  fi

  echo "Stopping OpenVPN service..."
  systemctl stop "${OVPN_SYSTEMD_UNIT}" 2>/dev/null || true

  local ts pki_dir
  ts="$(date -u +%Y%m%d%H%M%S)"
  pki_dir="$(ovpn_pki_dir)"

  if [[ -d "${pki_dir}" ]]; then
    mv "${pki_dir}" "${pki_dir}.pre-restore-${ts}"
  fi
  mkdir -p "${pki_dir}"
  cp -a "${staging}/pki/." "${pki_dir}/" 2>/dev/null || true
  chmod 0700 "${pki_dir}"
  [[ -d "${pki_dir}/private" ]] && chmod 0700 "${pki_dir}/private"

  if [[ -d "${OVPN_SERVER_DIR}" ]]; then
    mv "${OVPN_SERVER_DIR}" "${OVPN_SERVER_DIR}.pre-restore-${ts}"
  fi
  mkdir -p "${OVPN_SERVER_DIR}"
  cp -a "${staging}/openvpn/." "${OVPN_SERVER_DIR}/" 2>/dev/null || true

  if [[ -f "${CYFERIO_CONF_DIR}/cyferio.conf" ]]; then
    mv "${CYFERIO_CONF_DIR}/cyferio.conf" "${CYFERIO_CONF_DIR}/cyferio.conf.pre-restore-${ts}"
  fi
  mkdir -p "${CYFERIO_CONF_DIR}"
  if [[ -f "${staging}/config/cyferio.conf" ]]; then
    cp -a "${staging}/config/cyferio.conf" "${CYFERIO_CONF_DIR}/cyferio.conf"
  fi

  if [[ -f "${staging}/db/cyferio.db" ]]; then
    echo "Restoring database..."
    if [[ -f "$(db_path)" ]]; then
      mv "$(db_path)" "$(db_path).pre-restore-${ts}"
    fi
    db_ensure_dir
    sqlite3 "$(db_path)" ".restore '${staging}/db/cyferio.db'" || die "failed to restore database (pre-restore copy kept at $(db_path).pre-restore-${ts})" 3
    chmod 0660 "$(db_path)"
  fi

  db_grant_group_access nogroup
  rm -rf "${staging}"

  echo "Starting OpenVPN service..."
  systemctl start "${OVPN_SYSTEMD_UNIT}" 2>/dev/null || true
  sleep 1

  echo
  echo "Running post-restore diagnostics..."
  diagnose_run
  checks_print_table
  local overall
  overall="$(checks_overall)"

  echo
  if [[ "${overall}" == "fail" ]]; then
    ui_warn "Restore completed, but 'cyferio-vpn diagnose' reports issues — review the output above."
  else
    ui_ok "Restore completed successfully."
  fi
  log_info "restore" "result=success" "archive=${archive}" "overall=${overall}"
}

#!/usr/bin/env bash
# audit.sh — `cyferio-vpn audit [--json]` (Phase 10). Security/config
# posture checks against docs/architecture/09-security-review.md's
# threat model: file permissions/ownership on PKI, DB, hooks, logs, and
# config, plus a couple of DB/PKI consistency checks. Read-only — never
# chmod/chown's anything itself, only reports drift (that's what
# `install`, re-run, already does).
#
# Reuses lib/network.sh's shared checks accumulator (check_add,
# checks_print_table/_json, checks_overall) — the same data model
# `install`'s pre-flight banner and `network detect` already use, per
# that file's own header comment anticipating this.

if [[ -n "${__CYFERIO_AUDIT_LOADED:-}" ]]; then
  return 0
fi
__CYFERIO_AUDIT_LOADED=1

# _audit_check_perm NAME PATH EXPECTED_MODE [EXPECTED_OWNER] [EXPECTED_GROUP]
# — a missing path is a warning (not installed yet, or already
# uninstalled — not necessarily a security problem), a mode/owner/group
# mismatch is a fail.
_audit_check_perm() {
  local name="$1" path="$2" expected_mode="$3" expected_owner="${4:-}" expected_group="${5:-}"

  if [[ ! -e "${path}" ]]; then
    check_add "${name}" warning "${path} does not exist." "Run 'cyferio-vpn install' if this server hasn't been set up yet."
    return
  fi

  local mode owner group
  mode="$(stat -c '%a' "${path}" 2>/dev/null || echo '')"
  owner="$(stat -c '%U' "${path}" 2>/dev/null || echo '')"
  group="$(stat -c '%G' "${path}" 2>/dev/null || echo '')"

  local -a problems=()
  if [[ "${mode}" != "${expected_mode}" ]]; then
    problems+=("mode is ${mode}, expected ${expected_mode}")
  fi
  if [[ -n "${expected_owner}" && "${owner}" != "${expected_owner}" ]]; then
    problems+=("owner is ${owner}, expected ${expected_owner}")
  fi
  if [[ -n "${expected_group}" && "${group}" != "${expected_group}" ]]; then
    problems+=("group is ${group}, expected ${expected_group}")
  fi

  if [[ ${#problems[@]} -eq 0 ]]; then
    check_add "${name}" pass
  else
    local joined
    joined="$(IFS='; '; echo "${problems[*]}")"
    check_add "${name}" fail "${path}: ${joined}" \
      "Re-run 'cyferio-vpn install' to have permissions reasserted automatically, or fix manually if this was an intentional local change."
  fi
}

# _audit_check_reserved_name — no DB row should ever exist for the
# 'server' identity (reserved for the OpenVPN server's own certificate,
# see utils.sh's is_reserved_identity_name / users.sh's user_add guard).
_audit_check_reserved_name() {
  if [[ -n "$(db_user_get server)" ]]; then
    check_add "Reserved Name Integrity" fail \
      "A user named 'server' exists in the database." \
      "This should never happen — user_add blocks it. Investigate how the row was created; consider removing it directly if it's not the actual OpenVPN server cert owner."
  else
    check_add "Reserved Name Integrity" pass
  fi
}

# _audit_check_user_cert_consistency — every active user should have a
# currently-valid (non-revoked, non-expired-in-index) certificate on
# file; flags drift between the users table and the PKI store (e.g. a
# cert revoked directly via `cert revoke` without also disabling the
# user, or PKI state restored from an older backup than the DB).
_audit_check_user_cert_consistency() {
  local rows
  rows="$(db_user_list)"
  local mismatches=0 uname status _id _profile _created _updated
  if [[ -n "${rows}" ]]; then
    while IFS='|' read -r _id uname status _profile _created _updated; do
      if [[ "${status}" == "active" ]]; then
        local cert_line cert_status
        cert_line="$(vpn_backend_list_clients | awk -F'|' -v n="${uname}" '$5==n')"
        cert_status="${cert_line%%|*}"
        if [[ "${cert_status}" != "V" ]]; then
          mismatches=$((mismatches + 1))
        fi
      fi
    done <<<"${rows}"
  fi

  if [[ "${mismatches}" -eq 0 ]]; then
    check_add "User/Certificate Consistency" pass
  else
    check_add "User/Certificate Consistency" warning \
      "${mismatches} active user(s) have no currently-valid certificate on file." \
      "Run 'cyferio-vpn user list' and 'cyferio-vpn cert status USERNAME' to investigate; 'cyferio-vpn profile regenerate USERNAME' reissues a certificate."
  fi
}

# _audit_check_mac_enforcement_mode — informational: flags 'permissive'
# so it's visible in a routine audit, not just buried in the config file
# — see docs/architecture/04-mac-validation.md.
_audit_check_mac_enforcement_mode() {
  local mode
  mode="$(config_get mac_enforcement_mode)"
  if [[ "${mode}" == "strict" ]]; then
    check_add "MAC Enforcement Mode" pass "strict"
  else
    check_add "MAC Enforcement Mode" warning \
      "mac_enforcement_mode=${mode:-unset} — connections with no matching registered-MAC peer-info are accepted-and-logged, not rejected." \
      "Set mac_enforcement_mode=strict in ${CYFERIO_CONF_DIR}/cyferio.conf once rollout is complete."
  fi
}

# audit_run — populate NETWORK_CHECKS; call checks_print_table/_json/
# checks_overall after, same protocol as net_run_preflight.
audit_run() {
  check_reset

  local pki_dir
  pki_dir="$(ovpn_pki_dir)"
  _audit_check_perm "PKI Directory Permissions" "${pki_dir}" 700 root root
  _audit_check_perm "PKI Private Key Directory Permissions" "${pki_dir}/private" 700 root root
  _audit_check_perm "CA Private Key Permissions" "${pki_dir}/private/ca.key" 600 root root

  _audit_check_perm "Database File Permissions" "$(db_path)" 660 root nogroup
  _audit_check_perm "Data Directory Permissions" "${CYFERIO_DATA_DIR}" 770 root nogroup

  local hooks_dir
  hooks_dir="$(ovpn_hooks_dir)"
  _audit_check_perm "client-connect Hook Permissions" "${hooks_dir}/client-connect.sh" 755 root root
  _audit_check_perm "client-disconnect Hook Permissions" "${hooks_dir}/client-disconnect.sh" 755 root root

  _audit_check_perm "Log Directory Permissions" "${CYFERIO_LOG_DIR}" 770 root nogroup
  _audit_check_perm "Log File Permissions" "${CYFERIO_LOG_DIR}/cyferio.log" 660 root nogroup

  _audit_check_perm "Config File Permissions" "${CYFERIO_CONF_DIR}/cyferio.conf" 644 root root

  _audit_check_reserved_name
  _audit_check_user_cert_consistency
  _audit_check_mac_enforcement_mode
}

# cmd_audit [--json]
cmd_audit() {
  require_root
  local json=0
  for arg in "$@"; do
    [[ "${arg}" == "--json" ]] && json=1
  done

  audit_run

  if [[ "${json}" -eq 1 ]]; then
    checks_print_json
  else
    checks_print_table
    echo "Overall: $(checks_overall)"
  fi
}

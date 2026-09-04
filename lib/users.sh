#!/usr/bin/env bash
# users.sh — `cyferio-vpn user add|remove|enable|disable|get|list`.
# Composes certs.sh's PKI guard (_cert_require_pki), backends/openvpn.sh's
# vpn_backend_provision_client/_revoke_client/_render_profile, and
# database.sh's db_user_* — no easyrsa/sqlite calls live here directly.

if [[ -n "${__CYFERIO_USERS_LOADED:-}" ]]; then
  return 0
fi
__CYFERIO_USERS_LOADED=1

user_add() {
  local username="${1:-}"
  [[ -n "${username}" ]] || die "usage: cyferio-vpn user add USERNAME" 1
  validate_username "${username}" || die "invalid username '${username}' — use letters, digits, '_', '-' only (max 32 chars)" 1
  if is_reserved_identity_name "${username}"; then
    die "'${username}' is a reserved name" 1
  fi
  require_root
  _cert_require_pki

  if [[ -n "$(db_user_get "${username}")" ]]; then
    die "user '${username}' already exists" 1
  fi

  vpn_backend_provision_client "${username}"
  local profile_path
  # render_profile prints its own specific die() message on failure
  # (missing cert/key, no endpoint, validation failure) — the explicit
  # `|| exit 1` here is what actually stops this function afterward;
  # exit inside a function invoked via command substitution only kills
  # that subshell, not this caller (see lib/macs.sh's
  # _mac_get_user_id for the fuller explanation of this footgun).
  profile_path="$(vpn_backend_render_profile "${username}")" || exit 1

  db_user_insert "${username}" "${profile_path}"
  db_audit_log "user.add" "$(current_actor)" "$(jq -nc --arg username "${username}" '{username:$username}')"

  ui_ok "VPN Profile Generated Successfully"
  echo
  echo "Profile Location:"
  echo " ${profile_path}"
}

user_remove() {
  local username="${1:-}"
  shift || true
  local force=0
  for arg in "$@"; do
    [[ "${arg}" == "--force" ]] && force=1
  done
  [[ -n "${username}" ]] || die "usage: cyferio-vpn user remove USERNAME [--force]" 1
  require_root

  local row
  row="$(db_user_get "${username}")"
  [[ -n "${row}" ]] || die "no such user '${username}'" 1

  if [[ "${force}" -ne 1 ]] && ! confirm "Remove user '${username}'? This revokes their certificate and deletes their profile."; then
    echo "Aborted."
    exit 1
  fi

  local _id uname status profile_path created_at updated_at
  IFS='|' read -r _id uname status profile_path created_at updated_at <<<"${row}"

  # May already be revoked directly via `cert revoke` — ovpn_revoke_if_valid
  # is a no-op in that case rather than erroring on a re-revoke.
  ovpn_revoke_if_valid "${username}"

  if [[ -n "${profile_path}" && -f "${profile_path}" ]]; then
    rm -f "${profile_path}"
  fi

  db_user_delete "${username}"
  db_audit_log "user.remove" "$(current_actor)" "$(jq -nc --arg username "${username}" '{username:$username}')"

  ui_ok "User '${username}' removed (certificate revoked, profile deleted)."
}

# user_enable/user_disable are DB-level bookkeeping only — they do not
# touch the certificate. Live connection-time enforcement of a disabled
# user (rejecting their still-valid cert at connect) is handled by
# lib/macs.sh:mac_check_connection (Phase 7), not here: it reads this
# same `status` column on every connection attempt.
user_disable() {
  local username="${1:-}"
  [[ -n "${username}" ]] || die "usage: cyferio-vpn user disable USERNAME" 1
  require_root
  [[ -n "$(db_user_get "${username}")" ]] || die "no such user '${username}'" 1

  db_user_set_status "${username}" "disabled"
  db_audit_log "user.disable" "$(current_actor)" "$(jq -nc --arg username "${username}" '{username:$username}')"
  ui_ok "User '${username}' disabled."
}

user_enable() {
  local username="${1:-}"
  [[ -n "${username}" ]] || die "usage: cyferio-vpn user enable USERNAME" 1
  require_root
  [[ -n "$(db_user_get "${username}")" ]] || die "no such user '${username}'" 1

  db_user_set_status "${username}" "active"
  db_audit_log "user.enable" "$(current_actor)" "$(jq -nc --arg username "${username}" '{username:$username}')"
  ui_ok "User '${username}' enabled."
}

user_get() {
  local username="${1:-}"
  shift || true
  local json=0
  for arg in "$@"; do
    [[ "${arg}" == "--json" ]] && json=1
  done
  [[ -n "${username}" ]] || die "usage: cyferio-vpn user get USERNAME [--json]" 1
  require_root

  local row
  row="$(db_user_get "${username}")"
  [[ -n "${row}" ]] || die "no such user '${username}'" 1

  local _id uname status profile_path created_at updated_at
  IFS='|' read -r _id uname status profile_path created_at updated_at <<<"${row}"

  if [[ "${json}" -eq 1 ]]; then
    jq -n \
      --arg username "${uname}" --arg status "${status}" --arg profile_path "${profile_path}" \
      --arg created_at "${created_at}" --arg updated_at "${updated_at}" \
      '{username: $username, status: $status, profile_path: $profile_path, created_at: $created_at, updated_at: $updated_at}'
  else
    echo "Username: ${uname}"
    echo "Status:   ${status}"
    echo "Profile:  ${profile_path}"
    echo "Created:  ${created_at}"
    echo "Updated:  ${updated_at}"
  fi
}

user_list() {
  local json=0
  for arg in "$@"; do
    [[ "${arg}" == "--json" ]] && json=1
  done
  require_root

  local rows
  rows="$(db_user_list)"

  if [[ "${json}" -eq 1 ]]; then
    local out="[]"
    if [[ -n "${rows}" ]]; then
      while IFS='|' read -r _id uname status profile_path created_at updated_at; do
        out="$(jq -c \
          --arg username "${uname}" --arg status "${status}" --arg profile_path "${profile_path}" \
          --arg created_at "${created_at}" --arg updated_at "${updated_at}" \
          '. + [{username: $username, status: $status, profile_path: $profile_path, created_at: $created_at, updated_at: $updated_at}]' \
          <<<"${out}")"
      done <<<"${rows}"
    fi
    echo "${out}"
    return 0
  fi

  if [[ -z "${rows}" ]]; then
    echo "No users yet. Add one with: cyferio-vpn user add USERNAME"
    return 0
  fi

  printf '%-20s %-10s %s\n' "USERNAME" "STATUS" "PROFILE"
  while IFS='|' read -r _id uname status profile_path created_at updated_at; do
    printf '%-20s %-10s %s\n' "${uname}" "${status}" "${profile_path}"
  done <<<"${rows}"
}

cmd_user() {
  local subcommand="${1:-}"
  shift || true
  case "${subcommand}" in
    add) user_add "$@" ;;
    remove) user_remove "$@" ;;
    enable) user_enable "$@" ;;
    disable) user_disable "$@" ;;
    get) user_get "$@" ;;
    list) user_list "$@" ;;
    *)
      echo "cyferio-vpn: usage: cyferio-vpn user <add|remove|enable|disable|get|list> ..." >&2
      exit 1
      ;;
  esac
}

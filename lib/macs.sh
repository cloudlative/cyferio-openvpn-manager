#!/usr/bin/env bash
# macs.sh — `cyferio-vpn mac add|remove|update|list`. Owns MAC validation/
# normalization and duplicate-prevention policy; database.sh's db_mac_*
# handles the actual SQL. `mac report` (cross-user table/JSON summary) is
# Phase 8 — Reporting Engine, not this module.

if [[ -n "${__CYFERIO_MACS_LOADED:-}" ]]; then
  return 0
fi
__CYFERIO_MACS_LOADED=1

# _mac_get_user_id USERNAME — echoes the user's numeric id, or returns
# non-zero with no output if the user doesn't exist or the row looks
# unexpected. Deliberately does NOT call die() itself: this function is
# always invoked via command substitution (`user_id="$(_mac_get_user_id
# ...)"`), and exit inside a function called that way only terminates the
# subshell doing the substitution — it would NOT reliably abort the
# caller (relying on that requires `set -e` to be active at every call
# site, which it always is in the real bin/cyferio-vpn, but is exactly
# the kind of dependency that breaks silently, e.g. under a test harness
# that disables errexit around captured commands). Callers check the
# return value explicitly instead — see mac_add/_remove/_update/_list.
_mac_get_user_id() {
  local username="$1"
  local row
  row="$(db_user_get "${username}")"
  [[ -n "${row}" ]] || return 1
  local user_id="${row%%|*}"
  [[ "${user_id}" =~ ^[0-9]+$ ]] || return 1
  echo "${user_id}"
}

# _mac_check_available USERNAME USER_ID MAC — dies if MAC is already
# registered to this user (no-op duplicate) or to a DIFFERENT user
# (cross-user duplicate, per docs/architecture/04-mac-validation.md —
# rejected outright, not silently allowed as a second binding).
_mac_check_available() {
  local username="$1" user_id="$2" mac="$3"
  local owner
  owner="$(db_mac_find_owner "${mac}")"
  if [[ -n "${owner}" ]]; then
    if [[ "${owner}" == "${username}" ]]; then
      die "MAC ${mac} is already registered to '${username}'" 1
    else
      die "MAC ${mac} is already registered to user '${owner}' — contact support to transfer, or remove it from their account first" 1
    fi
  fi
}

mac_add() {
  local username="${1:-}" mac="${2:-}"
  [[ -n "${username}" && -n "${mac}" ]] || die "usage: cyferio-vpn mac add USERNAME MAC" 1
  require_root

  local user_id
  user_id="$(_mac_get_user_id "${username}")" || die "no such user '${username}' (use 'cyferio-vpn user add ${username}' first)" 1

  validate_mac "${mac}" || die "invalid MAC address '${mac}' — expected AA:BB:CC:DD:EE:FF" 1
  local norm_mac
  norm_mac="$(normalize_mac "${mac}")"

  _mac_check_available "${username}" "${user_id}" "${norm_mac}"

  db_mac_insert "${user_id}" "${norm_mac}"
  db_audit_log "mac.add" "$(current_actor)" "$(jq -nc --arg username "${username}" --arg mac "${norm_mac}" '{username:$username, mac:$mac}')"
  ui_ok "MAC ${norm_mac} added for '${username}'."
}

mac_remove() {
  local username="${1:-}" mac="${2:-}"
  [[ -n "${username}" && -n "${mac}" ]] || die "usage: cyferio-vpn mac remove USERNAME MAC" 1
  require_root

  local user_id
  user_id="$(_mac_get_user_id "${username}")" || die "no such user '${username}' (use 'cyferio-vpn user add ${username}' first)" 1

  validate_mac "${mac}" || die "invalid MAC address '${mac}' — expected AA:BB:CC:DD:EE:FF" 1
  local norm_mac
  norm_mac="$(normalize_mac "${mac}")"

  [[ -n "$(db_mac_get "${user_id}" "${norm_mac}")" ]] || die "MAC ${norm_mac} is not registered to '${username}'" 1

  db_mac_delete "${user_id}" "${norm_mac}"
  db_audit_log "mac.remove" "$(current_actor)" "$(jq -nc --arg username "${username}" --arg mac "${norm_mac}" '{username:$username, mac:$mac}')"
  ui_ok "MAC ${norm_mac} removed from '${username}'."
}

mac_update() {
  local username="${1:-}" old_mac="${2:-}" new_mac="${3:-}"
  [[ -n "${username}" && -n "${old_mac}" && -n "${new_mac}" ]] || die "usage: cyferio-vpn mac update USERNAME OLD_MAC NEW_MAC" 1
  require_root

  local user_id
  user_id="$(_mac_get_user_id "${username}")" || die "no such user '${username}' (use 'cyferio-vpn user add ${username}' first)" 1

  validate_mac "${old_mac}" || die "invalid MAC address '${old_mac}' — expected AA:BB:CC:DD:EE:FF" 1
  validate_mac "${new_mac}" || die "invalid MAC address '${new_mac}' — expected AA:BB:CC:DD:EE:FF" 1
  local norm_old norm_new
  norm_old="$(normalize_mac "${old_mac}")"
  norm_new="$(normalize_mac "${new_mac}")"

  [[ -n "$(db_mac_get "${user_id}" "${norm_old}")" ]] || die "MAC ${norm_old} is not registered to '${username}'" 1

  if [[ "${norm_old}" != "${norm_new}" ]]; then
    _mac_check_available "${username}" "${user_id}" "${norm_new}"
  fi

  db_mac_update "${user_id}" "${norm_old}" "${norm_new}"
  db_audit_log "mac.update" "$(current_actor)" "$(jq -nc --arg username "${username}" --arg old_mac "${norm_old}" --arg new_mac "${norm_new}" '{username:$username, old_mac:$old_mac, new_mac:$new_mac}')"
  ui_ok "MAC updated for '${username}': ${norm_old} -> ${norm_new}"
}

mac_list() {
  local username="${1:-}"
  shift || true
  local json=0
  for arg in "$@"; do
    [[ "${arg}" == "--json" ]] && json=1
  done
  [[ -n "${username}" ]] || die "usage: cyferio-vpn mac list USERNAME [--json]" 1
  require_root

  local user_id
  user_id="$(_mac_get_user_id "${username}")" || die "no such user '${username}' (use 'cyferio-vpn user add ${username}' first)" 1

  local rows
  rows="$(db_mac_list "${user_id}")"

  if [[ "${json}" -eq 1 ]]; then
    local out="[]"
    if [[ -n "${rows}" ]]; then
      while IFS='|' read -r mac created_at; do
        out="$(jq -c --arg mac "${mac}" --arg created_at "${created_at}" \
          '. + [{mac_address: $mac, created_at: $created_at}]' <<<"${out}")"
      done <<<"${rows}"
    fi
    jq -n --arg username "${username}" --argjson macs "${out}" '{username: $username, mac_addresses: $macs}'
    return 0
  fi

  if [[ -z "${rows}" ]]; then
    echo "No MAC addresses registered for '${username}'."
    return 0
  fi

  local -a macs=()
  while IFS='|' read -r mac created_at; do
    macs+=("${mac}")
  done <<<"${rows}"

  echo "${username}"
  local i last=$((${#macs[@]} - 1))
  for i in "${!macs[@]}"; do
    if [[ "${i}" -eq "${last}" ]]; then
      printf ' └── %s\n' "${macs[${i}]}"
    else
      printf ' ├── %s\n' "${macs[${i}]}"
    fi
  done
}

cmd_mac() {
  local subcommand="${1:-}"
  shift || true
  case "${subcommand}" in
    add) mac_add "$@" ;;
    remove) mac_remove "$@" ;;
    update) mac_update "$@" ;;
    list) mac_list "$@" ;;
    report)
      echo "cyferio-vpn: 'mac report' is not implemented yet (coming in Phase 8 — Reporting Engine)" >&2
      exit 2
      ;;
    *)
      echo "cyferio-vpn: usage: cyferio-vpn mac <add|remove|update|list> ..." >&2
      exit 1
      ;;
  esac
}

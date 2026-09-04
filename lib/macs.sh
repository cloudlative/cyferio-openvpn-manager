#!/usr/bin/env bash
# macs.sh — `cyferio-vpn mac add|remove|update|list|report`. Owns MAC
# validation/normalization and duplicate-prevention policy; database.sh's
# db_mac_* handles the actual SQL. `mac report` (Phase 8) is a thin
# consumer of lib/reporting.sh's shared table/plain formatter — its own
# JSON shape is built here directly, same as list's.

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

# mac_report [--table|--plain|--json] — cross-user summary: every user,
# their registered MAC count/list, and their most recent connection
# decision (from audit_logs' auth.mac_* rows — see lib/macs.sh's
# mac_check_connection and db_mac_report). --table is the default, per
# 00-overview.md's "structured output everywhere" principle.
mac_report() {
  local format="table"
  for arg in "$@"; do
    case "${arg}" in
      --json) format="json" ;;
      --plain) format="plain" ;;
      --table) format="table" ;;
    esac
  done
  require_root

  local rows
  rows="$(db_mac_report)"

  if [[ "${format}" == "json" ]]; then
    local out="[]"
    if [[ -n "${rows}" ]]; then
      while IFS='|' read -r uname status mac_count macs_csv last_event; do
        local macs_json="[]"
        if [[ -n "${macs_csv}" ]]; then
          macs_json="$(jq -R -c 'split(",")' <<<"${macs_csv}")"
        fi
        local last_action="" last_seen=""
        if [[ -n "${last_event}" ]]; then
          last_action="${last_event%%:*}"
          last_seen="${last_event#*:}"
        fi
        out="$(jq -c \
          --arg username "${uname}" --arg status "${status}" --argjson mac_count "${mac_count}" \
          --argjson mac_addresses "${macs_json}" --arg last_action "${last_action}" --arg last_seen "${last_seen}" \
          '. + [{username: $username, status: $status, mac_count: $mac_count, mac_addresses: $mac_addresses}
                + (if $last_action != "" then {last_event: {action: $last_action, timestamp: $last_seen}} else {} end)]' \
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

  local formatted="" uname status mac_count macs_csv last_event
  while IFS='|' read -r uname status mac_count macs_csv last_event; do
    local macs_display="${macs_csv:--}"
    local last_display="-"
    if [[ -n "${last_event}" ]]; then
      last_display="${last_event/:/ @ }"
    fi
    formatted+="${uname}|${status}|${mac_count}|${macs_display}|${last_display}"$'\n'
  done <<<"${rows}"

  if [[ "${format}" == "plain" ]]; then
    printf '%s' "${formatted}" | report_plain
  else
    printf '%s' "${formatted}" | report_table "USERNAME|STATUS|MAC COUNT|MAC ADDRESSES|LAST EVENT"
  fi
}

cmd_mac() {
  local subcommand="${1:-}"
  shift || true
  case "${subcommand}" in
    add) mac_add "$@" ;;
    remove) mac_remove "$@" ;;
    update) mac_update "$@" ;;
    list) mac_list "$@" ;;
    report) mac_report "$@" ;;
    *)
      echo "cyferio-vpn: usage: cyferio-vpn mac <add|remove|update|list|report> ..." >&2
      exit 1
      ;;
  esac
}

# --- Phase 7: connection-time enforcement --------------------------------
# Invoked by templates/client-connect.sh.tmpl / client-disconnect.sh.tmpl
# (installed to /etc/cyferio/hooks/, run by the OpenVPN daemon as
# `nobody:nogroup` on every connect/disconnect — see
# docs/architecture/04-mac-validation.md). Never called by an operator
# directly; reached only via `cyferio-vpn internal mac-check|disconnect-log`
# (cmd_internal below, dispatched from core_dispatch's `internal` case).
#
# mac_check_connection never die()s — an uncaught failure here must not
# crash the hook (and thus every connection attempt) with a stack dump;
# every branch is an explicit return so the caller's exit code is always
# a deliberate accept(0)/reject(1) decision. Each branch also writes its
# own audit_logs row directly (not via the mac_add/remove auditing in
# cmd_mac above) since 'the connecting user' is the actor here, not
# whoever ran a `cyferio-vpn mac ...` command.

# mac_check_connection COMMON_NAME [PEER_MAC] — prints "ACCEPT <reason>"
# or "REJECT <reason>" to stdout and returns 0/1 to match. PEER_MAC is
# OpenVPN's client-supplied IV_HWADDR peer-info — see 04-mac-validation.md's
# Limitations note: not cryptographically verified, policy enforcement
# only. A malformed/missing PEER_MAC is treated identically to no MAC at
# all, never as a crash or a free pass.
mac_check_connection() {
  local common_name="${1:-}" mac="${2:-}"
  local reason

  if [[ -n "${mac}" ]] && validate_mac "${mac}"; then
    mac="$(normalize_mac "${mac}")"
  else
    mac=""
  fi

  if [[ -z "${common_name}" ]]; then
    reason="no_common_name"
    db_audit_log "auth.mac_reject" "unknown" "$(jq -nc --arg reason "${reason}" '{reason:$reason}')" 2>/dev/null || true
    echo "REJECT ${reason}"
    return 1
  fi

  local row
  row="$(db_user_get "${common_name}")" 2>/dev/null || row=""
  if [[ -z "${row}" ]]; then
    reason="unknown_user"
    db_audit_log "auth.mac_reject" "${common_name}" "$(jq -nc --arg reason "${reason}" '{reason:$reason}')" 2>/dev/null || true
    echo "REJECT ${reason}"
    return 1
  fi

  local user_id _uname status _profile _created _updated
  IFS='|' read -r user_id _uname status _profile _created _updated <<<"${row}"

  if [[ "${status}" != "active" ]]; then
    reason="user_${status}"
    db_audit_log "auth.mac_reject" "${common_name}" "$(jq -nc --arg reason "${reason}" '{reason:$reason}')" 2>/dev/null || true
    echo "REJECT ${reason}"
    return 1
  fi

  local rows registered_count=0
  rows="$(db_mac_list "${user_id}")" 2>/dev/null || rows=""
  if [[ -n "${rows}" ]]; then
    registered_count="$(wc -l <<<"${rows}")"
  fi

  # No MAC ever registered for this user — nothing to enforce yet
  # (matches mac_add's own "no restriction until you add one" model).
  if [[ "${registered_count}" -eq 0 ]]; then
    reason="no_mac_policy"
    db_audit_log "auth.mac_accept" "${common_name}" "$(jq -nc --arg reason "${reason}" '{reason:$reason}')" 2>/dev/null || true
    echo "ACCEPT ${reason}"
    return 0
  fi

  if [[ -z "${mac}" ]]; then
    local mode
    mode="$(config_get mac_enforcement_mode)"
    [[ -n "${mode}" ]] || mode="strict"
    if [[ "${mode}" == "permissive" ]]; then
      reason="mac_unavailable_permissive"
      db_audit_log "auth.mac_unavailable" "${common_name}" "$(jq -nc --arg reason "${reason}" '{reason:$reason}')" 2>/dev/null || true
      echo "ACCEPT ${reason}"
      return 0
    fi
    reason="mac_unavailable_strict"
    db_audit_log "auth.mac_unavailable" "${common_name}" "$(jq -nc --arg reason "${reason}" '{reason:$reason}')" 2>/dev/null || true
    echo "REJECT ${reason}"
    return 1
  fi

  if grep -qxF "${mac}" <(cut -d'|' -f1 <<<"${rows}"); then
    reason="mac_match"
    db_audit_log "auth.mac_accept" "${common_name}" "$(jq -nc --arg reason "${reason}" --arg mac "${mac}" '{reason:$reason, mac:$mac}')" 2>/dev/null || true
    echo "ACCEPT ${reason}"
    return 0
  fi

  reason="mac_mismatch"
  db_audit_log "auth.mac_reject" "${common_name}" "$(jq -nc --arg reason "${reason}" --arg mac "${mac}" '{reason:$reason, mac:$mac}')" 2>/dev/null || true
  echo "REJECT ${reason}"
  return 1
}

# mac_log_disconnect COMMON_NAME [PEER_MAC] [DURATION_SECONDS] — audit
# trail only, per 04-mac-validation.md ("no enforcement action"); always
# succeeds from the hook's point of view.
mac_log_disconnect() {
  local common_name="${1:-unknown}" mac="${2:-}" duration="${3:-}"
  db_audit_log "session.disconnect" "${common_name}" "$(jq -nc --arg mac "${mac}" --arg duration "${duration}" '{mac:$mac, duration_seconds:$duration}')" 2>/dev/null || true
}

# cmd_internal — dispatcher for the hook-only plumbing commands above.
# Deliberately not documented in core_usage: this is not operator-facing.
cmd_internal() {
  local subcommand="${1:-}"
  shift || true
  case "${subcommand}" in
    mac-check)
      if mac_check_connection "$@"; then
        exit 0
      else
        exit 1
      fi
      ;;
    disconnect-log)
      mac_log_disconnect "$@" || true
      exit 0
      ;;
    *)
      echo "cyferio-vpn: unknown internal subcommand '${subcommand}'" >&2
      exit 1
      ;;
  esac
}

#!/usr/bin/env bash
# certs.sh — `cyferio-vpn cert create|revoke|list|status`, usable without
# ever running `install`'s webapp-adjacent user flow (Phase 4). Talks to
# the PKI only through backends/openvpn.sh's vpn_backend_* functions —
# no easyrsa/openssl calls live here.

if [[ -n "${__CYFERIO_CERTS_LOADED:-}" ]]; then
  return 0
fi
__CYFERIO_CERTS_LOADED=1

_cert_require_pki() {
  [[ -f "$(ovpn_pki_dir)/ca.crt" ]] || die "PKI not initialized — run 'cyferio-vpn install' first" 3
}

# 'server' is issued and managed by install/uninstall — block it from the
# generic cert command so it can't be revoked out from under a running
# VPN by accident.
_cert_reserved_name_guard() {
  local name="$1"
  if [[ "${name}" == "server" ]]; then
    die "'server' is managed by install/uninstall, not 'cert' — use those commands instead" 1
  fi
}

_cert_status_label() {
  case "$1" in
    V) echo "valid" ;;
    R) echo "revoked" ;;
    E) echo "expired" ;;
    *) echo "unknown" ;;
  esac
}

cert_create() {
  local name="${1:-}"
  [[ -n "${name}" ]] || die "usage: cyferio-vpn cert create NAME" 1
  validate_username "${name}" || die "invalid name '${name}' — use letters, digits, '_', '-' only (max 32 chars)" 1
  _cert_reserved_name_guard "${name}"
  require_root
  _cert_require_pki

  vpn_backend_provision_client "${name}"
  db_audit_log "cert.create" "$(current_actor)" "$(jq -nc --arg name "${name}" '{name:$name}')"

  ui_ok "Certificate created for '${name}'."
  echo "  Cert: $(ovpn_pki_dir)/issued/${name}.crt"
  echo "  Key:  $(ovpn_pki_dir)/private/${name}.key"
}

cert_revoke() {
  local name="${1:-}"
  shift || true
  local force=0
  for arg in "$@"; do
    [[ "${arg}" == "--force" ]] && force=1
  done
  [[ -n "${name}" ]] || die "usage: cyferio-vpn cert revoke NAME [--force]" 1
  _cert_reserved_name_guard "${name}"
  require_root
  _cert_require_pki

  if [[ "${force}" -ne 1 ]] && ! confirm "Revoke the certificate for '${name}'? This immediately blocks its VPN access."; then
    echo "Aborted."
    exit 1
  fi

  vpn_backend_revoke_client "${name}"
  db_audit_log "cert.revoke" "$(current_actor)" "$(jq -nc --arg name "${name}" '{name:$name}')"
  ui_ok "Certificate for '${name}' revoked."
}

cert_list() {
  local json=0
  for arg in "$@"; do
    [[ "${arg}" == "--json" ]] && json=1
  done
  require_root
  _cert_require_pki

  local entries
  entries="$(vpn_backend_list_clients)"

  if [[ "${json}" -eq 1 ]]; then
    local out="[]"
    if [[ -n "${entries}" ]]; then
      while IFS='|' read -r status expiry revoked serial cn; do
        local type="client"
        [[ "${cn}" == "server" ]] && type="server"
        out="$(jq -c \
          --arg name "${cn}" --arg type "${type}" --arg status "$(_cert_status_label "${status}")" \
          --arg expires_at "${expiry}" --arg revoked_at "${revoked}" --arg serial "${serial}" \
          '. + [{name: $name, type: $type, status: $status, serial: $serial, expires_at: $expires_at}
                + (if $revoked_at != "" then {revoked_at: $revoked_at} else {} end)]' \
          <<<"${out}")"
      done <<<"${entries}"
    fi
    echo "${out}"
    return 0
  fi

  if [[ -z "${entries}" ]]; then
    echo "No certificates issued yet."
    return 0
  fi

  printf '%-20s %-8s %-10s %s\n' "NAME" "TYPE" "STATUS" "EXPIRES"
  while IFS='|' read -r status expiry revoked serial cn; do
    local type="client"
    [[ "${cn}" == "server" ]] && type="server"
    printf '%-20s %-8s %-10s %s\n' "${cn}" "${type}" "$(_cert_status_label "${status}")" "${expiry}"
  done <<<"${entries}"
}

cert_status() {
  local name="${1:-}"
  shift || true
  local json=0
  for arg in "$@"; do
    [[ "${arg}" == "--json" ]] && json=1
  done
  [[ -n "${name}" ]] || die "usage: cyferio-vpn cert status NAME [--json]" 1
  require_root
  _cert_require_pki

  local line
  line="$(vpn_backend_list_clients | awk -F'|' -v n="${name}" '$5==n')"
  [[ -n "${line}" ]] || die "no certificate found for '${name}'" 1

  local status expiry revoked serial cn
  IFS='|' read -r status expiry revoked serial cn <<<"${line}"
  local type="client"
  [[ "${cn}" == "server" ]] && type="server"

  if [[ "${json}" -eq 1 ]]; then
    jq -n \
      --arg name "${cn}" --arg type "${type}" --arg status "$(_cert_status_label "${status}")" \
      --arg expires_at "${expiry}" --arg revoked_at "${revoked}" --arg serial "${serial}" \
      '{name: $name, type: $type, status: $status, serial: $serial, expires_at: $expires_at}
       + (if $revoked_at != "" then {revoked_at: $revoked_at} else {} end)'
  else
    echo "Name:       ${cn}"
    echo "Type:       ${type}"
    echo "Status:     $(_cert_status_label "${status}")"
    echo "Serial:     ${serial}"
    echo "Expires:    ${expiry}"
    if [[ -n "${revoked}" ]]; then
      echo "Revoked at: ${revoked}"
    fi
  fi
}

cmd_cert() {
  local subcommand="${1:-}"
  shift || true
  case "${subcommand}" in
    create) cert_create "$@" ;;
    revoke) cert_revoke "$@" ;;
    list) cert_list "$@" ;;
    status) cert_status "$@" ;;
    *)
      echo "cyferio-vpn: usage: cyferio-vpn cert <create|revoke|list|status> ..." >&2
      exit 1
      ;;
  esac
}

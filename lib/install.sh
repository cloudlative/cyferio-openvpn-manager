#!/usr/bin/env bash
# install.sh — orchestrates `install`, `uninstall`, and `network detect` by
# composing network.sh (pre-flight), cloud.sh (provider detection), and
# backends/openvpn.sh (PKI/server/firewall). No OpenVPN/EasyRSA specifics
# live here — see docs/architecture/00-overview.md's module boundaries.

if [[ -n "${__CYFERIO_INSTALL_LOADED:-}" ]]; then
  return 0
fi
__CYFERIO_INSTALL_LOADED=1

# _install_write_default_config — copy config/cyferio.conf.example to
# /etc/cyferio/cyferio.conf on first install only; never overwrites an
# existing config (that would silently discard an admin's edits).
_install_write_default_config() {
  local target="${CYFERIO_CONF_DIR}/cyferio.conf"
  mkdir -p "${CYFERIO_CONF_DIR}"
  if [[ -f "${target}" ]]; then
    log_info "install.config" "result=skipped_existing"
    return 0
  fi
  install -m 0644 "${CYFERIO_ROOT_DIR}/config/cyferio.conf.example" "${target}"
  log_info "install.config" "result=created"
}

# cmd_install [--force] — idempotent end-to-end install.
cmd_install() {
  require_root
  local force=0
  for arg in "$@"; do
    [[ "${arg}" == "--force" ]] && force=1
  done

  echo "Running pre-flight checks..."
  net_run_preflight
  checks_print_table
  local overall
  overall="$(checks_overall)"

  if [[ "${overall}" == "fail" && "${force}" -ne 1 ]]; then
    ui_err "Pre-flight checks failed. Fix the issues above, or re-run with --force to proceed anyway."
    exit 1
  fi

  echo
  echo "Installing packages..."
  ovpn_install_packages

  echo "Bootstrapping PKI (CA + server certificate)..."
  ovpn_pki_bootstrap

  echo "Installing MAC-enforcement hook stubs..."
  ovpn_install_hooks

  echo "Rendering OpenVPN server configuration..."
  ovpn_render_server_config

  echo "Enabling IP forwarding..."
  ovpn_configure_ip_forwarding

  echo "Configuring NAT and firewall..."
  ovpn_configure_nat_and_firewall

  echo "Starting OpenVPN service..."
  ovpn_enable_service

  echo "Initializing database..."
  db_migrate
  # Phase 7: the client-connect/-disconnect hooks run as the OpenVPN
  # daemon's dropped-privilege user (server.conf's `user nobody` / `group
  # nogroup`) and need to read user_macs and write audit_logs directly —
  # see lib/database.sh:db_grant_group_access and 09-security-review.md.
  db_grant_group_access nogroup

  _install_write_default_config

  echo
  ui_ok "Cyferio OpenVPN Manager installed successfully."
  echo "  Status:  $(vpn_backend_server_status)"
  echo "  Port:    $(config_get vpn_port)/$(config_get vpn_proto)"
  echo "  Subnet:  $(config_get vpn_subnet) $(config_get vpn_subnet_mask)"
  echo
  echo "Next: cyferio-vpn user add <username>"
  log_info "install" "result=success"
}

# cmd_uninstall [--force] — always backs up first (spec-mandated), then
# tears down service, firewall/NAT rules, PKI, server config, and DB.
cmd_uninstall() {
  require_root
  local force=0
  for arg in "$@"; do
    [[ "${arg}" == "--force" ]] && force=1
  done

  if [[ "${force}" -ne 1 ]]; then
    if ! confirm "This will remove OpenVPN, all certificates, and the Cyferio database. Continue?"; then
      echo "Aborted."
      exit 1
    fi
  fi

  echo "Creating backup before uninstall..."
  # Phase 11 — lib/backup.sh's backup_run is the one backup
  # implementation (cmd_backup uses it too); spec-mandated that
  # uninstall is never destructive without a recovery point, so a
  # backup failure here aborts the uninstall entirely rather than
  # proceeding without one.
  local archive
  archive="$(backup_run pre-uninstall)" || die "pre-uninstall backup failed — aborting uninstall (nothing was removed)" 3
  [[ -n "${archive}" ]] && echo "Backup saved to: ${archive}"

  echo "Removing OpenVPN, PKI, and firewall/NAT rules..."
  ovpn_uninstall

  echo "Removing database..."
  rm -f "$(db_path)"

  echo "Removing configuration..."
  rm -rf "${CYFERIO_CONF_DIR}"

  ui_ok "Cyferio OpenVPN Manager has been uninstalled."
  [[ -n "${archive}" ]] && echo "Recovery point: ${archive}"
  log_info "uninstall" "result=success"
}

# cmd_network SUBCOMMAND [--json] — currently only `detect`.
cmd_network() {
  local subcommand="${1:-}"
  shift || true
  local json=0
  for arg in "$@"; do
    [[ "${arg}" == "--json" ]] && json=1
  done

  case "${subcommand}" in
    detect|"")
      net_run_preflight
      if [[ "${json}" -eq 1 ]]; then
        jq -n --arg provider "${CYFERIO_CLOUD_PROVIDER}" --arg public_ip "${CYFERIO_PUBLIC_IP:-}" \
          --argjson checks "$(checks_print_json)" \
          '{provider: $provider, public_ip: $public_ip, checks: $checks}'
      else
        echo "Cloud Provider: ${CYFERIO_CLOUD_PROVIDER}"
        echo "Public IP:      ${CYFERIO_PUBLIC_IP:-unknown}"
        echo
        checks_print_table
      fi
      ;;
    *)
      echo "cyferio-vpn: unknown 'network' subcommand '${subcommand}'" >&2
      exit 1
      ;;
  esac
}

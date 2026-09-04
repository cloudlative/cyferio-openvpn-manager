#!/usr/bin/env bash
# diagnostics.sh — `cyferio-vpn diagnose [--json]` (Phase 10).
# Connectivity/troubleshooting checks against a server that's already
# (or was meant to be) installed: is the service actually running and
# listening, is NAT/forwarding actually in effect right now, are the PKI
# files and DB actually present — distinct from audit.sh's security-
# posture checks (file permissions), and from `network detect`'s
# pre-install validation (which checks whether install COULD succeed,
# not whether it DID).
#
# Reuses lib/network.sh's shared checks accumulator, and several of its
# individual checks directly (net_check_connectivity, net_check_firewall,
# net_check_ip_forwarding) rather than re-implementing them.

if [[ -n "${__CYFERIO_DIAGNOSTICS_LOADED:-}" ]]; then
  return 0
fi
__CYFERIO_DIAGNOSTICS_LOADED=1

_diag_check_service() {
  if systemctl is-active --quiet "${OVPN_SYSTEMD_UNIT}" 2>/dev/null; then
    check_add "OpenVPN Service" pass
  else
    check_add "OpenVPN Service" fail \
      "${OVPN_SYSTEMD_UNIT} is not running." \
      "Check 'systemctl status ${OVPN_SYSTEMD_UNIT}' and 'journalctl -u ${OVPN_SYSTEMD_UNIT}'."
  fi
}

# _diag_check_port_listening — is OpenVPN itself actually bound to the
# configured port right now (post-install reality), as opposed to
# net_check_port's pre-install "is something ALREADY using this port"
# check (a conflict warning, not a health check).
_diag_check_port_listening() {
  local port proto flag
  port="$(config_get vpn_port)"
  proto="$(config_get vpn_proto)"
  flag="-tln"
  [[ "${proto}" == "udp" ]] && flag="-uln"
  # Field 4, not 5 — see lib/network.sh's net_check_port for why (field 5
  # is the peer address, never the port we're listening on). Found via a
  # real VM: this check reported "fail" on a genuinely healthy, listening
  # server until fixed.
  if is_command_available ss && ss ${flag} 2>/dev/null | awk '{print $4}' | grep -q ":${port}\$"; then
    check_add "OpenVPN Listening" pass
  else
    check_add "OpenVPN Listening" fail \
      "Nothing is listening on ${port}/${proto}." \
      "Confirm the service is running and that server.conf's port/proto match cyferio.conf's."
  fi
}

_diag_check_nat_rule() {
  local subnet
  subnet="$(config_get vpn_subnet)"
  if ! is_command_available iptables; then
    check_add "NAT/Masquerade Rule" warning "iptables not found — cannot verify." "Install iptables to enable this check."
    return
  fi
  if iptables -t nat -S 2>/dev/null | grep -q "${subnet}"; then
    check_add "NAT/Masquerade Rule" pass
  else
    check_add "NAT/Masquerade Rule" fail \
      "No iptables NAT/MASQUERADE rule found for ${subnet}." \
      "Re-run 'cyferio-vpn install' to reapply firewall/NAT rules."
  fi
}

_diag_check_pki_files() {
  local pki_dir
  pki_dir="$(ovpn_pki_dir)"
  local -a missing=()
  local f
  for f in ca.crt "issued/server.crt" "private/server.key"; do
    [[ -f "${pki_dir}/${f}" ]] || missing+=("${f}")
  done
  [[ -f "${OVPN_CRL_PATH}" ]] || missing+=("${OVPN_CRL_PATH}")

  if [[ ${#missing[@]} -eq 0 ]]; then
    check_add "PKI Files Present" pass
  else
    local joined
    joined="$(IFS=', '; echo "${missing[*]}")"
    check_add "PKI Files Present" fail "Missing: ${joined}" \
      "Re-run 'cyferio-vpn install' to rebuild PKI, or restore from a backup."
  fi
}

_diag_check_database() {
  local ver
  ver="$(db_schema_version)"
  if [[ -n "${ver}" ]]; then
    check_add "Database Schema" pass
  else
    check_add "Database Schema" fail "No migrations recorded." "Run 'cyferio-vpn install' to initialize the database."
  fi
}

_diag_check_hooks_present() {
  local hooks_dir
  hooks_dir="$(ovpn_hooks_dir)"
  if [[ -x "${hooks_dir}/client-connect.sh" && -x "${hooks_dir}/client-disconnect.sh" ]]; then
    check_add "MAC Enforcement Hooks" pass
  else
    check_add "MAC Enforcement Hooks" fail \
      "client-connect.sh/client-disconnect.sh missing or not executable in ${hooks_dir}." \
      "Re-run 'cyferio-vpn install' to reinstall the hooks."
  fi
}

diagnose_run() {
  check_reset
  net_check_connectivity
  _diag_check_service
  _diag_check_port_listening
  net_check_ip_forwarding
  _diag_check_nat_rule
  net_check_firewall
  _diag_check_pki_files
  _diag_check_database
  _diag_check_hooks_present
}

# cmd_diagnose [--json]
cmd_diagnose() {
  require_root
  local json=0
  for arg in "$@"; do
    [[ "${arg}" == "--json" ]] && json=1
  done

  diagnose_run

  if [[ "${json}" -eq 1 ]]; then
    checks_print_json
  else
    checks_print_table
    echo "Overall: $(checks_overall)"
  fi
}

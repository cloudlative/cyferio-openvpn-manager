#!/usr/bin/env bash
# network.sh — pre-flight validation + the shared checks data model reused
# by `network detect`, `install`'s pre-flight banner, and (later) `audit`/
# `diagnose` — see docs/architecture/06-networking-validation.md.

if [[ -n "${__CYFERIO_NETWORK_LOADED:-}" ]]; then
  return 0
fi
__CYFERIO_NETWORK_LOADED=1

NETWORK_CHECKS=()
_CHECKS_US=$'\x1f'   # unit separator — never appears in our own messages

# check_reset — start a fresh check run.
check_reset() {
  NETWORK_CHECKS=()
}

# check_add NAME STATUS [MESSAGE] [REMEDIATION] — STATUS is pass|warning|fail.
check_add() {
  local name="$1" status="$2" message="${3:-}" remediation="${4:-}"
  NETWORK_CHECKS+=("${name}${_CHECKS_US}${status}${_CHECKS_US}${message}${_CHECKS_US}${remediation}")
}

# checks_overall — worst status across all recorded checks: fail > warning > pass.
checks_overall() {
  local worst="pass" entry status
  for entry in "${NETWORK_CHECKS[@]}"; do
    IFS="${_CHECKS_US}" read -r _ status _ _ <<<"${entry}"
    if [[ "${status}" == "fail" ]]; then
      echo "fail"
      return 0
    elif [[ "${status}" == "warning" ]]; then
      worst="warning"
    fi
  done
  echo "${worst}"
}

# checks_print_table — spec-format output (✓ / ⚠ + WARNING block / ✗ + FAIL block).
checks_print_table() {
  local entry name status message remediation
  for entry in "${NETWORK_CHECKS[@]}"; do
    IFS="${_CHECKS_US}" read -r name status message remediation <<<"${entry}"
    case "${status}" in
      pass) ui_ok "${name}" ;;
      warning)
        ui_warn "${name}"
        echo
        echo "WARNING"
        [[ -n "${message}" ]] && echo "${message}"
        if [[ -n "${remediation}" ]]; then
          echo
          echo "Recommended Action:"
          echo "${remediation}"
        fi
        echo
        ;;
      fail)
        ui_err "${name}"
        echo
        echo "FAIL"
        [[ -n "${message}" ]] && echo "${message}"
        if [[ -n "${remediation}" ]]; then
          echo
          echo "Recommended Action:"
          echo "${remediation}"
        fi
        echo
        ;;
    esac
  done
}

# checks_print_json — array of {name, status, message?, remediation?}.
checks_print_json() {
  local entry name status message remediation
  local json="[]"
  for entry in "${NETWORK_CHECKS[@]}"; do
    IFS="${_CHECKS_US}" read -r name status message remediation <<<"${entry}"
    json="$(jq -c \
      --arg name "${name}" --arg status "${status}" \
      --arg message "${message}" --arg remediation "${remediation}" \
      '. + [
        {name: $name, status: $status}
        + (if $message != "" then {message: $message} else {} end)
        + (if $remediation != "" then {remediation: $remediation} else {} end)
      ]' <<<"${json}")"
  done
  echo "${json}"
}

# --- individual pre-flight checks -------------------------------------

net_check_os() {
  local id="" version_id="" pretty="unknown OS"
  if [[ -f /etc/os-release ]]; then
    # /etc/os-release is a trusted, standard system file (not user input).
    local ID="" VERSION_ID="" PRETTY_NAME=""
    # shellcheck source=/dev/null
    source /etc/os-release
    id="${ID}"
    version_id="${VERSION_ID}"
    pretty="${PRETTY_NAME:-unknown OS}"
  fi
  case "${id}-${version_id}" in
    ubuntu-22.04|ubuntu-24.04|debian-12)
      check_add "Supported OS" pass
      ;;
    *)
      check_add "Supported OS" fail \
        "Detected ${pretty}. This tool supports Ubuntu 22.04 LTS, Ubuntu 24.04 LTS, and Debian 12." \
        "Run on a supported OS, or re-run with --force to proceed anyway (unsupported)."
      ;;
  esac
}

net_check_connectivity() {
  if curl -fsS -m5 -o /dev/null https://1.1.1.1 2>/dev/null \
     || curl -fsS -m5 -o /dev/null https://8.8.8.8 2>/dev/null; then
    check_add "Internet Connectivity" pass
  else
    check_add "Internet Connectivity" fail \
      "No outbound internet connectivity detected." \
      "Check network/DNS/firewall configuration before installing."
  fi
}

net_check_package_manager() {
  if ! is_command_available apt-get; then
    check_add "Package Manager" fail "apt-get not found." "This tool supports Debian/Ubuntu (apt) only."
    return
  fi
  if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
    check_add "Package Manager" warning \
      "Another process is holding the dpkg/apt lock." \
      "Wait for any running apt/unattended-upgrades process to finish, then retry."
  else
    check_add "Package Manager" pass
  fi
}

net_check_public_ip() {
  local ip
  ip="$(curl -fsS -m5 https://ifconfig.me 2>/dev/null || curl -fsS -m5 https://api.ipify.org 2>/dev/null || true)"
  if [[ -n "${ip}" ]]; then
    # shellcheck disable=SC2034  # consumed by lib/install.sh's cmd_network
    CYFERIO_PUBLIC_IP="${ip}"
    check_add "Public IP Detection" pass
  else
    check_add "Public IP Detection" warning \
      "Could not determine the public IP." \
      "Set it manually if the install proceeds and clients can't reach the server."
  fi
}

net_check_routing() {
  if [[ -n "$(ip route show default 2>/dev/null)" ]]; then
    check_add "Routing Validation" pass
  else
    check_add "Routing Validation" fail \
      "No default route found." \
      "Configure a default gateway before installing."
  fi
}

net_check_ip_forwarding() {
  local val
  val="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
  if [[ "${val}" == "1" ]]; then
    check_add "IP Forwarding Validation" pass
  else
    check_add "IP Forwarding Validation" warning \
      "net.ipv4.ip_forward is currently disabled." \
      "cyferio-vpn install enables and persists this automatically; no action needed unless running diagnose post-install."
  fi
}

net_check_port() {
  local port proto
  port="$(config_get vpn_port)"
  proto="$(config_get vpn_proto)"
  local flag="-tln"
  [[ "${proto}" == "udp" ]] && flag="-uln"
  if is_command_available ss && ss ${flag} 2>/dev/null | awk '{print $5}' | grep -q ":${port}\$"; then
    check_add "OpenVPN Port Validation" warning \
      "Port ${port}/${proto} appears already in use." \
      "Choose a different vpn_port in the config, or stop the conflicting service."
  else
    check_add "OpenVPN Port Validation" pass
  fi
}

net_check_firewall() {
  if is_command_available ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    check_add "Firewall Validation" warning \
      "ufw is active — install will add an allow rule for the OpenVPN port automatically." \
      "No action needed; re-run diagnose after install to confirm the rule was added."
  else
    check_add "Firewall Validation" pass
  fi
}

# net_run_preflight — run every check above plus cloud-provider detection
# and its per-provider checks (lib/cloud.sh). Populates NETWORK_CHECKS;
# call checks_print_table/checks_print_json/checks_overall after.
net_run_preflight() {
  check_reset
  net_check_os
  net_check_connectivity
  net_check_package_manager
  net_check_public_ip
  cloud_run_checks   # lib/cloud.sh — appends its own checks to NETWORK_CHECKS
  net_check_firewall
  net_check_routing
  net_check_ip_forwarding
  net_check_port
}

#!/usr/bin/env bash
# core.sh — bootstrap: strict mode, version, dispatch, error handling.
# Sourced once by bin/cyferio-vpn. Do not execute directly.

# shellcheck disable=SC2034  # consumed by other sourced modules
if [[ -n "${__CYFERIO_CORE_LOADED:-}" ]]; then
  return 0
fi
__CYFERIO_CORE_LOADED=1

set -Eeuo pipefail

CYFERIO_VERSION="1.0.0"
CYFERIO_NAME="Cyferio OpenVPN Manager"

# Runtime paths — overridable via env so tests/dev runs never touch real
# system paths. Defaults match docs/architecture/01-directory-structure.md.
CYFERIO_CONF_DIR="${CYFERIO_CONF_DIR:-/etc/cyferio}"
CYFERIO_DATA_DIR="${CYFERIO_DATA_DIR:-/var/lib/cyferio}"
CYFERIO_LOG_DIR="${CYFERIO_LOG_DIR:-/var/log/cyferio}"

# core_on_error — installed as the ERR trap by bin/cyferio-vpn. Prints a
# consistent, non-leaky error message instead of a raw bash stack dump.
core_on_error() {
  local exit_code=$1
  local line_no=$2
  echo "cyferio-vpn: error (exit ${exit_code}) at ${BASH_SOURCE[1]:-unknown}:${line_no}" >&2
  if declare -F log_error >/dev/null 2>&1; then
    log_error "core.error" "exit_code=${exit_code}" "line=${line_no}"
  fi
  exit "${exit_code}"
}

# core_usage — top-level help text.
core_usage() {
  cat <<EOF
${CYFERIO_NAME} v${CYFERIO_VERSION}

Usage:
  cyferio-vpn <command> [subcommand] [args...] [--json|--table|--plain]
  cyferio-vpn --interactive          Launch the menu-driven interface

Commands:
  install [--force]                         Install and configure OpenVPN
  uninstall [--force]                       Remove OpenVPN and all Cyferio state
  network detect [--json]                   Detect cloud provider, validate networking
  cert <create|revoke|list|status> ...      Manage certificates directly
  user <add|remove|enable|disable|get|list> USERNAME [--json]
                                            Manage VPN users
  profile <export|regenerate> USERNAME [--force]
                                            Export/regenerate a client .ovpn profile
  mac <add|remove|update|list|report> ...   Manage MAC-address device bindings
  status [--json]                           Show deployment health
  audit [--json]                            Run security/config audit
  diagnose [--json]                         Run connectivity/troubleshooting checks
  backup                                    Create a timestamped backup archive
  restore <archive> [--force]               Restore from a backup archive
  version                                   Print version
  help                                      Show this help

Run with no arguments to see this help; use --interactive for the menu-driven interface.

EOF
}

core_version() {
  echo "${CYFERIO_NAME} v${CYFERIO_VERSION}"
}

# _core_supports_color — gates the banner's cosmetic ANSI color only;
# never applied to command output (JSON/table/plain stay plain always).
# Honors NO_COLOR (https://no-color.org) and TERM=dumb, and checks a real
# terminal on stderr specifically — where the banner actually prints —
# not stdout, which may be redirected/piped independently of the tty.
_core_supports_color() {
  [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" && -t 2 ]]
}

# core_banner — printed on every execution per spec. Always to stderr, not
# stdout: this command's stdout may be piped or parsed as --json, and the
# banner must never end up mixed into machine-readable output.
core_banner() {
  local c_mark='' c_accent='' c_dim='' c_reset=''
  if _core_supports_color; then
    c_mark=$'\033[1;36m'    # bold cyan — the logo ring + wordmark (branding/assets/*.svg's #23D6C4)
    c_accent=$'\033[1;33m'  # bold yellow — the logo's center dot (branding's #F2A93B accent arc)
    c_dim=$'\033[2m'        # dim — the author line, secondary to the mark
    c_reset=$'\033[0m'
  fi

  # The logo mark ("◉", ring + center dot) approximates
  # branding/assets/github-avatar.svg's two-tone orbiting-arcs-plus-dot
  # mark at terminal-glyph scale — same idea, one character.
  cat >&2 <<EOF
${c_mark} ╭───╮    _____   _____ ___ ___ ___ ___
 │   │   / __\\ \\ / / __| __| _ \\_ _/ _ \\
 │ ${c_accent}◉${c_mark} │  | (__ \\ V /| _|| _||   /| | (_) |
 ╰───╯   \\___| |_| |_| |___|_|_\\___\\___/${c_reset}
EOF
  echo "${c_dim}Asif · LinkedIn: https://www.linkedin.com/in/cloudlative · +92-333-8885567${c_reset}" >&2
  echo >&2
}

# core_dispatch — top-level command router. Individual command
# implementations land in lib/<module>.sh as later phases build them; core.sh
# only knows about framework-level commands (help/version) plus a stub for
# anything not implemented yet, so Phase 1 fails loudly and clearly rather
# than silently doing nothing.
core_dispatch() {
  local cmd="${1:-}"

  case "$cmd" in
    ""|help|--help|-h)
      core_usage
      ;;
    version|--version|-v)
      core_version
      ;;
    --interactive)
      cmd_interactive
      ;;
    install)
      shift
      cmd_install "$@"
      ;;
    uninstall)
      shift
      cmd_uninstall "$@"
      ;;
    network)
      shift
      cmd_network "$@"
      ;;
    cert)
      shift
      cmd_cert "$@"
      ;;
    user)
      shift
      cmd_user "$@"
      ;;
    profile)
      shift
      cmd_profile "$@"
      ;;
    mac)
      shift
      cmd_mac "$@"
      ;;
    internal)
      # Plumbing for the installed client-connect/-disconnect hooks
      # (invoked as `nobody`, never by an operator) — deliberately absent
      # from core_usage's Commands list. See lib/macs.sh:cmd_internal.
      shift
      cmd_internal "$@"
      ;;
    status)
      shift
      cmd_status "$@"
      ;;
    audit)
      shift
      cmd_audit "$@"
      ;;
    diagnose)
      shift
      cmd_diagnose "$@"
      ;;
    backup)
      shift
      cmd_backup "$@"
      ;;
    restore)
      shift
      cmd_restore "$@"
      ;;
    *)
      echo "cyferio-vpn: unknown command '${cmd}'" >&2
      echo "Run 'cyferio-vpn help' for usage." >&2
      exit 1
      ;;
  esac
}

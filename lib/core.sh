#!/usr/bin/env bash
# core.sh — bootstrap: strict mode, version, dispatch, error handling.
# Sourced once by bin/cyferio-vpn. Do not execute directly.

# shellcheck disable=SC2034  # consumed by other sourced modules
if [[ -n "${__CYFERIO_CORE_LOADED:-}" ]]; then
  return 0
fi
__CYFERIO_CORE_LOADED=1

set -Eeuo pipefail

CYFERIO_VERSION="0.1.0"
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
  install [--force]              Install and configure OpenVPN
  uninstall [--force]            Remove OpenVPN and all Cyferio state
  user <add|remove|enable|disable|get|list> ...
  profile <export|regenerate> USERNAME
  mac <add|remove|update|list|report> ...
  status [--json]                Show deployment health
  audit [--json]                 Run security/config audit
  diagnose [--json]              Run connectivity/troubleshooting checks
  backup                         Create a timestamped backup archive
  restore <archive>              Restore from a backup archive
  network detect [--json]        Detect cloud provider and validate networking
  version                        Print version
  help                           Show this help

Run with no arguments to see this help; use --interactive for the menu-driven interface.

Docs: docs/architecture/  Website: https://cyferio.com
EOF
}

core_version() {
  echo "${CYFERIO_NAME} v${CYFERIO_VERSION}"
}

# core_banner — printed on every execution per spec. Always to stderr, not
# stdout: this command's stdout may be piped or parsed as --json, and the
# banner must never end up mixed into machine-readable output.
core_banner() {
  cat >&2 <<'EOF'
   ______      ____           _
  / ____/_  __/ __/__  ______(_)___
 / /   / / / / /_/ _ \/ ___/ / __ \
/ /___/ /_/ / __/  __/ /  / / /_/ /
\____/\__, /_/  \___/_/  /_/\____/
     /____/   OpenVPN Manager
EOF
  echo "v${CYFERIO_VERSION} · https://cyferio.com" >&2
  echo "Asif · LinkedIn: https://www.linkedin.com/in/cloudlative · +92-333-8885567" >&2
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
      echo "cyferio-vpn: the interactive menu is not implemented yet (coming in Phase 13)" >&2
      exit 2
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
    user|profile|mac|status|audit|diagnose|backup|restore)
      echo "cyferio-vpn: '${cmd}' is not implemented yet (coming in a later phase)" >&2
      exit 2
      ;;
    *)
      echo "cyferio-vpn: unknown command '${cmd}'" >&2
      echo "Run 'cyferio-vpn help' for usage." >&2
      exit 1
      ;;
  esac
}

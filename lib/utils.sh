#!/usr/bin/env bash
# utils.sh — shared helpers: validation, prompts, output, privilege checks.

if [[ -n "${__CYFERIO_UTILS_LOADED:-}" ]]; then
  return 0
fi
__CYFERIO_UTILS_LOADED=1

# die MESSAGE [EXIT_CODE] — print an error and exit. Use for user-facing
# fatal errors (bad input, missing prerequisite) rather than letting the
# ERR trap's raw exit-code message be the only signal.
die() {
  local message="$1"
  local code="${2:-1}"
  echo "cyferio-vpn: ${message}" >&2
  if declare -F log_error >/dev/null 2>&1; then
    log_error "fatal" "message=${message}"
  fi
  exit "${code}"
}

# require_root — fail fast and clearly for commands that mutate system
# state (install, user management, PKI). Read-only reporting commands
# should not call this.
require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "this command must be run as root (try: sudo cyferio-vpn ...)" 1
  fi
}

# is_command_available NAME
is_command_available() {
  command -v "$1" >/dev/null 2>&1
}

# validate_username USERNAME — allowlist only; blocks path traversal and
# shell metacharacters by construction (see docs/architecture/09-security-review.md).
validate_username() {
  local username="$1"
  [[ "${username}" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]
}

# validate_mac MAC — AA:BB:CC:DD:EE:FF form, case-insensitive on input.
validate_mac() {
  local mac="$1"
  [[ "${mac}" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]
}

# normalize_mac MAC — uppercase, for consistent storage/comparison.
normalize_mac() {
  local mac="$1"
  printf '%s' "${mac}" | tr '[:lower:]' '[:upper:]'
}

# confirm PROMPT — interactive yes/no; defaults to "no" on non-tty input
# (never assume consent when input can't actually be read).
confirm() {
  local prompt="$1"
  if [[ ! -t 0 ]]; then
    return 1
  fi
  local reply
  read -r -p "${prompt} [y/N] " reply
  [[ "${reply}" =~ ^[Yy]$ ]]
}

# ui_ok / ui_warn / ui_err — status-line output. Plain ASCII markers so
# output stays sane when piped or on a non-color terminal; color only when
# stdout is a tty.
_ui_color() {
  local code="$1"
  [[ -t 1 ]] && printf '\033[%sm' "${code}" || true
}
_ui_reset() {
  [[ -t 1 ]] && printf '\033[0m' || true
}

ui_ok()   { printf '%s✓ %s%s\n' "$(_ui_color 32)" "$1" "$(_ui_reset)"; }
ui_warn() { printf '%s⚠ %s%s\n' "$(_ui_color 33)" "$1" "$(_ui_reset)"; }
ui_err()  { printf '%s✗ %s%s\n' "$(_ui_color 31)" "$1" "$(_ui_reset)"; }

# netmask_to_prefix DOTTED_MASK — e.g. 255.255.255.0 -> 24. Used to build a
# CIDR string for iptables rules from the (dotted-decimal) vpn_subnet_mask
# config value.
netmask_to_prefix() {
  local mask="$1" IFS=. octet bits=0
  read -r -a octets <<<"${mask}"
  for octet in "${octets[@]}"; do
    case "${octet}" in
      255) bits=$((bits + 8)) ;;
      254) bits=$((bits + 7)) ;;
      252) bits=$((bits + 6)) ;;
      248) bits=$((bits + 5)) ;;
      240) bits=$((bits + 4)) ;;
      224) bits=$((bits + 3)) ;;
      192) bits=$((bits + 2)) ;;
      128) bits=$((bits + 1)) ;;
      0) ;;
      *) die "invalid netmask octet '${octet}' in '${mask}'" 1 ;;
    esac
  done
  echo "${bits}"
}

# sql_quote VALUE — escapes single quotes for embedding into a SQL literal.
# Callers should still validate input with validate_username/validate_mac
# etc. first — this is defense in depth, not the primary control (see
# docs/architecture/09-security-review.md).
sql_quote() {
  printf '%s' "$1" | sed "s/'/''/g"
}

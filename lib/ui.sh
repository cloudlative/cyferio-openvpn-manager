#!/usr/bin/env bash
# ui.sh — `cyferio-vpn --interactive`, the menu-driven interface for
# non-technical operators (Phase 12), per docs/architecture/00-overview.md's
# "Interactive menu via whiptail, falling back to a plain numbered prompt
# if neither whiptail nor dialog is present." Every menu action is a thin
# wrapper that collects input and calls the SAME cmd_* functions the CLI
# uses — no logic is duplicated here, so behavior (validation, auditing,
# confirm() prompts) is identical between `cyferio-vpn user add alice` and
# picking "Add user" from the menu.

if [[ -n "${__CYFERIO_UI_LOADED:-}" ]]; then
  return 0
fi
__CYFERIO_UI_LOADED=1

# _ui_has_whiptail — whiptail preferred (ubiquitous on Debian/Ubuntu
# minimal images per the design doc); dialog is NOT treated as a second
# whiptail-compatible backend here (different flag set) — only the plain
# fallback covers a box without either.
_ui_has_whiptail() {
  is_command_available whiptail
}

# _ui_menu TITLE PROMPT TAG1 DESC1 [TAG2 DESC2 ...] — draws a selection
# menu (whiptail, or a numbered plain-text prompt as fallback) and echoes
# ONLY the chosen tag on stdout, or an empty string on Cancel/ESC/EOF. A
# "0) Back" entry is added automatically — callers never pass it themselves.
#
# Every caller captures the result via `choice="$(_ui_menu ...)"` — command
# substitution grabs the WHOLE of a function's stdout, not just its last
# line. So the plain-fallback branch's menu banner/option list must be
# printed to stderr (same as `read -p`'s own prompt, and same as whiptail's
# dialog, which draws to /dev/tty and never touches stdout at all) —
# anything printed to stdout here silently becomes part of `choice` instead
# of being shown, and the caller's `case "${choice}" in 1) ... 2) ... esac`
# then matches nothing. (Caught via a real interactive session: every
# `case` fell straight to its `*)` branch because `choice` was the entire
# multi-line menu text with the typed digit stuck on the end, not the
# digit alone — see tests/integration/phase12-interactive.sh.)
#
# Also deliberately never propagates whiptail's/read's own exit status:
# under this project's strict mode (set -Eeuo pipefail, ERR trap installed
# by bin/cyferio-vpn), Cancel/ESC returns non-zero, and an unguarded
# `x=$(cmd)` would trip the ERR trap and kill the whole interactive
# session over a plain "user backed out of a menu" — same class of
# footgun as die()-inside-a-subshell documented elsewhere in this
# codebase, different trigger (a UI cancel, not a function's own logic).
_ui_menu() {
  local title="$1" prompt="$2"
  shift 2

  if _ui_has_whiptail; then
    local -a items=("$@" "0" "Back")
    local choice
    choice="$(whiptail --title "${title}" --menu "${prompt}" 20 72 12 "${items[@]}" 3>&1 1>&2 2>&3)" || choice=""
    echo "${choice}"
    return 0
  fi

  echo >&2
  echo "== ${title} ==" >&2
  [[ -n "${prompt}" ]] && echo "${prompt}" >&2
  local -a tags=() descs=()
  while [[ $# -gt 0 ]]; do
    tags+=("$1")
    descs+=("$2")
    shift 2
  done
  local i
  for i in "${!tags[@]}"; do
    printf '  %s) %s\n' "${tags[${i}]}" "${descs[${i}]}" >&2
  done
  echo "  0) Back" >&2
  local sel
  read -r -p "Choose: " sel || sel=""
  echo "${sel}"
}

# _ui_input TITLE PROMPT [DEFAULT] — echoes the entered text, or empty on
# Cancel/EOF. Same "never let a cancel propagate as a strict-mode error"
# guard as _ui_menu.
_ui_input() {
  local title="$1" prompt="$2" default="${3:-}"
  local val
  if _ui_has_whiptail; then
    val="$(whiptail --title "${title}" --inputbox "${prompt}" 10 72 "${default}" 3>&1 1>&2 2>&3)" || val=""
  else
    if [[ -n "${default}" ]]; then
      read -r -p "${prompt} [${default}]: " val || val=""
      [[ -z "${val}" ]] && val="${default}"
    else
      read -r -p "${prompt}: " val || val=""
    fi
  fi
  echo "${val}"
}

# _ui_pause — "press enter to continue" between an action's output and
# redrawing the next menu, so results aren't wiped off-screen immediately.
_ui_pause() {
  echo
  read -r -p "Press Enter to continue..." _ || true
}

# _ui_require FIELD_NAME VALUE — returns 1 (caller aborts the action) with
# a message when a required prompt was left empty/cancelled, instead of
# calling the underlying cmd_* with a blank argument and letting ITS
# die()-based usage message fire (still correct, just a worse UX from a
# menu the user just navigated, where "Cancelled." reads more naturally
# than a CLI usage string).
_ui_require() {
  local field="$1" value="$2"
  if [[ -z "${value}" ]]; then
    ui_warn "${field} is required — cancelled."
    return 1
  fi
  return 0
}

# _ui_run CMD [ARGS...] — runs a real cmd_* function in a subshell so its
# own die()/exit calls (and the ERR trap they can trigger) only end that
# subshell, not the whole interactive session — the menu loop always
# regains control afterward. Output goes straight to the real terminal
# (not captured), so ordinary stdout/stderr and confirm()'s tty prompt all
# behave exactly as they do from the CLI.
_ui_run() {
  echo
  local rc=0
  ( "$@" ) || rc=$?
  echo
  if [[ "${rc}" -ne 0 ]]; then
    ui_warn "Command exited with status ${rc}."
  fi
  _ui_pause
}

# ---------------------------------------------------------------------
# Submenus
# ---------------------------------------------------------------------

ui_user_menu() {
  while true; do
    local choice
    choice="$(_ui_menu "User Management" "" \
      1 "Add user" \
      2 "Remove user" \
      3 "Enable user" \
      4 "Disable user" \
      5 "Get user details" \
      6 "List users")"
    case "${choice}" in
      1)
        local u
        u="$(_ui_input "Add User" "Username")"
        _ui_require "Username" "${u}" && _ui_run cmd_user add "${u}"
        ;;
      2)
        local u
        u="$(_ui_input "Remove User" "Username")"
        _ui_require "Username" "${u}" && _ui_run cmd_user remove "${u}"
        ;;
      3)
        local u
        u="$(_ui_input "Enable User" "Username")"
        _ui_require "Username" "${u}" && _ui_run cmd_user enable "${u}"
        ;;
      4)
        local u
        u="$(_ui_input "Disable User" "Username")"
        _ui_require "Username" "${u}" && _ui_run cmd_user disable "${u}"
        ;;
      5)
        local u
        u="$(_ui_input "User Details" "Username")"
        _ui_require "Username" "${u}" && _ui_run cmd_user get "${u}"
        ;;
      6) _ui_run cmd_user list ;;
      *) return 0 ;;
    esac
  done
}

ui_cert_menu() {
  while true; do
    local choice
    choice="$(_ui_menu "Certificate Management" "" \
      1 "Create certificate" \
      2 "Revoke certificate" \
      3 "List certificates" \
      4 "Certificate status")"
    case "${choice}" in
      1)
        local n
        n="$(_ui_input "Create Certificate" "Name")"
        _ui_require "Name" "${n}" && _ui_run cmd_cert create "${n}"
        ;;
      2)
        local n
        n="$(_ui_input "Revoke Certificate" "Name")"
        _ui_require "Name" "${n}" && _ui_run cmd_cert revoke "${n}"
        ;;
      3) _ui_run cmd_cert list ;;
      4)
        local n
        n="$(_ui_input "Certificate Status" "Name")"
        _ui_require "Name" "${n}" && _ui_run cmd_cert status "${n}"
        ;;
      *) return 0 ;;
    esac
  done
}

ui_profile_menu() {
  while true; do
    local choice
    choice="$(_ui_menu "Profile Management" "" \
      1 "Export profile" \
      2 "Regenerate profile")"
    case "${choice}" in
      1)
        local u
        u="$(_ui_input "Export Profile" "Username")"
        _ui_require "Username" "${u}" && _ui_run cmd_profile export "${u}"
        ;;
      2)
        local u
        u="$(_ui_input "Regenerate Profile" "Username")"
        _ui_require "Username" "${u}" && _ui_run cmd_profile regenerate "${u}"
        ;;
      *) return 0 ;;
    esac
  done
}

ui_mac_menu() {
  while true; do
    local choice
    choice="$(_ui_menu "MAC Address Management" "" \
      1 "Add MAC" \
      2 "Remove MAC" \
      3 "Update MAC" \
      4 "List MACs for a user" \
      5 "MAC report (all users)")"
    case "${choice}" in
      1)
        local u m
        u="$(_ui_input "Add MAC" "Username")"
        _ui_require "Username" "${u}" || continue
        m="$(_ui_input "Add MAC" "MAC address (AA:BB:CC:DD:EE:FF)")"
        _ui_require "MAC address" "${m}" && _ui_run cmd_mac add "${u}" "${m}"
        ;;
      2)
        local u m
        u="$(_ui_input "Remove MAC" "Username")"
        _ui_require "Username" "${u}" || continue
        m="$(_ui_input "Remove MAC" "MAC address")"
        _ui_require "MAC address" "${m}" && _ui_run cmd_mac remove "${u}" "${m}"
        ;;
      3)
        local u old new
        u="$(_ui_input "Update MAC" "Username")"
        _ui_require "Username" "${u}" || continue
        old="$(_ui_input "Update MAC" "Current MAC address")"
        _ui_require "Current MAC address" "${old}" || continue
        new="$(_ui_input "Update MAC" "New MAC address")"
        _ui_require "New MAC address" "${new}" && _ui_run cmd_mac update "${u}" "${old}" "${new}"
        ;;
      4)
        local u
        u="$(_ui_input "List MACs" "Username")"
        _ui_require "Username" "${u}" && _ui_run cmd_mac list "${u}"
        ;;
      5) _ui_run cmd_mac report ;;
      *) return 0 ;;
    esac
  done
}

ui_backup_menu() {
  while true; do
    local choice
    choice="$(_ui_menu "Backup & Restore" "" \
      1 "Create backup" \
      2 "Restore from archive")"
    case "${choice}" in
      1) _ui_run cmd_backup ;;
      2)
        local a
        a="$(_ui_input "Restore" "Path to backup archive (.tar.gz)")"
        _ui_require "Archive path" "${a}" && _ui_run cmd_restore "${a}"
        ;;
      *) return 0 ;;
    esac
  done
}

# ---------------------------------------------------------------------
# Top-level menu
# ---------------------------------------------------------------------

ui_main_menu() {
  while true; do
    local choice
    choice="$(_ui_menu "${CYFERIO_NAME} v${CYFERIO_VERSION}" "Select an action:" \
      1 "Install OpenVPN server" \
      2 "User management" \
      3 "Certificate management" \
      4 "Profile management" \
      5 "MAC address management" \
      6 "Status" \
      7 "Audit" \
      8 "Diagnose" \
      9 "Backup & restore" \
      10 "Network detection" \
      11 "Uninstall")"
    case "${choice}" in
      1) _ui_run cmd_install ;;
      2) ui_user_menu ;;
      3) ui_cert_menu ;;
      4) ui_profile_menu ;;
      5) ui_mac_menu ;;
      6) _ui_run cmd_status ;;
      7) _ui_run cmd_audit ;;
      8) _ui_run cmd_diagnose ;;
      9) ui_backup_menu ;;
      10) _ui_run cmd_network detect ;;
      11) _ui_run cmd_uninstall ;;
      *) echo "Goodbye."; return 0 ;;
    esac
  done
}

# cmd_interactive — entry point for `cyferio-vpn --interactive`. Menus and
# prompts are meaningless without a real terminal on both ends (whiptail
# draws to /dev/tty; the plain fallback's `read` needs a readable stdin),
# so this fails fast and clearly rather than hanging or silently no-op'ing
# under a script/CI/piped invocation.
cmd_interactive() {
  if [[ ! -t 0 || ! -t 1 ]]; then
    die "--interactive requires an interactive terminal (stdin/stdout must both be a tty)" 1
  fi
  ui_main_menu
}

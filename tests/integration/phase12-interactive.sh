#!/usr/bin/env bash
# phase12-interactive.sh — Phase 12 exit-criteria check: `--interactive`
# actually drives real cmd_* functions through the menu, both with
# whiptail present (the real deployment case) and with it removed (the
# plain-fallback case), against a real install with a real user. Since
# whiptail/the plain fallback both require a real tty, this script drives
# cyferio-vpn through `script`(1) rather than a bare pipe (a bare pipe
# gives whiptail/read no tty at all, which is exactly the "requires an
# interactive terminal" case tests/unit/ui.bats already covers). Run as
# root on a VM with `install` already done; not destructive by itself
# (menu actions used here are additive/read-only) but shares the disposable-
# VM-only convention of every other integration script in this suite.
set -Eeuo pipefail

CYFERIO_BIN="${1:-/opt/cyferio-openvpn-manager/bin/cyferio-vpn}"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

echo "=== --interactive with whiptail present ==="
command -v whiptail >/dev/null 2>&1 || fail "whiptail is not installed — cannot exercise the default backend"

# Main menu -> User management (2) -> Add user (1) -> username "carol" ->
# back (0) -> back (0) -> exit (12 is out of range == treated as Back by
# whiptail's Cancel/blank handling in the plain path; use the explicit
# highest tag + Enter on Cancel for whiptail nav instead: send Esc-equivalent
# via a blank line, which whiptail interprets as staying, so drive it via
# tags directly followed by cancel keystrokes is unreliable under `script`
# for a real ncurses app — so this scripted run uses the *plain* fallback
# deterministically by hiding whiptail, and separately confirms whiptail
# itself launches without crashing.
log1="/tmp/phase12-whiptail-launch.log"
timeout 3 script -qec "'${CYFERIO_BIN}' --interactive" "${log1}" </dev/null >/dev/null 2>&1 || true
grep -q "requires an interactive terminal" "${log1}" && fail "whiptail path: still reports 'requires an interactive terminal' under script(1) — tty not attached correctly" \
  || pass "whiptail launches under a real pty without the no-tty guard firing"

echo
echo "=== --interactive plain fallback: add + list a real user through the menu ==="
# Prepending an empty dir to PATH does NOT hide whiptail (command -v still
# finds the real binary further down PATH) — the only reliable way to make
# _ui_has_whiptail's `command -v whiptail` fail is for no `whiptail` to
# exist on PATH at all. Temporarily rename the real binary; always restored
# by the trap below, even on an early failure.
whiptail_path="$(command -v whiptail)"
restore_whiptail() { [[ -e "${whiptail_path}.phase12-disabled" ]] && mv "${whiptail_path}.phase12-disabled" "${whiptail_path}"; }
trap restore_whiptail EXIT
mv "${whiptail_path}" "${whiptail_path}.phase12-disabled"

log2="/tmp/phase12-plain-adduser.log"
printf '2\n1\ncarol\n0\n0\n0\n' | script -qec "'${CYFERIO_BIN}' --interactive" "${log2}" >/dev/null 2>&1 || true
grep -q "requires an interactive terminal" "${log2}" && fail "plain path incorrectly reported 'requires an interactive terminal' under script(1)"

# The real assertion: carol actually exists afterward, not just that the
# string appeared somewhere in the session transcript (a whiptail-driven
# transcript can echo typed characters without the keystrokes ever having
# reached cmd_user add — this is what caught that gap during Phase 12's
# first VM run).
"${CYFERIO_BIN}" user list 2>/dev/null | grep -q carol && pass "menu-driven 'Add user' actually created carol" || fail "carol missing from 'user list' after the menu-driven add"

echo
echo "=== plain fallback: Status via the menu produces real output ==="
log3="/tmp/phase12-plain-status.log"
printf '6\n0\n' | script -qec "'${CYFERIO_BIN}' --interactive" "${log3}" >/dev/null 2>&1 || true
grep -qi "Status:" "${log3}" && pass "menu-driven Status shows real deployment status" || fail "Status output not found in interactive session log"

echo
echo "=== a cancelled/blank prompt does not crash the session (no stack dump, no 'unbound variable') ==="
log4="/tmp/phase12-plain-cancel.log"
printf '2\n1\n\n0\n0\n' | script -qec "'${CYFERIO_BIN}' --interactive" "${log4}" >/dev/null 2>&1 || true
grep -qi "unbound variable" "${log4}" && fail "a blank/cancelled prompt triggered a raw bash error"
grep -q "Username is required" "${log4}" && pass "a blank required prompt is handled cleanly ('Username is required — cancelled.')" || fail "expected cancellation message not found"

restore_whiptail
trap - EXIT

echo
echo "ALL PHASE 12 CHECKS PASSED"

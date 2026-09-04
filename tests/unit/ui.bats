#!/usr/bin/env bats
# ui.bats — lib/ui.sh's building blocks (_ui_menu/_ui_input/_ui_require/
# _ui_run/cmd_interactive), forced into the plain-fallback code path
# (_ui_has_whiptail stubbed to fail) so these tests are deterministic
# regardless of whether whiptail happens to be installed on the runner.
# Full menu navigation itself needs a real tty and whiptail/plain choice
# at runtime — covered by tests/integration/phase12-interactive.sh, not
# here.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  source "${REPO_ROOT}/lib/core.sh"
  source "${REPO_ROOT}/lib/logger.sh"
  source "${REPO_ROOT}/lib/utils.sh"
  source "${REPO_ROOT}/lib/ui.sh"

  log_error() { :; }
  _ui_has_whiptail() { return 1; }
}

@test "_ui_menu (plain) returns the tag the user typed" {
  run bash -c '
    source "'"${REPO_ROOT}"'/lib/core.sh"
    source "'"${REPO_ROOT}"'/lib/logger.sh"
    source "'"${REPO_ROOT}"'/lib/utils.sh"
    source "'"${REPO_ROOT}"'/lib/ui.sh"
    _ui_has_whiptail() { return 1; }
    _ui_menu "Test Menu" "pick one" 1 "First" 2 "Second" <<< "2"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"2"* ]]
}

@test "_ui_menu (plain) lists every option plus an auto-added Back entry" {
  run bash -c '
    source "'"${REPO_ROOT}"'/lib/core.sh"
    source "'"${REPO_ROOT}"'/lib/logger.sh"
    source "'"${REPO_ROOT}"'/lib/utils.sh"
    source "'"${REPO_ROOT}"'/lib/ui.sh"
    _ui_has_whiptail() { return 1; }
    _ui_menu "Test Menu" "pick one" 1 "First" 2 "Second" <<< "0"
  '
  [[ "$output" == *"1) First"* ]]
  [[ "$output" == *"2) Second"* ]]
  [[ "$output" == *"0) Back"* ]]
}

@test "_ui_menu (plain) returns empty on blank input, not an error" {
  run _ui_menu "Test Menu" "pick one" 1 "First" <<< ""
  [ "$status" -eq 0 ]
}

@test "_ui_input (plain) returns the entered text" {
  run _ui_input "Add User" "Username" <<< "alice"
  [ "$status" -eq 0 ]
  [[ "$output" == *"alice"* ]]
}

@test "_ui_input (plain) falls back to the given default on empty input" {
  run _ui_input "Add User" "Username" "bob" <<< ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"bob"* ]]
}

@test "_ui_require rejects an empty value with a warning, accepts a non-empty one" {
  run _ui_require "Username" ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"Username is required"* ]]

  run _ui_require "Username" "alice"
  [ "$status" -eq 0 ]
}

@test "_ui_run contains a failing command's exit/die to the subshell — the menu loop keeps going" {
  fails_hard() { die "boom" 7; }
  run bash -c '
    source "'"${REPO_ROOT}"'/lib/core.sh"
    source "'"${REPO_ROOT}"'/lib/logger.sh"
    source "'"${REPO_ROOT}"'/lib/utils.sh"
    source "'"${REPO_ROOT}"'/lib/ui.sh"
    fails_hard() { die "boom" 7; }
    _ui_run fails_hard
    echo "STILL_RUNNING_AFTER_UI_RUN"
  ' <<< ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"boom"* ]]
  [[ "$output" == *"Command exited with status 7"* ]]
  [[ "$output" == *"STILL_RUNNING_AFTER_UI_RUN"* ]]
}

@test "_ui_run passes through a successful command's output cleanly" {
  succeeds() { echo "hello from cmd"; }
  run bash -c '
    source "'"${REPO_ROOT}"'/lib/core.sh"
    source "'"${REPO_ROOT}"'/lib/logger.sh"
    source "'"${REPO_ROOT}"'/lib/utils.sh"
    source "'"${REPO_ROOT}"'/lib/ui.sh"
    succeeds() { echo "hello from cmd"; }
    _ui_run succeeds
  ' <<< ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello from cmd"* ]]
  [[ "$output" != *"exited with status"* ]]
}

@test "cmd_interactive refuses to run without a real terminal" {
  run cmd_interactive </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires an interactive terminal"* ]]
}

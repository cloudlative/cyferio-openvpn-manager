#!/usr/bin/env bats
# cli.bats — bin/cyferio-vpn framework-level command routing.

setup() {
  export REPO_ROOT
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export TMP_HOME
  TMP_HOME="$(mktemp -d)"
  export CYFERIO_CONF_DIR="${TMP_HOME}/etc"
  export CYFERIO_DATA_DIR="${TMP_HOME}/var"
  export CYFERIO_LOG_DIR="${TMP_HOME}/log"
}

teardown() {
  rm -rf "${TMP_HOME}"
}

@test "version prints name and version" {
  run "${REPO_ROOT}/bin/cyferio-vpn" version
  [ "$status" -eq 0 ]
  # banner (spec-mandated, printed on every execution) precedes this on
  # stderr, which `run` merges into $output — so check containment, not a
  # prefix match.
  [[ "$output" == *"Cyferio OpenVPN Manager v"* ]]
}

@test "help prints usage" {
  run "${REPO_ROOT}/bin/cyferio-vpn" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"cyferio-vpn <command>"* ]]
}

@test "no arguments prints usage" {
  run "${REPO_ROOT}/bin/cyferio-vpn"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "--interactive is recognized and requires a real terminal" {
  # bats' `run` never attaches a controlling tty, so cmd_interactive's own
  # guard is what fires here — the same thing every non-interactive
  # invocation (CI, a script, a pipe) actually hits. Full menu-navigation
  # behavior needs a real tty and is exercised by the integration test
  # instead (tests/integration/phase12-interactive.sh).
  run "${REPO_ROOT}/bin/cyferio-vpn" --interactive
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires an interactive terminal"* ]]
}

@test "unknown command exits 1 with a clear message" {
  run "${REPO_ROOT}/bin/cyferio-vpn" frobnicate
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown command 'frobnicate'"* ]]
}

@test "--interactive exits cleanly, not a stack dump" {
  run "${REPO_ROOT}/bin/cyferio-vpn" --interactive
  [ "$status" -eq 1 ]
  [[ "$output" != *"unbound variable"* ]]
}

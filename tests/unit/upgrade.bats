#!/usr/bin/env bats
# upgrade.bats — lib/upgrade.sh: version comparison, the CYFERIO_BUNDLED
# guard, --check reporting, and the download/sanity-check/atomic-replace
# path. Network access (_upgrade_fetch_latest) is stubbed directly, same
# convention status.bats uses for vpn_backend_server_status — no real
# curl call happens in this suite.

bats_require_minimum_version 1.5.0  # `run --separate-stderr`, used below

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  source "${REPO_ROOT}/lib/core.sh"
  source "${REPO_ROOT}/lib/logger.sh"
  source "${REPO_ROOT}/lib/utils.sh"
  source "${REPO_ROOT}/lib/upgrade.sh"

  TMP_HOME="$(mktemp -d)"
  export CYFERIO_LOG_DIR="${TMP_HOME}/log"
  export CYFERIO_BUNDLED=1
  export CYFERIO_SELF_PATH="${TMP_HOME}/cyferio-vpn"
  printf '#!/usr/bin/env bash\necho "old v1.0.0"\n' >"${CYFERIO_SELF_PATH}"
  chmod +x "${CYFERIO_SELF_PATH}"

  require_root() { :; }
  log_info() { :; }  # avoid log lines mixing into --json assertions, same
                     # convention backup.bats uses (logger.sh always also
                     # echoes to stderr, which `run` merges into $output)
}

teardown() {
  rm -rf "${TMP_HOME}"
}

@test "_upgrade_version_gt: newer > older" {
  run _upgrade_version_gt "1.1.0" "1.0.0"
  [ "$status" -eq 0 ]
}

@test "_upgrade_version_gt: equal versions are not greater" {
  run _upgrade_version_gt "1.0.0" "1.0.0"
  [ "$status" -eq 1 ]
}

@test "_upgrade_version_gt: older is not greater than newer" {
  run _upgrade_version_gt "1.0.0" "1.1.0"
  [ "$status" -eq 1 ]
}

@test "_upgrade_version_gt: numeric compare, not lexical (1.10.0 > 1.9.0)" {
  run _upgrade_version_gt "1.10.0" "1.9.0"
  [ "$status" -eq 0 ]
  run _upgrade_version_gt "1.9.0" "1.10.0"
  [ "$status" -eq 1 ]
}

@test "cmd_upgrade refuses outside the single-file bundle" {
  unset CYFERIO_BUNDLED
  run cmd_upgrade --check
  [ "$status" -eq 3 ]
  [[ "$output" == *"multi-file dev checkout"* ]]
  [[ "$output" == *"git pull"* ]]
}

@test "cmd_upgrade dies clearly when the release check fails" {
  _upgrade_fetch_latest() { return 1; }
  run cmd_upgrade --check
  [ "$status" -eq 4 ]
  [[ "$output" == *"could not check for updates"* ]]
}

@test "cmd_upgrade --check reports up to date when latest == current" {
  _upgrade_fetch_latest() { _UPGRADE_LATEST_VERSION="${CYFERIO_VERSION}"; _UPGRADE_LATEST_URL="https://example.invalid/x"; }
  run cmd_upgrade --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"Already up to date (v${CYFERIO_VERSION})."* ]]
}

@test "cmd_upgrade --check reports an available update" {
  _upgrade_fetch_latest() { _UPGRADE_LATEST_VERSION="9.9.9"; _UPGRADE_LATEST_URL="https://example.invalid/x"; }
  run cmd_upgrade --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"Update available: v${CYFERIO_VERSION} -> v9.9.9"* ]]
}

@test "cmd_upgrade --check --json emits the current/latest/update_available shape" {
  _upgrade_fetch_latest() { _UPGRADE_LATEST_VERSION="9.9.9"; _UPGRADE_LATEST_URL="https://example.invalid/x"; }
  run cmd_upgrade --check --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg cur "${CYFERIO_VERSION}" \
    '.current == $cur and .latest == "9.9.9" and .update_available == true' >/dev/null
}

@test "cmd_upgrade with no flags, already up to date: no-op, no root/confirm needed" {
  _upgrade_fetch_latest() { _UPGRADE_LATEST_VERSION="${CYFERIO_VERSION}"; _UPGRADE_LATEST_URL="https://example.invalid/x"; }
  run cmd_upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"Already up to date"* ]]
  [[ "$(cat "${CYFERIO_SELF_PATH}")" == *"old v1.0.0"* ]]
}

@test "cmd_upgrade --force downloads, sanity-checks, and atomically replaces the self path" {
  _upgrade_fetch_latest() { _UPGRADE_LATEST_VERSION="9.9.9"; _UPGRADE_LATEST_URL="https://example.invalid/x"; }
  curl() {
    local out=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "-o" ]]; then out="$2"; fi
      shift
    done
    printf '#!/usr/bin/env bash\necho "new v9.9.9"\n' >"${out}"
    return 0
  }
  export -f curl
  run cmd_upgrade --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"Upgraded: v${CYFERIO_VERSION} -> v9.9.9"* ]]
  [[ "$(cat "${CYFERIO_SELF_PATH}")" == *"new v9.9.9"* ]]
}

@test "cmd_upgrade --force --json reports the from/to versions" {
  _upgrade_fetch_latest() { _UPGRADE_LATEST_VERSION="9.9.9"; _UPGRADE_LATEST_URL="https://example.invalid/x"; }
  curl() {
    local out=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "-o" ]]; then out="$2"; fi
      shift
    done
    printf '#!/usr/bin/env bash\necho hi\n' >"${out}"
    return 0
  }
  export -f curl
  # --separate-stderr: the "Downloading..." progress line correctly goes
  # to stderr (this command's stdout may be parsed as --json), and bats'
  # $output merges both by default — split them so $output is pure JSON.
  run --separate-stderr cmd_upgrade --force --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg cur "${CYFERIO_VERSION}" \
    '.upgraded == true and .from == $cur and .to == "9.9.9"' >/dev/null
}

@test "cmd_upgrade without --force cancels on a declined confirmation, leaving the binary untouched" {
  _upgrade_fetch_latest() { _UPGRADE_LATEST_VERSION="9.9.9"; _UPGRADE_LATEST_URL="https://example.invalid/x"; }
  curl() { return 1; }  # must never be reached — cancel happens before any download
  export -f curl
  confirm() { return 1; }  # simulates the user answering "no" at the prompt
  run cmd_upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"Upgrade cancelled."* ]]
  [[ "$(cat "${CYFERIO_SELF_PATH}")" == *"old v1.0.0"* ]]
}

@test "cmd_upgrade aborts on a download failure, leaving the binary untouched" {
  _upgrade_fetch_latest() { _UPGRADE_LATEST_VERSION="9.9.9"; _UPGRADE_LATEST_URL="https://example.invalid/x"; }
  curl() { return 22; }
  export -f curl
  run cmd_upgrade --force
  [ "$status" -eq 6 ]
  [[ "$output" == *"download failed"* ]]
  [[ "$(cat "${CYFERIO_SELF_PATH}")" == *"old v1.0.0"* ]]
}

@test "cmd_upgrade rejects a downloaded file that isn't a valid script, leaving the binary untouched" {
  _upgrade_fetch_latest() { _UPGRADE_LATEST_VERSION="9.9.9"; _UPGRADE_LATEST_URL="https://example.invalid/x"; }
  curl() {
    local out=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "-o" ]]; then out="$2"; fi
      shift
    done
    echo "<html>not a script</html>" >"${out}"
    return 0
  }
  export -f curl
  run cmd_upgrade --force
  [ "$status" -eq 6 ]
  [[ "$output" == *"does not look like a valid cyferio-vpn build"* ]]
  [[ "$(cat "${CYFERIO_SELF_PATH}")" == *"old v1.0.0"* ]]
}

@test "_upgrade_print_if_available stays silent when the update check fails" {
  _upgrade_fetch_latest() { return 1; }
  run _upgrade_print_if_available
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_upgrade_print_if_available stays silent when already up to date" {
  _upgrade_fetch_latest() { _UPGRADE_LATEST_VERSION="${CYFERIO_VERSION}"; }
  run _upgrade_print_if_available
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_upgrade_print_if_available prints a hint when a newer version exists" {
  _upgrade_fetch_latest() { _UPGRADE_LATEST_VERSION="9.9.9"; }
  run _upgrade_print_if_available
  [ "$status" -eq 0 ]
  [[ "$output" == *"A newer version (v9.9.9) is available"* ]]
  [[ "$output" == *"cyferio-vpn upgrade"* ]]
}

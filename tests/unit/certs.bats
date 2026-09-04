#!/usr/bin/env bats
# certs.bats — lib/certs.sh guard functions and status formatting.
#
# These specifically regression-test a `set -e` footgun: a bare
# `[[ cond ]] && action` as the LAST statement of a function returns
# non-zero (and aborts the caller under `set -Eeuo pipefail`) whenever
# cond is false — which is exactly the common case for these two
# functions (a non-"server" name; a non-revoked certificate).

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  source "${REPO_ROOT}/lib/core.sh"
  source "${REPO_ROOT}/lib/logger.sh"
  source "${REPO_ROOT}/lib/utils.sh"
  source "${REPO_ROOT}/lib/config.sh"
  # certs.sh only needs die/ui_ok/etc from utils.sh at source time; it
  # doesn't call ovpn_* or db_* functions until its commands run, so it
  # can be sourced standalone for these guard-function-level tests.
  source "${REPO_ROOT}/lib/certs.sh"
}

@test "_cert_reserved_name_guard does not abort for a normal name" {
  run _cert_reserved_name_guard "alice"
  [ "$status" -eq 0 ]
}

@test "_cert_reserved_name_guard blocks 'server' with exit 1" {
  run _cert_reserved_name_guard "server"
  [ "$status" -eq 1 ]
  [[ "$output" == *"managed by install/uninstall"* ]]
}

@test "_cert_status_label maps known codes" {
  [ "$(_cert_status_label V)" = "valid" ]
  [ "$(_cert_status_label R)" = "revoked" ]
  [ "$(_cert_status_label E)" = "expired" ]
  [ "$(_cert_status_label X)" = "unknown" ]
}

# Regression test for the exact bug the VM integration run caught: with a
# non-revoked cert (the common case), cert_status's table branch used to
# end on a bare `[[ -n "$revoked" ]] && echo ...` as its LAST statement,
# which returns 1 under `set -e` whenever $revoked is empty — aborting
# the whole command with a spurious error for what should be success.
@test "cert_status table output succeeds for a non-revoked cert (regression)" {
  require_root() { :; }
  _cert_require_pki() { :; }
  vpn_backend_list_clients() {
    echo 'V|2027-01-01T00:00:00Z||01|alice'
  }

  run cert_status alice
  [ "$status" -eq 0 ]
  [[ "$output" == *"Status:     valid"* ]]
  [[ "$output" != *"Revoked at:"* ]]
}

@test "cert_status table output includes revoked_at for a revoked cert" {
  require_root() { :; }
  _cert_require_pki() { :; }
  vpn_backend_list_clients() {
    echo 'R|2027-01-01T00:00:00Z|2026-06-01T00:00:00Z|02|bob'
  }

  run cert_status bob
  [ "$status" -eq 0 ]
  [[ "$output" == *"Status:     revoked"* ]]
  [[ "$output" == *"Revoked at: 2026-06-01T00:00:00Z"* ]]
}

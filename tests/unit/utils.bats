#!/usr/bin/env bats
# utils.bats — lib/utils.sh validation helpers.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  source "${REPO_ROOT}/lib/core.sh"
  source "${REPO_ROOT}/lib/logger.sh"
  source "${REPO_ROOT}/lib/utils.sh"
}

@test "validate_username accepts a normal name" {
  run validate_username "john"
  [ "$status" -eq 0 ]
}

@test "validate_username accepts hyphens and underscores" {
  run validate_username "john_doe-2"
  [ "$status" -eq 0 ]
}

@test "validate_username rejects path traversal" {
  run validate_username "../../etc/passwd"
  [ "$status" -ne 0 ]
}

@test "validate_username rejects shell metacharacters" {
  run validate_username 'john; rm -rf /'
  [ "$status" -ne 0 ]
}

@test "validate_username rejects empty string" {
  run validate_username ""
  [ "$status" -ne 0 ]
}

@test "validate_mac accepts a well-formed address" {
  run validate_mac "AA:BB:CC:DD:EE:FF"
  [ "$status" -eq 0 ]
}

@test "validate_mac accepts lowercase" {
  run validate_mac "aa:bb:cc:dd:ee:ff"
  [ "$status" -eq 0 ]
}

@test "validate_mac rejects malformed address" {
  run validate_mac "AA:BB:CC:DD:EE"
  [ "$status" -ne 0 ]
}

@test "validate_mac rejects non-hex characters" {
  run validate_mac "GG:BB:CC:DD:EE:FF"
  [ "$status" -ne 0 ]
}

@test "normalize_mac uppercases" {
  result="$(normalize_mac "aa:bb:cc:dd:ee:ff")"
  [ "$result" = "AA:BB:CC:DD:EE:FF" ]
}

@test "sql_quote escapes single quotes" {
  result="$(sql_quote "o'brien")"
  [ "$result" = "o''brien" ]
}

@test "netmask_to_prefix converts /24" {
  result="$(netmask_to_prefix "255.255.255.0")"
  [ "$result" = "24" ]
}

@test "netmask_to_prefix converts /16" {
  result="$(netmask_to_prefix "255.255.0.0")"
  [ "$result" = "16" ]
}

@test "netmask_to_prefix converts /25" {
  result="$(netmask_to_prefix "255.255.255.128")"
  [ "$result" = "25" ]
}

@test "netmask_to_prefix rejects an invalid octet" {
  run netmask_to_prefix "255.255.255.7"
  [ "$status" -ne 0 ]
}

@test "asn1_to_iso converts an EasyRSA index.txt timestamp" {
  result="$(asn1_to_iso "260904120000Z")"
  [ "$result" = "2026-09-04T12:00:00Z" ]
}

@test "asn1_to_iso passes through an unparseable value unchanged" {
  result="$(asn1_to_iso "")"
  [ "$result" = "" ]
}

@test "current_actor prefers SUDO_USER over the current user" {
  result="$(SUDO_USER=asif current_actor)"
  [ "$result" = "asif" ]
}

@test "current_actor falls back to the current user when SUDO_USER is unset" {
  result="$(env -u SUDO_USER bash -c 'source '"${BATS_TEST_DIRNAME}"'/../../lib/core.sh; source '"${BATS_TEST_DIRNAME}"'/../../lib/logger.sh; source '"${BATS_TEST_DIRNAME}"'/../../lib/utils.sh; current_actor')"
  [ -n "$result" ]
}

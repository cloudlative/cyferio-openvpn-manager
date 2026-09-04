#!/usr/bin/env bats
# macs.bats — lib/macs.sh, with database.sh stubbed out (pure logic:
# validation, normalization, duplicate-prevention decisions, and the
# tree-formatted `mac list` output).

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  source "${REPO_ROOT}/lib/core.sh"
  source "${REPO_ROOT}/lib/logger.sh"
  source "${REPO_ROOT}/lib/utils.sh"
  source "${REPO_ROOT}/lib/config.sh"
  source "${REPO_ROOT}/lib/macs.sh"

  # Stub the DB layer: one user "john" (id 1) with no MACs yet, and a
  # single existing MAC AA:BB:CC:DD:EE:01 already owned by "sara" (id 2)
  # — enough state for validation/duplicate-prevention tests without a
  # real sqlite DB.
  db_user_get() {
    case "$1" in
      john) echo "1|john|active||2026-01-01 00:00:00|2026-01-01 00:00:00" ;;
      sara) echo "2|sara|active||2026-01-01 00:00:00|2026-01-01 00:00:00" ;;
      *) : ;;
    esac
  }
  db_mac_find_owner() {
    [[ "$1" == "AA:BB:CC:DD:EE:01" ]] && echo "sara"
  }
  db_mac_get() { :; }
  db_mac_insert() { :; }
  db_mac_delete() { :; }
  db_mac_update() { :; }
  db_mac_list() { :; }
  db_audit_log() { :; }
  current_actor() { echo "tester"; }
  require_root() { :; }
}

@test "mac_add rejects an invalid MAC" {
  run mac_add john "not-a-mac"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid MAC address"* ]]
}

@test "mac_add rejects an unknown user" {
  run mac_add nobody "AA:BB:CC:DD:EE:02"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such user"* ]]
}

@test "mac_add rejects a MAC already owned by a different user" {
  run mac_add john "AA:BB:CC:DD:EE:01"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already registered to user 'sara'"* ]]
}

@test "mac_add normalizes a lowercase MAC before checking/inserting" {
  db_mac_insert() { echo "INSERTED:$1:$2"; }
  run mac_add john "aa:bb:cc:dd:ee:02"
  [ "$status" -eq 0 ]
  [[ "$output" == *"AA:BB:CC:DD:EE:02"* ]]
}

@test "mac_remove rejects a MAC not registered to the user" {
  run mac_remove john "AA:BB:CC:DD:EE:99"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not registered to 'john'"* ]]
}

@test "mac_update rejects when the new MAC belongs to someone else" {
  db_mac_get() {
    [[ "$2" == "AA:BB:CC:DD:EE:02" ]] && echo "AA:BB:CC:DD:EE:02"
  }
  run mac_update john "AA:BB:CC:DD:EE:02" "AA:BB:CC:DD:EE:01"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already registered to user 'sara'"* ]]
}

@test "mac_list prints 'No MAC addresses' when the user has none" {
  db_mac_list() { :; }
  run mac_list john
  [ "$status" -eq 0 ]
  [[ "$output" == *"No MAC addresses registered for 'john'"* ]]
}

@test "mac_list renders a tree with the last entry using the corner glyph" {
  db_mac_list() {
    printf 'AA:BB:CC:DD:EE:01|2026-01-01 00:00:00\nAA:BB:CC:DD:EE:02|2026-01-02 00:00:00\n'
  }
  run mac_list john
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "john" ]]
  [[ "${lines[1]}" == " ├── AA:BB:CC:DD:EE:01" ]]
  [[ "${lines[2]}" == " └── AA:BB:CC:DD:EE:02" ]]
}

@test "mac_list --json emits the expected structure" {
  db_mac_list() {
    printf 'AA:BB:CC:DD:EE:01|2026-01-01 00:00:00\n'
  }
  run mac_list john --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.username == "john" and .mac_addresses[0].mac_address == "AA:BB:CC:DD:EE:01"' >/dev/null
}

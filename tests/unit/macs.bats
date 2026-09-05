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
  source "${REPO_ROOT}/lib/reporting.sh"
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

# --- Phase 7: mac_check_connection / cmd_internal ------------------------
# db_user_get from the outer setup() only knows john/sara; extend it here
# with an active user who HAS a registered MAC (dave) and a disabled one
# (mia), so enforcement branches can be exercised independently of the
# add/remove/update tests above.

@test "mac_check_connection rejects when common_name is empty" {
  run mac_check_connection "" "AA:BB:CC:DD:EE:01"
  [ "$status" -ne 0 ]
  [[ "$output" == "REJECT no_common_name" ]]
}

@test "mac_check_connection rejects an unknown common_name" {
  run mac_check_connection "ghost" "AA:BB:CC:DD:EE:01"
  [ "$status" -ne 0 ]
  [[ "$output" == "REJECT unknown_user" ]]
}

@test "mac_check_connection rejects a disabled user" {
  db_user_get() { [[ "$1" == "mia" ]] && echo "4|mia|disabled||2026-01-01 00:00:00|2026-01-01 00:00:00"; }
  run mac_check_connection "mia" "AA:BB:CC:DD:EE:01"
  [ "$status" -ne 0 ]
  [[ "$output" == "REJECT user_disabled" ]]
}

@test "mac_check_connection accepts a user with no MACs registered (no policy set)" {
  db_mac_list() { :; }
  run mac_check_connection "john" ""
  [ "$status" -eq 0 ]
  [[ "$output" == "ACCEPT no_mac_policy" ]]
}

@test "mac_check_connection rejects a user with no MACs registered when mac_required=true" {
  CYFERIO_CFG[mac_required]=true
  db_mac_list() { :; }
  run mac_check_connection "john" ""
  [ "$status" -ne 0 ]
  [[ "$output" == "REJECT no_mac_registered" ]]
}

@test "mac_check_connection: mac_required=true doesn't affect a user who already has a registered MAC" {
  CYFERIO_CFG[mac_required]=true
  db_user_get() { [[ "$1" == "dave" ]] && echo "3|dave|active||2026-01-01 00:00:00|2026-01-01 00:00:00"; }
  db_mac_list() { printf 'AA:BB:CC:DD:EE:05|2026-01-01 00:00:00\n'; }
  run mac_check_connection "dave" "aa:bb:cc:dd:ee:05"
  [ "$status" -eq 0 ]
  [[ "$output" == "ACCEPT mac_match" ]]
}

@test "mac_check_connection accepts on an exact MAC match" {
  db_user_get() { [[ "$1" == "dave" ]] && echo "3|dave|active||2026-01-01 00:00:00|2026-01-01 00:00:00"; }
  db_mac_list() { printf 'AA:BB:CC:DD:EE:05|2026-01-01 00:00:00\n'; }
  run mac_check_connection "dave" "aa:bb:cc:dd:ee:05"
  [ "$status" -eq 0 ]
  [[ "$output" == "ACCEPT mac_match" ]]
}

@test "mac_check_connection rejects a MAC that doesn't match any registered MAC" {
  db_user_get() { [[ "$1" == "dave" ]] && echo "3|dave|active||2026-01-01 00:00:00|2026-01-01 00:00:00"; }
  db_mac_list() { printf 'AA:BB:CC:DD:EE:05|2026-01-01 00:00:00\n'; }
  run mac_check_connection "dave" "AA:BB:CC:DD:EE:99"
  [ "$status" -ne 0 ]
  [[ "$output" == "REJECT mac_mismatch" ]]
}

@test "mac_check_connection rejects a missing peer MAC in strict mode (default)" {
  db_user_get() { [[ "$1" == "dave" ]] && echo "3|dave|active||2026-01-01 00:00:00|2026-01-01 00:00:00"; }
  db_mac_list() { printf 'AA:BB:CC:DD:EE:05|2026-01-01 00:00:00\n'; }
  run mac_check_connection "dave" ""
  [ "$status" -ne 0 ]
  [[ "$output" == "REJECT mac_unavailable_strict" ]]
}

@test "mac_check_connection accepts a missing peer MAC in permissive mode" {
  CYFERIO_CFG[mac_enforcement_mode]=permissive
  db_user_get() { [[ "$1" == "dave" ]] && echo "3|dave|active||2026-01-01 00:00:00|2026-01-01 00:00:00"; }
  db_mac_list() { printf 'AA:BB:CC:DD:EE:05|2026-01-01 00:00:00\n'; }
  run mac_check_connection "dave" ""
  [ "$status" -eq 0 ]
  [[ "$output" == "ACCEPT mac_unavailable_permissive" ]]
}

@test "mac_check_connection treats a malformed peer MAC the same as unavailable" {
  db_user_get() { [[ "$1" == "dave" ]] && echo "3|dave|active||2026-01-01 00:00:00|2026-01-01 00:00:00"; }
  db_mac_list() { printf 'AA:BB:CC:DD:EE:05|2026-01-01 00:00:00\n'; }
  run mac_check_connection "dave" "not-a-mac"
  [ "$status" -ne 0 ]
  [[ "$output" == "REJECT mac_unavailable_strict" ]]
}

@test "cmd_internal mac-check exits 0 on accept and 1 on reject" {
  db_mac_list() { :; }
  run cmd_internal mac-check john ""
  [ "$status" -eq 0 ]

  run cmd_internal mac-check ghost ""
  [ "$status" -eq 1 ]
}

@test "cmd_internal rejects an unknown subcommand" {
  run cmd_internal bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown internal subcommand"* ]]
}

# --- Phase 8: mac_report -------------------------------------------------

@test "mac_report prints an empty-state message when there are no users" {
  db_mac_report() { :; }
  run mac_report
  [ "$status" -eq 0 ]
  [[ "$output" == *"No users yet."* ]]
}

@test "mac_report table shows MAC count, MAC list, and last event" {
  db_mac_report() {
    printf 'alice|active|2|AA:BB:CC:DD:EE:01,AA:BB:CC:DD:EE:02|auth.mac_accept:2026-01-02 03:04:05\n'
    printf 'bob|disabled|0||\n'
  }
  run mac_report
  [ "$status" -eq 0 ]
  [[ "$output" == *"alice"*"active"*"2"*"AA:BB:CC:DD:EE:01,AA:BB:CC:DD:EE:02"*"auth.mac_accept @ 2026-01-02 03:04:05"* ]]
  [[ "$output" == *"bob"*"disabled"*"0"*"-"* ]]
}

@test "mac_report --json emits mac_addresses as an array and last_event as an object" {
  db_mac_report() {
    printf 'alice|active|2|AA:BB:CC:DD:EE:01,AA:BB:CC:DD:EE:02|auth.mac_accept:2026-01-02 03:04:05\n'
  }
  run mac_report --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    .[0].username == "alice"
    and (.[0].mac_addresses | length == 2)
    and .[0].mac_addresses[0] == "AA:BB:CC:DD:EE:01"
    and .[0].last_event.action == "auth.mac_accept"
    and .[0].last_event.timestamp == "2026-01-02 03:04:05"
  ' >/dev/null
}

@test "mac_report --json omits last_event for a user who never connected" {
  db_mac_report() {
    printf 'carol|active|0||\n'
  }
  run mac_report --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '(.[0] | has("last_event")) == false and .[0].mac_addresses == []' >/dev/null
}

@test "mac_report --plain emits unaligned pipe-delimited rows" {
  db_mac_report() {
    printf 'alice|active|1|AA:BB:CC:DD:EE:01|auth.mac_accept:2026-01-02 03:04:05\n'
  }
  run mac_report --plain
  [ "$status" -eq 0 ]
  [[ "$output" == "alice|active|1|AA:BB:CC:DD:EE:01|auth.mac_accept @ 2026-01-02 03:04:05" ]]
}

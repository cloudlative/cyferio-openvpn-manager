#!/usr/bin/env bats
# status.bats — lib/status.sh's cmd_status, with vpn_backend_server_status
# and ovpn_status_clients stubbed out (pure formatting/plumbing; real
# status-file parsing is covered by profiles.bats's ovpn_status_clients
# tests).

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  source "${REPO_ROOT}/lib/core.sh"
  source "${REPO_ROOT}/lib/logger.sh"
  source "${REPO_ROOT}/lib/utils.sh"
  source "${REPO_ROOT}/lib/config.sh"
  source "${REPO_ROOT}/lib/reporting.sh"
  source "${REPO_ROOT}/lib/status.sh"

  require_root() { :; }
  vpn_backend_server_status() { echo running; }
  ovpn_status_clients() { :; }
}

@test "cmd_status (table) shows server facts and 'no clients' with none connected" {
  run cmd_status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Status:  running"* ]]
  [[ "$output" == *"Port:    1194/udp"* ]]
  [[ "$output" == *"Subnet:  10.8.0.0 255.255.255.0"* ]]
  [[ "$output" == *"Connected clients: 0"* ]]
}

@test "cmd_status (table) lists connected clients" {
  ovpn_status_clients() {
    printf 'alice|34.82.9.157:52341|10.8.0.2|5000|4000|Fri Sep  4 12:00:05 2026\n'
  }
  run cmd_status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Connected clients: 1"* ]]
  [[ "$output" == *"alice"*"34.82.9.157:52341"*"10.8.0.2"*"5000"*"4000"* ]]
}

@test "cmd_status --plain emits unaligned pipe-delimited client rows" {
  ovpn_status_clients() {
    printf 'alice|34.82.9.157:52341|10.8.0.2|5000|4000|Fri Sep  4 12:00:05 2026\n'
  }
  run cmd_status --plain
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\n'"alice|34.82.9.157:52341|10.8.0.2|5000|4000|Fri Sep  4 12:00:05 2026" ]]
}

@test "cmd_status --json emits server + connected_clients structure" {
  ovpn_status_clients() {
    printf 'alice|34.82.9.157:52341|10.8.0.2|5000|4000|Fri Sep  4 12:00:05 2026\n'
  }
  run cmd_status --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    .server.status == "running"
    and .server.port == 1194
    and .server.proto == "udp"
    and .connected_clients.count == 1
    and .connected_clients.clients[0].common_name == "alice"
    and .connected_clients.clients[0].bytes_received == 5000
  ' >/dev/null
}

@test "cmd_status --json emits an empty clients array when nobody is connected" {
  run cmd_status --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.connected_clients.count == 0 and .connected_clients.clients == []' >/dev/null
}

@test "cmd_status reports a stopped server" {
  vpn_backend_server_status() { echo stopped; }
  run cmd_status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Status:  stopped"* ]]
}

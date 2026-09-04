#!/usr/bin/env bats
# database.bats — lib/database.sh migration runner, against a scratch DB.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP_HOME="$(mktemp -d)"
  export CYFERIO_ROOT_DIR="${REPO_ROOT}"
  export CYFERIO_CONF_DIR="${TMP_HOME}/etc"
  export CYFERIO_DATA_DIR="${TMP_HOME}/var"
  export CYFERIO_LOG_DIR="${TMP_HOME}/log"

  source "${REPO_ROOT}/lib/core.sh"
  source "${REPO_ROOT}/lib/logger.sh"
  source "${REPO_ROOT}/lib/utils.sh"
  source "${REPO_ROOT}/lib/database.sh"
}

teardown() {
  rm -rf "${TMP_HOME}"
}

@test "db_migrate creates the expected tables" {
  db_migrate
  tables="$(sqlite3 "$(db_path)" ".tables")"
  [[ "${tables}" == *"users"* ]]
  [[ "${tables}" == *"user_macs"* ]]
  [[ "${tables}" == *"audit_logs"* ]]
  [[ "${tables}" == *"schema_migrations"* ]]
}

@test "db_migrate is idempotent" {
  db_migrate
  first_version="$(db_schema_version)"
  db_migrate
  second_version="$(db_schema_version)"
  [ "${first_version}" = "${second_version}" ]
}

@test "database file is created with 0600 permissions" {
  db_migrate
  perms="$(stat -c '%a' "$(db_path)")"
  [ "${perms}" = "600" ]
}

@test "data directory is created with 0750 permissions" {
  db_migrate
  perms="$(stat -c '%a' "${CYFERIO_DATA_DIR}")"
  [ "${perms}" = "750" ]
}

@test "users.username unique constraint is enforced" {
  db_migrate
  db_exec "INSERT INTO users (username) VALUES ('john');"
  run db_exec "INSERT INTO users (username) VALUES ('john');"
  [ "$status" -ne 0 ]
}

@test "user_macs unique (user_id, mac_address) prevents duplicate MAC on same user" {
  db_migrate
  db_exec "INSERT INTO users (username) VALUES ('john');"
  db_exec "INSERT INTO user_macs (user_id, mac_address) VALUES (1, 'AA:BB:CC:DD:EE:FF');"
  run db_exec "INSERT INTO user_macs (user_id, mac_address) VALUES (1, 'AA:BB:CC:DD:EE:FF');"
  [ "$status" -ne 0 ]
}

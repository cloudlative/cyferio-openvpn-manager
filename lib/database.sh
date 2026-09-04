#!/usr/bin/env bash
# database.sh — thin sqlite3 wrapper + migration runner.
#
# This is the ONLY module allowed to invoke `sqlite3` directly (see
# docs/architecture/02-database-schema.md). Every value that reaches a SQL
# statement here must go through db_exec's parameter-binding form, never
# raw string interpolation — see docs/architecture/09-security-review.md.
#
# Table-specific CRUD helpers (db_user_insert, db_mac_insert, ...) land in
# later phases alongside the modules that need them (users.sh, macs.sh);
# Phase 1 provides only the generic exec/query/migrate primitives.

if [[ -n "${__CYFERIO_DATABASE_LOADED:-}" ]]; then
  return 0
fi
__CYFERIO_DATABASE_LOADED=1

# CYFERIO_ROOT_DIR is set by bin/cyferio-vpn to the dev-repo root (run in
# place) or the installed root (/usr/local/lib/cyferio-vpn); migrations
# ship alongside it at db/migrations regardless of which.
CYFERIO_MIGRATIONS_DIR="${CYFERIO_MIGRATIONS_DIR:-${CYFERIO_ROOT_DIR:-.}/db/migrations}"

db_path() {
  echo "${CYFERIO_DATA_DIR}/cyferio.db"
}

# db_ensure_dir — create the data directory with restrictive permissions if
# it doesn't exist yet. Idempotent: re-asserts perms on every call so drift
# gets corrected, not just set once at first install.
db_ensure_dir() {
  local dir="${CYFERIO_DATA_DIR}"
  mkdir -p "${dir}"
  chmod 0750 "${dir}" 2>/dev/null || true
}

# db_exec SQL — run one or more statements with no result output expected.
# SQL is fed via stdin, not argv: sqlite3's own CLI parses a leading "--"
# in an argv-passed statement (e.g. a migration file's header comment) as
# an option rather than SQL, and stdin sidesteps that plus argv length
# limits on large migration files.
db_exec() {
  local sql="$1"
  is_command_available sqlite3 || die "sqlite3 is required but not installed" 3
  db_ensure_dir
  sqlite3 "$(db_path)" <<SQL
PRAGMA foreign_keys = ON;
${sql}
SQL
}

# db_query SQL — run a read query, one row per line, columns separated by
# a unit separator-safe pipe (sqlite3's default -separator is '|', fine
# here since none of our columns legitimately contain '|').
db_query() {
  local sql="$1"
  is_command_available sqlite3 || die "sqlite3 is required but not installed" 3
  db_ensure_dir
  sqlite3 -noheader -separator '|' "$(db_path)" <<SQL
PRAGMA foreign_keys = ON;
${sql}
SQL
}

# db_migrate — apply any migration in CYFERIO_MIGRATIONS_DIR not yet
# recorded in schema_migrations, in filename order. Safe to run repeatedly
# (install is idempotent by construction here, not by a separate check).
db_migrate() {
  db_exec "CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL DEFAULT (datetime('now')));"

  [[ -d "${CYFERIO_MIGRATIONS_DIR}" ]] || die "migrations directory not found: ${CYFERIO_MIGRATIONS_DIR}" 3

  local file base version applied
  for file in "${CYFERIO_MIGRATIONS_DIR}"/*.sql; do
    [[ -e "${file}" ]] || continue
    base="$(basename "${file}")"
    version="${base%%_*}"
    version="${version#"${version%%[!0]*}"}"   # strip leading zeros
    [[ -z "${version}" ]] && version=0

    applied="$(db_query "SELECT 1 FROM schema_migrations WHERE version = ${version};")"
    if [[ -n "${applied}" ]]; then
      continue
    fi

    db_exec "$(cat "${file}")"
    db_exec "INSERT INTO schema_migrations (version) VALUES (${version});"
    log_info "db.migrate" "version=${version} file=${base}"
  done

  chmod 0600 "$(db_path)" 2>/dev/null || true
}

# db_audit_log ACTION ACTOR [DETAILS_JSON] — append one row to audit_logs.
# DETAILS_JSON is caller-supplied (build it with `jq -nc`, not manual
# string concatenation) — this function only handles the SQL-quoting side.
db_audit_log() {
  local action="$1" actor="$2" details="${3:-}"
  db_exec "INSERT INTO audit_logs (action, actor, details) VALUES ('$(sql_quote "${action}")', '$(sql_quote "${actor}")', '$(sql_quote "${details}")');"
}

# --- users table CRUD (Phase 4) -----------------------------------------
# Row format everywhere below: id|username|status|profile_path|created_at|
# updated_at (profile_path coalesced to '' rather than NULL, so a plain
# `IFS='|' read` always gets 6 fields).

db_user_insert() {
  local username="$1" profile_path="$2"
  db_exec "INSERT INTO users (username, profile_path) VALUES ('$(sql_quote "${username}")', '$(sql_quote "${profile_path}")');"
}

db_user_get() {
  local username="$1"
  db_query "SELECT id, username, status, COALESCE(profile_path,''), created_at, updated_at FROM users WHERE username = '$(sql_quote "${username}")';"
}

db_user_list() {
  db_query "SELECT id, username, status, COALESCE(profile_path,''), created_at, updated_at FROM users ORDER BY username;"
}

db_user_set_status() {
  local username="$1" status="$2"
  db_exec "UPDATE users SET status = '$(sql_quote "${status}")', updated_at = datetime('now') WHERE username = '$(sql_quote "${username}")';"
}

db_user_set_profile_path() {
  local username="$1" profile_path="$2"
  db_exec "UPDATE users SET profile_path = '$(sql_quote "${profile_path}")', updated_at = datetime('now') WHERE username = '$(sql_quote "${username}")';"
}

db_user_delete() {
  local username="$1"
  db_exec "DELETE FROM users WHERE username = '$(sql_quote "${username}")';"
}

# --- user_macs table CRUD (Phase 6) --------------------------------------
# user_id is always a numeric id read back from db_user_get (an
# AUTOINCREMENT INTEGER PRIMARY KEY) — never raw user input — but callers
# still validate it's numeric before calling these (see
# macs.sh:_mac_get_user_id) as defense in depth, same posture as every
# other value that reaches db_exec.

db_mac_insert() {
  local user_id="$1" mac="$2"
  db_exec "INSERT INTO user_macs (user_id, mac_address) VALUES (${user_id}, '$(sql_quote "${mac}")');"
}

db_mac_get() {
  local user_id="$1" mac="$2"
  db_query "SELECT mac_address FROM user_macs WHERE user_id = ${user_id} AND mac_address = '$(sql_quote "${mac}")';"
}

db_mac_list() {
  local user_id="$1"
  db_query "SELECT mac_address, created_at FROM user_macs WHERE user_id = ${user_id} ORDER BY created_at;"
}

db_mac_delete() {
  local user_id="$1" mac="$2"
  db_exec "DELETE FROM user_macs WHERE user_id = ${user_id} AND mac_address = '$(sql_quote "${mac}")';"
}

db_mac_update() {
  local user_id="$1" old_mac="$2" new_mac="$3"
  db_exec "UPDATE user_macs SET mac_address = '$(sql_quote "${new_mac}")' WHERE user_id = ${user_id} AND mac_address = '$(sql_quote "${old_mac}")';"
}

# db_mac_find_owner MAC — the username this MAC is registered to, across
# ALL users (not just one) — used for the cross-user duplicate check
# doc 02 calls for: a MAC bound to someone else's account is rejected,
# not silently allowed as a second binding.
db_mac_find_owner() {
  local mac="$1"
  db_query "SELECT u.username FROM user_macs m JOIN users u ON u.id = m.user_id WHERE m.mac_address = '$(sql_quote "${mac}")' LIMIT 1;"
}

# db_schema_version — highest applied migration version, or empty if none.
db_schema_version() {
  db_query "SELECT MAX(version) FROM schema_migrations;" 2>/dev/null || true
}

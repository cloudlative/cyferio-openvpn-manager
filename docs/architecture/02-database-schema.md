---
title: "02 — Database Schema (SQLite)"
permalink: /architecture/02-database-schema/
---

# 02 — Database Schema (SQLite)

Location: `/var/lib/cyferio/cyferio.db`, mode `0600`, owned by `root`. All access goes through `lib/database.sh` — no other module calls `sqlite3` directly.

## `schema_migrations`

Tracks applied migrations so `database.sh` can bootstrap or upgrade an existing DB idempotently.

```sql
CREATE TABLE IF NOT EXISTS schema_migrations (
  version     INTEGER PRIMARY KEY,
  applied_at  TEXT NOT NULL DEFAULT (datetime('now'))
);
```

## `users`

```sql
CREATE TABLE IF NOT EXISTS users (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  username      TEXT NOT NULL UNIQUE,
  status        TEXT NOT NULL DEFAULT 'active'   -- active | disabled
                 CHECK (status IN ('active','disabled')),
  profile_path  TEXT,                             -- last-exported .ovpn path
  created_at    TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at    TEXT NOT NULL DEFAULT (datetime('now'))
);
```

## `user_macs`

```sql
CREATE TABLE IF NOT EXISTS user_macs (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id       INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  mac_address   TEXT NOT NULL,                     -- normalized uppercase AA:BB:CC:DD:EE:FF
  created_at    TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE (user_id, mac_address)                     -- duplicate prevention per user
);
CREATE INDEX IF NOT EXISTS idx_user_macs_mac ON user_macs(mac_address);
```

`UNIQUE (user_id, mac_address)` blocks a duplicate MAC on the *same* user at the DB layer; `macs.sh` additionally checks cross-user duplicates before insert (a MAC bound to someone else's account is rejected with a clear error, not a silent second binding) and logs both cases to `audit_logs`.

## `audit_logs`

```sql
CREATE TABLE IF NOT EXISTS audit_logs (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  action      TEXT NOT NULL,     -- e.g. 'user.add', 'mac.remove', 'auth.fail'
  actor       TEXT NOT NULL,     -- invoking OS user (from $SUDO_USER / whoami)
  details     TEXT,              -- free-form context, JSON-encoded via jq
  timestamp   TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_audit_logs_action ON audit_logs(action);
CREATE INDEX IF NOT EXISTS idx_audit_logs_timestamp ON audit_logs(timestamp);
```

## Access pattern

`database.sh` exposes narrow functions per table (`db_user_insert`, `db_user_get`, `db_user_list`, `db_mac_insert`, `db_mac_list_for_user`, `db_audit_log`, …) — every value is bound, never interpolated into the SQL string, per the SQL-injection section of [09-security-review.md](09-security-review.md). Migrations live as numbered `.sql` files applied in order and recorded in `schema_migrations`, so `cyferio-vpn install` run against an existing DB just applies any migrations not yet recorded — idempotent by construction.

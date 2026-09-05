---
title: "08 — Backup & Restore Architecture"
permalink: /architecture/08-backup-restore/
---

# 08 — Backup & Restore Architecture

## `cyferio-vpn backup`

Produces one timestamped tarball: `/var/backups/cyferio/cyferio-backup-YYYYmmdd-HHMMSS.tar.gz`, containing:

```
pki/            # /etc/cyferio/pki — CA, server & client certs/keys
openvpn/        # /etc/openvpn/server/*.conf
db/cyferio.db   # sqlite3 .backup (online-safe, not a raw file copy) → consistent snapshot
profiles/       # every admin's ~/vpn-profiles/ the tool has record of (from profile_path column)
config/         # /etc/cyferio/cyferio.conf
MANIFEST.json   # tool version, timestamp, hostname, item checksums (sha256)
```

Archive permissions `0600`, root-owned — it contains private keys. `MANIFEST.json` lets `restore` validate integrity (checksum mismatch → abort with a clear error) before touching anything.

## `cyferio-vpn restore <archive>`

1. Extract to a temp dir, verify `MANIFEST.json` checksums.
2. Stop `openvpn-server@server`.
3. Restore `pki/`, `openvpn/`, `config/` in place (existing files backed up to `.pre-restore` suffix first, not deleted outright — one extra safety net).
4. `sqlite3 cyferio.db ".restore db/cyferio.db"` style restore into `/var/lib/cyferio/cyferio.db`.
5. Restart service, run `network.sh`'s post-install checks (reuses [06-networking-validation.md](06-networking-validation.md)'s check set) to confirm the restored deployment is actually healthy before declaring success.

## Automatic pre-uninstall backup

Per spec, `cyferio-vpn uninstall` (with or without `--force`) always runs the same backup flow first and prints the resulting archive path — uninstall is never destructive without a recovery point.

## Retention

Not auto-pruned by default (backups are small — PKI + SQLite DB, no traffic logs) — `cyferio-vpn backup` documents in its own `--help` that retention/off-box copying is the operator's responsibility (rsync/cron), matching the "no bandwidth limiting, no extra infra assumptions" scope constraint from the spec.

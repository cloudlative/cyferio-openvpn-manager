---
title: "07 — Logging Architecture"
permalink: /architecture/07-logging/
---

# 07 — Logging Architecture

## Location & format

`/var/log/cyferio/cyferio.log` — one line per event, structured:

```
2026-09-04T10:15:32Z [INFO] [user.add] actor=asif username=john result=success
2026-09-04T10:16:01Z [WARN] [mac.reject] actor=system username=john mac=AA:BB:CC:DD:EE:99 reason=not_registered
2026-09-04T10:16:45Z [ERROR] [install] actor=root step=firewall_config result=failure detail="ufw not installed"
```

`logger.sh` exposes `log_info`, `log_warn`, `log_error`, each taking a tag + key=value pairs — every module logs through these, never raw `echo >> file`.

## What's logged (spec-mandated categories)

- Installations (`install.*`, `uninstall.*`)
- User actions (`user.add|remove|enable|disable`)
- MAC actions (`mac.add|remove|update|reject|unavailable`)
- Authentication failures (`auth.mac_reject`, from the `client-connect` hook)
- Audits (`audit.run`, summary result)
- Diagnostics (`diagnose.run`, summary result)

Security/user-relevant events (not raw connectivity checks) are additionally written to the `audit_logs` SQLite table (see [02-database-schema.md](02-database-schema.md)) — the log file is the operational trail, the DB table is the structured/queryable trail `cyferio-vpn audit --json` and `mac report` read from.

## Rotation

`logrotate` config installed to `/etc/logrotate.d/cyferio` during `install`:
```
/var/log/cyferio/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0660 root nogroup
}
```
(`create`'s mode/group matches the Permissions section below — a plain `0640 root root` here would silently lose hook write access again on the very first rotation.)

## Permissions

`/var/log/cyferio/` is `0770`, group `nogroup` — not `0750 root:root` as originally planned here. The `client-connect`/`client-disconnect` hooks (Phase 2) run as the OpenVPN daemon's dropped-privilege `nobody:nogroup` (`server.conf`'s `user nobody` / `group nogroup`), and need to append their own connect/disconnect audit lines to `cyferio.log` — a root-only directory silently drops every hook-written log line (caught by real end-to-end VPN-client testing in Phase 5). `cyferio.log` itself is kept `0660` for the same reason. Still not world-readable — `nogroup` is the daemon's own low-privilege group, not "everyone."

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
    create 0640 root root
}
```

## Permissions

`/var/log/cyferio/` mode `0750`, owned by `root:root` — logs may contain usernames/MACs (not secrets, but still operationally sensitive), so not world-readable.

# 04 — MAC Address Validation Design

## Data model

See [02-database-schema.md](02-database-schema.md) `user_macs` — multiple MACs per user, normalized uppercase `AA:BB:CC:DD:EE:FF`, duplicate-checked both per-user (DB `UNIQUE`) and cross-user (`macs.sh` pre-check) before insert, each add/remove/update audit-logged via `db_audit_log`.

## Commands

```bash
cyferio-vpn mac add USERNAME MAC
cyferio-vpn mac remove USERNAME MAC
cyferio-vpn mac update USERNAME OLD_MAC NEW_MAC     # atomic: rejects if NEW_MAC already used
cyferio-vpn mac list USERNAME [--json]
cyferio-vpn mac report [--table|--json]
```

Validation regex (`utils.sh:validate_mac`): `^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$`, normalized to uppercase before any DB operation or comparison.

## Enforcement at connection time

OpenVPN's `client-connect` script (set via `script-security 2` + `client-connect /etc/cyferio/hooks/client-connect.sh` in `server.conf`) runs on every connection attempt with client-supplied `IV_*` peer-info exposed as environment variables (populated because the client profile sets `push-peer-info`, per [03-openvpn-integration.md](03-openvpn-integration.md)).

```
┌──────────┐  connects   ┌─────────────────┐  reads   ┌──────────────────┐
│ OpenVPN   │────────────▶│ client-connect   │─────────▶│ user_macs table   │
│ client    │             │ .sh hook         │          │ (via database.sh) │
│ (push-    │             │                  │          │                    │
│ peer-info)│             │ common_name =    │          │ WHERE user_id=?    │
└──────────┘             │ $common_name     │          │ AND mac_address=?  │
                          │ client MAC from  │          └──────────────────┘
                          │ IV_HWADDR peer-  │
                          │ info (if client   │
                          │ OS supplies it)   │
                          └────────┬─────────┘
                                   │ match found?
                         ┌─────────┴─────────┐
                      yes│                   │no
                         ▼                   ▼
                 exit 0 (accept)     exit 1 (reject) +
                                     audit_logs: 'auth.mac_reject'
```

**Caveat documented up front (goes in `04-mac-validation.md`'s own "Limitations" note in the shipped docs, not hidden):** `push-peer-info`/`IV_*` variables are populated by the OpenVPN client at connect time and are *client-supplied*, not independently verified by the server — a modified client could spoof `IV_HWADDR`. This is the same trust model OpenVPN itself uses for peer-info generally; the design treats MAC binding as **device-management/policy enforcement** (stop known-good users from using unapproved devices, produce an audit trail) rather than a cryptographic security boundary. This distinction is called out explicitly in the README's Security Considerations section so it isn't oversold.

If the client's OS/OpenVPN version does not supply a MAC in peer-info at all, the hook logs `auth.mac_unavailable` and — per an installer-time policy setting (`config/cyferio.conf.example`: `mac_enforcement_mode=strict|permissive`) — either rejects (`strict`, default once a user has ≥1 MAC registered) or allows-and-logs (`permissive`, e.g. during initial rollout).

## `client-disconnect`

Logs `session.disconnect` (username, MAC, duration) to `audit_logs` — no enforcement action, purely for the audit trail `cyferio-vpn audit`/`diagnose` and `mac report`'s "Status" column read from.

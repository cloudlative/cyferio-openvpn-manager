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

**Verified against a real client (Phase 7):** the standard Linux `openvpn` CLI client (2.5.11, Ubuntu 22.04) does NOT populate `IV_HWADDR` even with `push-peer-info` set — that key is populated by GUI/managed clients (OpenVPN Connect, the mobile apps) that have direct access to device hardware info, not the bare community daemon. So on a typical Linux/CLI deployment, every connection lands on the `mac_unavailable_*` branch above, not `mac_match`/`mac_mismatch` — MAC enforcement in practice is mostly useful where OpenVPN Connect or an equivalent managed client is mandated. This doesn't change the design (the fallback policy exists for exactly this case) but is worth knowing before setting `mac_enforcement_mode=strict` as a hard requirement.

## `client-disconnect`

Logs `session.disconnect` (username, MAC, duration) to `audit_logs` — no enforcement action, purely for the audit trail `cyferio-vpn audit`/`diagnose` and `mac report`'s "Status" column read from.

## Implementation (Phase 7)

`client-connect.sh`/`client-disconnect.sh` (installed 0755, running as `nobody:nogroup`) don't touch the database themselves — they shell out to `cyferio-vpn internal mac-check`/`internal disconnect-log` (undocumented, hook-only subcommands — see `lib/macs.sh`'s `mac_check_connection`/`mac_log_disconnect`/`cmd_internal`), which:

1. Rejects immediately if `$common_name` doesn't match a known user (`unknown_user`), or the user's `status` isn't `active` (`user_<status>` — this is where a `user disable`d account actually stops connecting, since disabling alone only flips a DB column and doesn't touch the still-valid certificate).
2. Accepts unconditionally if the user has zero MACs registered (`no_mac_policy`) — MAC binding is opt-in per user, not a blanket requirement.
3. Otherwise requires `$IV_HWADDR` (normalized/validated the same way `mac add` does; malformed peer-info is treated as absent, never as a crash or a free pass) to exactly match one of the user's registered MACs (`mac_match`/`mac_mismatch`), or — if peer-info is absent entirely — falls back to `mac_enforcement_mode` (`mac_unavailable_strict` rejects, `mac_unavailable_permissive` accepts-and-logs).

Every branch writes its own `audit_logs` row (`auth.mac_accept`/`auth.mac_reject`/`auth.mac_unavailable`, actor = the connecting username) in addition to the flat-file line the hook script itself appends to `/var/log/cyferio/cyferio.log`.

This requires the dropped-privilege `nobody:nogroup` daemon user to read `users`/`user_macs` and write `audit_logs` directly — `install` re-groups `/var/lib/cyferio` and `cyferio.db` to `nogroup` (`0770`/`0660`) for this, the same trade-off already made for the log directory in Phase 5. See [09-security-review.md](09-security-review.md) for the documented posture.

# 00 — Architecture Overview

## Design principles

- **Bash only, no web UI.** Every capability is reachable from the CLI (`cyferio-vpn <command>`) or the interactive menu (`cyferio-vpn` with no args). No daemon serves HTTP.
- **Idempotent.** `cyferio-vpn install` run twice must not corrupt or duplicate an existing deployment — every mutating operation checks current state before acting.
- **Secure by default.** Least-privilege file permissions, no secrets in shell history or process args, no unsanitized input reaching `sqlite3`, `openssl`, or shell `eval`.
- **Modular.** Each concern (`core`, `network`, `openvpn`, `users`, `profiles`, `macs`, `database`, `audit`, `diagnostics`, `backup`, `restore`, `reporting`, `cloud`, `ui`, `logging`) is one file in `lib/`, sourced once by `bin/cyferio-vpn`, with narrow function-call boundaries — no module reaches into another's internals or private state.
- **ShellCheck-clean, strict mode.** Every script starts with `set -Eeuo pipefail`; CI runs `shellcheck` on every `.sh` file with zero warnings.
- **Structured output everywhere.** Every reporting command supports `table` (default), `--json`, and `plain` via one shared formatter layer (`lib/reporting.sh`), so the tool is automatable without ever parsing table output.
- **Extensible to other VPN backends.** `openvpn.sh` is the only module that knows OpenVPN specifics (config file format, `easyrsa`, `client-connect` hooks). `users.sh`, `profiles.sh`, `macs.sh` talk to it through a small backend-agnostic interface (`vpn_backend_provision_client`, `vpn_backend_revoke_client`, `vpn_backend_render_profile`) so a future `wireguard.sh` implementing the same interface plugs in without touching user/profile/mac logic.

## Component diagram

```
                         ┌─────────────────────────────┐
                         │   bin/cyferio-vpn (CLI)      │
                         │   - argument parsing         │
                         │   - dispatch to command fns  │
                         │   - interactive menu (ui.sh) │
                         └──────────────┬────────────────┘
                                        │
        ┌───────────────┬──────────────┼──────────────┬───────────────┐
        ▼               ▼               ▼              ▼               ▼
  ┌──────────┐   ┌─────────────┐  ┌──────────┐  ┌────────────┐  ┌─────────────┐
  │ core.sh  │   │ network.sh  │  │ users.sh │  │ macs.sh    │  │ audit.sh    │
  │ config.sh│   │ cloud.sh    │  │ profiles │  │            │  │ diagnostics │
  │ utils.sh │   │             │  │ .sh      │  │            │  │ .sh         │
  └────┬─────┘   └──────┬──────┘  └────┬─────┘  └─────┬──────┘  └──────┬──────┘
       │                │              │              │                │
       │                │              └──────┬───────┴────────────────┘
       │                │                     ▼
       │                │             ┌──────────────┐
       │                │             │ openvpn.sh    │◀── backend-agnostic
       │                │             │ (PKI, server, │    interface, see
       │                │             │  client-connect)│  Design Principles
       │                │             └───────┬───────┘
       │                │                     │
       ▼                ▼                     ▼
  ┌──────────────────────────────────────────────────┐
  │ database.sh — thin sqlite3 wrapper                 │
  │   users | user_macs | audit_logs                   │
  └──────────────────────────────────────────────────┘
       │
       ▼
  ┌──────────────┐   ┌─────────────┐   ┌──────────────┐
  │ backup.sh     │   │ restore.sh  │   │ logging.sh   │
  │ restore.sh    │   │             │   │ /var/log/    │
  └──────────────┘   └─────────────┘   │ cyferio/      │
                                        └──────────────┘
       │
       ▼
  ┌──────────────────────────────────┐
  │ reporting.sh — formatter layer    │
  │   table | json | plain            │
  └──────────────────────────────────┘
```

Every module writes through `logging.sh` (structured, timestamped, action-tagged) and — for anything user- or security-relevant (user add/remove, MAC changes, license... N/A, auth failures) — also through `database.sh`'s `audit_logs` table, so `cyferio-vpn audit` and `cyferio-vpn diagnose` have a durable trail to inspect, not just log-grepping.

## Command surface (from spec)

```
cyferio-vpn install [--force]
cyferio-vpn uninstall [--force]

cyferio-vpn user add|remove|disable|enable|get|list USERNAME

cyferio-vpn profile export|regenerate USERNAME

cyferio-vpn mac add|remove|update|list USERNAME [MAC ...]
cyferio-vpn mac report [--table|--json]

cyferio-vpn status [--json]
cyferio-vpn audit [--json]
cyferio-vpn diagnose [--json]

cyferio-vpn backup
cyferio-vpn restore <archive>

cyferio-vpn network detect [--json]

cyferio-vpn version
cyferio-vpn --help
cyferio-vpn                      # interactive menu
```

All list/get/report commands accept `--json`; `mac report` additionally accepts `--table` (default) per spec.

## Open technical decisions (flagged for sign-off, see plan)

- Binary `cyferio-vpn` → `/usr/local/bin`, modules → `/usr/local/lib/cyferio-vpn/lib/*.sh`.
- JSON via `jq` (installer-ensured dependency).
- Interactive menu via `whiptail`, falling back to a plain numbered prompt if neither `whiptail` nor `dialog` is present.
- `database.sh` wraps the `sqlite3` CLI; all values passed via `sqlite3 ... <<SQL` heredocs with values bound through `.param set`, never string-interpolated — detailed in [09-security-review.md](09-security-review.md).
- Tests: `bats-core` + `shellcheck` in GitHub Actions across Ubuntu 22.04/24.04 + Debian 12.
- License: MIT.

## Future VPN backends (not built now, architecture reserves the seam)

`lib/backends/openvpn.sh` implements:
```
vpn_backend_provision_client <username>   # generate cert + return profile path
vpn_backend_revoke_client <username>
vpn_backend_render_profile <username>     # renders .ovpn incl. push-peer-info
vpn_backend_server_status                 # for status.sh
vpn_backend_connected_clients             # for status.sh
```
A future `lib/backends/wireguard.sh` implementing the same five functions is the entire integration surface — `users.sh`/`profiles.sh`/`status.sh` never change.

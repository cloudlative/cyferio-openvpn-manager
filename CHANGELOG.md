# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Nothing yet.

## [1.0.0] - 2026-09-05

First tagged release. Every command in the spec's command surface is
implemented and has been verified end-to-end on real disposable GCP
Compute Engine VMs.

### Added

- **Core framework** — `cyferio-vpn` CLI entry point, module loader, config
  file (`/etc/cyferio/cyferio.conf`), structured logging, SQLite schema and
  migrations.
- **Installation engine** — `install`/`uninstall`, PKI bootstrap, cloud
  provider detection (AWS/GCP/OVH/Contabo/Hetzner/bare-metal), NAT/firewall
  configuration, IP forwarding, networking pre-flight checks.
- **Certificate management** — `cert create|revoke|list|status`.
- **User management** — `user add|remove|enable|disable|get|list`.
- **Profile management** — `profile export|regenerate`, `.ovpn` rendering
  with `push-peer-info`.
- **MAC address engine** — `mac add|remove|update|list`, duplicate rejection,
  per-user and all-users delegation scopes for self-service MAC control.
- **Connection-time MAC enforcement** — `client-connect`/`client-disconnect`
  hooks, configurable `mac_enforcement_mode` (`strict`/`permissive`), full
  audit trail of accept/reject decisions.
- **Reporting engine** — shared `table`/`--json`/`--plain` formatter layer;
  `mac report` surfacing enforcement history per user.
- **Status command** — `status [--json]`: server state, port/proto/subnet,
  connected clients.
- **Audit & diagnose** — `audit [--json]` (permissions/ownership drift,
  reserved-name checks, user/cert consistency, enforcement-mode posture)
  and `diagnose [--json]` (service, port, NAT, PKI, database, hooks).
- **Backup & restore** — `backup`, `restore <archive> [--force]`: manifest-
  verified (SHA-256 per file), path-traversal-guarded archives; automatic
  pre-uninstall backup.
- **Interactive menu** — `cyferio-vpn --interactive`: whiptail-based menu
  (plain numbered-prompt fallback when whiptail isn't installed) covering
  every command above, reusing the same `cmd_*` functions as the CLI.
- **Release-readiness documentation** — CONTRIBUTING.md, SECURITY.md, and
  this CHANGELOG.

### Notes

- Every command in the spec's command surface (`install`, `uninstall`,
  `network detect`, `cert`, `user`, `profile`, `mac` incl. `report`,
  `status`, `audit`, `diagnose`, `backup`, `restore`, `--interactive`) is
  implemented.
- CA private keys stay on the deployment host by default (`/etc/cyferio/pki`,
  `0700` root-owned) for install simplicity; see
  [SECURITY.md](SECURITY.md) for the documented offline-CA option for
  high-security deployments.

### Known limitations

- Cloud provider detection (`network detect`) has been validated against a
  real instance only on GCP; AWS, OVH, Contabo, and Hetzner detection
  logic is covered by unit tests against mocked metadata responses only,
  not yet confirmed on real instances of those providers.
- Every integration-test VM run so far has used Ubuntu 22.04 LTS; Ubuntu
  24.04 LTS and Debian 12 (both named in the test matrix) haven't been
  exercised on real hardware yet.
- No second VPN backend (e.g. WireGuard) exists yet — `lib/backends/openvpn.sh`
  is the only implementation of the backend interface described in
  [docs/architecture/00-overview.md](docs/architecture/00-overview.md).

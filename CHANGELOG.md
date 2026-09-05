# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`mac_required` config key** — makes MAC registration itself
  mandatory: a user with zero MACs registered is rejected outright
  (`no_mac_registered`) instead of connecting unrestricted. Defaults
  `false` (today's opt-in-per-user behavior, unchanged). Deliberately a
  separate key from `mac_enforcement_mode`, not a new value of it —
  that setting only ever governed an already-registered user's
  fallback behavior when their client fails to report a MAC; folding
  the zero-MACs case into "strict" would have silently changed what an
  existing deployment's `strict` setting does on upgrade. See
  [docs/architecture/04-mac-validation.md](docs/architecture/04-mac-validation.md).

## [1.1.0] - 2026-09-05

### Added

- **Single-file distribution** — `scripts/build-dist.sh` generates
  `dist/cyferio-vpn`, a single self-contained file bundling every
  `lib/*.sh` module plus the config/template/migration assets normally
  read from the checkout, so it can be copied straight to
  `/usr/local/bin/cyferio-vpn` with no sibling `lib/`, `config/`,
  `templates/`, or `db/` directory required. See
  [docs/architecture/11-single-file-distribution.md](docs/architecture/11-single-file-distribution.md).
- **Self-upgrade** — `cyferio-vpn upgrade [--check] [--force] [--json]`
  checks GitHub Releases for a newer version and, unless `--check`,
  downloads and atomically replaces the running single-file binary in
  place; `cyferio-vpn version` now also notes when an update is
  available. Single-file build only (`dist/cyferio-vpn` installed via
  `/usr/local/bin`) — a multi-file dev checkout is told to `git pull`
  instead. Also reachable from `--interactive`'s main menu.
- **Banner refresh** — the boot banner is now the CYFERIO wordmark only
  (color when the terminal supports it), a trimmed author line
  (`Asif · cyferio.com · linkedin.com/in/cloudlative`), and `--help`'s
  duplicate/misaligned command entries were fixed.

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

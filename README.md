# Cyferio OpenVPN Manager

A production-grade, bash-only OpenVPN deployment and management toolkit — no web UI, no browser dependency. Built for home labs, SMBs, enterprises, MSPs, resellers, and dedicated customer deployments.

> **Status: v1.0.0.** Every command in the spec's command surface is implemented and verified end-to-end on real disposable cloud VMs — see [CHANGELOG.md](CHANGELOG.md) for what's shipped, including this release's known limitations.

## What this is

A single CLI (`cyferio-vpn`) that installs, configures, and manages an OpenVPN server end to end: cloud-aware pre-flight validation, PKI/certificate lifecycle, per-user profile generation, MAC-address device binding, backup/restore, auditing, and diagnostics — fully scriptable (JSON output on every reporting command) and fully interactive (`--interactive` menu mode for non-technical operators).

Designed to grow to WireGuard, IPSec, and OpenConnect without a redesign — see [`docs/architecture/00-overview.md`](docs/architecture/00-overview.md) for the module boundaries that make that possible.

## Quick start

**Single file, no checkout needed** — build (or grab a released)
`dist/cyferio-vpn` and drop it anywhere on your `PATH`:

```bash
sudo ./scripts/build-dist.sh          # produces dist/cyferio-vpn
sudo cp dist/cyferio-vpn /usr/local/bin/cyferio-vpn
sudo cyferio-vpn install
sudo cyferio-vpn user add alice
sudo cyferio-vpn profile export alice
```

`dist/cyferio-vpn` is a generated build artifact — see
[docs/architecture/11-single-file-distribution.md](docs/architecture/11-single-file-distribution.md)
for how it bundles every module and asset into one file with no sibling
`lib/`, `config/`, or `templates/` directory required.

**Or run in place from this checkout**, e.g. for development:

```bash
cd cyferio-openvpn-manager   # this checkout
sudo ./bin/cyferio-vpn install
sudo ./bin/cyferio-vpn user add alice
sudo ./bin/cyferio-vpn profile export alice
```

Either way, launch the menu-driven interface instead of the CLI with:

```bash
sudo cyferio-vpn --interactive
```

## Command surface

```
cyferio-vpn install [--force]
cyferio-vpn uninstall [--force]

cyferio-vpn cert create|revoke|list|status ...
cyferio-vpn user add|remove|enable|disable|get|list USERNAME [--json]
cyferio-vpn profile export|regenerate USERNAME [--force]
cyferio-vpn mac add|remove|update|list|report ...

cyferio-vpn status [--json]
cyferio-vpn audit [--json]
cyferio-vpn diagnose [--json]

cyferio-vpn backup
cyferio-vpn restore <archive> [--force]

cyferio-vpn network detect [--json]

cyferio-vpn version
cyferio-vpn help
cyferio-vpn --interactive          # menu-driven interface
```

Every list/get/report command supports `--json` for scripting; `mac
report` and `status` additionally support `--plain`.

## Requirements

- Ubuntu 22.04/24.04 LTS or Debian 12 (the tested/supported OS matrix)
- Root access (every mutating command requires it)
- `jq`, `sqlite3` (installed automatically by `install` if missing)
- `whiptail` (optional — `--interactive` falls back to a plain prompt without it)

## Documentation

- [Architecture overview](docs/architecture/00-overview.md)
- [Directory structure](docs/architecture/01-directory-structure.md)
- [Database schema](docs/architecture/02-database-schema.md)
- [OpenVPN integration & PKI lifecycle](docs/architecture/03-openvpn-integration.md)
- [MAC address validation](docs/architecture/04-mac-validation.md)
- [Cloud provider detection](docs/architecture/05-cloud-detection.md)
- [Networking validation](docs/architecture/06-networking-validation.md)
- [Logging](docs/architecture/07-logging.md)
- [Backup & restore](docs/architecture/08-backup-restore.md)
- [Security review & threat model](docs/architecture/09-security-review.md)
- [Testing strategy](docs/architecture/10-testing-strategy.md)
- [Single-file distribution](docs/architecture/11-single-file-distribution.md)

See also [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow
and [SECURITY.md](SECURITY.md) for the security posture summary and how
to report a vulnerability.

## Security considerations

MAC-address enforcement is a device-management/policy control, **not** a
cryptographic security boundary — OpenVPN's client-supplied peer-info is
not independently verified. See [SECURITY.md](SECURITY.md) for the full
posture, including CA key handling and the dropped-privilege hook design.

## License

MIT — see [LICENSE](LICENSE).

## Author

Asif — [cyferio.com](https://cyferio.com) · [LinkedIn](https://www.linkedin.com/in/cloudlative)

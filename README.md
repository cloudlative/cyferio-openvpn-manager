# Cyferio OpenVPN Manager

A production-grade, bash-only OpenVPN deployment and management toolkit — no web UI, no browser dependency. Built for home labs, SMBs, enterprises, MSPs, resellers, and dedicated customer deployments.

> **Status: under active development.** Phase 0 (architecture & design) is complete — see [`docs/architecture/`](docs/architecture/00-overview.md). Implementation has not started yet.

## What this is

A single CLI (`cyferio-vpn`) that installs, configures, and manages an OpenVPN server end to end: cloud-aware pre-flight validation, PKI/certificate lifecycle, per-user profile generation, MAC-address device binding, backup/restore, auditing, and diagnostics — fully scriptable (JSON output on every reporting command) and fully interactive (menu-driven mode for non-technical operators).

Designed to grow to WireGuard, IPSec, and OpenConnect without a redesign — see [`docs/architecture/00-overview.md`](docs/architecture/00-overview.md) for the module boundaries that make that possible.

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

## License

MIT — see [LICENSE](LICENSE).

## Author

Asif — [cyferio.com](https://cyferio.com) · [LinkedIn](https://www.linkedin.com/in/cloudlative)

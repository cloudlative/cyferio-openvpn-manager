---
layout: home
title: Cyferio OpenVPN Manager
description: >-
  A production-grade, bash-only OpenVPN deployment and management toolkit —
  no web UI, no browser dependency. Install a full OpenVPN server, manage
  users and certificates, enforce MAC-address device binding, and back up
  and restore, all from a single CLI or a menu-driven interface.
permalink: /
---

**Cyferio OpenVPN Manager** installs, configures, and manages an OpenVPN
server end to end from a single bash CLI (`cyferio-vpn`) — no web UI, no
browser dependency, no account. Cloud-aware pre-flight validation,
PKI/certificate lifecycle, per-user profile generation, MAC-address
device binding, backup/restore, auditing, and diagnostics, all
scriptable via `--json` output and also reachable through a menu-driven
`--interactive` mode.

## Install

```bash
curl -fsSL https://github.com/cloudlative/cyferio-openvpn-manager/releases/latest/download/cyferio-vpn \
  -o cyferio-vpn
chmod +x cyferio-vpn
sudo mv cyferio-vpn /usr/local/bin/cyferio-vpn

sudo cyferio-vpn install
sudo cyferio-vpn user add alice
sudo cyferio-vpn profile export alice
```

One self-contained file — no sibling directories required. See
[Single-File Distribution](architecture/11-single-file-distribution/) for
how that's built.

## Documentation

- [Architecture Overview](architecture/00-overview/) — design principles, component diagram, module boundaries
- [Directory Structure](architecture/01-directory-structure/)
- [Database Schema](architecture/02-database-schema/)
- [OpenVPN Integration & PKI Lifecycle](architecture/03-openvpn-integration/)
- [MAC Address Validation](architecture/04-mac-validation/)
- [Cloud Provider Detection](architecture/05-cloud-detection/)
- [Networking Validation](architecture/06-networking-validation/)
- [Logging](architecture/07-logging/)
- [Backup & Restore](architecture/08-backup-restore/)
- [Security Review & Threat Model](architecture/09-security-review/)
- [Testing Strategy](architecture/10-testing-strategy/)
- [Single-File Distribution](architecture/11-single-file-distribution/)

## Source & releases

- [GitHub repository](https://github.com/cloudlative/cyferio-openvpn-manager)
- [Latest release](https://github.com/cloudlative/cyferio-openvpn-manager/releases/latest)
- [CHANGELOG](https://github.com/cloudlative/cyferio-openvpn-manager/blob/master/CHANGELOG.md)

## Looking for a managed alternative?

This CLI is free and MIT-licensed, built to run entirely on your own
infrastructure. If you'd rather not self-host, Cyferio also offers a
hosted/managed OpenVPN product with a web dashboard — see
[cyferio.com](https://cyferio.com).

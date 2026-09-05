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

<div class="hero">
  <span class="hero-eyebrow">v1.1.0 &middot; MIT licensed</span>
  <h1>Cyferio OpenVPN Manager</h1>
  <p class="hero-tagline">A production-grade, bash-only OpenVPN deployment
  and management toolkit — no web UI, no browser dependency, no account.</p>
  <div class="hero-actions">
    <a class="btn btn-primary" href="#install">Install</a>
    <a class="btn btn-secondary" href="https://github.com/cloudlative/cyferio-openvpn-manager">View on GitHub</a>
    <a class="btn btn-secondary" href="architecture/00-overview/">Read the docs</a>
  </div>
</div>

Installs, configures, and manages an OpenVPN server end to end from a
single CLI (`cyferio-vpn`): cloud-aware pre-flight validation,
PKI/certificate lifecycle, per-user profile generation, MAC-address
device binding, backup/restore, auditing, and diagnostics — scriptable
via `--json` output on every reporting command, and also reachable
through a menu-driven `--interactive` mode.

## Install

```bash
curl -fsSL https://github.com/cloudlative/cyferio-openvpn-manager/releases/latest/download/cyferio-vpn \
  -o cyferio-vpn
chmod +x cyferio-vpn
sudo mv cyferio-vpn /usr/local/bin/cyferio-vpn

sudo cyferio-vpn install
sudo cyferio-vpn user add alice   # also exports alice's .ovpn profile
```

One self-contained file — no sibling directories required. See
[Single-File Distribution](architecture/11-single-file-distribution/)
for how that's built.

## Documentation

<ul class="doc-grid">
  <li><a class="doc-card" href="architecture/00-overview/"><span class="doc-card-num">00</span><span class="doc-card-title">Architecture Overview</span></a></li>
  <li><a class="doc-card" href="architecture/01-directory-structure/"><span class="doc-card-num">01</span><span class="doc-card-title">Directory Structure</span></a></li>
  <li><a class="doc-card" href="architecture/02-database-schema/"><span class="doc-card-num">02</span><span class="doc-card-title">Database Schema</span></a></li>
  <li><a class="doc-card" href="architecture/03-openvpn-integration/"><span class="doc-card-num">03</span><span class="doc-card-title">OpenVPN Integration & PKI Lifecycle</span></a></li>
  <li><a class="doc-card" href="architecture/04-mac-validation/"><span class="doc-card-num">04</span><span class="doc-card-title">MAC Address Validation</span></a></li>
  <li><a class="doc-card" href="architecture/05-cloud-detection/"><span class="doc-card-num">05</span><span class="doc-card-title">Cloud Provider Detection</span></a></li>
  <li><a class="doc-card" href="architecture/06-networking-validation/"><span class="doc-card-num">06</span><span class="doc-card-title">Networking Validation</span></a></li>
  <li><a class="doc-card" href="architecture/07-logging/"><span class="doc-card-num">07</span><span class="doc-card-title">Logging</span></a></li>
  <li><a class="doc-card" href="architecture/08-backup-restore/"><span class="doc-card-num">08</span><span class="doc-card-title">Backup & Restore</span></a></li>
  <li><a class="doc-card" href="architecture/09-security-review/"><span class="doc-card-num">09</span><span class="doc-card-title">Security Review & Threat Model</span></a></li>
  <li><a class="doc-card" href="architecture/10-testing-strategy/"><span class="doc-card-num">10</span><span class="doc-card-title">Testing Strategy</span></a></li>
  <li><a class="doc-card" href="architecture/11-single-file-distribution/"><span class="doc-card-num">11</span><span class="doc-card-title">Single-File Distribution</span></a></li>
</ul>

## Source & releases

- [GitHub repository](https://github.com/cloudlative/cyferio-openvpn-manager)
- [Latest release](https://github.com/cloudlative/cyferio-openvpn-manager/releases/latest)
- [CHANGELOG](https://github.com/cloudlative/cyferio-openvpn-manager/blob/master/CHANGELOG.md)

## Looking for a managed alternative?

This CLI is free and MIT-licensed, built to run entirely on your own
infrastructure. If you'd rather not self-host, Cyferio also offers a
hosted/managed OpenVPN product with a web dashboard — see
[cyferio.com](https://cyferio.com).

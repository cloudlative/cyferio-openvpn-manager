---
title: "06 — Networking Validation Design"
permalink: /architecture/06-networking-validation/
---

# 06 — Networking Validation Design

`lib/network.sh`, run automatically as `install`'s pre-flight and standalone via `cyferio-vpn diagnose`.

## Pre-flight sequence (spec-mandated checklist)

```
✓ Supported OS              (lib/core.sh: /etc/os-release match against Ubuntu 22.04/24.04, Debian 12)
✓ Internet Connectivity     (curl -s -m5 against a small fixed set of reliable endpoints)
✓ Package Manager           (apt-get lock check, not mid-upgrade)
✓ Public IP Detection       (curl against ifconfig.me-style endpoint, falls back to cloud metadata IP if available)
✓ Cloud Provider Detection  (delegates to cloud.sh, see 05-cloud-detection.md)
✓ Firewall Validation       (ufw/iptables/nftables state — is the chosen OpenVPN port open)
✓ Routing Validation        (default route present, no obviously conflicting routes to the VPN subnet)
✓ IP Forwarding Validation  (net.ipv4.ip_forward=1, and persisted in /etc/sysctl.d/ not just runtime)
✓ OpenVPN Port Validation   (chosen port not already bound by another process)
```

Each check returns `pass | warning | fail` plus an optional remediation string. `install` proceeds past `warning`s (with the warning block shown, per spec's AWS example) but stops before `fail`s (e.g., unsupported OS) unless `--force` is passed.

## Output contract

Shared by `install`'s pre-flight banner and `cyferio-vpn diagnose`:

```
✓ Supported OS
✓ Internet Connectivity
✓ Package Manager
✓ Public IP Detection
✓ Cloud Provider Detection
⚠ Firewall Validation

WARNING
AWS Source/Destination Check appears enabled.
OpenVPN routing may fail.

Recommended Action:
Disable Source/Destination Check.

✓ Routing Validation
✓ IP Forwarding Validation
✓ OpenVPN Port Validation
```

`--json` emits the same set as an array of `{name, status, message?, remediation?}` objects (identical shape to `05-cloud-detection.md`'s per-check objects — one schema reused across `network detect`, `diagnose`, and install's pre-flight).

## Relationship to `diagnose` (see also 10)

`diagnose` re-runs this same check set post-install plus service/cert/PKI-specific checks (owned by `diagnostics.sh`, which composes `network.sh`'s checks with its own rather than duplicating them) — one shared "checks" data shape flows into both `audit` and `diagnose`'s different-but-overlapping report sets.

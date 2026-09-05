---
title: "01 — Directory Structure"
permalink: /architecture/01-directory-structure/
---

# 01 — Directory Structure

```
cyferio-openvpn-manager/
├── bin/
│   └── cyferio-vpn                 # entry point: resolves lib/, sources modules, dispatches
├── lib/
│   ├── core.sh                     # bootstrap: strict mode, version, dispatch table
│   ├── logger.sh                   # structured logging to /var/log/cyferio/
│   ├── utils.sh                    # shared helpers: validation, prompts, privilege checks
│   ├── config.sh                   # load/merge /etc/cyferio/cyferio.conf
│   ├── database.sh                 # sqlite3 wrapper: migrations, exec/query primitives
│   ├── network.sh                  # pre-flight checks: connectivity, ports, forwarding
│   ├── cloud.sh                    # provider detection + per-provider validators
│   ├── backends/
│   │   └── openvpn.sh              # PKI, server config, hooks, client-connect/-disconnect
│   ├── certs.sh                    # cert create/revoke/list/status
│   ├── users.sh                    # user add/remove/enable/disable/get/list
│   ├── profiles.sh                 # .ovpn export/regenerate
│   ├── reporting.sh                # shared table/json/plain formatter layer
│   ├── macs.sh                     # MAC CRUD + enforcement + report
│   ├── status.sh                   # status command
│   ├── audit.sh                    # security/config audit checks
│   ├── diagnostics.sh              # connectivity/troubleshooting checks
│   ├── backup.sh                   # backup + restore (one implementation, both directions)
│   ├── install.sh                  # install/uninstall/network detect orchestration
│   └── ui.sh                       # whiptail/plain-fallback interactive menu
├── db/
│   └── migrations/
│       └── 0001_initial_schema.sql
├── config/
│   ├── cyferio.conf.example        # default config, copied to /etc/cyferio/ on install
│   └── server.conf.tmpl            # OpenVPN server config template
├── templates/
│   ├── client.ovpn.tmpl            # client profile template (push-peer-info, etc.)
│   ├── client-connect.sh.tmpl      # MAC enforcement hook
│   └── client-disconnect.sh.tmpl
├── scripts/
│   └── build-dist.sh               # generates dist/cyferio-vpn — see 11-single-file-distribution.md
├── dist/
│   └── cyferio-vpn                 # GENERATED single-file bundle — never hand-edit, gitignored
├── tests/
│   ├── unit/                       # bats-core, one *.bats per lib/*.sh (12 files)
│   ├── integration/                # phase2–phase13 scripts, run on a disposable VM
│   └── fixtures/
├── docs/
│   └── architecture/               # this design set, 00–11
├── .github/
│   └── workflows/
│       ├── shellcheck.yml
│       └── bats.yml
├── .gitignore
├── README.md
├── LICENSE
├── CHANGELOG.md
├── CONTRIBUTING.md
└── SECURITY.md
```

`lib/install.sh`, `lib/certs.sh`, `lib/status.sh`, and `db/migrations/` are
each their own file/directory rather than folded into `core.sh` or
`backends/openvpn.sh` — one module per command surface area, same
boundary rule as every other module (see
[00-overview.md](00-overview.md)).

`scripts/` and `dist/` exist for exactly one purpose — producing the
single-file distributable build — and are unrelated to the module
boundaries above; see
[11-single-file-distribution.md](11-single-file-distribution.md).

## Runtime filesystem layout (on a deployed server)

```
/usr/local/bin/cyferio-vpn                  # dist/cyferio-vpn, OR a symlink/copy of bin/cyferio-vpn
/usr/local/lib/cyferio-vpn/lib/*.sh         # installed modules (multi-file layout only)
/etc/cyferio/cyferio.conf                   # runtime config
/etc/cyferio/pki/                           # EasyRSA PKI (0700, root-owned)
/etc/cyferio/hooks/                         # client-connect/-disconnect hook scripts (0755, root-owned)
/etc/openvpn/server/                        # OpenVPN server config + certs in use
/var/lib/cyferio/cyferio.db                 # SQLite database (0600 root-owned, or 0660/nogroup post-install)
/var/log/cyferio/                           # application logs, rotated
~/vpn-profiles/                             # per-admin-user exported .ovpn files (spec-mandated path)
/var/backups/cyferio/                       # timestamped backup archives
```

`~/vpn-profiles/` is intentionally the *invoking admin's* home directory
(SUDO_USER-aware — see [03-openvpn-integration.md](03-openvpn-integration.md)),
not a shared system path — each admin who runs `user add` gets profiles
under their own account, whether run via `sudo` from the multi-file
checkout or via the single-file `dist/cyferio-vpn` build.

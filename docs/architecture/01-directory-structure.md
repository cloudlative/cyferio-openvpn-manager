# 01 — Directory Structure

```
cyferio-openvpn-manager/
├── bin/
│   └── cyferio-vpn                 # entry point: parses args, sources lib/, dispatches
├── lib/
│   ├── core.sh                     # bootstrap: strict mode, sourcing, dispatch table
│   ├── config.sh                   # load/write /etc/cyferio/cyferio.conf
│   ├── utils.sh                    # shared helpers: validation, prompts, retries
│   ├── logger.sh                   # structured logging to /var/log/cyferio/
│   ├── database.sh                 # sqlite3 wrapper: migrations, CRUD helpers
│   ├── network.sh                  # pre-flight checks: connectivity, ports, forwarding
│   ├── cloud.sh                    # provider detection + per-provider validators
│   ├── backends/
│   │   └── openvpn.sh              # PKI, server config, client-connect/-disconnect
│   ├── users.sh                    # user lifecycle, calls backends/openvpn.sh
│   ├── profiles.sh                 # .ovpn export/regenerate
│   ├── macs.sh                     # MAC CRUD + validation
│   ├── audit.sh                    # security/config audit checks
│   ├── diagnostics.sh              # connectivity/troubleshooting checks
│   ├── backup.sh
│   ├── restore.sh
│   ├── reporting.sh                # table/json/plain formatter layer
│   └── ui.sh                       # whiptail/dialog interactive menu
├── config/
│   ├── cyferio.conf.example        # default config, copied to /etc/cyferio/ on install
│   └── server.conf.tmpl            # OpenVPN server config template
├── templates/
│   ├── client.ovpn.tmpl            # client profile template (push-peer-info, etc.)
│   ├── client-connect.sh.tmpl      # MAC enforcement hook
│   └── client-disconnect.sh.tmpl
├── tests/
│   ├── unit/                       # bats-core, one *.bats per lib/*.sh
│   ├── integration/                # full install/uninstall/user-lifecycle on a VM
│   └── fixtures/
├── docs/
│   └── architecture/               # this design set
├── .github/
│   └── workflows/
│       ├── shellcheck.yml
│       └── bats.yml
├── README.md
├── LICENSE
├── CHANGELOG.md                    # added Phase 15
├── CONTRIBUTING.md                 # added Phase 15
└── SECURITY.md                     # added Phase 15
```

## Runtime filesystem layout (on a deployed server)

```
/usr/local/bin/cyferio-vpn                  # symlink or copy of bin/cyferio-vpn
/usr/local/lib/cyferio-vpn/lib/*.sh         # installed modules
/etc/cyferio/cyferio.conf                   # runtime config
/etc/cyferio/pki/                           # EasyRSA PKI (0700, root-owned)
/etc/openvpn/server/                        # OpenVPN server config + certs in use
/var/lib/cyferio/cyferio.db                 # SQLite database (0600, root-owned)
/var/log/cyferio/                           # application logs, rotated
~/vpn-profiles/                             # per-admin-user exported .ovpn files (spec-mandated path)
/var/backups/cyferio/                       # timestamped backup archives
```

`~/vpn-profiles/` is intentionally the *invoking admin's* home directory (per spec), not a shared system path — each admin who runs `user add` gets profiles under their own account.

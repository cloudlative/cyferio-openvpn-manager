---
title: "11 — Single-File Distribution (Phase 13)"
permalink: /architecture/11-single-file-distribution/
---

# 11 — Single-File Distribution (Phase 13)

## Why

The multi-file checkout (`bin/cyferio-vpn` sourcing 19 `lib/*.sh` modules,
plus `config/`, `templates/`, `db/migrations/`) is the right shape for
development — small, focused, `shellcheck`/`bats`-per-module — but it is
not the shape people expect to be handed for a CLI tool like this one:
the convention (see `angristan/openvpn-install`, `Nyr/openvpn-install`) is
one file you `curl`/`scp` straight to `/usr/local/bin/` and run.

`scripts/build-dist.sh` produces exactly that: `dist/cyferio-vpn`, a
single generated file with the full command surface, that runs with no
sibling `lib/`, `config/`, `templates/`, or `db/` directory anywhere near
it.

**`dist/cyferio-vpn` is a build artifact — never hand-edit it.** The
source of truth stays `lib/*.sh`; regenerate with `./scripts/build-dist.sh`.

## How it works

1. **Module order** is parsed directly out of `bin/cyferio-vpn`'s own
   `for module in ...` loop (see that file's ordering-dependency
   comment) rather than duplicated in the build script, so the two can
   never drift apart.
2. **Each module's shebang and `__CYFERIO_X_LOADED` guard block are
   stripped.** The guard exists to make re-sourcing a no-op — meaningless
   in a bundle where each module's text appears exactly once — and a
   bare top-level `return` (the guard's early-exit) errors when the file
   is *executed* rather than *sourced*, which is exactly how the
   installed single file runs.
3. **Non-script assets** — `config/cyferio.conf.example`,
   `config/server.conf.tmpl`, `templates/client.ovpn.tmpl`,
   `templates/client-connect.sh.tmpl`,
   `templates/client-disconnect.sh.tmpl`, and the one migration SQL file
   — are embedded as quoted-heredoc variable assignments (safe for
   arbitrary content — no expansion risk regardless of what the asset
   text contains).
4. **A bootstrap prologue runs first, before any module code** — mirroring
   `bin/cyferio-vpn`, which resolves `CYFERIO_ROOT_DIR` *before* its
   `source` loop, not after. This ordering matters: `database.sh` reads
   `CYFERIO_ROOT_DIR` on its very first line to set
   `CYFERIO_MIGRATIONS_DIR`, so the temp asset tree must already exist
   the moment module code starts running — a bug caught during this
   phase's real-VM verification (`install` failed with "migrations
   directory not found: ./db/migrations" until the bootstrap was moved
   ahead of the module loop).
   - `CYFERIO_SELF_PATH` is resolved once (same symlink-following logic
     `bin/cyferio-vpn` uses) and is the path baked into the installed
     `client-connect`/`client-disconnect` hooks
     ([04-mac-validation.md](04-mac-validation.md)) — it must be a
     stable, permanent path.
   - `CYFERIO_ROOT_DIR`, by contrast, is a fresh `mktemp -d` staging tree
     populated with the embedded assets on *every* invocation and removed
     on exit via an `EXIT` trap — it only needs to survive one command,
     never a reboot or a second invocation, so there is no
     stale-asset-on-upgrade problem to manage.

## What stays out of scope

Nothing about the command surface, security model, or module boundaries
changes — this phase is packaging only. See
[00-overview.md](00-overview.md) for the architecture itself and
[10-testing-strategy.md](10-testing-strategy.md) for how
`tests/integration/phase13-single-file-bundle.sh` verifies the bundle
end to end (install → cert/user/profile → status/audit/diagnose →
uninstall) from a directory containing nothing but the single file.

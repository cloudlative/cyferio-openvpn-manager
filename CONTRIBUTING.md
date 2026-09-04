# Contributing to Cyferio OpenVPN Manager

Thanks for considering a contribution. This is a bash-only CLI — no web UI,
no runtime dependencies beyond a handful of standard packages — and the
project holds itself to a fairly strict bar for a shell codebase. This
document covers what's expected of a change before it's mergeable.

## Prerequisites

- Bash 5+ (the codebase runs under `set -Eeuo pipefail` throughout).
- [`shellcheck`](https://www.shellcheck.net/) 0.9+
- [`bats-core`](https://bats-core.readthedocs.io/) for unit tests
- `jq`, `sqlite3` (the tool's own runtime dependencies — needed to run it
  at all, in-place or installed)
- `whiptail` (optional — the interactive menu falls back to a plain
  numbered prompt if it isn't present, but you'll want it to exercise the
  default path)

On Debian/Ubuntu:

```bash
sudo apt-get install shellcheck bats jq sqlite3 whiptail
```

## Project layout

See [`docs/architecture/01-directory-structure.md`](docs/architecture/01-directory-structure.md)
for the full layout and [`docs/architecture/00-overview.md`](docs/architecture/00-overview.md)
for the module boundaries — each concern (`core`, `network`, `openvpn`,
`users`, `macs`, `audit`, `backup`, `ui`, ...) is exactly one file in `lib/`,
sourced once by `bin/cyferio-vpn`. Read the architecture doc for the area
you're touching before making changes; it documents the design decisions
(and a few hard-won bugs) behind non-obvious code.

## Running the tool without installing it

`bin/cyferio-vpn` resolves its own `lib/` directory relative to itself, so
it runs fine straight out of a checkout:

```bash
sudo ./bin/cyferio-vpn install
./bin/cyferio-vpn status
```

Override `CYFERIO_CONF_DIR` / `CYFERIO_DATA_DIR` / `CYFERIO_LOG_DIR` to
point at scratch directories instead of `/etc`, `/var/lib`, `/var/log` —
every unit test does exactly this, and it's the easiest way to poke at the
tool without touching real system state.

## Coding conventions

- **Strict mode everywhere.** Every script starts with
  `set -Eeuo pipefail`. Know the two footguns this codebase has already hit
  and worked around, both documented inline where they matter:
  - `exit`/`die()` inside a function invoked via command substitution
    (`x="$(some_func)"`) only kills the subshell that command substitution
    runs in, not the caller — functions that need to signal failure to a
    caller doing `x="$(...)"` must use an explicit `return`, and the call
    site must check it (`|| die ...`).
  - The same applies to any non-zero exit under `$(...)` tripping the ERR
    trap — see `lib/ui.sh`'s `_ui_menu`/`_ui_input` for the pattern used to
    swallow a whiptail Cancel/ESC cleanly instead of killing the session.
- **No `eval` on user-derived input**, anywhere. Every external input
  (username, MAC address, file path) is checked against a strict allowlist
  regex (`lib/utils.sh:validate_username`, `validate_mac`) *before* it's
  used, not just quoted defensively.
- **Quote every expansion.** ShellCheck enforces most of this already —
  see below.
- **SQL values are bound, never interpolated.** `lib/database.sh` wraps
  every write through `.param set`; don't add a new query that builds SQL
  by string concatenation.
- **Idempotency.** Any command that mutates system state (`install`,
  `user add`, `mac add`, ...) must be safe to re-run — check current state
  before acting, don't assume a clean slate.
- **Every reporting command supports `table` (default), `--json`, and
  `--plain`** via `lib/reporting.sh`'s shared formatter — don't hand-roll
  a fourth output format.
- 2-space indentation, `snake_case` function names, a module-load guard at
  the top of every `lib/*.sh` file (see any existing file for the pattern)
  so double-sourcing is a no-op.

## Tests

### Unit tests (required for every change)

One `.bats` file per `lib/*.sh` module under `tests/unit/`. Run the whole
suite:

```bash
bats tests/unit/
```

Or a single file while iterating:

```bash
bats tests/unit/macs.bats
```

Unit tests never touch real `/etc` or `/var` paths — they redirect
`CYFERIO_*_DIR` to a `mktemp -d` scratch tree and stub out anything that
would otherwise shell out to the real system (`systemctl`, `ss`,
`iptables`, `easyrsa`, ...). Follow that pattern for new tests.

### Static analysis (required for every change)

```bash
shellcheck lib/*.sh lib/backends/*.sh bin/cyferio-vpn templates/*.sh.tmpl
```

Zero warnings is the bar. SC2015 (`A && B || C`) notes on the
`pass`/`fail` idiom used throughout `tests/integration/*.sh` are a known,
accepted exception in that directory only — don't carry that pattern into
`lib/`.

### Integration tests (maintainer-run, need cloud credentials)

`tests/integration/*.sh` drive the real installed tool end-to-end against
disposable cloud VMs — they're destructive by design (install/uninstall
cycles, permission tampering, service restarts) and are not part of the
PR-gate CI. If you're changing anything under `lib/backends/openvpn.sh`,
`lib/install.sh`, or anything else that touches real system state, a
maintainer will run the relevant integration script against a throwaway
VM before merging; feel free to do the same against your own disposable
VM and include the output in your PR description.

## Submitting a change

1. Fork and branch from `master`.
2. Make your change, keeping it scoped — prefer several small PRs over one
   large one.
3. Run `shellcheck` and the full unit suite locally; both must be clean.
4. Update the relevant `docs/architecture/*.md` file if your change alters
   a documented design decision (schema, command surface, security
   posture, etc.) — the architecture docs are meant to stay accurate, not
   describe an earlier design.
5. Add a `CHANGELOG.md` entry under `[Unreleased]`.
6. Open a PR describing what changed and why; link any relevant issue.

## Reporting bugs / requesting features

Open a GitHub issue. For anything security-relevant, see
[SECURITY.md](SECURITY.md) instead — please don't open a public issue for
a vulnerability.

## License

By contributing, you agree your contribution is licensed under this
project's [MIT License](LICENSE).

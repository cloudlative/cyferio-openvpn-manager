# Security Policy

## Supported versions

No version has been tagged for release yet — `master` is the only
supported line during pre-release development. Once tagging begins, this
section will list which release lines receive security fixes.

## Reporting a vulnerability

Please **do not** open a public GitHub issue for a security vulnerability.

Instead, email **security@cyferio.com** with a description of the issue,
steps to reproduce, and its impact. If you don't get a response within 72
hours, follow up via [LinkedIn](https://www.linkedin.com/in/cloudlative).

We'll acknowledge your report, investigate, and keep you updated as a fix
is developed. Please give us a reasonable window to ship a fix before any
public disclosure.

## Scope

In scope: anything in this repository — the CLI itself, the installer,
the client-connect/-disconnect hooks, PKI handling, the database layer,
backup/restore.

Out of scope, by design (see
[docs/architecture/09-security-review.md](docs/architecture/09-security-review.md)):
this tool never starts a web server or listens on any port itself (OpenVPN
does that), so there is no HTTP-layer attack surface — no XSS, CSRF, or
web auth bypass to report, because none of that code exists.

## Security posture summary

The full threat model lives in
[docs/architecture/09-security-review.md](docs/architecture/09-security-review.md);
this is the short version.

| Area | Posture |
|---|---|
| Privilege | Every mutating command checks `EUID` up front and refuses cleanly rather than failing partway through. |
| Input validation | Username and MAC address are checked against a strict allowlist regex *before* use anywhere (`utils.sh:validate_username`, `validate_mac`) — not just quoted defensively. No `eval` on user-derived input anywhere in the codebase. |
| SQL | `database.sh` binds every value via `sqlite3`'s parameter binding; nothing is string-concatenated into a query. |
| File permissions | PKI directory `0700`, CA private key `0600`, database `0660`, both re-asserted (not just set once) so drift gets corrected on every `install` re-run, not only on first install. `cyferio-vpn audit` checks and reports on all of this directly. |
| Path traversal | Username allowlist blocks `../`-style paths by construction for profile exports; `restore` additionally rejects any backup archive containing an absolute path or a `..` path segment *before* extracting anything, and verifies a SHA-256 manifest against every extracted file before touching live state. |
| Secrets | No application login/password exists — there is no web UI. Private keys are never printed to stdout or logs, never passed as a CLI argument (visible in `ps`/shell history), and are only ever read from disk. |
| Dropped-privilege hook access | The OpenVPN `client-connect`/`client-disconnect` hooks run as `nobody:nogroup` (matching OpenVPN's own `user nobody` / `group nogroup` directives) and need to read `users`/`user_macs` and write `audit_logs` directly. `install` grants `nogroup` group access to the data directory and database file (`0770`/`0660`) for exactly this. This is an accepted trade-off: it grants `nogroup` write access to the whole database file, not just the `audit_logs` table — but the hook scripts themselves are root-installed and root-owned (`0755`, not attacker-writable), and the only attacker-influenced input reaching SQL through them (`IV_HWADDR`, `common_name`) is validated the same way every other write path is. |
| MAC-address enforcement | OpenVPN's client-supplied `IV_HWADDR` peer-info is **not cryptographically verified** — it's whatever the client chooses to report. Treat MAC enforcement as a device-management/policy control, not a security boundary. Note also that the standard Linux `openvpn` CLI client does not populate this field at all (only managed clients like OpenVPN Connect do) — see [docs/architecture/04-mac-validation.md](docs/architecture/04-mac-validation.md). |

## CA key handling: default vs. offline-CA posture

**Default (`cyferio-vpn install`):** the CA private key is generated on,
and stays on, the deployment host at `/etc/cyferio/pki/private/ca.key`
(`0600`, root-owned, never leaves that directory, never included
unencrypted anywhere it wouldn't already be at that permission level).
This is a deliberate trade-off for install simplicity — a single command
stands up a fully working VPN with no separate CA infrastructure to
manage. It means CA key compromise is equivalent to full compromise of
the deployment host itself.

**For high-security deployments**, consider an offline-CA posture
instead: generate the CA on a separate, air-gapped machine using the same
`easyrsa` tooling `cyferio-vpn` uses internally, then only ever copy the
signed **server certificate** (not the CA key) to the deployment host.
Client certificate signing requests would then need to be transferred to
the offline CA machine and the signed certs brought back — this is a
manual process `cyferio-vpn` does not currently automate (`cert
create`/`profile export` assume a co-located CA). If you need this, treat
`/etc/cyferio/pki` as CA-key-absent on the deployment host and adapt the
signing step accordingly; this is worth automating properly rather than
hand-rolling per deployment — see the open items in
[README.md](README.md)/[CHANGELOG.md](CHANGELOG.md) if you'd like to
contribute it.

## Static analysis

Every commit runs `shellcheck` with zero warnings as a merge gate — see
[docs/architecture/10-testing-strategy.md](docs/architecture/10-testing-strategy.md).
This catches unquoted expansions, unsafe `eval`, and word-splitting bugs
before any manual review, though it's not a substitute for one.

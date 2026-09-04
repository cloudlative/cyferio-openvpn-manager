# 09 — Security Review & Threat Model

## Threat model summary

| Threat | Attack surface | Mitigation |
|---|---|---|
| Privilege escalation | Any command run as non-root that touches PKI/system config | Every mutating command checks `EUID`/`sudo` up front and refuses with a clear message rather than silently failing partway through (avoids partial-privilege corruption); PKI/DB files `0600`/`0700` root-owned so even a local non-root user can't read keys |
| Command injection | Username/MAC/paths interpolated into shell commands (`easyrsa`, `sqlite3`, `tar`) | Every external input validated against a strict allowlist regex *before* use (`utils.sh:validate_username` `^[a-zA-Z0-9_-]{1,32}$`, `validate_mac` as in 04); all variable expansions quoted; no `eval` on user-derived strings anywhere in the codebase (enforced by a ShellCheck rule + a CI grep-based guard for raw `eval`) |
| SQL injection | Username/MAC values reaching `sqlite3` | `database.sh` binds every value via `sqlite3`'s parameter binding (`.param set`), never string-concatenates user input into a SQL string — detailed pattern shown below |
| Path traversal | Username used to build `~/vpn-profiles/<username>.ovpn`, backup/restore archive paths | Username allowlist (above) blocks `../` and similar by construction; `restore` additionally validates the extracted archive path stays within its temp dir before any file operation |
| Secrets handling | CA/server/client private keys, no application "password" secrets in this design (no web login) | Keys never printed to stdout/logs; never passed as CLI args (visible in `ps`/history) — always read from files; PKI dir `0700` |
| File permissions | DB, PKI, logs, config | Explicit `chmod`/`chown` as part of `install`, re-asserted (not just set-once) on every idempotent re-run so drift gets corrected, not just initial state |
| DB access from the dropped-privilege hook user | `client-connect`/`client-disconnect` run as `nobody:nogroup` and need to read `users`/`user_macs` and write `audit_logs` (Phase 7 — [04-mac-validation.md](04-mac-validation.md)) | `install` re-groups `/var/lib/cyferio` and `cyferio.db` to `nogroup`, `0770`/`0660` (same posture as the Phase 5 log-directory precedent). Accepted trade-off: this grants `nogroup` write access to the *whole* DB file, not just `audit_logs` — a compromised/modified hook script could tamper with `users`/`user_macs` too — but the hook scripts are root-installed/root-owned `0755` (not attacker-writable) and the only attacker-controlled input reaching SQL through them is `$IV_HWADDR`/`$common_name`, both routed through `validate_mac`/`sql_quote` before ever reaching `db_exec`, same as every other write path |
| PKI protection | CA private key compromise = full trust compromise | CA key never leaves `/etc/cyferio/pki` (`0700`); no plaintext CA key in backups beyond the same-permission tarball; `SECURITY.md` (Phase 15) documents recommended offline-CA posture for high-security deployments as a documented option, not forced default (keeps the default install simple per spec's ease-of-use goals) |
| MAC spoofing | Client-supplied `IV_HWADDR` peer-info is not cryptographically verified | Documented explicitly as a policy/device-management control, not a security boundary — see [04-mac-validation.md](04-mac-validation.md)'s Limitations note; called out again in README's Security Considerations |
| `client-connect` script trust | `script-security 2` widens OpenVPN's own attack surface if the hook script itself is writable by non-root | Hook scripts installed `0700` root-owned; `script-security 2` (not `3`) — no shell metacharacter execution beyond running the fixed hook path itself |

## SQL injection — binding pattern

```bash
# database.sh
db_user_insert() {
  local username="$1"
  sqlite3 "$DB_PATH" <<SQL
.param set :username '$(printf '%s' "$username" | sed "s/'/''/g")'
INSERT INTO users (username) VALUES (:username);
SQL
}
```
(Actual implementation in Phase 1 will additionally re-validate `username` against the allowlist regex *before* this function is ever called — defense in depth, not relying on quoting alone.)

## ShellCheck / static analysis

CI runs `shellcheck -x` (follows `source`) on every `.sh` file with zero warnings as a merge gate — covers unquoted expansions, unsafe `eval`, word-splitting bugs, and more, before any manual review. See [10-testing-strategy.md](10-testing-strategy.md).

## Out of scope (explicitly, per spec)

Geo-restrictions, bandwidth limiting, and any browser-facing surface are explicitly not part of this product's threat model — no web server is ever started, so no HTTP-layer attack surface (XSS/CSRF/auth-bypass) exists to review.

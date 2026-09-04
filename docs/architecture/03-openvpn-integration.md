# 03 — OpenVPN Integration & PKI Lifecycle

`lib/backends/openvpn.sh` is the only module aware of OpenVPN/EasyRSA specifics.

## PKI lifecycle

1. **Bootstrap** (`install`): `easyrsa init-pki` → `easyrsa build-ca nopass` → `easyrsa gen-req server nopass` → `easyrsa sign-req server server` → `easyrsa gen-dh` → `openvpn --genkey secret ta.key` (tls-crypt). PKI lives at `/etc/cyferio/pki`, `0700` root-owned; CA private key never leaves that directory and is never copied into a client profile.
2. **Client cert issuance** (`user add`): `easyrsa gen-req <username> nopass` → `easyrsa sign-req client <username>`. One cert per username; re-running `user add` on an existing active user is rejected (idempotency is at the `users` table level, not re-issuing silently).
3. **Revocation** (`user remove` / `user disable`): `easyrsa revoke <username>` → `easyrsa gen-crl` → reload `crl-verify` file OpenVPN already watches (no service restart needed, matches upstream OpenVPN CRL reload behavior).
4. **Regeneration** (`profile regenerate`): revokes the old cert, issues a new one, re-renders the `.ovpn` — used for a lost/compromised client without changing the username or DB row.

## Server configuration

Rendered from `config/server.conf.tmpl` (placeholders: port, proto, subnet, DNS, `client-connect`/`client-disconnect` script paths) into `/etc/openvpn/server/server.conf`. Managed via the distro's `openvpn-server@server` systemd unit (`systemctl enable --now openvpn-server@server`), so idempotent re-installs just re-render the template and `systemctl reload-or-restart` rather than reinstalling the package.

## Client profile rendering

`templates/client.ovpn.tmpl` embeds:
- CA cert, client cert, client key, `tls-crypt` key (inlined `<ca>`/`<cert>`/`<key>`/`<tls-crypt>` blocks — single-file profile, no companion files to lose)
- `remote <public-ip-or-hostname> <port> <proto>`
- **`push-peer-info`** — required per spec, so the server receives client-supplied info (used by the MAC-enforcement hook, see [04-mac-validation.md](04-mac-validation.md))

`profiles.sh` calls `vpn_backend_render_profile <username>` which fills the template and writes to `~/vpn-profiles/<username>.ovpn` for the invoking admin, then updates `users.profile_path`.

## Backend-agnostic interface (see also 00-overview.md)

```bash
vpn_backend_provision_client <username>    # -> cert issuance, returns 0/1
vpn_backend_revoke_client <username>
vpn_backend_render_profile <username>      # -> writes .ovpn, echoes path
vpn_backend_server_status                  # -> running|stopped (+ optional detail)
vpn_backend_connected_clients              # -> count, for status.sh
```
`users.sh`, `profiles.sh`, and `status.sh` call only these five functions — never `easyrsa`/`openvpn` directly — so a future backend module is a drop-in replacement.

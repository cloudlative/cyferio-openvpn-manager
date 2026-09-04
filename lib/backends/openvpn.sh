#!/usr/bin/env bash
# backends/openvpn.sh — the only module aware of OpenVPN/EasyRSA specifics.
# Backend-agnostic interface (see docs/architecture/00-overview.md):
#   vpn_backend_provision_client / _revoke_client / _render_profile
#   vpn_backend_server_status / _connected_clients
# Phase 2 implements PKI bootstrap (CA + server cert), server config
# rendering, systemd, and NAT/firewall — the client-cert side of the
# interface (provision/revoke/render_profile) lands in Phase 3/4.

if [[ -n "${__CYFERIO_BACKEND_OPENVPN_LOADED:-}" ]]; then
  return 0
fi
__CYFERIO_BACKEND_OPENVPN_LOADED=1

OVPN_SERVER_DIR="/etc/openvpn/server"
OVPN_SERVER_CONF="${OVPN_SERVER_DIR}/server.conf"
OVPN_CRL_PATH="${OVPN_SERVER_DIR}/crl.pem"
OVPN_SYSTEMD_UNIT="openvpn-server@server"

ovpn_pki_dir() {
  echo "${CYFERIO_CONF_DIR}/pki"
}

ovpn_hooks_dir() {
  echo "${CYFERIO_CONF_DIR}/hooks"
}

# _ovpn_easyrsa_bin — locate the easyrsa3 executable across distro layouts.
_ovpn_easyrsa_bin() {
  if is_command_available easyrsa; then
    command -v easyrsa
    return 0
  fi
  local candidate
  for candidate in /usr/share/easy-rsa/easyrsa /usr/share/easy-rsa/*/easyrsa; do
    if [[ -x "${candidate}" ]]; then
      echo "${candidate}"
      return 0
    fi
  done
  return 1
}

# _ovpn_easyrsa ARGS... — run easyrsa non-interactively against our PKI dir.
# Deliberately does NOT set EASYRSA_REQ_CN globally: easyrsa3 in batch mode
# does NOT derive a cert's CN from gen-req's short-name argument — every
# `gen-req`/`build-ca` call uses EASYRSA_REQ_CN verbatim (falling back to
# its own built-in placeholder, "ChangeMe", if unset). A single global CN
# would put the SAME CN on the CA, the server cert, and every client cert.
# Each call site that issues a cert sets its own CN explicitly via
# _ovpn_easyrsa_env below.
_ovpn_easyrsa() {
  _ovpn_easyrsa_env "$@"
}

# _ovpn_easyrsa_env [VAR=VALUE ...] -- ARGS... — like _ovpn_easyrsa, but lets
# the caller pass extra environment for this one invocation — every
# gen-req/build-ca call uses this to set EASYRSA_REQ_CN to the identity
# actually being issued. Env assignments must come first and be followed
# by `--`.
_ovpn_easyrsa_env() {
  local -a extra_env=()
  while [[ "$1" == *=* ]]; do
    extra_env+=("$1")
    shift
  done
  [[ "${1:-}" == "--" ]] && shift

  local bin
  bin="$(_ovpn_easyrsa_bin)" || die "easyrsa executable not found (is the easy-rsa package installed?)" 3
  env "${extra_env[@]}" \
    EASYRSA_PKI="$(ovpn_pki_dir)" \
    EASYRSA_BATCH=1 \
    "${bin}" "$@" >/tmp/cyferio-easyrsa.$$ 2>&1
  local status=$?
  if [[ ${status} -ne 0 ]]; then
    cat /tmp/cyferio-easyrsa.$$ >&2
  fi
  rm -f /tmp/cyferio-easyrsa.$$
  return "${status}"
}

# ovpn_install_packages — idempotent: apt-get install is a no-op for
# already-installed packages.
ovpn_install_packages() {
  require_root
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq openvpn easy-rsa sqlite3 jq curl iproute2 iptables >/dev/null
  log_info "install.packages" "result=success"
}

# ovpn_pki_bootstrap — CA + server certificate. Idempotent: skips whatever
# already exists rather than re-running (a partial prior run resumes
# cleanly instead of erroring on "already exists").
ovpn_pki_bootstrap() {
  require_root
  local pki_dir
  pki_dir="$(ovpn_pki_dir)"
  mkdir -p "${CYFERIO_CONF_DIR}"

  if [[ ! -f "${pki_dir}/ca.crt" ]]; then
    _ovpn_easyrsa init-pki || die "easyrsa init-pki failed" 3
    _ovpn_easyrsa_env "EASYRSA_REQ_CN=Cyferio-CA" -- build-ca nopass || die "easyrsa build-ca failed" 3
    log_info "install.pki" "step=ca result=created"
  else
    log_info "install.pki" "step=ca result=skipped_existing"
  fi

  if [[ ! -f "${pki_dir}/issued/server.crt" ]]; then
    _ovpn_easyrsa_env "EASYRSA_REQ_CN=server" -- gen-req server nopass || die "easyrsa gen-req server failed" 3
    _ovpn_easyrsa sign-req server server || die "easyrsa sign-req server failed" 3
    log_info "install.pki" "step=server_cert result=created"
  else
    log_info "install.pki" "step=server_cert result=skipped_existing"
  fi

  if [[ ! -f "${pki_dir}/dh.pem" ]]; then
    _ovpn_easyrsa gen-dh || die "easyrsa gen-dh failed" 3
    log_info "install.pki" "step=dh result=created"
  else
    log_info "install.pki" "step=dh result=skipped_existing"
  fi

  if [[ ! -f "${pki_dir}/ta.key" ]]; then
    openvpn --genkey secret "${pki_dir}/ta.key" || die "openvpn --genkey secret failed" 3
    log_info "install.pki" "step=tls_crypt_key result=created"
  else
    log_info "install.pki" "step=tls_crypt_key result=skipped_existing"
  fi

  # Always (re-)export the CRL — cheap, and covers the case where a prior
  # install got this far but crashed before the export step.
  _ovpn_easyrsa gen-crl || die "easyrsa gen-crl failed" 3
  ovpn_export_crl

  chmod 0700 "${pki_dir}"
  [[ -d "${pki_dir}/private" ]] && chmod 0700 "${pki_dir}/private"
  chmod 0600 "${pki_dir}"/private/* 2>/dev/null || true
}

# ovpn_export_crl — copy the CRL out of the 0700 PKI dir to a
# world-readable location so `openvpn-server@server` (running as
# `nobody`) can re-read it on every client connect. Called by
# ovpn_pki_bootstrap and again on every future revocation (Phase 3).
ovpn_export_crl() {
  local pki_dir
  pki_dir="$(ovpn_pki_dir)"
  mkdir -p "${OVPN_SERVER_DIR}"
  install -m 0644 "${pki_dir}/crl.pem" "${OVPN_CRL_PATH}"
}

# ovpn_install_hooks — render the client-connect/-disconnect hooks (Phase 2:
# accept-and-log stub; Phase 7: real MAC enforcement, same file paths,
# delegating to `cyferio-vpn internal mac-check` — see
# docs/architecture/04-mac-validation.md).
#
# Installed 0755 (root-owned, world-executable), NOT 0700: the daemon
# invokes these as `nobody:nogroup` (server.conf's `user nobody` /
# `group nogroup`, dropped before any client connects), so a root-only
# mode makes every connection fail with a silent-looking AUTH_FAILED —
# OpenVPN logs "could not execute external program" server-side, but the
# client just sees an auth failure with no indication it was a
# permissions problem on the hook script. Still root-owned/writable only
# by root — these scripts carry no secrets, only log lines.
ovpn_install_hooks() {
  require_root
  local hooks_dir template_dir
  hooks_dir="$(ovpn_hooks_dir)"
  template_dir="${CYFERIO_ROOT_DIR}/templates"
  mkdir -p "${hooks_dir}"

  # The hooks also need to actually be able to WRITE their audit-trail
  # log line, not just execute — /var/log/cyferio is 0750 root:root by
  # default (07-logging.md), which the daemon's dropped-privilege
  # `nobody:nogroup` can't write into. Re-group it to `nogroup` (the
  # group server.conf's `group nogroup` directive actually drops to) and
  # make it group-writable, rather than leaving connect/disconnect
  # events silently undocumented in the log.
  mkdir -p "${CYFERIO_LOG_DIR}"
  chgrp nogroup "${CYFERIO_LOG_DIR}" 2>/dev/null || true
  chmod 0770 "${CYFERIO_LOG_DIR}"
  # The directory bit alone isn't enough for a file that already exists
  # (root-created log entries from earlier install steps land as 0644,
  # not group-writable) — fix the file's own mode/group too, creating it
  # first if this is a fresh install.
  touch "${CYFERIO_LOG_DIR}/cyferio.log"
  chgrp nogroup "${CYFERIO_LOG_DIR}/cyferio.log" 2>/dev/null || true
  chmod 0660 "${CYFERIO_LOG_DIR}/cyferio.log"

  # The hooks invoke `cyferio-vpn internal mac-check`/`disconnect-log`
  # themselves (Phase 7) — bake in the real path to this checkout's own
  # bin/cyferio-vpn (CYFERIO_ROOT_DIR is set by bin/cyferio-vpn to
  # wherever it's actually running from, dev-in-place or installed, so
  # this is always correct without guessing $PATH at hook-execution time
  # — the hook runs as `nobody`, which may not even share root's PATH).
  local cyferio_bin="${CYFERIO_ROOT_DIR}/bin/cyferio-vpn"
  sed -e "s|__CYFERIO_BIN__|${cyferio_bin}|g" \
    "${template_dir}/client-connect.sh.tmpl" >"${hooks_dir}/client-connect.sh.new"
  sed -e "s|__CYFERIO_BIN__|${cyferio_bin}|g" \
    "${template_dir}/client-disconnect.sh.tmpl" >"${hooks_dir}/client-disconnect.sh.new"
  mv "${hooks_dir}/client-connect.sh.new" "${hooks_dir}/client-connect.sh"
  mv "${hooks_dir}/client-disconnect.sh.new" "${hooks_dir}/client-disconnect.sh"
  chmod 0755 "${hooks_dir}/client-connect.sh" "${hooks_dir}/client-disconnect.sh"
  log_info "install.hooks" "result=success"
}

# ovpn_render_server_config — fill config/server.conf.tmpl and install it.
# Re-run on every `install` (idempotent by re-render, not by skip) so a
# config-format change in a later version is picked up on upgrade.
ovpn_render_server_config() {
  require_root
  local template="${CYFERIO_ROOT_DIR}/config/server.conf.tmpl"
  [[ -f "${template}" ]] || die "server config template not found: ${template}" 3

  mkdir -p "${OVPN_SERVER_DIR}"

  sed \
    -e "s|__VPN_PORT__|$(config_get vpn_port)|g" \
    -e "s|__VPN_PROTO__|$(config_get vpn_proto)|g" \
    -e "s|__VPN_SUBNET__|$(config_get vpn_subnet)|g" \
    -e "s|__VPN_SUBNET_MASK__|$(config_get vpn_subnet_mask)|g" \
    -e "s|__PKI_DIR__|$(ovpn_pki_dir)|g" \
    -e "s|__HOOKS_DIR__|$(ovpn_hooks_dir)|g" \
    "${template}" >"${OVPN_SERVER_CONF}.new"

  mkdir -p /var/lib/cyferio
  mv "${OVPN_SERVER_CONF}.new" "${OVPN_SERVER_CONF}"
  chmod 0644 "${OVPN_SERVER_CONF}"
  log_info "install.server_config" "result=success" "port=$(config_get vpn_port)" "proto=$(config_get vpn_proto)"
}

# ovpn_configure_ip_forwarding — enable + persist net.ipv4.ip_forward=1.
ovpn_configure_ip_forwarding() {
  require_root
  local sysctl_file="/etc/sysctl.d/99-cyferio-forwarding.conf"
  echo "net.ipv4.ip_forward = 1" >"${sysctl_file}"
  sysctl -q -p "${sysctl_file}"
  log_info "install.ip_forward" "result=success"
}

# _ovpn_wan_interface — best-effort primary outbound interface.
_ovpn_wan_interface() {
  ip route show default 2>/dev/null | awk '/^default/ {for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -n1
}

# ovpn_configure_nat_and_firewall — MASQUERADE the VPN subnet out the WAN
# interface and open the OpenVPN port. Idempotent: rule-presence is checked
# with `iptables -C` before `iptables -A`, so re-running doesn't duplicate
# rules. Persisted via netfilter-persistent so it survives reboot.
ovpn_configure_nat_and_firewall() {
  require_root
  local wan_if subnet_cidr port proto
  wan_if="$(_ovpn_wan_interface)"
  [[ -n "${wan_if}" ]] || die "could not determine the outbound network interface" 3
  local prefix
  # Computed separately, not inlined into the subnet_cidr expression: if
  # netmask_to_prefix's internal die() fires, exit-inside-a-subshell only
  # kills that nested command substitution — buried inside a larger
  # string-concatenation assignment, that failure could otherwise be
  # silently swallowed into a malformed "10.8.0.0/" CIDR instead of
  # actually stopping the function.
  prefix="$(netmask_to_prefix "$(config_get vpn_subnet_mask)")" || die "invalid vpn_subnet_mask in config" 1
  subnet_cidr="$(config_get vpn_subnet)/${prefix}"
  port="$(config_get vpn_port)"
  proto="$(config_get vpn_proto)"

  if ! iptables -t nat -C POSTROUTING -s "${subnet_cidr}" -o "${wan_if}" -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s "${subnet_cidr}" -o "${wan_if}" -j MASQUERADE
  fi
  if ! iptables -C INPUT -p "${proto}" --dport "${port}" -j ACCEPT 2>/dev/null; then
    iptables -I INPUT -p "${proto}" --dport "${port}" -j ACCEPT
  fi
  if ! iptables -C FORWARD -i tun0 -o "${wan_if}" -j ACCEPT 2>/dev/null; then
    iptables -A FORWARD -i tun0 -o "${wan_if}" -j ACCEPT
  fi
  if ! iptables -C FORWARD -i "${wan_if}" -o tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
    iptables -A FORWARD -i "${wan_if}" -o tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT
  fi

  if is_command_available netfilter-persistent; then
    netfilter-persistent save >/dev/null 2>&1 || true
  elif [[ -d /etc/iptables ]]; then
    iptables-save >/etc/iptables/rules.v4 2>/dev/null || true
  fi

  log_info "install.firewall" "result=success" "wan_if=${wan_if}" "port=${port}/${proto}"
}

# ovpn_enable_service — enable + (re)start via systemd, then verify.
ovpn_enable_service() {
  require_root
  systemctl enable "${OVPN_SYSTEMD_UNIT}" >/dev/null 2>&1
  systemctl restart "${OVPN_SYSTEMD_UNIT}"
  sleep 1
  if ! systemctl is-active --quiet "${OVPN_SYSTEMD_UNIT}"; then
    journalctl -u "${OVPN_SYSTEMD_UNIT}" --no-pager -n 30 >&2 || true
    die "openvpn-server@server failed to start — see journalctl output above" 3
  fi
  log_info "install.service" "result=running"
}

# vpn_backend_server_status — running|stopped, for status.sh (Phase 9).
vpn_backend_server_status() {
  if systemctl is-active --quiet "${OVPN_SYSTEMD_UNIT}" 2>/dev/null; then
    echo running
  else
    echo stopped
  fi
}

# ovpn_status_clients — one pipe-delimited row per currently connected
# client: common_name|real_address|virtual_address|bytes_received|
# bytes_sent|connected_since. Parses OpenVPN's status-version 2 file
# (server.conf.tmpl's `status-version 2` — the default, unset, is
# version 1's plain CSV with no CLIENT_LIST prefix at all, which this
# would silently match zero lines of). Column indices per OpenVPN's own
# v2 CLIENT_LIST header: CommonName,RealAddress,VirtualAddress,
# VirtualIPv6Address,BytesReceived,BytesSent,ConnectedSince,... — field 5
# (IPv6) is skipped, nothing else in this repo needs it yet.
ovpn_status_clients() {
  local status_file="${CYFERIO_LOG_DIR}/openvpn-status.log"
  [[ -f "${status_file}" ]] || return 0
  awk -F',' '$1=="CLIENT_LIST"{print $2"|"$3"|"$4"|"$6"|"$7"|"$8}' "${status_file}"
}

# vpn_backend_connected_clients — count of currently connected clients,
# for status.sh (Phase 9).
vpn_backend_connected_clients() {
  local clients
  clients="$(ovpn_status_clients)"
  if [[ -z "${clients}" ]]; then
    echo 0
  else
    wc -l <<<"${clients}"
  fi
}

# --- client certificate lifecycle (Phase 3) -----------------------------
# vpn_backend_provision_client / _revoke_client complete the
# backend-agnostic interface from docs/architecture/00-overview.md.
# lib/certs.sh (cert create/revoke/list/status) and, from Phase 4 on,
# lib/users.sh call these — nothing outside backends/openvpn.sh touches
# easyrsa directly.

# vpn_backend_provision_client NAME — issue a client certificate. Errors
# clearly (not silently) if a currently-VALID certificate already exists
# for this name. If a PRIOR certificate for this name was revoked,
# archives the old issued/private/req files (timestamped, kept for audit
# — never deleted) rather than blocking: easyrsa's gen-req refuses to run
# if those files are still present, and Phase 5's "profile regenerate"
# needs to reissue under the same name after revoking the old cert.
vpn_backend_provision_client() {
  local name="$1"
  local pki_dir
  pki_dir="$(ovpn_pki_dir)"
  [[ -f "${pki_dir}/ca.crt" ]] || die "PKI not initialized — run 'cyferio-vpn install' first" 3

  if [[ -f "${pki_dir}/issued/${name}.crt" ]]; then
    local cert_line cert_status
    cert_line="$(vpn_backend_list_clients | awk -F'|' -v n="${name}" '$5==n')"
    cert_status="${cert_line%%|*}"
    if [[ "${cert_status}" == "R" ]]; then
      local ts
      ts="$(date -u +%Y%m%d%H%M%S)"
      mv "${pki_dir}/issued/${name}.crt" "${pki_dir}/issued/${name}.revoked-${ts}.crt"
      [[ -f "${pki_dir}/private/${name}.key" ]] && mv "${pki_dir}/private/${name}.key" "${pki_dir}/private/${name}.revoked-${ts}.key"
      [[ -f "${pki_dir}/reqs/${name}.req" ]] && mv "${pki_dir}/reqs/${name}.req" "${pki_dir}/reqs/${name}.revoked-${ts}.req"
      log_info "cert.create" "name=${name} result=archived_prior_revoked ts=${ts}"
    else
      die "a certificate for '${name}' already exists (see 'cyferio-vpn cert status ${name}')" 1
    fi
  fi

  _ovpn_easyrsa_env "EASYRSA_REQ_CN=${name}" -- gen-req "${name}" nopass || die "easyrsa gen-req failed for '${name}'" 3
  _ovpn_easyrsa sign-req client "${name}" || die "easyrsa sign-req failed for '${name}'" 3
  chmod 0600 "${pki_dir}/private/${name}.key"
  log_info "cert.create" "name=${name} result=success"
}

# vpn_backend_revoke_client NAME — revoke + regenerate/export the CRL so
# the running server (which re-reads /etc/openvpn/server/crl.pem on every
# connect) picks up the revocation immediately, no restart needed.
vpn_backend_revoke_client() {
  local name="$1"
  local pki_dir
  pki_dir="$(ovpn_pki_dir)"
  [[ -f "${pki_dir}/issued/${name}.crt" ]] || die "no certificate found for '${name}'" 1
  _ovpn_easyrsa revoke "${name}" || die "easyrsa revoke failed for '${name}'" 3
  _ovpn_easyrsa gen-crl || die "easyrsa gen-crl failed" 3
  ovpn_export_crl
  log_info "cert.revoke" "name=${name} result=success"
}

# ovpn_revoke_if_valid NAME — revoke only if a currently-valid
# (non-revoked) cert exists; a no-op if never issued or already revoked.
# Shared by users.sh's user_remove and profiles.sh's profile_regenerate
# so neither duplicates the "don't re-revoke" check nor risks erroring
# on an already-revoked cert.
ovpn_revoke_if_valid() {
  local name="$1"
  [[ -f "$(ovpn_pki_dir)/issued/${name}.crt" ]] || return 0
  local cert_line cert_status
  cert_line="$(vpn_backend_list_clients | awk -F'|' -v n="${name}" '$5==n')"
  cert_status="${cert_line%%|*}"
  if [[ "${cert_status}" != "R" ]]; then
    vpn_backend_revoke_client "${name}"
  fi
}

# vpn_backend_list_clients — one line per DISTINCT name (server cert
# included), pipe-delimited: status|expiry_iso|revoked_iso|serial|cn,
# sorted by name. Sourced from EasyRSA's own index.txt — the PKI store is
# the source of truth here, not the SQLite DB (Phase 3 is explicitly
# usable without any `users` row existing; Phase 4 wires the two
# together).
#
# A name can appear MORE THAN ONCE in index.txt: Phase 5's "profile
# regenerate" revokes the old cert and issues a new one under the same
# CN, appending a second index.txt line rather than replacing the first.
# The final `awk` pass here collapses that to just the latest entry per
# name (last line wins — index.txt is append-only/chronological) so
# every caller (cert_status, ovpn_revoke_if_valid, user lookups, ...)
# sees current state, not a stale revoked entry from before a
# regenerate.
vpn_backend_list_clients() {
  local index
  index="$(ovpn_pki_dir)/index.txt"
  [[ -f "${index}" ]] || return 0
  awk -F'\t' '
    NF==5 { print $1"|"$2"||"$3"|"$5 }
    NF==6 { print $1"|"$2"|"$3"|"$4"|"$6 }
  ' "${index}" | while IFS='|' read -r status expiry revoked serial subject; do
    local cn="${subject#*CN=}"
    echo "${status}|$(asn1_to_iso "${expiry}")|$([[ -n "${revoked}" ]] && asn1_to_iso "${revoked}")|${serial}|${cn}"
  done | awk -F'|' '{ line[$5] = $0 } END { for (n in line) print line[n] }' | sort -t'|' -k5,5
}

# _ovpn_public_endpoint — the hostname/IP embedded in exported profiles.
# Prefers the admin-configured vpn_public_endpoint (DNS name, floating
# IP, ...); falls back to a live public-IP lookup, same sources as
# network.sh's net_check_public_ip.
_ovpn_public_endpoint() {
  local endpoint
  endpoint="$(config_get vpn_public_endpoint)"
  if [[ -n "${endpoint}" ]]; then
    echo "${endpoint}"
    return 0
  fi
  curl -fsS -m5 https://ifconfig.me 2>/dev/null || curl -fsS -m5 https://api.ipify.org 2>/dev/null || true
}

# _ovpn_validate_profile PATH — sanity-check a rendered profile before
# it's handed to an admin or replaces an existing one: the required
# directives are present, and every embedded block actually has content
# (not just an empty pair of tags — e.g. a cat of a truncated/missing
# key file would otherwise produce a silently-broken profile).
_ovpn_validate_profile() {
  local path="$1"
  local -a errors=()

  grep -q "^client$" "${path}" || errors+=("missing 'client' directive")
  grep -q "^remote " "${path}" || errors+=("missing 'remote' directive")
  grep -q "^push-peer-info$" "${path}" || errors+=("missing push-peer-info")

  local tag body_lines
  for tag in ca cert key tls-crypt; do
    if ! grep -q "^<${tag}>\$" "${path}" || ! grep -q "^</${tag}>\$" "${path}"; then
      errors+=("missing <${tag}> block")
      continue
    fi
    body_lines="$(sed -n "/^<${tag}>\$/,/^<\\/${tag}>\$/p" "${path}" | sed '1d;$d' | grep -c .)"
    if [[ "${body_lines}" -eq 0 ]]; then
      errors+=("<${tag}> block is empty")
    fi
  done

  if [[ ${#errors[@]} -gt 0 ]]; then
    die "generated profile failed validation: $(printf '%s; ' "${errors[@]}")" 3
  fi
}

# vpn_backend_render_profile NAME — fill templates/client.ovpn.tmpl and
# write the single-file profile to the invoking admin's ~/vpn-profiles/
# (per spec — NOT /root, even though this command runs via sudo; see
# utils.sh:invoking_user_home). Echoes the resulting path. The <ca>/
# <cert>/<key>/<tls-crypt> blocks are appended by reading the PEM/key
# files directly (cat), never sed-substituted into the template —
# certificate content isn't safe to run through a regex engine.
vpn_backend_render_profile() {
  local name="$1"
  local pki_dir cert_file key_file
  pki_dir="$(ovpn_pki_dir)"
  cert_file="${pki_dir}/issued/${name}.crt"
  key_file="${pki_dir}/private/${name}.key"
  [[ -f "${cert_file}" ]] || die "no certificate found for '${name}' (run 'cyferio-vpn cert create ${name}' first)" 1
  [[ -f "${key_file}" ]] || die "private key missing for '${name}'" 3

  local template="${CYFERIO_ROOT_DIR}/templates/client.ovpn.tmpl"
  [[ -f "${template}" ]] || die "client profile template not found: ${template}" 3

  local endpoint port proto
  endpoint="$(_ovpn_public_endpoint)"
  [[ -n "${endpoint}" ]] || die "could not determine a public endpoint for the VPN server (set vpn_public_endpoint in ${CYFERIO_CONF_DIR}/cyferio.conf)" 1
  port="$(config_get vpn_port)"
  proto="$(config_get vpn_proto)"

  local profile_dir
  profile_dir="$(invoking_user_home)/vpn-profiles"
  mkdir -p "${profile_dir}"
  chmod 0700 "${profile_dir}"

  local out="${profile_dir}/${name}.ovpn"
  {
    sed \
      -e "s|__VPN_PROTO__|${proto}|g" \
      -e "s|__VPN_ENDPOINT__|${endpoint}|g" \
      -e "s|__VPN_PORT__|${port}|g" \
      "${template}"
    echo "<ca>"
    cat "${pki_dir}/ca.crt"
    echo "</ca>"
    echo "<cert>"
    sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "${cert_file}"
    echo "</cert>"
    echo "<key>"
    cat "${key_file}"
    echo "</key>"
    echo "<tls-crypt>"
    cat "${pki_dir}/ta.key"
    echo "</tls-crypt>"
  } >"${out}.new"

  # Validate before replacing any existing good profile — a bad render
  # (truncated cert, missing tag) must never overwrite a working one.
  _ovpn_validate_profile "${out}.new"

  mv "${out}.new" "${out}"
  chmod 0600 "${out}"
  if [[ -n "${SUDO_USER:-}" ]]; then
    chown "${SUDO_USER}:${SUDO_USER}" "${profile_dir}" "${out}" 2>/dev/null || true
  fi

  log_info "profile.render" "name=${name} result=success path=${out}"
  echo "${out}"
}

# ovpn_uninstall — stop/disable the service and remove OpenVPN-managed
# state. Does NOT touch the SQLite database or backups — install.sh's
# cmd_uninstall orchestrates those separately, and always backs up first.
ovpn_uninstall() {
  require_root
  systemctl disable --now "${OVPN_SYSTEMD_UNIT}" >/dev/null 2>&1 || true

  local wan_if subnet_cidr port proto
  wan_if="$(_ovpn_wan_interface)"
  local prefix
  # Computed separately, not inlined into the subnet_cidr expression: if
  # netmask_to_prefix's internal die() fires, exit-inside-a-subshell only
  # kills that nested command substitution — buried inside a larger
  # string-concatenation assignment, that failure could otherwise be
  # silently swallowed into a malformed "10.8.0.0/" CIDR instead of
  # actually stopping the function.
  prefix="$(netmask_to_prefix "$(config_get vpn_subnet_mask)")" || die "invalid vpn_subnet_mask in config" 1
  subnet_cidr="$(config_get vpn_subnet)/${prefix}"
  port="$(config_get vpn_port)"
  proto="$(config_get vpn_proto)"
  if [[ -n "${wan_if}" ]]; then
    iptables -t nat -D POSTROUTING -s "${subnet_cidr}" -o "${wan_if}" -j MASQUERADE 2>/dev/null || true
    iptables -D INPUT -p "${proto}" --dport "${port}" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i tun0 -o "${wan_if}" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "${wan_if}" -o tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    is_command_available netfilter-persistent && netfilter-persistent save >/dev/null 2>&1 || true
  fi

  rm -f /etc/sysctl.d/99-cyferio-forwarding.conf
  rm -rf "${OVPN_SERVER_DIR}"
  rm -rf "$(ovpn_pki_dir)"
  rm -rf "$(ovpn_hooks_dir)"
  log_info "uninstall.openvpn" "result=success"
}

#!/usr/bin/env bash
# status.sh — `cyferio-vpn status [--table|--plain|--json]` (Phase 9).
# Composes backends/openvpn.sh's vpn_backend_server_status/
# ovpn_status_clients and config.sh's config_get; no easyrsa/sqlite calls
# live here directly, same module-boundary rule as users.sh/profiles.sh.

if [[ -n "${__CYFERIO_STATUS_LOADED:-}" ]]; then
  return 0
fi
__CYFERIO_STATUS_LOADED=1

# cmd_status [--table|--plain|--json] — server run state + config summary
# + the live connected-client list (lib/backends/openvpn.sh's
# ovpn_status_clients, sourced from OpenVPN's own status file — this is
# real-time server state, not audit_logs' historical connect/disconnect
# trail that `mac report`/a future `audit` command read instead).
cmd_status() {
  local format="table"
  for arg in "$@"; do
    case "${arg}" in
      --json) format="json" ;;
      --plain) format="plain" ;;
      --table) format="table" ;;
    esac
  done
  require_root

  local server_status port proto subnet mask
  server_status="$(vpn_backend_server_status)"
  port="$(config_get vpn_port)"
  proto="$(config_get vpn_proto)"
  subnet="$(config_get vpn_subnet)"
  mask="$(config_get vpn_subnet_mask)"

  local clients count=0
  clients="$(ovpn_status_clients)"
  if [[ -n "${clients}" ]]; then
    count="$(wc -l <<<"${clients}")"
  fi

  if [[ "${format}" == "json" ]]; then
    local clients_json="[]"
    if [[ -n "${clients}" ]]; then
      local cn real vaddr rx tx since
      while IFS='|' read -r cn real vaddr rx tx since; do
        clients_json="$(jq -c \
          --arg cn "${cn}" --arg real "${real}" --arg vaddr "${vaddr}" \
          --argjson rx "${rx:-0}" --argjson tx "${tx:-0}" --arg since "${since}" \
          '. + [{common_name: $cn, real_address: $real, virtual_address: $vaddr,
                 bytes_received: $rx, bytes_sent: $tx, connected_since: $since}]' \
          <<<"${clients_json}")"
      done <<<"${clients}"
    fi
    jq -n \
      --arg status "${server_status}" --argjson port "${port}" --arg proto "${proto}" \
      --arg subnet "${subnet}" --arg mask "${mask}" --argjson connected_count "${count}" \
      --argjson clients "${clients_json}" \
      '{server: {status: $status, port: $port, proto: $proto, subnet: $subnet, subnet_mask: $mask},
        connected_clients: {count: $connected_count, clients: $clients}}'
    return 0
  fi

  echo "Status:  ${server_status}"
  echo "Port:    ${port}/${proto}"
  echo "Subnet:  ${subnet} ${mask}"
  echo "Connected clients: ${count}"

  if [[ "${count}" -eq 0 ]]; then
    return 0
  fi

  echo
  local formatted="" cn real vaddr rx tx since
  while IFS='|' read -r cn real vaddr rx tx since; do
    formatted+="${cn}|${real}|${vaddr}|${rx}|${tx}|${since}"$'\n'
  done <<<"${clients}"

  if [[ "${format}" == "plain" ]]; then
    printf '%s' "${formatted}" | report_plain
  else
    printf '%s' "${formatted}" | report_table "COMMON NAME|REAL ADDRESS|VIRTUAL ADDRESS|BYTES RX|BYTES TX|CONNECTED SINCE"
  fi
}

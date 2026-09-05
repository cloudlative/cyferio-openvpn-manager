#!/usr/bin/env bash
# config.sh — load/merge runtime configuration.
#
# Deliberately does NOT `source` the config file (even though it's
# root-owned) — it's parsed as plain key=value lines against an allowlist of
# known keys, so a corrupted or tampered config file can never execute
# arbitrary bash. See docs/architecture/09-security-review.md.

if [[ -n "${__CYFERIO_CONFIG_LOADED:-}" ]]; then
  return 0
fi
__CYFERIO_CONFIG_LOADED=1

# -g (not just -A): this file is always sourced from inside a function in
# bin/cyferio-vpn's dependency-order loop, and `declare` without -g makes
# the declaration local to whatever function is currently executing —
# harmless there since that loop runs at the script's top level, but a
# latent trap for any test harness that sources modules from inside its
# own setup() function (bats does): CYFERIO_CFG would silently vanish the
# moment setup() returned, before the actual test body ran. Found via
# tests/unit/macs.bats's Phase 7 mac_enforcement_mode tests.
declare -gA CYFERIO_CFG=(
  [vpn_port]=1194
  [vpn_proto]=udp
  [vpn_subnet]=10.8.0.0
  [vpn_subnet_mask]=255.255.255.0
  [vpn_public_endpoint]=""
  [mac_enforcement_mode]=strict
  [mac_required]=false
  [default_output_format]=table
)

# config_load [PATH] — merge a config file's values over the defaults.
# Missing file is not an error (fresh install before `cyferio-vpn install`
# has written one yet); unknown keys and malformed lines are warned about,
# not silently dropped, so a typo in the config file is discoverable.
config_load() {
  local conf_file="${1:-${CYFERIO_CONF_DIR}/cyferio.conf}"

  [[ -f "${conf_file}" ]] || return 0

  local line key value line_no=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line_no=$((line_no + 1))
    line="${line%%#*}"                 # strip comments
    line="${line#"${line%%[![:space:]]*}"}"  # ltrim
    line="${line%"${line##*[![:space:]]}"}"  # rtrim
    [[ -z "${line}" ]] && continue

    if [[ "${line}" != *=* ]]; then
      echo "cyferio-vpn: warning: ${conf_file}:${line_no}: malformed line, ignored" >&2
      continue
    fi

    key="${line%%=*}"
    value="${line#*=}"

    if [[ -v "CYFERIO_CFG[${key}]" ]]; then
      CYFERIO_CFG["${key}"]="${value}"
    else
      echo "cyferio-vpn: warning: ${conf_file}:${line_no}: unknown config key '${key}', ignored" >&2
    fi
  done <"${conf_file}"
}

# config_get KEY — echoes the resolved value, or nothing if unknown.
config_get() {
  local key="$1"
  if [[ -v "CYFERIO_CFG[${key}]" ]]; then
    printf '%s\n' "${CYFERIO_CFG[${key}]}"
  fi
}

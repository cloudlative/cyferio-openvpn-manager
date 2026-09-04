#!/usr/bin/env bash
# profiles.sh — `cyferio-vpn profile export|regenerate`. Thin wrappers
# around backends/openvpn.sh's vpn_backend_render_profile and the
# revoke/reissue primitives Phase 4 already built — this module owns no
# PKI logic of its own.

if [[ -n "${__CYFERIO_PROFILES_LOADED:-}" ]]; then
  return 0
fi
__CYFERIO_PROFILES_LOADED=1

_profile_require_user() {
  local username="$1"
  [[ -n "$(db_user_get "${username}")" ]] || die "no such user '${username}' (use 'cyferio-vpn user add ${username}' first)" 1
}

# profile export — re-render the .ovpn for an existing user's CURRENT
# certificate, without touching the certificate itself. Useful when the
# original profile file was lost, or vpn_public_endpoint changed and
# existing profiles need to point at the new address.
profile_export() {
  local username="${1:-}"
  [[ -n "${username}" ]] || die "usage: cyferio-vpn profile export USERNAME" 1
  require_root
  _profile_require_user "${username}"

  local profile_path
  profile_path="$(vpn_backend_render_profile "${username}")"
  db_user_set_profile_path "${username}" "${profile_path}"
  db_audit_log "profile.export" "$(current_actor)" "$(jq -nc --arg username "${username}" '{username:$username}')"

  ui_ok "VPN Profile Generated Successfully"
  echo
  echo "Profile Location:"
  echo " ${profile_path}"
}

# profile regenerate — revoke the current certificate and issue a fresh
# one under the same name, then re-render. The OLD profile stops working
# immediately (its cert is now on the CRL); this is the "I think this
# profile may have leaked" / lost-device flow.
profile_regenerate() {
  local username="${1:-}"
  shift || true
  local force=0
  for arg in "$@"; do
    [[ "${arg}" == "--force" ]] && force=1
  done
  [[ -n "${username}" ]] || die "usage: cyferio-vpn profile regenerate USERNAME [--force]" 1
  require_root
  _profile_require_user "${username}"

  if [[ "${force}" -ne 1 ]] && ! confirm "Regenerate the certificate and profile for '${username}'? The old profile will stop working immediately."; then
    echo "Aborted."
    exit 1
  fi

  ovpn_revoke_if_valid "${username}"
  vpn_backend_provision_client "${username}"
  local profile_path
  profile_path="$(vpn_backend_render_profile "${username}")"
  db_user_set_profile_path "${username}" "${profile_path}"
  db_audit_log "profile.regenerate" "$(current_actor)" "$(jq -nc --arg username "${username}" '{username:$username}')"

  ui_ok "Profile regenerated for '${username}'."
  echo
  echo "Profile Location:"
  echo " ${profile_path}"
}

cmd_profile() {
  local subcommand="${1:-}"
  shift || true
  case "${subcommand}" in
    export) profile_export "$@" ;;
    regenerate) profile_regenerate "$@" ;;
    *)
      echo "cyferio-vpn: usage: cyferio-vpn profile <export|regenerate> USERNAME ..." >&2
      exit 1
      ;;
  esac
}

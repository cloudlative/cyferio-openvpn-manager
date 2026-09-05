#!/usr/bin/env bash
# upgrade.sh — `cyferio-vpn upgrade [--check] [--force] [--json]`, plus
# the "update available" hint `version` prints. Checks GitHub Releases
# for a newer tag and, unless --check, downloads the released
# dist/cyferio-vpn asset and replaces the running binary in place.
#
# Only meaningful for the single-file build (CYFERIO_BUNDLED=1, set by
# the bundle's own bootstrap — see docs/architecture/11-single-file-distribution.md):
# a multi-file dev checkout has no single binary to replace and should
# use `git pull` instead.

if [[ -n "${__CYFERIO_UPGRADE_LOADED:-}" ]]; then
  return 0
fi
__CYFERIO_UPGRADE_LOADED=1

CYFERIO_GITHUB_REPO="${CYFERIO_GITHUB_REPO:-asifrafiq/cyferio-openvpn-manager}"
CYFERIO_RELEASE_ASSET_NAME="${CYFERIO_RELEASE_ASSET_NAME:-cyferio-vpn}"

_UPGRADE_LATEST_VERSION=""
_UPGRADE_LATEST_URL=""

# _upgrade_fetch_latest — populates the two globals above from GitHub's
# "latest release" API. Returns non-zero on ANY failure (network,
# rate-limit, no releases yet, malformed response) — callers must treat
# that as "couldn't check," never silently as "no update available."
_upgrade_fetch_latest() {
  _UPGRADE_LATEST_VERSION=""
  _UPGRADE_LATEST_URL=""
  local api_url="https://api.github.com/repos/${CYFERIO_GITHUB_REPO}/releases/latest"
  local response
  response="$(curl -fsS -m5 -H "Accept: application/vnd.github+json" "${api_url}" 2>/dev/null)" || return 1
  _UPGRADE_LATEST_VERSION="$(jq -r '.tag_name // empty' <<<"${response}" 2>/dev/null | sed 's/^v//')"
  [[ -n "${_UPGRADE_LATEST_VERSION}" ]] || return 1
  _UPGRADE_LATEST_URL="$(jq -r --arg name "${CYFERIO_RELEASE_ASSET_NAME}" \
    '.assets[]? | select(.name == $name) | .browser_download_url' <<<"${response}" 2>/dev/null)"
  [[ -n "${_UPGRADE_LATEST_URL}" ]] || return 1
  return 0
}

# _upgrade_version_gt A B — true if dotted-numeric version A > B (uses
# `sort -V` rather than a naive string compare, so e.g. 1.10.0 correctly
# sorts above 1.9.0).
_upgrade_version_gt() {
  local a="$1" b="$2"
  [[ "${a}" == "${b}" ]] && return 1
  [[ "$(printf '%s\n%s\n' "${a}" "${b}" | sort -V | tail -n1)" == "${a}" ]]
}

# _upgrade_print_if_available — best-effort, silent-on-failure hint
# printed by `cyferio-vpn version`. Never errors, never blocks: a
# network failure here (offline box, rate limit) must not make `version`
# itself fail or look broken.
_upgrade_print_if_available() {
  _upgrade_fetch_latest 2>/dev/null || return 0
  if _upgrade_version_gt "${_UPGRADE_LATEST_VERSION}" "${CYFERIO_VERSION}"; then
    echo "A newer version (v${_UPGRADE_LATEST_VERSION}) is available — run \`cyferio-vpn upgrade\`."
  fi
}

# cmd_upgrade [--check] [--force] [--json] — see file header.
cmd_upgrade() {
  local check_only=false force=false format="table"
  for arg in "$@"; do
    case "${arg}" in
      --check) check_only=true ;;
      --force) force=true ;;
      --json) format="json" ;;
      *) die "unknown flag for upgrade: ${arg}" 2 ;;
    esac
  done

  if [[ "${CYFERIO_BUNDLED:-}" != "1" ]]; then
    die "upgrade only applies to the single-file build (dist/cyferio-vpn installed via /usr/local/bin) — this is a multi-file dev checkout; use 'git pull' instead" 3
  fi

  if ! _upgrade_fetch_latest; then
    die "could not check for updates (network error, rate-limited, or no releases published yet for ${CYFERIO_GITHUB_REPO})" 4
  fi

  local update_available=false
  _upgrade_version_gt "${_UPGRADE_LATEST_VERSION}" "${CYFERIO_VERSION}" && update_available=true

  if [[ "${check_only}" == true ]]; then
    if [[ "${format}" == "json" ]]; then
      jq -n --arg current "${CYFERIO_VERSION}" --arg latest "${_UPGRADE_LATEST_VERSION}" \
        --argjson update_available "${update_available}" \
        '{current: $current, latest: $latest, update_available: $update_available}'
    elif [[ "${update_available}" == true ]]; then
      echo "Update available: v${CYFERIO_VERSION} -> v${_UPGRADE_LATEST_VERSION}"
      echo "Run 'cyferio-vpn upgrade' to install it."
    else
      echo "Already up to date (v${CYFERIO_VERSION})."
    fi
    return 0
  fi

  if [[ "${update_available}" != true && "${force}" != true ]]; then
    if [[ "${format}" == "json" ]]; then
      jq -n --arg current "${CYFERIO_VERSION}" '{upgraded: false, reason: "already up to date", current: $current}'
    else
      echo "Already up to date (v${CYFERIO_VERSION})."
    fi
    return 0
  fi

  require_root

  if [[ "${force}" != true ]]; then
    confirm "Install v${_UPGRADE_LATEST_VERSION} over the running v${CYFERIO_VERSION} at ${CYFERIO_SELF_PATH}?" \
      || { echo "Upgrade cancelled."; return 0; }
  fi

  local self_dir tmp_file
  self_dir="$(dirname "${CYFERIO_SELF_PATH}")"
  tmp_file="$(mktemp "${self_dir}/.cyferio-vpn-upgrade.XXXXXX")" \
    || die "could not create a temp file in ${self_dir} to stage the download" 5

  # Progress message, not data — always stderr, same rule as the banner:
  # this command's stdout may be parsed as --json.
  echo "Downloading v${_UPGRADE_LATEST_VERSION}..." >&2
  if ! curl -fsSL -m30 -o "${tmp_file}" "${_UPGRADE_LATEST_URL}"; then
    rm -f "${tmp_file}"
    die "download failed: ${_UPGRADE_LATEST_URL}" 6
  fi

  # Sanity-check before replacing the running binary: a truncated
  # download, an HTML error page saved by mistake, or an empty file
  # must never end up as the new `cyferio-vpn`.
  if [[ ! -s "${tmp_file}" ]] || ! head -c 32 "${tmp_file}" | grep -q '^#!.*bash'; then
    rm -f "${tmp_file}"
    die "downloaded file does not look like a valid cyferio-vpn build — aborting, nothing replaced" 6
  fi

  chmod 0755 "${tmp_file}"
  # Same-directory temp file + mv = an atomic rename on the same
  # filesystem — safe even though CYFERIO_SELF_PATH is the file this
  # very process is currently executing (Unix keeps the running
  # process's already-open inode intact; the rename only swaps the
  # directory entry).
  mv "${tmp_file}" "${CYFERIO_SELF_PATH}"

  log_info "upgrade.apply" "from=${CYFERIO_VERSION}" "to=${_UPGRADE_LATEST_VERSION}"
  if [[ "${format}" == "json" ]]; then
    jq -n --arg from "${CYFERIO_VERSION}" --arg to "${_UPGRADE_LATEST_VERSION}" \
      '{upgraded: true, from: $from, to: $to}'
  else
    echo "Upgraded: v${CYFERIO_VERSION} -> v${_UPGRADE_LATEST_VERSION}"
    echo "Installed at: ${CYFERIO_SELF_PATH}"
  fi
}

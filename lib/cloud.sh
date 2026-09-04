#!/usr/bin/env bash
# cloud.sh — cloud provider detection + per-provider validation checks.
# See docs/architecture/05-cloud-detection.md. Appends to network.sh's
# shared NETWORK_CHECKS via check_add — this module never prints directly.

if [[ -n "${__CYFERIO_CLOUD_LOADED:-}" ]]; then
  return 0
fi
__CYFERIO_CLOUD_LOADED=1

CYFERIO_CLOUD_PROVIDER=""
_CLOUD_MD_TIMEOUT=2

# cloud_detect — sets CYFERIO_CLOUD_PROVIDER, echoes it too. Ordered,
# first match wins; every metadata call is short-timeout so a non-cloud
# box doesn't hang.
cloud_detect() {
  if [[ -n "${CYFERIO_CLOUD_PROVIDER}" ]]; then
    echo "${CYFERIO_CLOUD_PROVIDER}"
    return 0
  fi

  local provider="bare-metal"

  if curl -fsS -m "${_CLOUD_MD_TIMEOUT}" http://169.254.169.254/hetzner/v1/metadata >/dev/null 2>&1; then
    provider="hetzner"
  elif curl -fsS -m "${_CLOUD_MD_TIMEOUT}" -H "Metadata-Flavor: Google" \
       http://169.254.169.254/computeMetadata/v1/ >/dev/null 2>&1; then
    provider="gcp"
  elif curl -fsS -m "${_CLOUD_MD_TIMEOUT}" -H "Metadata:true" \
       "http://169.254.169.254/metadata/instance?api-version=2021-02-01" >/dev/null 2>&1; then
    provider="azure"
  elif curl -fsS -m "${_CLOUD_MD_TIMEOUT}" http://169.254.169.254/metadata/v1/id >/dev/null 2>&1; then
    provider="digitalocean"
  elif _cloud_aws_imds_token >/dev/null 2>&1; then
    provider="aws"
  elif grep -qi "ovh" /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/bios_vendor 2>/dev/null; then
    provider="ovh"
  elif grep -qi "contabo" /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name 2>/dev/null; then
    provider="contabo"
  fi

  CYFERIO_CLOUD_PROVIDER="${provider}"
  echo "${provider}"
}

# _cloud_aws_imds_token — IMDSv2 token fetch, used both to detect AWS and
# to make the follow-up metadata calls in cloud_aws_checks().
_cloud_aws_imds_token() {
  curl -fsS -m "${_CLOUD_MD_TIMEOUT}" -X PUT \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
    http://169.254.169.254/latest/api/token
}

cloud_public_ip() {
  case "$(cloud_detect)" in
    gcp)
      curl -fsS -m "${_CLOUD_MD_TIMEOUT}" -H "Metadata-Flavor: Google" \
        "http://169.254.169.254/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" 2>/dev/null
      ;;
    aws)
      local token
      token="$(_cloud_aws_imds_token 2>/dev/null || true)"
      [[ -n "${token}" ]] && curl -fsS -m "${_CLOUD_MD_TIMEOUT}" -H "X-aws-ec2-metadata-token: ${token}" \
        http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null
      ;;
    *)
      return 1
      ;;
  esac
}

# --- per-provider checks (see docs/architecture/05-cloud-detection.md) ---

_cloud_aws_checks() {
  local token
  token="$(_cloud_aws_imds_token 2>/dev/null)" || {
    check_add "AWS Networking" warning "Could not obtain an IMDSv2 token." "Verify instance metadata access is enabled."
    return
  }
  local mac sdc
  mac="$(curl -fsS -m "${_CLOUD_MD_TIMEOUT}" -H "X-aws-ec2-metadata-token: ${token}" \
    http://169.254.169.254/latest/meta-data/network/interfaces/macs/ 2>/dev/null | head -n1 || true)"
  if [[ -n "${mac}" ]]; then
    sdc="$(curl -fsS -m "${_CLOUD_MD_TIMEOUT}" -H "X-aws-ec2-metadata-token: ${token}" \
      "http://169.254.169.254/latest/meta-data/network/interfaces/macs/${mac}source-dest-check" 2>/dev/null || true)"
    if [[ "${sdc}" == "true" ]]; then
      check_add "AWS Source/Destination Check" warning \
        "AWS Source/Destination Check appears enabled." \
        "Disable Source/Destination Check on this instance's ENI (required for it to route VPN client traffic)."
    else
      check_add "AWS Source/Destination Check" pass
    fi
  fi
  check_add "AWS NACLs / Route Tables" warning \
    "Not verified — requires AWS API credentials this tool does not use." \
    "Confirm in the AWS Console that NACLs and route tables allow the OpenVPN port and VPN subnet traffic."
}

_cloud_gcp_checks() {
  # `canIpForward` is a Compute Engine instance property, not something the
  # metadata server exposes to the instance itself — there's no
  # metadata-service path for it, so this can only be surfaced as a
  # reminder, not verified in-band (same constraint as the AWS/Azure
  # checks below that need Console/API access this tool doesn't have).
  check_add "GCP IP Forwarding (instance setting)" warning \
    "Not verified — the 'IP forward' instance setting isn't exposed via the metadata service." \
    "Confirm 'IP forwarding' is set to On for this instance (GCP Console, or 'gcloud compute instances describe <name> --format=\"value(canIpForward)\"') — required in addition to the OS-level sysctl for VPN routing to work on GCP."

  local mtu
  mtu="$(curl -fsS -m "${_CLOUD_MD_TIMEOUT}" -H "Metadata-Flavor: Google" \
    "http://169.254.169.254/computeMetadata/v1/instance/network-interfaces/0/mtu" 2>/dev/null || true)"
  check_add "GCP MTU" pass "Network MTU: ${mtu:-unknown} (GCP default 1460 — lower than the usual 1500; already accounted for by OpenVPN's default tun MTU handling)."

  check_add "GCP Firewall Rules" warning \
    "Not verified — requires GCP API credentials this tool does not use." \
    "Confirm a VPC firewall rule allows ingress on the OpenVPN port/protocol."
}

_cloud_azure_checks() {
  local public_ip
  public_ip="$(curl -fsS -m "${_CLOUD_MD_TIMEOUT}" -H "Metadata:true" \
    "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2021-02-01&format=text" 2>/dev/null || true)"
  if [[ -n "${public_ip}" ]]; then
    check_add "Azure Public IP" pass
  else
    check_add "Azure Public IP" warning \
      "No public IP found on the primary interface." \
      "Attach a public IP, or ensure inbound NAT/load balancing is configured for the OpenVPN port."
  fi
  check_add "Azure NSGs / Route Tables" warning \
    "Not verified — requires Azure API credentials this tool does not use." \
    "Confirm in the Azure Portal that the NSG allows the OpenVPN port and the route table doesn't blackhole VPN subnet traffic."
}

_cloud_ovh_checks() {
  check_add "OVH Gateway Routing" warning \
    "Not independently verified." \
    "If using an OVH failover IP, ensure it's correctly routed to this instance per OVH's failover IP documentation."
}

_cloud_hetzner_checks() {
  check_add "Hetzner Cloud Firewall" warning \
    "Hetzner Cloud Firewalls are API-managed and separate from this host's iptables rules — not visible to this tool." \
    "Confirm in the Hetzner Cloud Console that any attached Cloud Firewall allows the OpenVPN port."
}

_cloud_contabo_checks() {
  check_add "Contabo Networking" pass "No metadata service published by Contabo; using DMI-based detection only. Verify the primary interface name matches this host's actual configuration."
}

_cloud_digitalocean_checks() {
  check_add "DigitalOcean Networking" warning \
    "Not independently verified." \
    "Confirm DigitalOcean Cloud Firewalls (if any) allow the OpenVPN port."
}

# cloud_run_checks — detect + append the matching provider's checks (or
# nothing extra for bare-metal/generic VPS) to NETWORK_CHECKS.
cloud_run_checks() {
  # Not `provider="$(cloud_detect)"` — that would run cloud_detect in a
  # subshell (command substitution), losing its CYFERIO_CLOUD_PROVIDER
  # side effect the moment the subshell exits. Run it directly so the
  # global actually persists for callers like install.sh's cmd_network.
  cloud_detect >/dev/null
  local provider="${CYFERIO_CLOUD_PROVIDER}"
  check_add "Cloud Provider Detection" pass "Detected: ${provider}"

  case "${provider}" in
    aws) _cloud_aws_checks ;;
    gcp) _cloud_gcp_checks ;;
    azure) _cloud_azure_checks ;;
    ovh) _cloud_ovh_checks ;;
    hetzner) _cloud_hetzner_checks ;;
    contabo) _cloud_contabo_checks ;;
    digitalocean) _cloud_digitalocean_checks ;;
    bare-metal) ;;  # no provider-specific checks
  esac
}

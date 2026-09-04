# 05 — Cloud Provider Detection Design

`lib/cloud.sh`, invoked by `install`'s pre-flight and standalone via `cyferio-vpn network detect [--json]`.

## Detection method (ordered, first match wins, all with short timeouts so a non-cloud box doesn't hang)

| Provider | Detection |
|---|---|
| AWS | `curl -s -m2 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/` succeeds (IMDSv2 token fetch first) |
| GCP | `curl -s -m2 -H "Metadata-Flavor: Google" http://169.254.169.254/computeMetadata/v1/` succeeds |
| Azure | `curl -s -m2 -H "Metadata:true" "http://169.254.169.254/metadata/instance?api-version=2021-02-01"` succeeds |
| OVH | DMI vendor string match (`/sys/class/dmi/id/sys_vendor` / `bios_vendor` contains "OVH") |
| Hetzner | Hetzner Cloud metadata endpoint `http://169.254.169.254/hetzner/v1/metadata` succeeds |
| Contabo | DMI vendor/product heuristics (Contabo doesn't publish a metadata service; falls back to `sys_vendor`/network-interface-name heuristics documented inline) |
| DigitalOcean | DO metadata endpoint `http://169.254.169.254/metadata/v1/id` succeeds |
| Generic VPS / Bare Metal | none of the above matched — `network.sh` still runs, using only OS-level checks (no provider-specific validation) |

All metadata calls target the shared cloud-metadata link-local address `169.254.169.254` with strict timeouts and are skipped entirely if that address isn't reachable at all (fast bare-metal path).

## Per-provider validation (post-detection, feeds into `06-networking-validation.md`'s pre-flight report)

- **AWS**: `Source/Destination Check` on the primary ENI (via IMDS `network/interfaces/macs/<mac>/...` — read-only, no AWS API credentials required for what's exposed via IMDS), NACL/route-table checks flagged as "verify in AWS Console" (out of reach without IAM creds — the tool doesn't assume any).
- **GCP**: IP forwarding (`can_ip_forward` field in IMDS instance data) — GCP requires this to be enabled on the instance for VPN routing to work; MTU note in output (GCP default MTU 1460 vs standard 1500).
- **Azure**: NSG/route-table checks flagged "verify in Azure Portal" (same no-credentials constraint as AWS); public IP configuration checked via IMDS `network/interface/0/ipv4/ipAddress/0/publicIpAddress`.
- **OVH**: gateway routing sanity check (default route present, matches OVH's typical failover-IP gotchas) — documented remediation text, not auto-fixed.
- **Contabo**: primary interface name/detection sanity check only (Contabo's networking is close to bare-metal; mainly documents "check your provider's specific interface naming").
- **Hetzner**: Hetzner Cloud Firewall is API-managed (separate from `iptables`) — output an explicit note that host-level firewall rules alone are insufficient if a Hetzner Cloud Firewall is also attached, since the tool can't see that layer without API creds.

Every check that can't be fully verified without cloud API credentials the tool doesn't hold outputs a **warning with a remediation suggestion**, never a false "pass" — matching the spec's example format:

```
WARNING
AWS Source/Destination Check appears enabled.
OpenVPN routing may fail.
Recommended Action: Disable Source/Destination Check.
```

## Output

`cyferio-vpn network detect --json`:
```json
{
  "provider": "aws",
  "public_ip": "203.0.113.10",
  "checks": [
    {"name": "source_dest_check", "status": "warning", "message": "...", "remediation": "..."},
    {"name": "ip_forwarding", "status": "pass"}
  ]
}
```
Same data renders as the spec's `✓`/`WARNING` pre-flight block in table mode.

# 10 — Testing Strategy

## Static analysis (every commit, CI gate)

- `shellcheck -x` on every `.sh` file, zero warnings.
- `shfmt -d` for formatting consistency (non-blocking initially, can become a gate later).

## Unit tests (`tests/unit/*.bats`, bats-core)

One `.bats` file per `lib/*.sh` module, run against a scratch SQLite DB / temp dirs (never touches `/etc` or `/var` on the CI runner). Examples:
- `database.bats` — schema creation, migration idempotency, unique-constraint enforcement
- `macs.bats` — MAC validation regex edge cases, duplicate rejection (same user & cross-user)
- `reporting.bats` — table/json/plain output shape for a fixed fixture dataset
- `cloud.bats` — provider-detection function logic against mocked `curl` responses (no real network calls in unit tests)

## Integration tests (`tests/integration/`, VM-based)

Run against real GCP test VMs (see below) rather than the developer's machine:
- Fresh install → `status` shows running → `user add` produces a connectable-shaped profile → `uninstall` cleanly removes everything, confirmed by re-running pre-flight checks.
- Upgrade path: install at version N, re-run `install` at version N+1, confirm idempotency (no duplicate PKI, no broken config).
- MAC lifecycle: add/update/remove, confirm `client-connect` hook accepts/rejects correctly (simulated via a local OpenVPN client where feasible, or hook unit-invocation with fixture peer-info env vars).
- Backup/restore round-trip: backup → wipe `/etc/cyferio`, `/etc/openvpn`, DB → restore → `diagnose` reports healthy.

**Test infrastructure:** rather than running install/uninstall cycles against your local machine, integration tests target disposable **GCP Compute Engine VMs** (e2-small, Ubuntu 22.04/24.04 and Debian 12 images) spun up per test run and torn down after — matches the spec's cloud test matrix and means a bad `install`/`uninstall` run never touches real infrastructure. This is set up starting Phase 2 (Installation Engine), the first phase with something installable to test.

## Test matrix (per spec, exercised in CI + the GCP VMs above)

- **OS**: Ubuntu 22.04 LTS, Ubuntu 24.04 LTS, Debian 12
- **Cloud**: AWS, GCP, OVH, Contabo, Hetzner (detection-logic tested against mocked metadata responses in unit tests; a subset validated against real instances before v1.0.0 release, per Phase 15)

## CI

`.github/workflows/shellcheck.yml` — lint gate on every PR.
`.github/workflows/bats.yml` — unit tests on every PR.
A separate, manually-triggered (not per-PR, to control cloud spend) workflow runs the GCP integration suite before tagging a release.

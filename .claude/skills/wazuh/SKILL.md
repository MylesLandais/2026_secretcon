---
name: wazuh
description: Wazuh SIEM manager, indexer, and Windows-agent + Sysmon telemetry for the SecretCon range
---

# Wazuh

## When this skill applies

Two halves, often touched together:

1. Manager and indexer operations on the SIEM VM (custom rules, agent
   groups, dashboard access).
2. Windows agent + Sysmon configuration that ships from the Win10 EWS
   bootstrap, so endpoint telemetry actually reaches the manager.

If you are deploying the SIEM VM from scratch, that is a Proxmox task.
See `proxmox/SKILL.md` and the runbook at `docs/runbooks/deploy-wazuh.md`.

## Conventions in this repo

### Two deployment tiers

1. **Production lab** - single all-in-one Wazuh VM on Proxmox (this
   skill's main subject). Static `192.168.61.10/24` on `vmbr1`. Used
   for the full SecretCon range.
2. **Local lab** - in-tree single-node Wazuh docker stack at
   [`infrastructure/wazuh-docker/`](../../infrastructure/wazuh-docker/),
   pinned to 4.14.5, brought up with `./scripts/wazuh-docker-up.sh`.
   Dashboard on `https://127.0.0.1:1443`. Used by:
   - the SIEM capture loop (`./scripts/observability-loop.sh`, 3x chain
     validator),
   - the baseline observability tour (`./scripts/observability/run-baseline-tour.sh`,
     per-tool footprint), and
   - the **10x stress campaign** (`./scripts/observability/stress-campaign.sh`,
     full walkthrough x10 with red/blue scorecards)
   alongside `run-local-cysvuln.sh` QEMU VMs.

Custom rule pack in `config/wazuh_cluster/local_rules.xml`:
   - `100501-100506` — walkthrough phase coverage
   - `100507` — EFS `fswsService.exe` crash (Application 1000, 0xc0000005)
   - `100508` / `100509` — winPEAS / SharpUp execution attribution
   - `100510-100517` — msiexec deep-dive (AIE elevation receipts)
   - `100520` / `100521` — flag-access receipts (Sysmon EID 11 / cmdLine)
   - `100530` — velocity / correlation (enum -> AIE within 15 min); when
     this rule fires Wazuh suppresses the underlying 100508/100509 in
     `alerts.json`, so the stress-campaign blue scorecard credits both
     child rules when 100530 matches.

   The `ews` agent group's `shared/ews/agent.conf` adds the Sysmon +
   MSI/Operational + `C:\Users\Public\aie-*.log` + EFS access log +
   `C:\Users\Public\audit-aie-*.json` subscriptions that the
   SwiftOnSecurity sysmon config alone does not enable on the manager
   side. Manager runs with `<logall_json>yes</logall_json>` so the
   capture loop produces forensic-grade `archives.json` (every decoded
   event), not just `alerts.json` (level >= 3 hits).

### Dataset export and Proxmox replay

The local lab is the *generator* tier. To carry a captured corpus
elsewhere (analyst review, regression testing of the production-tier
rules), use:

- [`scripts/wazuh-export-dataset.sh`](../../scripts/wazuh-export-dataset.sh)
  to docker-cp the manager's raw logs + config + agent metadata into a
  `dataset/` directory (with a `MANIFEST.md` and `sha256sums.txt`).
  Optional `--tarball` produces `dataset.tar.zst`. The default source
  layout is `artifacts/cysvuln/observability-loop/<run-id>/`; for the
  stress campaign pass `--source-dir artifacts/cysvuln/stress-campaign/<run-id>`
  so per-phase summaries and red/blue scorecards travel with the
  alerts. `flags.env` is intentionally not included.
- [`scripts/wazuh-replay-to-proxmox.sh`](../../scripts/wazuh-replay-to-proxmox.sh)
  to stream `archives.json` (or `alerts.json`) into a remote Wazuh
  manager's syslog listener (default target: production manager at
  `192.168.61.10:514/tcp`), preserving original timestamps via a
  `[SECRETCON-REPLAY ...]` structured-data tag.
- Full procedure (Proxmox-side `<remote>` block, `local_rules.xml`
  sync, analyst grep patterns) lives in
  [`docs/runbooks/wazuh-dataset-export-and-replay.md`](../../docs/runbooks/wazuh-dataset-export-and-replay.md).

### Config-mount footgun

`infrastructure/wazuh-docker/docker-compose.yml` bind-mounts
`wazuh_manager.conf` to `/wazuh-config-mount/etc/ossec.conf`. The
container's entrypoint only syncs that staging path to
`/var/ossec/etc/ossec.conf` **on first start** (when `/var/ossec` is an
empty named volume). Subsequent restarts ignore staged edits.
`wazuh-docker-up.sh` works around this by `docker cp`-ing
`wazuh_manager.conf` *and* `local_rules.xml` into the canonical paths
on every up. If you ever edit the manager config and a restart "does
nothing", re-run `wazuh-docker-up.sh` (or repeat the docker cp
manually).

### Manager and indexer (production lab)

- Single all-in-one VM (VMID 110), Ubuntu 22.04 cloud-image base.
- Service NIC `net1` on `vmbr1`, static `192.168.61.10/24`. Management
  NIC `net0` on `vmbr0`, DHCP.
- Bootstrap runs `wazuh-install.sh -a` (all-in-one). The script lives at
  `provisioning/bash/bootstrap-wazuh-ubuntu.sh`.
- Agent group `ews` is created at bootstrap. New Win10 EWS clones join
  this group automatically via `WAZUH_AGENT_GROUP=ews` in the agent MSI
  install command.
- Custom Suricata rules `86600` through `86604` live in
  `/var/ossec/etc/rules/local_rules.xml`, seeded by the bootstrap.
- EVE listener: TCP/1514 (JSON). Suricata or any compatible producer
  can fan in here.
- Dashboard URL: `https://192.168.61.10`. From a workstation that
  cannot route into `vmbr1`, tunnel via the Proxmox host:

  ```
  ssh -N -L 8443:192.168.61.10:443 root@192.168.60.1
  ```

  Then open `https://localhost:8443`.

### Windows agent + Sysmon

- Agent install is driven by `provisioning/powershell/bootstrap_win.ps1`
  during the Packer Windows build.
- MSI is staged on the Proxmox host at
  `/var/lib/vz/template/iso/wazuh-agent/wazuh-agent-4.8.0-1.msi` for
  offline installs. SHA-256 is pinned in the bootstrap.
- Install command pattern:

  ```
  msiexec /i wazuh-agent-4.8.0-1.msi /q WAZUH_MANAGER=192.168.61.10 WAZUH_AGENT_GROUP=ews
  Start-Service WazuhSvc
  ```

- Sysmon configuration lands as part of the Windows bootstrap. Its
  events feed Wazuh rule series `92xxx` and become the primary
  endpoint detection signal for the EWS challenge.

## Canonical examples

- `scripts/proxmox/build-wazuh-template.sh`
- `scripts/proxmox/deploy-wazuh-siem.sh`
- `scripts/proxmox/verify-wazuh-siem.sh`
- `provisioning/bash/bootstrap-wazuh-ubuntu.sh`
- `provisioning/powershell/bootstrap_win.ps1`
- `provisioning/cloud-init/wazuh/user-data`

## Common pitfalls

- "Agent shows online but no events": check that the agent group is
  `ews` (`/var/ossec/bin/agent_groups`) and that the rules file is the
  customised one, not the stock template.
- "Suricata alerts not arriving": the EVE listener is TCP/1514, not
  UDP. Some shippers default to UDP. Match the protocol.
- "Dashboard certificate refused": the install generates a self-signed
  cert. Accept it once or import the CA. Do not disable TLS.
- Routing from the WireGuard client into `192.168.61.0/24` is
  unreliable. Always tunnel via `root@192.168.60.1` for dashboard work.

## Debugging tips

- Manager logs: `/var/ossec/logs/ossec.log` on the SIEM VM.
- Agent enrollment: `/var/ossec/logs/api.log` and
  `/var/ossec/var/db/agents.db` on the manager.
- Windows agent logs: `C:\Program Files (x86)\ossec-agent\ossec.log`.
- A synthetic EVE alert sent to TCP/1514 should land as rule `86601`.
  This is the fastest end-to-end smoke test for the ingest path.

## References

- `docs/runbooks/deploy-wazuh.md` for the deploy sequence.
- `docs/runbooks/deploy-windowsvm.md` for the agent + Sysmon side of
  the pipeline.
- Wazuh upstream docs at https://documentation.wazuh.com.

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

### Manager and indexer

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

- `infrastructure/proxmox/build-wazuh-template.sh`
- `infrastructure/proxmox/deploy-wazuh-siem.sh`
- `infrastructure/proxmox/verify-wazuh-siem.sh`
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

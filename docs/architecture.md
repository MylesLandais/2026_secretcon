# SecretCon 2026 Lab Architecture

This document describes the network, hypervisor, and VM layout for the
SecretCon 2026 adversarial-simulation threat range. It is the reference
that the build, deploy, and verify scripts assume.

For the year-on-year planning context see the SecretCon community at
[secretconctf.com](https://secretconctf.com/).

## Network layout

The lab is reached through a WireGuard tunnel managed on a UniFi OS
gateway. The tunnel only carries small IaC and text. Large artifacts
(ISOs, qcow2) move directly between the Proxmox host and the public
internet.

| Network              | Subnet             | Gateway          | Purpose                                |
|----------------------|--------------------|------------------|----------------------------------------|
| WireGuard tunnel     | 192.168.2.0/24     | 192.168.2.254    | Operator workstation tunnel            |
| Management VLAN      | 192.168.60.0/24    | 192.168.60.254   | Proxmox host and admin services        |
| Challenge VLAN       | 192.168.61.0/24    | 192.168.61.1     | Player-facing challenge VMs            |
| Domain Controller    | 172.16.30.0/24    | 172.16.30.1     | dc01.care-secllc.com                   |
| Primary DNS          | 172.16.130.0/27    | 172.16.130.30    | Internet and external resolution       |

Required workstation routes:

```
nmcli connection modify wg-ctf \
  ipv4.routes "192.168.2.0/24, 192.168.60.0/24, 192.168.61.0/24, 172.16.30.0/24, 172.16.130.0/27" \
  ipv4.dns "192.168.2.254, 172.16.130.2"
```

## Hypervisor

Single-node Proxmox VE 9.x. Node name `manage`.

| Field    | Value                                  |
|----------|----------------------------------------|
| Web UI   | https://192.168.60.1:8006              |
| SSH      | `root@192.168.60.1`                    |
| Storage  | `local` (ISOs, imports, templates), `local-lvm` (VM disks) |
| Bridges  | `vmbr0` = 192.168.60.1/24, `vmbr1` = 192.168.61.1/24 |

## Network layouts (read this first)

Two layouts coexist. Scripts and docs must say which one they target.

### Live / prod layout (management bridge)

Used by the long-running EWS box on the Proxmox host today. Ansible
inventory, prod-proof scripts, and WireGuard reachability tests assume
this layout unless you override `EWS_HOST`.

| VMID | Name                            | Bridge | IP               | Role |
|------|---------------------------------|--------|------------------|------|
| 109  | secretcon-ews-vnc-unquoted-path | vmbr0  | 192.168.60.109   | Win10 EWS (live prod box) |
| 110  | wazuh-siem                      | vmbr0 + vmbr1 | 192.168.61.10 | Wazuh manager (dual-homed) |

Source of truth for live EWS: `ansible/inventory/host_vars/ews-prod.yml`.
Prod-proof driver: `scripts/proxmox/reproduce-ews-prod-proof.sh` (set
`EWS_HOST=192.168.60.109` when probing the live box).

### Campaign layout (challenge VLAN)

Used by the integrated three-box chain and VNC/OPNsense analyst tracks.
Deploy scripts target `vmbr1` directly; defaults live in
`scripts/lib/chain_env.sh`.

| VMID | Name                            | Bridge | IP               | Role |
|------|---------------------------------|--------|------------------|------|
| 119  | secretcon-cysvuln-proxmox       | vmbr1  | 192.168.61.51    | CysVuln (chain box 1) |
| 109  | secretcon-ews-vnc-unquoted-path | vmbr1  | 192.168.61.20    | EWS (chain box 2) |
| 112  | asrep-dc-secretcon              | vmbr1  | 192.168.61.52    | AS-REP DC (chain box 3) |
| 110  | wazuh-siem                      | vmbr0 + vmbr1 | 192.168.61.10 | Wazuh manager |
| 111  | crit-capture                    | vmbr1  | 192.168.61.11    | Arkime PCAP ingest |
| —    | OPNsense                        | vmbr1  | 192.168.61.253   | SPAN sensor + Suricata |

Integrated chain: CysVuln `.51` → PtH → EWS `.20` → AS-REP → DC `.52`.
See [docs/campaign/three-box-chain.md](campaign/three-box-chain.md).

Moving EWS from prod (`vmbr0` / `.60.109`) to campaign (`vmbr1` /
`.61.20`) is a deliberate migration (`scripts/proxmox/rebuild-ews.sh`);
do not assume both IPs describe the same running VM.

## VM inventory (full host)

| VMID | Name                                | NIC bridge | IP               | Role |
|------|-------------------------------------|------------|------------------|------|
| 104  | kali-2025                           | vmbr1      | DHCP             | Operator test origin inside the challenge VLAN |
| 105  | (existing Windows UEFI VM)          | varies     | varies           | Pre-existing, do not overwrite |
| 108  | CysVulnServer (legacy)              | vmbr0      | static           | External contributor challenge |
| 119  | secretcon-cysvuln-proxmox           | vmbr1      | 192.168.61.51    | CysVuln campaign deploy (chain box 1) |
| 112  | asrep-dc-secretcon                  | vmbr1      | 192.168.61.52    | AS-REP roast DC (`secretcon.local`, chain box 3) |
| 109  | secretcon-ews-vnc-unquoted-path     | vmbr0 or vmbr1 | see layouts above | Win10 EWS (VNC + unquoted path) |
| 110  | wazuh-siem                          | vmbr0 + vmbr1 | 192.168.61.10 | All-in-one Wazuh manager + indexer + dashboard |
| 111  | crit-capture                        | vmbr1      | 192.168.61.11    | Arkime PCAP ingest (campaign) |
| 9000 | jammy-cloudimg-template             | n/a        | n/a              | Ubuntu 22.04 cloud-image base template |

Provisioning bridge is `vmbr0`; campaign deploy scripts target `vmbr1`
directly.

## Build pipeline

Two paths, same artifacts.

### Local QEMU

```
flake.nix .#win10-ews-local
  -> infrastructure/packer/ews/local-qemu-ews.pkr.hcl
       -> Packer (qemu builder)
            -> autounattend.xml + bootstrap_win.ps1
                 -> qcow2 in infrastructure/packer/ews/output/
                      -> scripts/run-local-vm.sh exposes RDP/WinRM/VNC on localhost
```

### Proxmox-native

```
infrastructure/packer/ews/proxmox-vm-ews.pkr.hcl
  -> Packer (proxmox-iso builder) on node manage
       -> ISO from local storage + autounattend on PROVISION ISO
            -> bootstrap_win.ps1 over SSH
                 -> challenge VM live on vmbr1
```

Wazuh SIEM is its own pipeline (cloud-image, not Packer-baked):

```
scripts/proxmox/build-wazuh-template.sh   # one-shot template build, runs on host
scripts/proxmox/deploy-wazuh-siem.sh      # tear down, clone, cloud-init, bootstrap
scripts/proxmox/verify-wazuh-siem.sh      # acceptance test
provisioning/bash/bootstrap-wazuh-ubuntu.sh      # runs inside the VM via cloud-init
provisioning/cloud-init/wazuh/user-data          # NoCloud payload
```

## Telemetry pipeline

```
Win10 EWS (VM 109)
  Sysmon EventChannel  --+
  Wazuh agent (group ews) +--> Wazuh manager (192.168.61.10:1514/agent)
  Suricata EVE -----------+--> Wazuh manager TCP/1514 EVE listener
                                  -> indexer
                                  -> dashboard at https://192.168.61.10
```

Dashboard access from a workstation outside vmbr1:

```
ssh -N -L 8443:192.168.61.10:443 root@192.168.60.1
```

## Capture pipeline (local lab)

A small local-lab Arkime stack lives at
[`infrastructure/arkime-docker/`](../infrastructure/arkime-docker/),
parallel to the local Wazuh stack and brought up by
[`scripts/arkime-docker-up.sh`](../scripts/arkime-docker-up.sh).

```
PCAP corpus (gitignored)        Arkime stack (local docker)
  vnc_auth.pcap  ---import-->   arkime.viewer (127.0.0.1:8005)
                                arkime.opensearch (127.0.0.1:9201)
```

It is dataset-driven, not live-capture-driven. PCAPs are generated
once by
[`scripts/observability/vnc-adversary-emulation.sh`](../scripts/observability/vnc-adversary-emulation.sh)
and staged under `infrastructure/arkime-docker/pcaps/`. The same run
also produces a Wazuh dataset under
`artifacts/ews/vnc-foothold/<run-id>/dataset/` that is replayed into
the production manager on every deploy via
[`scripts/observability/vnc-replay-on-deploy.sh`](../scripts/observability/vnc-replay-on-deploy.sh).

Full procedure:
[`docs/runbooks/ews-vnc-adversary-emulation.md`](runbooks/ews-vnc-adversary-emulation.md).

### Deployed: production-lab `crit-capture` VM (file-PCAP ingest only)

The local-lab Arkime stack is still used for synthesising and
locally cracking PCAPs, but the production lab now has a sibling
file-PCAP ingest VM on `vmbr1`:

- VMID 111 `crit-capture`, static `192.168.61.11/24` on `vmbr1` plus
  `vmbr0` DHCP for egress, cloned from `ubuntu-2204-cloud-tmpl`
  (VMID 9000).
- Cloud-init ([`provisioning/cloud-init/arkime/user-data`](../provisioning/cloud-init/arkime/user-data))
  installs Docker CE + compose plugin.
- In-guest [`provisioning/cloud-init/arkime/bootstrap.sh`](../provisioning/cloud-init/arkime/bootstrap.sh)
  brings up the in-tree
  [`infrastructure/arkime-docker/docker-compose.yml`](../infrastructure/arkime-docker/docker-compose.yml)
  with a generated `docker-compose.override.yml` that binds the viewer
  and OpenSearch on `0.0.0.0` (so analysts on `wg-ctf` can reach
  `http://192.168.61.11:8005` directly), runs the first-run
  `db.pl init`, and creates the admin user.
- Deployed by [`scripts/proxmox/deploy-arkime-capture.sh`](../scripts/proxmox/deploy-arkime-capture.sh)
  (full clone + cloud-init + scp + bootstrap), verified by
  [`scripts/proxmox/verify-arkime-capture.sh`](../scripts/proxmox/verify-arkime-capture.sh),
  and fed via [`scripts/proxmox/sync-arkime-pcap.sh`](../scripts/proxmox/sync-arkime-pcap.sh)
  (operator-side scp + `docker exec arkime.viewer /opt/arkime/bin/capture`).

### Deployed: OPNsense SPAN sensor for `vmbr1` (live NSM track)

Live capture on `vmbr1` is now wired through the existing OPNsense VM
(192.168.61.253). A Proxmox host-side `tc`-mirror copies every frame
on `vmbr1` (ingress + egress) to OPNsense's third NIC `vtnet2`, which
is bound to a dummy bridge `vmbrmirror` and configured as a passive
`MIRROR` interface in OPNsense (no IP, promisc, block-all filter rule
so it can never leak).

```mermaid
flowchart LR
    Kali["Kali .50 (vmbr1)"] -->|"hydra tcp/5900"| EWS["EWS .20 (vmbr1)"]
    vmbr1["vmbr1 (Linux bridge)"]
    Kali --- vmbr1
    EWS --- vmbr1
    vmbr1 -->|"tc-mirror ingress+egress"| tapMirror["tapX i2 -> vmbrmirror"]
    tapMirror --> Opnsense["OPNsense vtnet2 MIRROR (passive, IDS-only)"]
    Opnsense -->|"Suricata EVE -> tcp/1514"| Wazuh["wazuh.manager .10"]
    Opnsense -->|"pf filterlog -> tcp/514"|  Wazuh
    Opnsense -->|"saved pcap rotated"| Crit["crit-capture .11 Arkime"]
    Wazuh --> Dash["wazuh dashboard https"]
    Crit  --> Viewer["arkime viewer :8005"]
```

Components and ownership:

- Host-side mirror:
  [`scripts/proxmox/enable-vmbr1-mirror.sh`](../scripts/proxmox/enable-vmbr1-mirror.sh)
  attaches `net2` to OPNsense, creates `vmbrmirror`, installs the
  `tc ingress + egress mirred` filters, and persists via a systemd unit
  `vmbr1-mirror.service`. Inverse:
  [`disable-vmbr1-mirror.sh`](../scripts/proxmox/disable-vmbr1-mirror.sh).
- OPNsense-side config: GUI/API setup documented in
  [`provisioning/opnsense/setup-instructions.md`](../provisioning/opnsense/setup-instructions.md);
  custom Suricata rules in
  [`provisioning/opnsense/suricata/secretcon.rules`](../provisioning/opnsense/suricata/secretcon.rules)
  (SIDs 2400001 / 2400002 for VNC brute-force) pushed by
  [`scripts/proxmox/opnsense-apply-config.sh`](../scripts/proxmox/opnsense-apply-config.sh);
  sanitized `/conf/config.xml` snapshot at
  [`provisioning/opnsense/config.xml`](../provisioning/opnsense/config.xml).
- Wazuh-side bridge: rules 100810/100811/100812 (Suricata SID match
  + velocity correlator) and 100815 (pf filterlog fallback) in
  [`infrastructure/wazuh-docker/config/wazuh_cluster/local_rules.xml`](../infrastructure/wazuh-docker/config/wazuh_cluster/local_rules.xml).
- Arkime feeder: on-demand
  [`scripts/proxmox/opnsense-export-pcap.sh`](../scripts/proxmox/opnsense-export-pcap.sh)
  runs `tcpdump` on the OPNsense MIRROR interface over SSH and chains
  the resulting pcap into `sync-arkime-pcap.sh`.
- Pre-change safety net:
  [`scripts/proxmox/snapshot-before-mirror.sh`](../scripts/proxmox/snapshot-before-mirror.sh)
  + [`rollback-vmbr1-mirror.sh`](../scripts/proxmox/rollback-vmbr1-mirror.sh)
  snapshot both the OPNsense VM and the Wazuh manager VMID 110 before
  any of the above touches them.

End-to-end orchestrator:
[`scripts/observability/opnsense-vnc-challenge.sh`](../scripts/observability/opnsense-vnc-challenge.sh)
runs the live VNC brute-force + capture + Arkime import + Wazuh slice
+ INDEX.md emission. Acceptance test:
[`scripts/validate/validate-opnsense-vnc-pipeline.sh`](../scripts/validate/validate-opnsense-vnc-pipeline.sh).
Participant walkthrough:
[`docs/runbooks/opnsense-vnc-brute-analyst-challenge.md`](runbooks/opnsense-vnc-brute-analyst-challenge.md).

## Deferred: OT segment

The 2026 design originally included an OT segment with a CompactLogix
PLC, EtherNet/IP traffic, and Studio 5000 / RSLogix tooling on the EWS
for engineers. That work was pruned for resources and is not deployed.

If reintroduced, the design was:

- New VLAN on a third bridge, isolated from `vmbr0` and `vmbr1`.
- PLC reachable from the EWS only, with `pycomm3` Python tooling.
- Suricata coverage of EtherNet/IP traffic feeding Wazuh.
- Out-of-band attack surface via a NanoKVM appliance.

Do not introduce PLC, pycomm3, or EtherNet references elsewhere in
the repo without restoring the substrate first.

## CTF design notes (intentional)

Some configuration in this repo is part of the training game, not a
mistake. Listed here so contributors do not "fix" them:

- `targets/ews-win11/flag-notes.md` documents the intended kill chain.
- `provisioning/powershell/bootstrap_win.ps1` sets a TightVNC password
  drawn from the public SecLists default-credentials list. This is the
  intended foothold.
- The `SecretConEwsSync` service has an unquoted image path on purpose.
  It is the intended LPE primitive.
- `bootstrap_win.ps1` enables the "Audit Registry" subcategory and
  applies a SACL on `HKLM\SOFTWARE\TightVNC\Server` so reads of the
  password key generate Security EID 4663 (Wazuh rule `100805`).
  This is part of the planted forensic trail, not a defensive
  hardening step.
- `C:\Users\Public\vnc-pwd-dump.txt` is a planted exfil receipt
  written by the adversary-emulation runner. Wazuh tails it (rule
  `100806`) so the password hex blob lands in `alerts.json` as
  `full_log`. Do not "fix" this by adding the path to a deny list.

Real secrets (sops files, dashboard admin credentials, WireGuard
endpoint, RoE protected domains) live outside the repo.

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

## VM inventory

| VMID | Name                                | NIC bridge | IP               | Role |
|------|-------------------------------------|------------|------------------|------|
| 104  | kali-2025                           | vmbr1      | DHCP             | Operator test origin inside the challenge VLAN |
| 105  | (existing Windows UEFI VM)          | varies     | varies           | Pre-existing, do not overwrite |
| 108  | CysVulnServer                       | vmbr0      | static           | External contributor challenge |
| 109  | secretcon-ews-vnc-unquoted-path     | vmbr0 → vmbr1 | 192.168.61.20 | Win10 LTSC challenge: VNC foothold + unquoted service path LPE |
| 110  | wazuh-siem                          | vmbr0 + vmbr1 | 192.168.61.10 | All-in-one Wazuh manager + indexer + dashboard |
| 9000 | jammy-cloudimg-template             | n/a        | n/a              | Ubuntu 22.04 cloud-image base template |

Provisioning bridge is `vmbr0`; challenge VMs are moved to `vmbr1` after
first successful boot.

## Build pipeline

Two paths, same artifacts.

### Local QEMU

```
flake.nix .#win10-ews-local
  -> infrastructure/packer/local-qemu.pkr.hcl
       -> Packer (qemu builder)
            -> autounattend.xml + bootstrap_win.ps1
                 -> qcow2 in infrastructure/packer/output/
                      -> scripts/run-local-vm.sh exposes RDP/WinRM/VNC on localhost
```

### Proxmox-native

```
infrastructure/packer/proxmox-vm.pkr.hcl
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

Real secrets (sops files, dashboard admin credentials, WireGuard
endpoint, RoE protected domains) live outside the repo.

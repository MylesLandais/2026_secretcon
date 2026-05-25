---
name: hyperv
description: Hyper-V native Packer builds for SecretCon Windows images on a Windows host
---

# Hyper-V

## When this skill applies

Reach for this skill when building or running challenge VMs on a Windows workstation with the Hyper-V role, instead of QEMU (Nix) or Proxmox.

Hyper-V recipes (both under target directories):

- EWS Win10 LTSC: `infrastructure/packer/ews/win10-ews-hyperv.pkr.hcl`
- CysVuln Server 2016: `infrastructure/packer/cysvuln/hyperv-cysvuln.pkr.hcl`

All EWS builders (QEMU, Proxmox, Hyper-V) live in `infrastructure/packer/ews/`.

## Conventions in this repo

- Hyper-V Packer plugin cannot consume `cd_files` the way QEMU/VMware do. CysVuln uses a pre-built PROVISION ISO:
  1. `scripts/build-provision-iso.ps1` (Windows, `oscdimg.exe` from ADK or winget `Microsoft.OSCDIMG`)
  2. `packer build` with `-var cysvuln_provision_iso=...\provision.iso`
- Linux hosts can build the same ISO via `scripts/build-provision-iso.sh` (xorriso/genisoimage) for transfer to Windows.
- Generation 1 VMs (BIOS) for both recipes — matches Server 2016 and LTSC installer expectations.
- EWS Hyper-V workflow scripts under `scripts/hyperv/`:
  - `Prepare-SecretConHyperVBuild.ps1` — vendor downloads + LTSC ISO SHA pin to `%USERPROFILE%\Downloads\`
  - `Build-SecretConEwsVhdx.ps1` — packer init/build
  - `Start-SecretConEwsVm.ps1` / `Connect-SecretConEwsVnc.ps1` — register VM and portproxy for VNC
- Packer needs Administrator or membership in `Hyper-V Administrators` (`S-1-5-32-578`). `Build-SecretConEwsVhdx.ps1` checks this up front.
- CysVuln autounattend on Hyper-V does not ship `setstatic.ps1`; the guest uses DHCP. Pin SSH host after first boot or use reservations.
- Do not convert qcow2 to vhdx for cross-hypervisor sharing. Rebuild from the same Packer sources per platform (see multi-hypervisor runbook).

## Canonical examples

- [scripts/hyperv/Build-SecretConEwsVhdx.ps1](scripts/hyperv/Build-SecretConEwsVhdx.ps1)
- [scripts/hyperv/Prepare-SecretConHyperVBuild.ps1](scripts/hyperv/Prepare-SecretConHyperVBuild.ps1)
- [infrastructure/packer/cysvuln/hyperv-cysvuln.pkr.hcl](infrastructure/packer/cysvuln/hyperv-cysvuln.pkr.hcl)
- [docs/runbooks/deploy-cysvuln-multi-hypervisor.md](docs/runbooks/deploy-cysvuln-multi-hypervisor.md)

## Common pitfalls

- Missing `oscdimg.exe` on PATH causes Packer PROVISION ISO creation to fail on Windows. Run `Prepare-SecretConHyperVBuild.ps1` or install ADK Deployment Tools.
- LTSC ISO filename must be exactly `en-us_windows_10_enterprise_ltsc_2021_x64_dvd_d289cf96.iso` under Downloads for the EWS recipe default.
- `-AndVncTunnel` requires elevated PowerShell for `netsh portproxy`.
- VMware and Hyper-V CysVuln recipes use `ssh_username packer`; QEMU local build uses `Administrator` + `PizzaMan123!` — do not confuse verify scripts across hypervisors.

## References

- HashiCorp hyperv plugin: https://developer.hashicorp.com/packer/integrations/hashicorp/hyperv
- See also `packer/SKILL.md`, `windows-bootstrap/SKILL.md`, `nix/SKILL.md`

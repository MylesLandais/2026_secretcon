---
name: packer
description: Building bootable VM images for the SecretCon lab with HashiCorp Packer
---

# Packer

## When this skill applies

Reach for Packer when you need to bake a reproducible VM image for the
lab. We use Packer for two paths:

- Local QEMU builds, for fast iteration on a workstation.
- Proxmox-native builds, run on the lab host so the disk never crosses the
  WireGuard tunnel.

If you only need to provision an existing VM, use the bash and cloud-init
scripts under `provisioning/` instead.

## Conventions in this repo

- Recipes live in `infrastructure/packer/` and end in `.pkr.hcl`.
- One recipe per (target, hypervisor) pair. Do not multiplex hypervisors
  in a single recipe with a giant `source` switch.
- Communicator choice is explicit. For Windows we use SSH via the
  CD-delivered OpenSSH bundle in `provisioning/openssh/`. WinRM is
  deprecated for this repo because it has bitten us repeatedly on Win10
  LTSC.
- Autounattend is delivered on a generated PROVISION ISO, not by relying
  on the installer to find `autounattend.xml` on the boot media.
- ISOs are referenced by absolute path under `~/Downloads/` for local
  builds, and by Proxmox `local` storage paths for Proxmox builds.
- ISO checksums are pinned. If a checksum is missing, fail closed.
- Variables that look like secrets (`proxmox_password`, `ssh_password`)
  are defaulted to `packer` and overridden via env or a gitignored
  `*.pkrvars.hcl`. The `example.pkrvars.hcl` whitelist in `.gitignore`
  is the public template.

## Canonical examples

- `infrastructure/packer/ews/local-qemu-ews.pkr.hcl` — Win10 LTSC EWS under
  QEMU, SSH communicator.
- `infrastructure/packer/ews/proxmox-vm-ews.pkr.hcl` — Same EWS target on
  Proxmox, node `manage`, storage `local-lvm`, bridge `vmbr0` for provisioning
  then `vmbr1` for the player-facing run.
- `infrastructure/packer/wazuh-ubuntu.pkr.hcl` — Ubuntu cloud-image based
  template for the Wazuh SIEM.

## Common pitfalls

- "Packer is waiting on guest SSH" forever: the autounattend was almost
  certainly not picked up. Check that the PROVISION ISO is attached as a
  second CD and that the answer file path matches what Windows scans.
- WinRM timeout: not a WinRM problem. It is almost always the boot chain
  loading the wrong installer, or BCD pointing at the wrong partition.
  Fix the boot chain, not the WinRM config.
- Proxmox builder errors on `pve-manager/9.x`: confirm the recipe uses
  the modern `proxmox-iso` or `proxmox-clone` source. The legacy
  `proxmox` builder was removed.
- ISO too slow over the WireGuard tunnel: do not pull ISOs from the
  workstation. Stage them on the Proxmox host directly via the 8-way
  HTTP-range script and reference the host-local path.

## Debugging tips

- `PACKER_LOG=1 packer build -debug` pauses between steps so you can RDP
  in and inspect the guest mid-install.
- For Proxmox builds, watch the VM console in the Proxmox UI in parallel
  with Packer logs. Most failures show up there long before Packer times
  out.

## References

- HCL recipes in `infrastructure/packer/`.
- Vendored OpenSSH and TightVNC binaries in `provisioning/openssh/` and
  `provisioning/tightvnc/` (gitignored, fetched out of band).
- See also `proxmox/SKILL.md` for the post-build deploy and verify flow.

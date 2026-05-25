# EWS Packer recipes

Win10 LTSC Enterprise EWS challenge — one recipe per hypervisor, shared bootstrap.

| File | Builder | Output |
|------|---------|--------|
| local-qemu-ews.pkr.hcl | qemu | `output/win10-ews-local/win10-ews-local.qcow2` |
| proxmox-vm-ews.pkr.hcl | proxmox-iso | VMID 109 template on node `manage` |
| win10-ews-hyperv.pkr.hcl | hyperv-iso | VHDX under `output/win10-ews-hyperv/` |
| ews-shared.pkr.hcl | (locals only) | manifests, `bootstrap_win.ps1`, flag env vars |

## Manifests

- `provision-manifest-qemu.txt` — OpenSSH, TightVNC, Sysmon, bootstrap module (QEMU + Hyper-V `cd_files`)
- `provision-manifest-proxmox.txt` — above plus `provisioning/proxmox/autounattend.xml`, `setstatic.ps1`, static IP hint

## Build

```bash
# QEMU (Nix)
nix build .#win10-ews-local

# QEMU (direct)
cd infrastructure/packer/ews
packer init .
packer build -only=qemu.win10-ews-local .

# Proxmox (from lab host or tunnel)
packer build -only=proxmox-iso.win10-ews .

# Hyper-V (Windows host)
# scripts/hyperv/Build-SecretConEwsVhdx.ps1
```

`stubs/provision-validate.iso` is reserved for future Hyper-V secondary-ISO validate paths (CysVuln pattern).

## Docs

- [docs/runbooks/deploy-windowsvm.md](../../../docs/runbooks/deploy-windowsvm.md)
- [.claude/skills/packer/SKILL.md](../../../.claude/skills/packer/SKILL.md)

Parent `infrastructure/packer/` holds only cross-target recipes (`wazuh-ubuntu.pkr.hcl`, `proxmox-common.pkr.hcl`).

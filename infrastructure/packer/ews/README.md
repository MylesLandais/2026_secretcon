# EWS Packer recipes

Win10 LTSC Enterprise EWS — Packer installs Windows + thin `bootstrap_win.ps1`, then the **Ansible** provisioner runs [ansible/playbooks/ews.yml](../../../ansible/playbooks/ews.yml). Proxmox campaign bridge: [ansible/playbooks/proxmox/ews-hypervisor.yml](../../../ansible/playbooks/proxmox/ews-hypervisor.yml).

Migration docs: [ansible-proxmox-migration.md](../../../docs/refactor/ansible-proxmox-migration.md), [ansible-parity-matrix.md](../../../docs/refactor/ansible-parity-matrix.md).

| File | Builder | Output |
|------|---------|--------|
| local-qemu-ews.pkr.hcl | qemu | `output/win10-ews-local/win10-ews-local.qcow2` |
| proxmox-vm-ews.pkr.hcl | proxmox-iso | VMID 109 template on node `manage` |
| win10-ews-hyperv.pkr.hcl | hyperv-iso | VHDX under `output/win10-ews-hyperv/` |
| win10-ews-vmware.pkr.hcl | vmware-iso | VMDX export |
| ews-shared.pkr.hcl | (locals only) | manifests, thin bootstrap, Ansible inventory template |

## Manifests

- `provision-manifest-qemu.txt` — OpenSSH, TightVNC, Sysmon, bootstrap module (QEMU + Hyper-V `cd_files`)
- `provision-manifest-proxmox.txt` — above plus `provisioning/proxmox/autounattend.xml`, `setstatic.ps1`, static IP hint

## Build

Controller needs `ansible` + collections (`ansible-galaxy collection install -r ansible/requirements.yml`).

```bash
cd infrastructure/packer/ews
packer init .   # installs proxmox, qemu, hyperv, vmware, ansible plugins

# Proxmox (full pipeline via rebuild-ews.sh is preferred)
packer build -only=proxmox-iso.win10-ews .

# QEMU / Hyper-V / VMware — same thin bootstrap + ansible provisioner
packer build -only=qemu.win10-ews-local .
```

Proxmox orchestration (Packer + OpenTofu bridge + Ansible): [scripts/proxmox/rebuild-ews.sh](../../../scripts/proxmox/rebuild-ews.sh).

Day-2 converge only: [scripts/proxmox/converge-ews.sh](../../../scripts/proxmox/converge-ews.sh).

`stubs/provision-validate.iso` is used by the CysVuln Hyper-V pattern, not EWS (EWS Hyper-V uses `cd_files` directly).

## Docs

- [docs/runbooks/deploy-windowsvm.md](../../../docs/runbooks/deploy-windowsvm.md)
- [.claude/skills/packer/SKILL.md](../../../.claude/skills/packer/SKILL.md)

Parent `infrastructure/packer/` holds only cross-target recipes (`wazuh-ubuntu.pkr.hcl`, `proxmox-common.pkr.hcl`).

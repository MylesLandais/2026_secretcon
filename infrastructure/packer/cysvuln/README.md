# CysVuln Packer recipes

> **Transitional** — see [ansible-opentofu-migration.md](../../../docs/refactor/ansible-opentofu-migration.md), [ansible-parity-matrix.md](../../../docs/refactor/ansible-parity-matrix.md).

Windows Server 2016 CysVulnServer challenge — one recipe per hypervisor, shared bootstrap.

| File | Builder | Output |
|------|---------|--------|
| local-qemu-cysvuln.pkr.hcl | qemu | `output/cysvuln-local/cysvuln.qcow2` |
| hyperv-cysvuln.pkr.hcl | hyperv-iso | VHDX (needs `provision.iso`) |
| vmware-cysvuln.pkr.hcl | vmware-iso | VMX + VMDK |
| cysvuln-shared.pkr.hcl | (locals only) | manifest-driven `cd_files` |

Proxmox-native recipe: `proxmox-vm-cysvuln.pkr.hcl` (same directory).

`stubs/provision-validate.iso` is a 2 KiB placeholder so `packer validate` can
check Hyper-V recipes without a real PROVISION ISO.

## Manifests

- `provision-manifest-cysvuln.txt` — `provisioning/cysvuln/autounattend.xml` only
- `provision-manifest-shared.txt` — OpenSSH, EFS installer, Sysmon, AIE MSI, bootstrap module

Hyper-V: run `scripts/build-provision-iso.ps1` then pass `-var cysvuln_provision_iso=...`.

## Docs

- [docs/runbooks/deploy-cysvuln-multi-hypervisor.md](../../../docs/runbooks/deploy-cysvuln-multi-hypervisor.md)
- [docs/cysvulnserver/readme.md](../../../docs/cysvulnserver/readme.md)

Nix build: `nix build .#cysvuln-local` (see `.claude/skills/nix/SKILL.md`).

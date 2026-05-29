# AS-REP DC (Packer)

> **Transitional** — Packer bakes are on the deprecation glide path. In-VM state is migrating to Ansible; see [ansible-opentofu-migration.md](../../docs/refactor/ansible-opentofu-migration.md), [ansible-parity-matrix.md](../../docs/refactor/ansible-parity-matrix.md).

Windows Server 2016 AS-REP roasting DC for `secretcon.local`.

| Recipe | Output |
|--------|--------|
| `local-qemu-asrep.pkr.hcl` | Local `asrep.qcow2` |
| `proxmox-vm-asrep.pkr.hcl` | Proxmox VM (VMID 112 default) |

Shared variables and manifests: `asrep-shared.pkr.hcl`, `provision-manifest-asrep.txt`, `provision-manifest-shared.txt`.

Proxmox builds set `WAZUH_MANAGER=192.168.61.10` via `proxmox_bootstrap_env` (QEMU default remains `10.0.3.2` in shared vars).

Deploy without full Packer rebake: [`scripts/proxmox/deploy-asrep.sh`](../../scripts/proxmox/deploy-asrep.sh).

Player docs: [docs/asrep/readme.md](../../docs/asrep/readme.md).

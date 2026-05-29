# Domain controllers (Packer)

> **Transitional** — see [ansible-opentofu-migration.md](../../docs/refactor/ansible-opentofu-migration.md), [ansible-parity-matrix.md](../../docs/refactor/ansible-parity-matrix.md). The `heliumsupply.local` two-DC forest is a parallel track to the AS-REP `secretcon.local` box.

| Recipe | Purpose |
|--------|---------|
| `proxmox-vm-dc.pkr.hcl` | Proxmox DC1/DC2 templates |
| `proxmox-vars.pkr.hcl` | Proxmox API + OpenSSH bundle locals |

Deploy wrapper: [`scripts/proxmox/deploy-dc.sh`](../../scripts/proxmox/deploy-dc.sh).

Runbook: [docs/runbooks/deploy-dc.md](../../docs/runbooks/deploy-dc.md).

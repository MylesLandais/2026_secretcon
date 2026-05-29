# Ansible + Proxmox API migration

Status: **ACTIVE** (2026-05). Proxmox VM lifecycle uses the Ansible [`community.proxmox`](https://docs.ansible.com/ansible/latest/collections/community/proxmox/index.html) collection (`proxmox_kvm`). **OpenTofu was removed** from this repo.

Related: [ansible-opentofu-migration.md](ansible-opentofu-migration.md) (in-guest Ansible history), [ansible-parity-matrix.md](ansible-parity-matrix.md).

## Target architecture

| Layer | Tool | Scope |
|-------|------|--------|
| Golden image | Packer | Windows install, thin bootstrap, Ansible provisioner on bake |
| Hypervisor | Ansible `community.proxmox` | VM create/clone/update/destroy, bridge, agent, CPU/RAM |
| In-guest | Ansible `playbooks/*.yml` | Registry, services, flags, VNC, Wazuh, etc. |

`proxmox_node_network` is for **host** bridges only. VM NICs use `proxmox_kvm` `net` / `ipconfig`.

## Layout

```
ansible/
  inventory/group_vars/proxmox.yml   # API creds from .env
  playbooks/proxmox/
    ews-hypervisor.yml             # EWS bridge / agent / sizing
    wazuh-siem.yml                 # clone + cloud-init
    arkime.yml
    asrep.yml / cysvuln.yml        # ISO install VMs
    dc-teardown.yml
  roles/
    proxmox_kvm_vm/                # update existing VMID
    proxmox_vm_destroy/
scripts/lib/ansible-proxmox-env.sh
scripts/proxmox/converge-ews.sh    # guest ews.yml then ews-hypervisor.yml
```

## EWS converge order

1. `playbooks/ews.yml` on the Windows host (includes in-guest `proxmox_guest_agent`).
2. `playbooks/proxmox/ews-hypervisor.yml` on `localhost` — enables Proxmox `agent` only when `proxmox_guest_agent_converged=true`.

Bridge detection: live `net0` unless `EWS_FORCE_BRIDGE=1`.

## Deploy scripts

Thin wrappers call Ansible for `qm` CRUD, then keep bash for:

- xorriso PROVISION CDs (CysVuln / AS-REP)
- ARP / WinRM install polling
- in-guest bootstrap over tunnels

## Prerequisites

```bash
nix develop
ansible-galaxy collection install -r ansible/requirements.yml
# .env: PROXMOX_PASSWORD, PROXMOX_HOST, PROXMOX_USERNAME, PROXMOX_NODE
```

## Troubleshooting

If `qm reboot` hangs with **QEMU Guest Agent is not running**: `qm set <vmid> --agent 0`, hard stop/start, confirm `QEMU-GA` service in guest, re-run converge with agent enabled.

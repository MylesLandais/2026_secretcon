# Ansible — EWS convergence (canonical for Win10 EWS)

In-VM state for the EWS challenge VM is owned by [playbooks/ews.yml](playbooks/ews.yml). Packer runs a thin [bootstrap_win.ps1](../provisioning/powershell/bootstrap_win.ps1) then the Ansible provisioner during bake.

**Orchestration**

| Script | Purpose |
|--------|---------|
| [scripts/proxmox/discover-proxmox-inventory.sh](../scripts/proxmox/discover-proxmox-inventory.sh) | ARP/MAC discovery + `inventory/proxmox.discovered.yml` |
| [scripts/proxmox/discover-ews-ip.sh](../scripts/proxmox/discover-ews-ip.sh) | Print live guest IP for `nmap` / hydra |
| [scripts/proxmox/move-ews-bridge.sh](../scripts/proxmox/move-ews-bridge.sh) | Ansible `ews-hypervisor.yml` — net0 to vmbr1 + reboot (~2 min) |
| [scripts/proxmox/converge-ews.sh](../scripts/proxmox/converge-ews.sh) | Guest `ews.yml` + hypervisor play (runs discovery by default) |
| [scripts/proxmox/rebuild-ews.sh](../scripts/proxmox/rebuild-ews.sh) | Full rebuild: Packer + Ansible hypervisor + verify (last resort) |

**Docs:** [ansible-proxmox-migration.md](../docs/refactor/ansible-proxmox-migration.md), [ansible-parity-matrix.md](../docs/refactor/ansible-parity-matrix.md)

## Roles (EWS playbook order)

| Role | Status |
|------|--------|
| `sysmon` | Implemented |
| `wazuh_agent` | Implemented |
| `ultravnc` | Implemented (Chocolatey, winvnc -run watchdog, live RFB verify) |
| `tightvnc` | Legacy (parked; see `roles/tightvnc/`) |
| `ews_lpe_service` | Implemented |
| `flags` | Implemented |
| `ews_reset_task` | Implemented (30-minute in-guest reset for shared CTF state) |
| `defender_relax` | Implemented |
| `autologon` | Implemented |
| `ews_vnc_desktop` | Implemented |
| `proxmox_guest_agent` | Implemented (in-guest QEMU-GA) |
| `proxmox_kvm_vm` | Hypervisor playbooks (`playbooks/proxmox/`) |
| `windows_startup_task` | Implemented (included from flags/defender) |

CysVuln / AS-REP / DC playbooks remain scaffolded (migration step 5).

## Usage

```bash
nix develop
cp example.env .env
ansible-galaxy collection install -r ansible/requirements.yml

cd ansible
ansible-playbook --syntax-check playbooks/ews.yml

# Discover live IP + drift preview
../scripts/proxmox/discover-proxmox-inventory.sh
../scripts/proxmox/converge-ews.sh --check

# Apply (bridge move first if discovery reports vmbr0)
../scripts/proxmox/move-ews-bridge.sh   # when needed
../scripts/proxmox/converge-ews.sh
```

Set `ANSIBLE_ADMIN_PASSWORD` to match the guest (`packer` during bake, `PizzaMan123!` after shared-admin converge).

### UltraVNC troubleshooting

If `reg query` shows `Password` = `52E6654C7AA1885F` (`FELDTECH_VNC`) but `vncviewer` / Hydra fail:

1. Run `../scripts/proxmox/converge-ews.sh` (reapplies UltraVNC state, clears stale legacy VNC artifacts, probes live RFB auth).
2. Prefer the in-tree RFB validator over Hydra:
   `python3 ansible/roles/ultravnc/files/check_vnc_auth.py --host <ip> --password FELDTECH_VNC --cred-tool scripts/observability/vnc-cred-tool.py`
   or `--wordlist provisioning/wordlists/vnc-betterdefaultpasslist.txt --delay-seconds 0.5` (raise the delay if a run aborts with `no_vnc_auth`).
3. Hydra works as a compatibility fallback with **`-t 1`**; parallel tasks can still degrade the shared-player experience.
4. Force UltraVNC reapply: `ansible-playbook playbooks/ews.yml --tags ultravnc_hot -e ansible_host=<ip>`.

The `ews_reset_task` role restarts UltraVNC every 30 minutes by default during
competition to clear hung sessions between players.

Kali tool matrix and live VM workflow: [docs/runbooks/ews-vnc-adversary-emulation.md](../docs/runbooks/ews-vnc-adversary-emulation.md#kali-tool-and-package-audit-matrix).

## Coverage audit

```bash
python3 .claude/skills/repo-audit/audit.py ansible-migration-coverage
```

# Ansible migration (in-guest + Proxmox API)

Status: **ACTIVE** (2026-05-27). Packer re-bakes are too slow for incremental registry/policy changes; **Packer + Ansible** is the target architecture.

**Proxmox hypervisor:** [ansible-proxmox-migration.md](ansible-proxmox-migration.md) (`community.proxmox`). OpenTofu was removed.

Related artifacts:

- Step-level PowerShell mapping: [ansible-parity-matrix.md](ansible-parity-matrix.md)
- Proxmox VM lifecycle (retired OpenTofu doc): [opentofu-proxmox-scope.md](opentofu-proxmox-scope.md)
- Ansible tree: [ansible/README.md](../../ansible/README.md)

## Planning vs implementation

**EWS (steps 1–4, 6):** Implemented — `playbooks/ews.yml` is canonical; `bootstrap_win.ps1` is thin; Packer runs the Ansible provisioner; `playbooks/proxmox/ews-hypervisor.yml` manages campaign bridge via `rebuild-ews.sh` / `converge-ews.sh`.

**Other boxes (step 5):** Still on PowerShell bootstrap + Ansible scaffolds.

Do not add new challenge behaviour in both `bootstrap_*.ps1` and Ansible without a cutover PR (see [Cutover protocol](#cutover-protocol)).

Machine-readable rollup: `python3 .claude/skills/repo-audit/audit.py ansible-migration-coverage`.

## Phase tracker

| Step | Scope | Status | Acceptance |
|------|--------|--------|------------|
| 1 | Scaffold `ansible/`; `sysmon` + `tightvnc`; `ews.yml`; `--check --diff` on live EWS | **Done** | Roles implemented; use `converge-ews.sh --check` on lab host |
| 2 | Apply `sysmon` + `tightvnc` on live EWS | **Lab verify** | Wazuh rules `100800` / `100801` fire without Packer rebake |
| 3 | Port `wazuh_agent`, `ews_lpe_service`, `flags`, `defender_relax`, `autologon` | **Done** | `ews.yml` enabled; verify via `probe-ews.sh` on bake |
| 4 | Packer `provisioner "ansible"` for EWS; thin `bootstrap_win.ps1` | **Done** | All four EWS builders have ansible provisioner; Hyper-V/VMware bake smoke on Windows host |
| 5 | Repeat 1–4 for CysVuln + AS-REP DC | Not started | Per-box verify scripts pass |
| 6 | `playbooks/proxmox/ews-hypervisor.yml` — EWS VM only | **Done** | `rebuild-ews.sh` / `converge-ews.sh` use Ansible `proxmox_kvm` |
| 7 | Remaining Proxmox VMs via `community.proxmox` | **Done** | `deploy-*.sh` call `playbooks/proxmox/*.yml` |
| 8 | `ansible-playbook --check --diff` in CI / stress chain | Not started | Drift surfaces on every run |

Hypervisor scope: [ansible-proxmox-migration.md](ansible-proxmox-migration.md).

## Why this is on the board

Packer is a build-time tool. We have been treating it like a runtime configuration-management tool, and the seams are showing.

Concrete drift observed on the live EWS VM (VMID 109) on 2026-05-26, against the working tree on the same date:

- `Administrator` password is still `packer` (the Packer autounattend default). The shared-admin pivot (`PizzaMan123!`) added in commit `8e2d8ac` (2026-05-25) never reached this box because it was baked from `53ae202` (2026-05-13) and nothing converges live state.
- `HKLM:\SOFTWARE\TightVNC\Server\BlacklistThreshold=100` and `BlacklistTimeout=0` are set on the deployed box but were applied out-of-band (manually), not by the bootstrap. The bootstrap line that sets them (`e309ad0`, 2026-05-24) post-dates the bake. Git has no record of the manual change.
- `HKLM:\SOFTWARE\TightVNC\Server\LogLevel` and `LogDir` are unset on the live box, which is why Wazuh rule `100801` (`tvnserver.log "Authentication failed"`) cannot fire — the agent.conf is configured to tail a file TightVNC never produces.
- The Sysmon config on the live box is the SwiftOnSecurity baseline with no `DestinationPort 5900` include in `<NetworkConnect onmatch="include">`, so inbound VNC brute-force traffic to `tvnserver.exe` is dropped at the Sysmon kernel filter. Wazuh rule `100800` cannot fire.
- Defender real-time protection and the SecretCon exclusion list (added in the AS-REP integration work, `8e2d8ac`) were never applied. The AS-REP pivot from EWS will SmartScreen-block Rubeus today.
- `docs/architecture.md` claims EWS lives at `192.168.61.20` on `vmbr1`. Reality on 2026-05-26: `192.168.60.109` on `vmbr0`. Nothing reconciles the doc against the live network state.

Our only "fix" for any of these has been a 30-minute destructive Packer rebake via `scripts/proxmox/rebuild-ews.sh`. That is the wrong cost function for a 4-line registry change.

## What the target architecture looks like

Three layers, each with one tool and a clear scope:

1. **Packer** bakes the golden image. Stripped down to ONLY what cannot be applied to a running VM: Windows install, OpenSSH enablement, long-paths registry, seed account. Runs once per campaign, not per change.
2. **Ansible** (`community.proxmox`) owns Proxmox VM lifecycle — create/clone/update/destroy, bridge, agent, sizing. See [ansible-proxmox-migration.md](ansible-proxmox-migration.md).
3. **Ansible** owns inside-the-VM state. Every `Set-ItemProperty`, `Set-Service`, `New-NetFirewallRule`, `icacls`, `Register-ScheduledTask`, `Add-MpPreference`, Sysmon reload, Wazuh agent group assignment, flag artifact, and SACL in `provisioning/powershell/bootstrap_*.ps1` becomes a role. Same playbook runs during the Packer bake (Ansible-as-provisioner) and against the live VM after deploy (`ansible-playbook -l ews`).

## Hypervisor preservation constraint

The artifact-export builders for Hyper-V and VMware Workstation already exist in tree and they ALL run `bootstrap_win.ps1` end-to-end via SSH (OpenSSH on Windows). The Ansible migration must keep producing working artifacts on every existing path:

| Builder source | VM target | Build host | Communicator |
| -------------- | --------- | ---------- | ------------ |
| `proxmox-iso.win10-ews` (`infrastructure/packer/ews/proxmox-vm-ews.pkr.hcl`) | Proxmox lab VM | Linux (cerberus) | SSH |
| `qemu.win10-ews-local` (`infrastructure/packer/ews/local-qemu-ews.pkr.hcl`) | qcow2 export | Linux (any) | SSH |
| `hyperv-iso.win10-ews-hyperv` (`infrastructure/packer/ews/win10-ews-hyperv.pkr.hcl`) | .vhdx export | Windows host | SSH |
| `vmware-iso.win10-ews-vmware` (`infrastructure/packer/ews/win10-ews-vmware.pkr.hcl`) | .vmdk export | Windows host | SSH |

Mirror table for CysVuln (`cysvuln-shared.pkr.hcl`) and AS-REP DC (`asrep-shared.pkr.hcl`); same shape, same constraint.

One `provisioner "ansible"` block in `ews-shared.pkr.hcl` runs the SAME `playbooks/ews.yml` against any of the four sources. We standardize on SSH everywhere (not WinRM). `pywinrm` stays in the Nix shell as a forward-compatibility hedge only.

Builder-specific gotchas:

- Hyper-V Gen 2: Secure Boot disabled for unattended installs; CysVuln Hyper-V uses `secondary_iso_images` (`hyperv-cysvuln.pkr.hcl`). EWS Hyper-V uses Gen 1 + `floppy_files`.
- VMware Workstation on Windows requires the application installed on the build host, not just the Packer plugin.

OpenTofu does **not** touch Hyper-V or VMware paths — Proxmox lab runtime only.

## Concrete shape in this tree

```
ansible/
  ansible.cfg
  inventory/
    proxmox.yml
  group_vars/
    all.yml
    windows.yml
  host_vars/
    ews-prod.yml
  roles/
    sysmon/
    wazuh_agent/
    tightvnc/
    ews_lpe_service/
    flags/
    defender_relax/
    autologon/
    cysvuln_efs_installer/
    cysvuln_aie_levers/
    asrep_promote/
    asrep_users_and_flags/
    dc_promote/
    windows_startup_task/
  playbooks/
    ews.yml
    cysvuln.yml
    asrep.yml
    dc.yml

ansible/playbooks/proxmox/   # community.proxmox hypervisor plays
  ews-hypervisor.yml
  wazuh-siem.yml
  arkime.yml
  asrep.yml
  cysvuln.yml
```

Target rebuild flow:

```
./scripts/proxmox/rebuild-ews.sh
# or day-2: ./scripts/proxmox/converge-ews.sh
```

Expected inside-VM convergence: ~5 minutes vs ~30 minutes for a destructive Packer rebake.

## Migration order (detail)

Same eight steps as the [phase tracker](#phase-tracker); see that table for status.

Step 4 end state for `bootstrap_win.ps1`: long-paths registry, OpenSSH sanity, handoff to Ansible only.

Step 5: AS-REP `Install-ADDSForest` may remain in PowerShell through the Packer reboot window until SSH is stable post-promotion (documented in parity matrix as bootstrap-phase).

## What this does NOT include

- Replacing the Wazuh docker-compose stack with NixOS modules.
- OPNsense automation (`config.xml`); consider `ansibleguy.opnsense` only after Windows convergence is stable.
- Wazuh rule management (`local_rules.xml` + `sync-wazuh-rules.sh` stays as-is).
- Hyper-V / VMware builders or attendee artifact paths.
- Switching Packer communicator from SSH to WinRM.

## Honest costs

- One operator-day to scaffold and prove one role end-to-end.
- Two to three operator-days to port the rest of `bootstrap_win.ps1` and `bootstrap_dc.ps1`.
- Ongoing: Ansible via `nix develop` (`ansible`, `proxmoxer`, collections in `ansible/requirements.yml`).

## Acceptance test (EWS)

The drift items in [Why this is on the board](#why-this-is-on-the-board) are the acceptance test. After step 3, `ansible-playbook --check --diff` on a freshly-baked EWS should report only differences Ansible is about to converge — not permanent dual truth in PowerShell.

First ports (already validated in tree): TightVNC `LogLevel`/`LogDir` at MSI install time and Sysmon `DestinationPort 5900` — see `sysmon` and `tightvnc` roles.

## Cutover protocol

When an Ansible role reaches parity (validated via the relevant `verify-*.sh` / `probe-*.sh` against a freshly deployed VM):

1. Delete the corresponding PowerShell block in the **same PR**.
2. Flip the row to **COVERED** in [ansible-parity-matrix.md](ansible-parity-matrix.md).
3. Re-run `python3 .claude/skills/repo-audit/audit.py ansible-migration-coverage`.

Dual edits without deletion are allowed only during the porting PR, not as a permanent state.

## Proxmox hypervisor (Ansible)

See **[ansible-proxmox-migration.md](ansible-proxmox-migration.md)**. OpenTofu was removed; use `community.proxmox.proxmox_kvm`.

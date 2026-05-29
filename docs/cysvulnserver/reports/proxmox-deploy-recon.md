# Proxmox cysvuln deploy reconnaissance (Phase 0)

One-pager grounding for the
[cysvuln_proxmox_campaign](../../.cursor/plans/cysvuln_proxmox_campaign_4c46be90.plan.md)
plan. Captured before any state-changing commands.

Date: 2026-05-25
Origin: WireGuard from workstation (`wg-ctf`, routes `192.168.60.0/24` +
`192.168.61.0/24` over `192.168.2.12`).

## SSH reachability

| Hop | Auth | Outcome |
| --- | --- | --- |
| `root@192.168.60.1` (Proxmox `manage`) | password from `.env` `PROXMOX_PASSWORD` only — no pubkey accepted | works via `sshpass`. The on-disk `~/.ssh/id_ed25519` is passphrase-encrypted and Bitwarden SSH agent socket is missing; `provisioning/ssh/packer_ed25519.pub` is not in `/root/.ssh/authorized_keys`. |
| `dadmin@192.168.61.10` (Wazuh `wazuh-siem`) via ProxyJump | `provisioning/ssh/packer_ed25519` (cloud-init key) | works; `dadmin` has passwordless sudo. |

Concrete command used throughout recon:

```bash
SSHPASS_BIN=/nix/store/.../sshpass
"$SSHPASS_BIN" -p "$PROXMOX_PASSWORD" ssh \
    -o StrictHostKeyChecking=accept-new \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    root@192.168.60.1 'qm list'

ssh -i provisioning/ssh/packer_ed25519 \
    -o "ProxyCommand=$SSHPASS_BIN -p $PROXMOX_PASSWORD ssh \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -W %h:%p root@192.168.60.1" \
    dadmin@192.168.61.10 'sudo cat /var/ossec/etc/rules/local_rules.xml'
```

## Proxmox VM inventory (`qm list` snapshot)

| VMID | Name | Status | Notes |
| ---: | --- | --- | --- |
| 100 | opnsense-fw | running | Already enrolled as Wazuh agent `001`. |
| 101 | windows-server-2016 | running | Generic Win2016. |
| 103 | zentyal-prim-dns-local | running | |
| 104 | kali-2025 | running | Attack box. |
| 106 | wind-2012-dc-bios | running | |
| 107 | rules-information-page | running | |
| 108 | **CysVulnServer** | running | Older Win2016 EFS/AIE box; vmbr0; only 32G disk. **No Wazuh agent enrolled.** This is what we will compare against. |
| 109 | secretcon-ews-vnc-unquoted-path | running | Different challenge VM; vmbr0. Enrolled as agent `003` (`WIN10-EWS`). |
| 110 | wazuh-siem | running | Native Wazuh stack (manager + indexer + dashboard); vmbr0 DHCP + vmbr1 static `192.168.61.10/24`. |
| 9000 | ubuntu-2204-cloud-tmpl | stopped | Template used by `deploy-wazuh-siem.sh`. |
| **119** | — | **FREE** | Target for this campaign. |

The plan referenced VMID 118 as the existing build; **118 does not exist
on the host today**. 108 is the live cysvuln. So the deploy is
side-by-side `108` (untouched) → `119` (new hardened build), not
`118 → 119`. No conflict with `108` because they only share `vmbr0` and
the IPs are different.

## Per-VM configs that matter

VMID 108 (current cysvuln, reference only):

- machine `pc-i440fx-10.1`, BIOS SeaBIOS, 32G `local-lvm`, `vmbr0` e1000.
- No `qemu_agent`, no snapshots listed by `qm config 108` (this is just
  the live runtime config; snapshots would show under
  `qm listsnapshot 108`).

VMID 110 (Wazuh manager):

- Dual NIC: `vmbr0` for upstream/mgmt (DHCP), `vmbr1` `192.168.61.10/24`
  for agent traffic. No gateway on vmbr1.
- cloud-init customization: `local:snippets/wazuh-user.yaml` with
  `dadmin` user keyed to `provisioning/ssh/packer_ed25519.pub`.
- Native Wazuh install on Ubuntu 22.04.

## Wazuh manager state (`192.168.61.10`)

### Rule pack

```text
sudo cat /var/ossec/etc/rules/local_rules.xml
-->
<group name="suricata,secretcon,">
  <rule id="86600">…Suricata alert event…</rule>
  <rule id="86601">…high-severity…</rule>
  <rule id="86602">…medium-severity…</rule>
  <rule id="86603">…low-severity…</rule>
  <rule id="86604">…Attempted Administrator Privilege Gain…</rule>
</group>
```

The SecretCon CysVuln pack (`100501`–`100530`) from
[`infrastructure/wazuh-docker/config/wazuh_cluster/local_rules.xml`](../../infrastructure/wazuh-docker/config/wazuh_cluster/local_rules.xml)
is **not present**. Phase 3 of the plan will push it.

### `ews` agent group

```text
/var/ossec/etc/shared/
├── agent-template.conf
├── ar.conf
├── default/
└── ews/
    ├── agent.conf       # placeholder: <agent_config></agent_config> (76 bytes)
    └── merged.mg

/var/ossec/etc/shared/ews/agent.conf:
<agent_config>
  <!-- Shared agent configuration here -->
</agent_config>
```

The `ews` group already exists (so `agent_groups -a -g ews` is a no-op),
but the actual `localfile` subscriptions
(`Microsoft-Windows-Sysmon/Operational`,
`Microsoft-Windows-MSI/Operational`, EFS log, `audit-aie-*.json`) from
[`infrastructure/wazuh-docker/config/wazuh_cluster/shared/ews/agent.conf`](../../infrastructure/wazuh-docker/config/wazuh_cluster/shared/ews/agent.conf)
need to be synced.

### Enrolled agents

```text
ID: 000, wazuh-siem (server)        — 127.0.0.1   — Active
ID: 001, opnsense                   — any         — Active
ID: 003, WIN10-EWS                  — any         — Active
ID: 004, WIN-UB5Q52138VG            — any         — Active
```

Agent ID `002` is free, which is the natural slot for the new cysvuln
VMID 119 once it bootstraps.

## Packer + provisioning gaps

[`infrastructure/packer/cysvuln/proxmox-vm-cysvuln.pkr.hcl`](../../infrastructure/packer/cysvuln/proxmox-vm-cysvuln.pkr.hcl):

- `vm_id` defaults to `118` (stale; nothing on the host uses this).
- `build_ssh_host = "192.168.60.118"` is **inconsistent with**
  [`provisioning/proxmox/setstatic.ps1`](../../provisioning/proxmox/setstatic.ps1)
  which hardcodes `192.168.60.109`. The two literals do not agree, which
  is why the current Proxmox cysvuln build path cannot complete without
  the Phase 1 templating work.

## Implications for the rest of the plan

- Phase 1 (IP parameterization) is **required** before any Packer build —
  pick a stable token in `setstatic.ps1`, render to a tempfile, and feed
  it to the PROVISION ISO. Default render target: `192.168.60.119` to
  match the chosen VMID.
- Phase 2 (deploy-cysvuln.sh) must use `sshpass` for every Proxmox SSH
  hop until the workstation has a key authorized on the Proxmox host
  (out of scope for this campaign).
- Phase 3 (rules sync) — `agent_groups -a -g ews` is a safe no-op
  thanks to the existing group; the script should still call it for
  idempotence on a fresh manager.
- Phase 5 (`stress-campaign.sh --platform proxmox`) needs three
  primitives swapped:
  - snapshot revert: `ssh root@192.168.60.1 'qm rollback 119 baseline && qm start 119'`
    (via `sshpass`).
  - stop_vm: `ssh root@192.168.60.1 'qm shutdown 119 --timeout 60 || qm stop 119'`.
  - target host: `192.168.60.119` + `WINRM_PORT=5985` (real WinRM, not
    the QEMU user-net forward at `127.0.0.1:15985`).
  - `wait_for_winrm.sh` currently hardcodes
    `https://127.0.0.1:55000/security/user/authenticate` for the Wazuh
    API gate; needs a `WAZUH_API_HOST` knob so the Proxmox manager
    (`192.168.61.10:55000`) can answer.

No state-changing commands were issued. Plan execution can proceed
from Phase 1.

## Reconciliation: 108 vs 118 (post-fix)

Captured 2026-05-26 after working through the
[`reconcile_118_vs_108`](../../.cursor/plans/reconcile_118_vs_108,_validate_flags_+_wazuh_aaea0304.plan.md)
plan. VMID 119 was destroyed and replaced by VMID 118 built to mirror
the live VMID 108 reference. Findings:

### `qm config` parity (before/after on the new build)

| Knob             | VMID 108 reference         | VMID 118 (old `deploy-cysvuln.sh`) | VMID 118 (current)        |
|------------------|----------------------------|------------------------------------|---------------------------|
| Memory           | 8000 MB                    | 4096 MB                            | 8000 MB                   |
| Cores            | 1                          | 2                                  | 1                         |
| CPU type         | `x86-64-v2-AES`            | `host`                             | `x86-64-v2-AES`           |
| Disk bus         | `ide0` (local-lvm:32)      | `sata0` (local-lvm:32)             | `ide0` (local-lvm:32)     |
| Boot order       | `ide0;ide2;net0`           | `ide2` only                        | `ide0;ide2;net0`          |
| NIC              | `e1000,bridge=vmbr0`       | `e1000,bridge=vmbr0`               | `e1000,bridge=vmbr0,firewall=1` |
| Default VMID     | n/a                        | 119                                | 118                       |

All five drifted knobs were the cause of two failure modes: (a) the new
box only ever booted from the install CD because no disk was in the
boot order, and (b) `--cpu host` made the resulting baseline snapshot
non-portable between Proxmox CPU revisions.

### Autounattend.xml SKU + OOBE fix

[`provisioning/proxmox/autounattend.xml`](../../provisioning/proxmox/autounattend.xml)
selected `/IMAGE/INDEX = 1` on the Windows Server 2016 Eval ISO, which
is `SERVERSTANDARDCORE` (Server Core — bare command prompt, no Server
Manager, no taskbar, no AIE-friendly shell). Replaced with the
by-name selector used by the QEMU template:

```xml
<MetaData wcm:action="add">
  <Key>/IMAGE/NAME</Key>
  <Value>Windows Server 2016 SERVERSTANDARD</Value>
</MetaData>
```

Added `RunSynchronousCommand` blocks (specialize pass) + `FirstLogonCommand`
blocks (oobeSystem pass) to suppress the post-OOBE noise that masked
provisioning state on the noVNC console:

- `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU\NoAutoUpdate=1`
- `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\DoNotConnectToWindowsUpdateInternetLocations=1`
- `HKLM\SOFTWARE\Microsoft\ServerManager\DoNotOpenServerManagerAtLogon=1`
- `HKCU\SOFTWARE\Microsoft\ServerManager\DoNotOpenServerManagerAtLogon=1`
- `HKCU\SOFTWARE\Microsoft\ServerManager\Roles\RefreshFrequency=00:00:00`
- `Stop-Service wuauserv; Set-Service wuauserv -StartupType Disabled`

### Bootstrap hive seeding (load-bearing for new accounts)

Autounattend only writes the HKCU keys for the `packer` first-logon
account. Server Manager / Get-updates re-appear for `Administrator`
and `User_Joe` on first interactive logon unless the keys are also
planted in their hives. Added a `Set-SecretConHivePrompts` helper to
[`provisioning/powershell/bootstrap_cysvuln.ps1`](../../provisioning/powershell/bootstrap_cysvuln.ps1)
that uses `reg.exe load`/`unload` (PSDrive `HKU:` is unreliable from
WinRM `cmd.exe`-spawned scripts) to apply the same registry tweaks +
`DisableNotificationCenter` to:

- `C:\Users\Default\NTUSER.DAT` (Default user template — every new
  account inherits)
- `C:\Users\Administrator\NTUSER.DAT`
- `C:\Users\User_Joe\NTUSER.DAT` (also gets `AlwaysInstallElevated=1`
  for the privesc chain, in the same `reg load` block)

### Flag validation

Both flags read back byte-exact from the live VM via WinRM and matched
`artifacts/cysvuln/proxmox-deploy/flags.env`. Recorded at
[`artifacts/cysvuln/proxmox-deploy/118-flag-verify.json`](../../artifacts/cysvuln/proxmox-deploy/118-flag-verify.json):

| Flag       | On-disk path                                  | Match |
|------------|-----------------------------------------------|-------|
| user.txt   | `C:\Users\User_Joe\Desktop\user.txt`          | ✓     |
| root.txt   | `C:\Users\Administrator\Desktop\root.txt`     | ✓     |

### Wazuh agent enrollment fix

The plan assumed first-boot agents auto-enroll under their hostname
(`WIN10-EWS`) and pick an unused agent ID. In practice, VMIDs 108 and
109 both have agents running with that same hostname/key on the same
Proxmox network. `wazuh-remoted` accepts only one TCP session per key
and silently rejects the rest with
`WARNING: Agent key already in use: agent ID 'NNN'`. VMID 118 was the
loser, so even though `agent_control -i 006` reported `Status: Active`
(from a brief window during enrollment), no later events from 118
reached `alerts.json`.

Fix applied directly on VMID 118 (no manager-side rule changes
needed):

- Stopped `WazuhSvc`, deleted `client.keys`, edited `ossec.conf` to add:
  ```xml
  <enrollment>
    <enabled>yes</enabled>
    <agent_name>WIN10-EWS-118</agent_name>
    <manager_address>192.168.61.10</manager_address>
    <groups>ews</groups>
  </enrollment>
  ```
- Restarted `WazuhSvc`. `authd` issued agent ID `007` with name
  `WIN10-EWS-118`, group `ews`. `agent_control -l` now distinguishes
  the three EWS-class boxes cleanly.

The fresh `baseline` snapshot
(`post-WIN10-EWS-118-enrollment, sysmon flowing to manager
(2026-05-26T02:46:32Z)`) was taken **after** this fix, so any
`qm rollback 118 baseline` resumes with the unique enrollment intact.
The same unique-name pattern should be folded into
[`provisioning/powershell/bootstrap_cysvuln.ps1`](../../provisioning/powershell/bootstrap_cysvuln.ps1)
as a follow-up (set `<agent_name>WIN10-EWS-${env:COMPUTERNAME}</agent_name>`
or include the VMID) so this never bites the next rebuild.

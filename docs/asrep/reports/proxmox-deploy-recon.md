# Proxmox ASREP deploy reconnaissance

Grounding notes for VMID **112** (`secretcon-asrep-dc-secretcon`) on the SecretCon range.

## Target VM

| Field | Value |
|---|---|
| VMID | 112 (planned; verify `qm list` before deploy) |
| Bridge | `vmbr1` (range / agent network) |
| OS | Windows Server 2016 DC |
| Domain | `secretcon.local` |
| Wazuh manager | `192.168.61.10` (VMID 110) |
| Agent group | `asrep` |

## Deploy path

Preferred: DHCP discovery + WinRM bootstrap (avoids Packer SSH timeout on Proxmox):

```bash
./scripts/proxmox/deploy-asrep.sh --vmid 112
```

Alternative: native Packer builder:

```bash
cd infrastructure/packer/asrep
packer build proxmox-vm-asrep.pkr.hcl
```

## Post-deploy QC

```bash
./scripts/verify-asrep.sh <vm-ip>
./scripts/proxmox/baseline-snapshot-asrep.sh --vmid 112 --ip <vm-ip>
./scripts/proxmox/sync-wazuh-rules.sh   # ensure 100700-100702 on manager
```

## Bootstrap flow

1. Windows install from Server 2016 ISO + PROVISION CD (`asrep` autounattend).
2. `winrm_bootstrap_asrep.py` uploads `bootstrap_asrep.ps1`, stages runtime script.
3. Two promotion/seed passes with reboots (mirrors local QEMU Packer flow).
4. `verify-post-promote.ps1` confirms `enite` roastable + flag present.

## SSH / WinRM hops

Same as CysVuln Proxmox deploy:

- `root@192.168.60.1` via `PROXMOX_PASSWORD` (sshpass)
- WinRM tunnel `127.0.0.1:15986` → guest `:5985`
- Wazuh manager via `dadmin@192.168.61.10` + `packer_ed25519` ProxyJump

## Conflicts

- Do not collide VMID 112 with existing range VMs (`qm list`).
- ASREP is independent of Chain 8 (`hackerblueprint.local`) and CysVuln (VMID 108/119).

See [readme.md](readme.md) and [attack-faq-walkthrough.md](attack-faq-walkthrough.md) for local QEMU QC parity.

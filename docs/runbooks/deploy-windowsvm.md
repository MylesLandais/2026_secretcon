# Runbook: Deploy the Win10 EWS challenge VM

Build the Engineering Workstation challenge VM. Two paths: local QEMU
for fast iteration, and Proxmox-native for the live lab. Both produce
the same artifact: a Win10 LTSC VM with TightVNC, the Wazuh agent,
and Sysmon installed.

The challenge ships with:

- A TightVNC password drawn from the public SecLists
  default-credentials list (intended foothold).
- A low-priv user `patrick` with a flag at `C:\Users\patrick\Desktop\flag.txt`.
- The `SecretConEwsSync` service with an unquoted image path
  (intended LPE).
- An Administrator flag at `C:\Users\Administrator\Desktop\root.txt`.

See `targets/ews-win11/flag-notes.md` for the full intended kill chain.

## Prerequisites

- Windows 10 LTSC eval ISO and `virtio-win.iso` on hand. For local
  builds, drop them in `~/Downloads/`. For Proxmox, stage them on the
  host under `local` storage.
- ISO SHA-256 must match the pinned value in the recipe.
- `nix develop` shell active. Packer, qemu, and xorriso must be on
  `PATH`.

If you do not have the Win10 LTSC ISO, the Fido wrapper in
`scripts/fetch-iso.sh` can pull it. Run it from the workstation only
for local builds; for Proxmox builds, fetch directly on the host with
the 8-way HTTP-range script (the WireGuard tunnel uplink is too slow).

## Local QEMU build

```
nix build .#win10-ews-local
./scripts/run-local-vm.sh result/win10-ews-local.qcow2
```

What this does:

- Runs Packer against `infrastructure/packer/local-qemu.pkr.hcl`.
- Generates a PROVISION ISO with `autounattend.xml` and attaches it
  alongside the install ISO.
- Boots Windows under QEMU, waits for SSH (delivered by the
  CD-mounted OpenSSH bundle in `provisioning/openssh/`).
- Runs `provisioning/powershell/bootstrap_win.ps1` to install TightVNC,
  the Wazuh agent, and Sysmon.
- Drops the qcow2 at `infrastructure/packer/output/win10-ews-local/`.

Running VM exposes:

| Service | Host port |
|---------|-----------|
| RDP     | 3389      |
| WinRM   | 5985      |
| VNC     | 5900      |
| SSH     | 2222      |

Expected runtime: about 45 to 75 minutes, dominated by the Windows
installer and Wazuh agent install.

## Proxmox-native build

```
packer init  infrastructure/packer/proxmox-vm.pkr.hcl
packer build infrastructure/packer/proxmox-vm.pkr.hcl
```

Required environment variables:

```
PROXMOX_URL=https://192.168.60.1:8006/api2/json
PROXMOX_TOKEN_ID=<token-id>
PROXMOX_TOKEN_SECRET=<token-secret>
```

What this does:

- Creates VMID `109` on node `manage`.
- Storage `local-lvm`, bridge `vmbr0` for provisioning.
- Attaches the staged ISO from `local` plus a generated PROVISION ISO.
- Boots, waits for guest SSH, runs `bootstrap_win.ps1` with
  `WAZUH_MANAGER=192.168.61.10` and `WAZUH_AGENT_GROUP=ews`.

After the first successful boot, switch the NIC to `vmbr1`:

```
ssh root@192.168.60.1 'qm set 109 --net0 e1000,bridge=vmbr1'
```

This moves the VM onto the player-facing challenge VLAN.

## Sysmon and Wazuh agent telemetry

`bootstrap_win.ps1` installs and starts:

- TightVNC, on TCP/5900, with the intended foothold password.
- Wazuh agent 4.8.0 against manager `192.168.61.10`, in group `ews`.
- Sysmon with the bundled config. Events feed Wazuh rule series
  `92xxx`.

To smoke-test the pipeline:

1. SSH into the SIEM VM, tail `/var/ossec/logs/archives/archives.log`.
2. Generate a noisy event on the EWS VM (open a PowerShell prompt as
   the low-priv user).
3. Watch for a `92xxx` rule firing within a few seconds.

If nothing arrives, see `.claude/skills/wazuh/SKILL.md` "Common
pitfalls."

## Common failures

- "Packer waiting on guest SSH" for more than 30 minutes: autounattend
  was not picked up. Confirm the PROVISION ISO is attached and the
  installer scanned for it. This is the most common Proxmox-side
  failure mode.
- "Bootstrap fails on Wazuh agent install": the staged MSI checksum
  drifted, or the manager IP is unreachable from the build bridge. The
  build bridge is `vmbr0`; the manager lives on `vmbr1`. The
  bootstrap is written to tolerate this and retry once on the
  challenge bridge after the move.
- "VNC password rejected by player tooling": confirm the bootstrap
  set `VALUE_OF_PASSWORD` and `VALUE_OF_CONTROLPASSWORD`. Both must be
  set for the SecLists wordlist to land the foothold.

## Related

- `.claude/skills/packer/SKILL.md` for build authoring patterns.
- `.claude/skills/wazuh/SKILL.md` for telemetry conventions.
- `targets/ews-win11/flag-notes.md` for the intended attack paths.

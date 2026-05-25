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

- Windows 10 Enterprise LTSC 2021 x64 (en-us) ISO. The recipe pins
  sha256 `c90a6df8997bf49e56b9673982f3e80745058723a707aef8f22998ae6479597d`.
- `virtio-win.iso` for the local QEMU path.
- `nix develop` shell active. Packer, qemu, xorriso on `PATH`.

### Getting the ISO

Fido is unreliable for LTSC variants and the prior wrapper shipped
Windows Home to one tester. Use `scripts/fetch-iso.sh` with an
operator-resolved mirror URL:

```
./scripts/fetch-iso.sh win10-ltsc <url>
```

Mirrors, in preference order:

1. `https://massgrave.dev/windows_ltsc_links` — resolve to the en-us x64 LTSC 2021 link.
2. `https://archive.org/details/Windows10EnterpriseLTSC202164Bit` — slow but stable.
3. `https://buzzheavier.com/pj97mvcpou4e`.

The script refuses to proceed if sha256 does not match the pinned value.
That guard is the single source of truth — if it passes, you have the
right edition.

For Proxmox, stage the verified ISO into `local` storage:

```
scp infrastructure/packer/iso/en-us_windows_10_enterprise_ltsc_2021_x64_dvd_d289cf96.iso \
    root@<proxmox>:/var/lib/vz/template/iso/
```

### Setting flag values

The user and root flags are injected via environment variables at build
time. Defaults are `crit-low-priv-patrick` and `crit-root-system-privs`;
override per deployment so testers cannot carry flag values between
events:

```
export SECRETCON_USER_FLAG="event-<name>-user-<random>"
export SECRETCON_ROOT_FLAG="event-<name>-root-<random>"
```

## Local QEMU build

```
export SECRETCON_USER_FLAG=... SECRETCON_ROOT_FLAG=...
nix build .#win10-ews-local
./scripts/run-local-vm.sh result/win10-ews-local.qcow2
```

What this does:

- Runs Packer against `infrastructure/packer/ews/local-qemu-ews.pkr.hcl`.
- Generates a PROVISION ISO with `autounattend.xml` and attaches it
  alongside the install ISO.
- Boots Windows under QEMU, waits for SSH (delivered by the
  CD-mounted OpenSSH bundle in `provisioning/openssh/`).
- Runs `provisioning/powershell/bootstrap_win.ps1` to install TightVNC,
  the Wazuh agent, and Sysmon.
- Drops the qcow2 at `infrastructure/packer/ews/output/win10-ews-local/`.

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
cd infrastructure/packer/ews
packer init .
packer build -only=proxmox-iso.win10-ews .
```

Required environment variables:

```
PROXMOX_URL=https://192.168.60.1:8006/api2/json
PROXMOX_USERNAME=root@pam
PROXMOX_PASSWORD=<password>
```

Copy `example.env` to `.env` and set these values. The Packer `proxmox-iso`
builder uses username/password, not API tokens.

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
- Wazuh agent (default 4.14.5, override with `WAZUH_AGENT_VERSION`) against
  manager `192.168.61.10`, in group `ews`. Bootstrap fails the build if the
  agent does not log "Connected to the server" within 60 s.
- Sysmon with the bundled config (SwiftOnSecurity master, snapshot pinned
  at `provisioning/powershell/assets/sysmonconfig.xml`, sha256 verified at
  install time). Events feed Wazuh rule series `92xxx`.

To smoke-test the pipeline:

1. SSH into the SIEM VM, tail `/var/ossec/logs/archives/archives.log`.
2. Generate a noisy event on the EWS VM (open a PowerShell prompt as
   the low-priv user).
3. Watch for a `92xxx` rule firing within a few seconds.

If nothing arrives, see `.claude/skills/wazuh/SKILL.md` "Common
pitfalls."

## Post-build verification

Before shipping a rebuild to testers, run `scripts/verify-ews.sh`
from Kali (or any attacker host on vmbr1) against the deployed VM IP.
The script confirms the two things a tester will actually attempt:

- VNC reachable on tcp/5900 and the SecLists default password is
  accepted (foothold path).
- Service-path LPE preconditions hold: `SecretConEwsSync` ImagePath is
  unquoted, contains a space, and `C:\Program Files\SecretCon\` is
  writable by `BUILTIN\Users`.

```
export WAZUH_API_PASSWORD=...   # from .env, gates the manager-side check
./scripts/verify-ews.sh <target-ip>
```

Exits non-zero on any failure. Run before declaring a build green. The
`wazuh-agent-active` check requires `WAZUH_API_PASSWORD` (and optionally
`WAZUH_MANAGER_HOST`, `WAZUH_API_USER`) — without it the check FAILs with
"WAZUH_API_PASSWORD unset".

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

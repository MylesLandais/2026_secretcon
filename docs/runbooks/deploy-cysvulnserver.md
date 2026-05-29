# Runbook: Deploy the CysVulnServer challenge VM

Build a deterministic replica of Cy's VM 108 challenge box: Windows
Server 2016 running Easy File Sharing Web Server 6.9 with the
`AlwaysInstallElevated` Windows Installer policy misconfig set.

Two flags by design:

- Flag 1 — Foothold via EDB-42256 (stack BoF in `fsws.exe`,
  unauthenticated, HTTP/80). Service runs as `User_Joe` so the
  foothold lands low-priv. Catches at `C:\Users\User_Joe\Desktop\user.txt`.
- Flag 2 — SYSTEM via `AlwaysInstallElevated` MSI privesc
  (T1574.009). Catches at `C:\Users\Administrator\Desktop\root.txt`.

The atomic notes covering each step live in the Vault:
[[cysvulnserver-foothold]], [[cysvulnserver-system-flag-chain]],
[[alwaysinstallelevated]], [[msi-privesc-msiexec-quiet-install]],
[[edb-42256-efs-web-server]], [[easy-file-sharing-web-server-6-9]].

## Prerequisites

- Windows Server 2016 ISO — [docs/windows-image-inputs.md](../windows-image-inputs.md);
  stage on Proxmox as `local:iso/windows-server-2016.iso`.
- CysVuln artifacts via `./scripts/fetch-cysvuln-artifacts.sh` (EFS installer
  SHA-256 `60ea3256...`, validation MSI). See
  `infrastructure/artifacts/cysvuln/readme.md`.
- `nix develop` shell. Packer with the `proxmox` plugin.
- `.env` from `example.env` with `PROXMOX_*` set.

### Setting flag values

```
export SECRETCON_USER_FLAG="event-<name>-cysvuln-user-<random>"
export SECRETCON_ROOT_FLAG="event-<name>-cysvuln-root-<random>"
```

Defaults are committed to the bootstrap and will fire if unset, but
override per event so flag strings do not carry between runs.

## Proxmox-native build

```
cd infrastructure/packer/cysvuln
packer init .
packer build -only=proxmox-iso.win2016-cysvuln .
```

Required environment:

```
PROXMOX_URL=https://192.168.60.1:8006/api2/json
PROXMOX_USERNAME=root@pam
PROXMOX_PASSWORD=<password>
```

What this does:

- Creates VMID `118` on node `manage` (NOT 108 — Cy's original lives
  there; the replica must not collide). 2 GB RAM, 32 GB disk, 1 socket
  / 1 core, e1000 on `vmbr0`, machine `pc-i440fx-10.1`, ostype `win10`
  — matches `qm config 108` from the 2026-05-19 recon.
- Mounts the Server 2016 ISO and a generated PROVISION ISO carrying
  `autounattend.xml`, the OpenSSH bundle, and the EFS installer.
- Boots Windows, waits for guest SSH, runs
  `provisioning/powershell/bootstrap_cysvuln.ps1`.

The bootstrap performs, in order:

1. SHA-256-validates the EFS installer; aborts on mismatch.
2. Creates local user `User_Joe` with the documented password
   `VeryStrongPassword123!@#` (preserves Cy's plaintext-creds side door
   — flag for Cy's confirmation at the working session).
3. Silent-installs EFS via Inno Setup flags
   (`/VERYSILENT /SUPPRESSMSGBOXES /SP- /NORESTART`).
4. Downgrades `fswsService` from `LocalSystem` to `.\User_Joe` via
   `sc.exe config` + secedit `SeServiceLogonRight`. **This is
   load-bearing**: if the service runs as SYSTEM, EDB-42256 collapses
   Flag 1 and Flag 2 into one step and the chain is broken.
5. Opens TCP/80, TCP/443, and ICMPv4 echo on the Windows Firewall.
6. Sets HKLM `AlwaysInstallElevated=1` and pre-seeds HKCU in User_Joe's
   `NTUSER.DAT` via direct hive load (no logon scheduled tasks).
7. Direct-seeds Joe's desktop: `user.txt`, `Notes.txt`, and the EFS
   installer for reproducibility.
8. Writes `C:\Users\Administrator\Desktop\root.txt`.
9. Installs Sysmon (SwiftOnSecurity config) and the Wazuh agent
   against `WAZUH_MANAGER=192.168.61.10` in group `ews`.

Post-build the recipe prints a validation block: services, accounts,
service identity. Inspect before shipping.

## Verification

### Tier 1 — post-build smoke (`scripts/verify-cysvuln.sh`)

Automated checks from an attacker vantage (WinRM):

- TCP WinRM port open (use `WINRM_PORT=15985` for local QEMU)
- HKLM/HKCU `AlwaysInstallElevated = 1`
- UAC keys `ConsentPromptBehaviorAdmin = 0`, `PromptOnSecureDesktop = 0`
- `User_Joe` present
- User and root flag files at documented paths
- Optional: Wazuh agent active when `WAZUH_API_PASSWORD` is set (skipped if unset)

```
./scripts/verify-cysvuln.sh <target-ip>
```

This script does not send EDB exploits or run the MSI privesc chain.

### Tier 2 — exploit chain

Manual or scripted chain validation:

- [docs/cysvulnserver/attack-faq-walkthrough.md](../cysvulnserver/walkthrough.md)
- `scripts/validate/check_efs69_response.py` (EFS HTTP)
- `scripts/validate-cysvuln-chain.sh` (full chain, needs a running VM)
- Reference PoCs: `scripts/validate/reference/`

Prerequisites for Tier 2: Tier 1 green, plus `./scripts/fetch-cysvuln-artifacts.sh`.

## Telemetry

Wazuh manager picks up the agent in group `ews`. The detections that
should fire on a player run:

- FIM rule 594 if either `AlwaysInstallElevated` value is touched after
  baseline. Custom rule 100594 (see
  [[wazuh-fim-installer-policy-detection]]) escalates to level 12.
- Sysmon EID 1 with parent `msiexec.exe` and child `cmd.exe` /
  `powershell.exe` — the MSI privesc signature
  ([[msi-privesc-msiexec-quiet-install]]).

## Open items for Cy

The recon-derived spec ships with assumptions that need confirmation
before this replica replaces VM 108:

- Service-account intent. The replica downgrades `fswsService` to
  `User_Joe`. If Cy intended `LocalSystem`, revert with
  `sc.exe config fswsService obj= LocalSystem` and drop the
  `SeServiceLogonRight` step.
- Plaintext creds on `User_Joe`'s desktop are an explicit side door.
  Intentional?
- Flag string format. Bootstrap writes raw strings; if Cy prefers
  `flag{...}` wrappers, override `SECRETCON_USER_FLAG` /
  `SECRETCON_ROOT_FLAG`.

## Related

- `infrastructure/packer/cysvuln/proxmox-vm-cysvuln.pkr.hcl` — the recipe.
- `provisioning/powershell/bootstrap_cysvuln.ps1` — the bootstrap.
- `infrastructure/artifacts/cysvuln/` — pinned installer + seed files.
- `docs/runbooks/deploy-windowsvm.md` — sibling EWS runbook.
- Vault recon walkthrough:
  `/home/warby/Vault/2026-05-19-secretcon-cysvuln-recon.md`.

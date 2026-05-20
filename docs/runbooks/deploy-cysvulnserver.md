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

- Windows Server 2016 evaluation ISO staged at
  `local:iso/windows-server-2016.iso` on the Proxmox node.
- EFS Software installer pinned in
  `infrastructure/artifacts/cysvuln/60f3ff1f3cd34dec80fba130ea481f31-efssetup.exe`
  (SHA-256
  `60ea3256cd272797675e2ec6ea8e02d8ad51209f1cbf9083bc909284b5331d79`,
  3,877,866 bytes). The bootstrap aborts on hash mismatch.
- `nix develop` shell. Packer with the `proxmox` plugin.

### Setting flag values

```
export SECRETCON_USER_FLAG="event-<name>-cysvuln-user-<random>"
export SECRETCON_ROOT_FLAG="event-<name>-cysvuln-root-<random>"
```

Defaults are committed to the bootstrap and will fire if unset, but
override per event so flag strings do not carry between runs.

## Proxmox-native build

```
packer init  infrastructure/packer/proxmox-vm-cysvuln.pkr.hcl
packer build infrastructure/packer/proxmox-vm-cysvuln.pkr.hcl
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
6. Sets HKLM `AlwaysInstallElevated=1`. Registers a logon-trigger
   scheduled task `CysVulnSeedJoeHKCU` that sets the matching HKCU
   value the first time `User_Joe` logs in (the HKCU hive only exists
   under that user's context).
7. Registers `CysVulnUserFlag`, `CysVulnSeedJoeNotes`,
   `CysVulnSeedJoeInstaller` logon tasks to drop flag and the
   reproducibility artifacts on first login.
8. Writes `C:\Users\Administrator\Desktop\root.txt`.
9. Installs Sysmon (SwiftOnSecurity config) and the Wazuh agent
   against `WAZUH_MANAGER=192.168.61.10` in group `ews`.

Post-build the recipe prints a validation block: services, accounts,
service identity. Inspect before shipping.

## Verification

`scripts/verify-cysvuln.sh <target-ip>` (TODO) should confirm from an
attacker vantage:

- HTTP/80 reachable, banner `Server: Easy File Sharing Web Server v6.9`.
- WinRM/5985 reachable for the side-door login.
- `evil-winrm -i <ip> -u User_Joe -p 'VeryStrongPassword123!@#'` lands
  a shell.
- From that shell:
  `reg query HKLM\Software\Policies\Microsoft\Windows\Installer /v AlwaysInstallElevated`
  returns `1`, and likewise for HKCU.
- EDB-42256 PoC fires and returns a `User_Joe` shell (not SYSTEM).
- MSI payload via `msiexec /quiet /qn /i shell.msi` returns SYSTEM.
- Both flag files exist at their documented paths.

Until that script lands, run those checks by hand per
[[cysvulnserver-foothold]] and [[cysvulnserver-system-flag-chain]].

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

- `infrastructure/packer/proxmox-vm-cysvuln.pkr.hcl` — the recipe.
- `provisioning/powershell/bootstrap_cysvuln.ps1` — the bootstrap.
- `infrastructure/artifacts/cysvuln/` — pinned installer + seed files.
- `docs/runbooks/deploy-windowsvm.md` — sibling EWS runbook.
- Vault recon walkthrough:
  `/home/warby/Vault/2026-05-19-secretcon-cysvuln-recon.md`.

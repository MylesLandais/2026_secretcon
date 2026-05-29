---
name: windows-bootstrap
description: PowerShell Packer bootstrap scripts for SecretCon Windows challenge VMs
---

# Windows bootstrap

## When this skill applies

Reach for this skill when editing or debugging:

- Packer `powershell` provisioners that run after guest SSH is up.
- PROVISION ISO contents (OpenSSH bundle, Sysmon config, challenge artifacts, flags).
- Intentional misconfigurations baked into challenge images (VNC defaults, AIE, unquoted paths).

If you are only changing Packer builder blocks (QEMU vs Proxmox vs Hyper-V), see `packer/SKILL.md` first.

## Conventions in this repo

- Entry scripts under `provisioning/powershell/`:
  - `bootstrap_win.ps1` — Win10 LTSC EWS (VNC foothold + unquoted service path).
  - `bootstrap_cysvuln.ps1` — Server 2016 CysVuln (EFS 6.9 + AlwaysInstallElevated chain).
  - `bootstrap_dc.ps1` — AD DC primary/replica (staged dcpromo via scheduled task).
- Shared module: `provisioning/powershell/lib/SecretCon.Bootstrap.psm1`
  - Loaded from the PROVISION CD (`SecretCon.Bootstrap.psm1` on the ISO root) or from `lib/` beside the bootstrap during dev.
  - `Find-ProvisionFile`, `Install-SecretConSysmon`, `Install-SecretConWazuhAgent`, `Register-SecretConLogonSeederTask`, `Get-SecretConEnvDefault`.
- PROVISION files are discovered by scanning mounted drives (`Get-PSDrive -PSProvider FileSystem`), not by hard-coded `D:\` letters.
- Sysmon uses SwiftOnSecurity config staged as `sysmonconfig.xml` with SHA-256 pin `055febc600e6d7448cdf3812307275912927a62b1f94d0d933b64b294bc87162`.
- Wazuh agent version defaults to `4.14.5`, group varies (`ews`, `dc-primary`, `dc-replica`). Build fails if `ossec.log` does not show `Connected to the server` within 60s unless `WAZUH_ENROLLMENT_OPTIONAL=1` (local QEMU CysVuln path).
- Manifest-driven ISO lists:
  - CysVuln: `infrastructure/packer/cysvuln/provision-manifest-*.txt`
  - EWS QEMU/Hyper-V: `infrastructure/packer/ews/provision-manifest-qemu.txt`
  - EWS Proxmox: `infrastructure/packer/ews/provision-manifest-proxmox.txt`

## Load-bearing misconfigs (do not "fix")

### CysVulnServer

- `fswsService` must run as `User_Joe`, not `LocalSystem`, or the two-flag chain collapses.
- HKLM `AlwaysInstallElevated=1` plus HKCU in Joe's hive (NTUSER.DAT pre-seed or interactive session).
- `ConsentPromptBehaviorAdmin=0` and `PromptOnSecureDesktop=0` — AIE alone is insufficient on Server 2016.
- `C:\Windows\SysWOW64\swsfe.dll` needs Modify for `User_Joe` or the service dies on start.
- Defender neutered and SRP key removed so `msiexec` and exploit payloads work in the lab.

### EWS

- TightVNC password `FELDTECH_VNC` (SecLists default) is the foothold.
- `SecretConEwsSync` service ImagePath is unquoted with a space; `BUILTIN\Users` has Modify on `C:\Program Files\SecretCon`.

## Canonical examples

- [provisioning/powershell/bootstrap_cysvuln.ps1](provisioning/powershell/bootstrap_cysvuln.ps1)
- [provisioning/powershell/bootstrap_win.ps1](provisioning/powershell/bootstrap_win.ps1)
- [provisioning/powershell/bootstrap_dc.ps1](provisioning/powershell/bootstrap_dc.ps1)
- [docs/cysvulnserver/attack-faq-walkthrough.md](docs/cysvulnserver/attack-faq-walkthrough.md)

## Common pitfalls

- Scheduled-task `msiexec` for AIE validation returns 1601 (non-interactive logon). Players and validators must use an interactive `User_Joe` shell (EFS callback or RDP).
- Hyper-V CysVuln builds cannot use Packer `cd_files`; run `scripts/build-provision-iso.ps1` and pass `cysvuln_provision_iso`.
- Changing Wazuh manager IP in only one bootstrap while the SIEM VM moved — grep `WAZUH_MANAGER` across recipes and runbooks.
- Placeholder flags ship if `SECRETCON_USER_FLAG` / `SECRETCON_ROOT_FLAG` are unset. Override per event.

## References

- See also `packer/SKILL.md`, `wazuh/SKILL.md`, `validate-aie/SKILL.md`, `hyperv/SKILL.md`.
- Player-facing chain: [docs/cysvulnserver/readme.md](docs/cysvulnserver/readme.md)

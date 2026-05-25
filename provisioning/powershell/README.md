# PowerShell bootstraps

Run during Packer `powershell` provisioners after guest SSH is available.

## Scripts

| File | Target | Key env vars |
|------|--------|----------------|
| bootstrap_win.ps1 | Win10 LTSC EWS | `WAZUH_MANAGER`, `SECRETCON_USER_FLAG`, `SECRETCON_ROOT_FLAG`, `SECRETCON_KASM_DESKTOP` |
| bootstrap_cysvuln.ps1 | Server 2016 CysVuln | `WAZUH_MANAGER`, `WAZUH_ENROLLMENT_OPTIONAL`, `SECRETCON_*_FLAG`, `CYSVULN_JOE_PASSWORD`, `CYSVULN_INSTALLER_HASH` |
| bootstrap_dc.ps1 | AD DC primary/replica | `DC_ROLE`, `AD_DOMAIN`, `AD_SAFEMODE_PASSWORD`, `AD_ADMIN_PASSWORD`, `REPLICA_SOURCE_DC`, `WAZUH_*` |

## Shared module

`lib/SecretCon.Bootstrap.psm1` is copied to the PROVISION ISO root as `SecretCon.Bootstrap.psm1`. Functions:

- `Find-ProvisionFile` — locate a file on mounted PROVISION media
- `Install-SecretConSysmon` / `Install-SecretConWazuhAgent`
- `Register-SecretConLogonSeederTask`
- `Get-SecretConEnvDefault`

Listed in `infrastructure/packer/cysvuln/provision-manifest-shared.txt` and EWS Proxmox manifest.

## Assets

`assets/sysmonconfig.xml` — SwiftOnSecurity Sysmon config, SHA-pinned at install time.

Agent skill: `.claude/skills/windows-bootstrap/SKILL.md`

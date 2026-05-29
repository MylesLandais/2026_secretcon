Generated: 2026-05-27T13:45:42Z

# Ansible migration coverage

COVERED: 0 | PARTIAL: 14 | MISSING: 0

| Concern | Role | Status | PS source |
|---------|------|--------|-----------|
| Install-SecretConSysmon | sysmon | PARTIAL | SecretCon.Bootstrap.psm1 |
| Install-SecretConWazuhAgent | wazuh_agent | PARTIAL | SecretCon.Bootstrap.psm1 |
| Register-SecretConLogonSeederTask | windows_startup_task | PARTIAL | SecretCon.Bootstrap.psm1 |
| TightVNC MSI + runtime registry | tightvnc | PARTIAL | bootstrap_win.ps1 |
| Wazuh tvnserver tailer + SACL | tightvnc | PARTIAL | bootstrap_win.ps1 |
| Unquoted service path LPE | ews_lpe_service | PARTIAL | bootstrap_win.ps1 |
| Flag staging user/root | flags | PARTIAL | bootstrap_win.ps1 |
| Defender relax scheduled task | defender_relax | PARTIAL | bootstrap_win.ps1 |
| Autologon | autologon | PARTIAL | bootstrap_win.ps1 |
| CysVuln EFS + AIE levers | cysvuln_efs_installer | PARTIAL | bootstrap_cysvuln.ps1 |
| CysVuln AIE registry | cysvuln_aie_levers | PARTIAL | bootstrap_cysvuln.ps1 |
| AS-REP promote + enite | asrep_promote | PARTIAL | bootstrap_asrep.ps1 |
| AS-REP users and flags | asrep_users_and_flags | PARTIAL | bootstrap_asrep.ps1 |
| DC promote | dc_promote | PARTIAL | bootstrap_dc.ps1 |

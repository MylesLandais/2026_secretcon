# Ansible parity matrix

Step-level mapping from PowerShell bootstrap sources to Ansible roles. When a row reaches **COVERED**, delete the cited PowerShell block in the same PR.

**Status legend:** `COVERED` | `PARTIAL` | `MISSING` | `PACKER_ONLY` | `EXTERNAL`

Machine-readable rollup: `python3 .claude/skills/repo-audit/audit.py ansible-migration-coverage`

See also: [ansible-opentofu-migration.md](ansible-opentofu-migration.md) | [opentofu-proxmox-scope.md](opentofu-proxmox-scope.md)

## Matrix maintenance

1. One PS block deleted per row when flipped to **COVERED**.
2. Re-run `audit.py ansible-migration-coverage` after cutover.
3. Role READMEs under `ansible/roles/*/README.md` list `step_id`s for that role.

---

## Shared — `provisioning/powershell/lib/SecretCon.Bootstrap.psm1`

| step_id | ps_source | description | ansible_role | status | cutover |
|---------|-----------|-------------|--------------|--------|---------|
| psm-001 | `SecretCon.Bootstrap.psm1:4-12` | `Get-SecretConEnvDefault` env fallback | `group_vars` / `host_vars` | MISSING | N/A (vars only) |
| psm-002 | `SecretCon.Bootstrap.psm1:14-23` | `Find-ProvisionFile` PROVISION ISO scan | per-role `win_copy` | MISSING | Document ISO contract in role READMEs |
| psm-003 | `SecretCon.Bootstrap.psm1:25-49` | `Install-SecretConSysmon` download, SHA pin, install | `sysmon` | PARTIAL | Delete function; keep Packer handoff until step 4 |
| psm-004 | `SecretCon.Bootstrap.psm1:51-101` | `Install-SecretConWazuhAgent` MSI, remote_commands, enroll | `wazuh_agent` | COVERED | EWS uses Ansible; function remains for other boxes until step 5 |
| psm-005 | `SecretCon.Bootstrap.psm1:103-120` | `Register-SecretConLogonSeederTask` | `windows_startup_task` | COVERED | EWS uses Ansible role |

---

## EWS — `provisioning/powershell/bootstrap_win.ps1`

| step_id | ps_source | description | ansible_role | status | cutover |
|---------|-----------|-------------|--------------|--------|---------|
| ews-001 | `bootstrap_win.ps1:19-22` | `LongPathsEnabled` HKLM | PACKER_ONLY | PACKER_ONLY | Stays in thin Packer bootstrap (step 4) |
| ews-002 | `bootstrap_win.ps1` (removed) | `Install-SecretConSysmon` call | `sysmon` | COVERED | Removed from thin bootstrap |
| ews-003 | `bootstrap_win.ps1` (removed) | `Install-SecretConWazuhAgent` group `ews` | `wazuh_agent` | COVERED | Ansible role |
| ews-004 | `bootstrap_win.ps1` (removed) | Shared local Administrator password | `ews.yml` pre_task | COVERED | `secretcon_shared_local_admin_password` |
| ews-005 | `bootstrap_win.ps1` (removed) | `patrick` local user | `autologon` | COVERED | Ansible role |
| ews-006 | `bootstrap_win.ps1` (removed) | TightVNC MSI, firewall, service start | `tightvnc` / `install.yml` | COVERED | Ansible role |
| ews-007 | `bootstrap_win.ps1` (removed) | BlacklistThreshold / BlacklistTimeout | `tightvnc` / `service_config.yml` | COVERED | Ansible role |
| ews-008 | `bootstrap_win.ps1` (removed) | Stage `wazuh-tvnserver-tail.ps1` | `tightvnc` / `observability.yml` | COVERED | Ansible role |
| ews-009 | `bootstrap_win.ps1` (removed) | auditpol Registry + TightVNC SACL | `tightvnc` / `observability.yml` | COVERED | Ansible role |
| ews-010 | `bootstrap_win.ps1` (removed) | User flag logon scheduled task | `flags` | COVERED | Ansible role |
| ews-011 | `bootstrap_win.ps1` (removed) | `SecretConEwsSync` unquoted path LPE | `ews_lpe_service` | COVERED | Ansible role |
| ews-012 | `bootstrap_win.ps1` (removed) | Administrator `root.txt` | `flags` | COVERED | Ansible role |
| ews-013 | `bootstrap_win.ps1` (removed) | Defender exclusions + disable RTP | `defender_relax` | COVERED | Ansible role |
| ews-014 | `bootstrap_win.ps1` (removed) | `SecretConDefenderRelax` startup task | `defender_relax` + `windows_startup_task` | COVERED | Ansible role |
| ews-015 | `bootstrap_win.ps1` (removed) | Winlogon AutoAdminLogon for patrick | `autologon` | COVERED | Ansible role |
| ews-016 | `bootstrap_win.ps1:281-305` | Bootstrap validation (services, ACLs, flags) | EXTERNAL | EXTERNAL | `scripts/proxmox/probe-ews.sh` |

---

## CysVuln — `provisioning/powershell/bootstrap_cysvuln.ps1`

| step_id | ps_source | description | ansible_role | status | cutover |
|---------|-----------|-------------|--------------|--------|---------|
| cyv-001 | `bootstrap_cysvuln.ps1:31-34` | Long paths HKLM | PACKER_ONLY | PACKER_ONLY | Thin Packer bootstrap |
| cyv-002 | `bootstrap_cysvuln.ps1:36` | Sysmon install | `sysmon` | MISSING | Delete line |
| cyv-003 | `bootstrap_cysvuln.ps1:37-41` | Wazuh agent group `cysvuln` | `wazuh_agent` | MISSING | Delete lines |
| cyv-004 | `bootstrap_cysvuln.ps1:43-47` | Shared Administrator password | `group_vars` + pre_task | MISSING | Delete block |
| cyv-005 | `bootstrap_cysvuln.ps1:49-99` | `Set-SecretConHivePrompts` Default/Admin hives | `cysvuln_aie_levers` | MISSING | Delete function + calls |
| cyv-006 | `bootstrap_cysvuln.ps1:101-106` | Disable WU / UsoSvc / WaaSMedicSvc | `cysvuln_aie_levers` | MISSING | Delete block |
| cyv-007 | `bootstrap_cysvuln.ps1:108-114` | `User_Joe` local user | `cysvuln_aie_levers` | MISSING | Delete block |
| cyv-008 | `bootstrap_cysvuln.ps1:116-163` | Pre-seed User_Joe HKCU AIE + prompts | `cysvuln_aie_levers` | MISSING | Delete block |
| cyv-009 | `bootstrap_cysvuln.ps1:165-179` | EFS installer copy + SHA256 pin | `cysvuln_efs_installer` | MISSING | Delete block |
| cyv-010 | `bootstrap_cysvuln.ps1:181-189` | Inno silent EFS install | `cysvuln_efs_installer` | MISSING | Delete block |
| cyv-011 | `bootstrap_cysvuln.ps1:191-216` | `fswsService` as User_Joe + secedit logon right | `cysvuln_efs_installer` | MISSING | Delete block |
| cyv-012 | `bootstrap_cysvuln.ps1:218-227` | `swsfe.dll` counter ACL for Joe | `cysvuln_efs_installer` | MISSING | Delete block |
| cyv-013 | `bootstrap_cysvuln.ps1:229-236` | Deploy `option.ini` from PROVISION | `cysvuln_efs_installer` | MISSING | Delete block |
| cyv-014 | `bootstrap_cysvuln.ps1:238-270` | `Savelog=1` in option.ini | `cysvuln_efs_installer` | MISSING | Delete block |
| cyv-015 | `bootstrap_cysvuln.ps1:274-277` | `C:\vfolders` tree + ACLs | `cysvuln_efs_installer` | MISSING | Delete block |
| cyv-016 | `bootstrap_cysvuln.ps1:279-297` | Joe interactive/RDP secedit + RDP enable | `cysvuln_aie_levers` | MISSING | Delete block |
| cyv-017 | `bootstrap_cysvuln.ps1:299-306` | Start `fswsService` | `cysvuln_efs_installer` | MISSING | Delete block |
| cyv-018 | `bootstrap_cysvuln.ps1:308-319` | Firewall 80/443/3389 + ICMP | `cysvuln_efs_installer` | MISSING | Delete block |
| cyv-019 | `bootstrap_cysvuln.ps1:321-331` | HKLM AlwaysInstallElevated + installer policy | `cysvuln_aie_levers` | MISSING | Delete block |
| cyv-020 | `bootstrap_cysvuln.ps1:333-342` | UAC ConsentPromptBehaviorAdmin | `cysvuln_aie_levers` | MISSING | Delete block |
| cyv-021 | `bootstrap_cysvuln.ps1:344-353` | Administrator `root.txt` | `flags` | MISSING | Delete block |
| cyv-022 | `bootstrap_cysvuln.ps1:355-375` | Joe `Notes.txt` | `cysvuln_efs_installer` | MISSING | Delete block |
| cyv-023 | `bootstrap_cysvuln.ps1:377-379` | EFS installer on Joe desktop | `cysvuln_efs_installer` | MISSING | Delete block |
| cyv-024 | `bootstrap_cysvuln.ps1:381-405` | Stage `PsExec.exe` to Users\Public | `cysvuln_aie_levers` | MISSING | Delete block |
| cyv-025 | `bootstrap_cysvuln.ps1:407-418` | Disable Defender RTP + GPO key | `cysvuln_aie_levers` | MISSING | Delete block |
| cyv-026 | `bootstrap_cysvuln.ps1:420-430` | Remove Software Restriction Policies | `cysvuln_aie_levers` | MISSING | Delete block |
| cyv-027 | `bootstrap_cysvuln.ps1:432-438` | Stage AIE validation MSI | `cysvuln_aie_levers` | MISSING | Delete block |
| cyv-028 | `bootstrap_cysvuln.ps1:440-444` | Joe `user.txt` flag | `flags` | MISSING | Delete block |
| cyv-029 | `bootstrap_cysvuln.ps1:446-452` | Stage `validate-aie.ps1` | `cysvuln_aie_levers` | MISSING | Delete block |
| cyv-030 | `bootstrap_cysvuln.ps1:454-505` | Bootstrap validation | EXTERNAL | EXTERNAL | `scripts/validate/*` / deploy verify |

---

## AS-REP — `provisioning/powershell/bootstrap_asrep.ps1`

| step_id | ps_source | description | ansible_role | status | cutover |
|---------|-----------|-------------|--------------|--------|---------|
| asr-001 | `bootstrap_asrep.ps1:36` | Sysmon install | `sysmon` | MISSING | Delete line |
| asr-002 | `bootstrap_asrep.ps1:37-41` | Wazuh agent group `asrep` | `wazuh_agent` | MISSING | Delete lines |
| asr-003 | `bootstrap_asrep.ps1:43-44` | `AD-Domain-Services` Windows feature | `asrep_promote` | MISSING | Delete block |
| asr-004 | `bootstrap_asrep.ps1:46-53` | Stage `asrep-bootstrap-runtime.ps1` | `asrep_promote` | MISSING | Delete block |
| asr-005 | `bootstrap_asrep.ps1:55-64` | Machine-scoped AD/flag env vars | `group_vars` / `asrep_promote` | MISSING | Delete block |
| asr-006 | `bootstrap_asrep.ps1:66-71` | `SecretConAsrepBootstrap` startup task | `windows_startup_task` | MISSING | Delete block |

---

## AS-REP runtime — `provisioning/asrep/asrep-bootstrap-runtime.ps1`

| step_id | ps_source | description | ansible_role | status | cutover |
|---------|-----------|-------------|--------------|--------|---------|
| asr-010 | `asrep-bootstrap-runtime.ps1:80-104` | `Install-ADDSForest` / Packer reboot path | `asrep_promote` | MISSING | May stay PS through Packer reboot (bootstrap-phase) |
| asr-011 | `asrep-bootstrap-runtime.ps1:27-52` | Wait for AD readiness | `asrep_promote` | MISSING | Delete or Ansible `until` |
| asr-012 | `asrep-bootstrap-runtime.ps1:108-111` | Weak domain password policy | `asrep_promote` | MISSING | Delete block |
| asr-013 | `asrep-bootstrap-runtime.ps1:113-114` | Kerberos auditpol | `asrep_promote` | MISSING | Delete block |
| asr-014 | `asrep-bootstrap-runtime.ps1:116-125` | RC4 enctype / SupportedEncryptionTypes | `asrep_promote` | MISSING | Delete block |
| asr-015 | `asrep-bootstrap-runtime.ps1:127-131` | Kerberos/LDAP firewall rules | `asrep_promote` | MISSING | Delete block |
| asr-016 | `asrep-bootstrap-runtime.ps1:133-135` | Set network profile Private | `asrep_promote` | MISSING | Delete block |
| asr-017 | `asrep-bootstrap-runtime.ps1:137-152` | `enite` user + AS-REP UF + RC4 | `asrep_users_and_flags` | MISSING | Delete block |
| asr-018 | `asrep-bootstrap-runtime.ps1:154-157` | `enite` Domain Admins (optional) | `asrep_users_and_flags` | MISSING | Delete block |
| asr-019 | `asrep-bootstrap-runtime.ps1:159-169` | Decoy AD users | `asrep_users_and_flags` | MISSING | Delete block |
| asr-020 | `asrep-bootstrap-runtime.ps1:171-184` | user.txt / root.txt / enite-flag.txt | `asrep_users_and_flags` | MISSING | Delete block |
| asr-021 | `asrep-bootstrap-runtime.ps1:186-187` | Seed marker file | `asrep_promote` | MISSING | Delete block |

---

## Helium DC — `provisioning/powershell/bootstrap_dc.ps1`

| step_id | ps_source | description | ansible_role | status | cutover |
|---------|-----------|-------------|--------------|--------|---------|
| dc-001 | `bootstrap_dc.ps1:38` | Sysmon install | `sysmon` | MISSING | Delete line |
| dc-002 | `bootstrap_dc.ps1:39-40` | Wazuh agent `dc-primary` / `dc-replica` | `wazuh_agent` | MISSING | Delete lines |
| dc-003 | `bootstrap_dc.ps1:42-43` | `AD-Domain-Services` feature | `dc_promote` | MISSING | Delete block |
| dc-004 | `bootstrap_dc.ps1:48-117` | Generated promote script (forest / replica) | `dc_promote` | MISSING | Delete block; may stay PS for reboot |
| dc-005 | `bootstrap_dc.ps1:119+` | `SecretConDcPromote` scheduled task | `windows_startup_task` | MISSING | Delete block |

---

## Summary by role

| Role | step_ids | Status |
|------|----------|--------|
| `sysmon` | psm-003, ews-002, cyv-002, asr-001, dc-001 | COVERED (EWS); PARTIAL (other boxes) |
| `tightvnc` | ews-006–009 | COVERED (EWS) |
| `wazuh_agent` | psm-004, ews-003, cyv-003, asr-002, dc-002 | COVERED (EWS) |
| `flags` | ews-010, ews-012, cyv-021, cyv-028, asr-020 | COVERED (EWS) |
| `ews_lpe_service` | ews-011 | COVERED |
| `defender_relax` | ews-013, ews-014 | COVERED (EWS) |
| `autologon` | ews-005, ews-015 | COVERED |
| `windows_startup_task` | psm-005, ews-014, asr-006, dc-005 | COVERED (EWS) |
| `cysvuln_efs_installer` | cyv-009–018, cyv-022–023 | MISSING |
| `cysvuln_aie_levers` | cyv-005–008, cyv-016, cyv-019–020, cyv-024–027, cyv-029 | MISSING |
| `asrep_promote` | asr-003–005, asr-010–016, asr-021 | MISSING |
| `asrep_users_and_flags` | asr-017–020 | MISSING |
| `dc_promote` | dc-003–004 | MISSING |

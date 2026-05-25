# deploy-dc

Stand up the `heliumsupply.local` AD forest as a two-DC pair on Proxmox.

- DC1 (primary): VMID 120, 192.168.61.20
- DC2 (replica): VMID 121, 192.168.61.21
- Domain: `heliumsupply.local` / NetBIOS `HELIUM`
- Forest/domain mode: WinThreshold (Server 2016 functional level)
- OS: Windows Server 2016 (using existing `local:iso/windows-server-2016.iso`; bump to 2022 later by swapping the ISO + `IMAGE/INDEX` in the per-DC autounattend)
- Network: built directly on `vmbr1` alongside the Wazuh manager — no bridge cutover

## Prerequisites

- Proxmox node reachable at `192.168.60.1` with `local:iso/windows-server-2016.iso` present
- `.env` populated:
  ```
  PROXMOX_URL=https://192.168.60.1:8006/api2/json
  PROXMOX_USERNAME=root@pam
  PROXMOX_PASSWORD=...
  AD_SAFEMODE_PASSWORD=...        # DSRM password, complexity req'd
  AD_ADMIN_PASSWORD=...           # Domain Admin pw, used by DC2 to join
  ```
- Wazuh SIEM live at `192.168.61.10` with manager API reachable
- Workstation can SSH to `192.168.61.20`/`.21` (route via Proxmox host / OPNsense)

## Deploy

```
./scripts/proxmox/deploy-dc.sh --dc1
# wait for "DC1 is live at 192.168.61.20"
./scripts/proxmox/deploy-dc.sh --dc2
```

What each invocation does:

1. Destroys any existing VM at the target ID.
2. Runs `packer build` against `infrastructure/packer/dc/proxmox-vm-dc.pkr.hcl` (`-only=proxmox-iso.dc-primary` or `dc-replica`). Packer installs Windows, runs `bootstrap_dc.ps1` which:
   - installs Sysmon (pinned config) + Wazuh agent (group `dc-primary` / `dc-replica`)
   - installs the `AD-Domain-Services` Windows feature
   - stages `C:\secretcon\promote-dc.ps1` and a SYSTEM scheduled task `SecretConDcPromote` triggered AtStartup, guarded by `C:\secretcon\promoted.marker`
3. Issues `qm reset` to fire the scheduled task.
4. Polls `<dc-ip>:389` for up to 30 min until LDAP responds.

The promotion auto-reboots once it completes; the marker file prevents the task from re-running on subsequent boots.

## Verify

```
# Wazuh agents (run on manager 192.168.61.10):
/var/ossec/bin/agent_control -ls | grep -iE 'dc1|dc2'

# Forest + DCs (from any reachable host):
dig @192.168.61.20 heliumsupply.local SOA
dig @192.168.61.20 _ldap._tcp.dc._msdcs.heliumsupply.local SRV

# From DC1 (SSH as Administrator after promo):
Get-ADDomainController -Filter * | Select Name,IPv4Address,Site
repadmin /replsummary
```

## Troubleshooting

- Promotion fails / scheduled task didn't fire: SSH into the DC, check `C:\secretcon\promote.log`. Re-run by deleting `C:\secretcon\promoted.marker` and rebooting.
- DC2 hangs on "Waiting for DC1 LDAP": confirm `192.168.61.20:389` is reachable from `192.168.61.21` (no OPNsense rule needed — same broadcast domain).
- Local `packer`/`Administrator` accounts work pre-promo; post-promo SSH should authenticate as `HELIUM\Administrator` with `AD_ADMIN_PASSWORD`. OpenSSH `administrators_authorized_keys` continues to honour the packer ed25519 key for Administrator.

## Out of scope

Challenge content (cached-credential flag on a member workstation, intentional DCSync ACL on DC2, BloodHound-targetable misconfigs) is a follow-up plan.

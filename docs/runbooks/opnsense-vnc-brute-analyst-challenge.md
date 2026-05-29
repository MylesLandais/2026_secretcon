# Runbook: OPNsense VNC brute-force analyst challenge

End-to-end procedure for the SecretCon EWS analyst-challenge variant
that adds a **live NSM track** on top of the existing
[`ews-vnc-adversary-emulation`](ews-vnc-adversary-emulation.md) flow.
After this runbook completes, participants have three independent
analyst paths into the same plaintext `FELDTECH_VNC`:

1. **PCAP track (Arkime).** OPNsense SPAN-mirrored capture in
   `crit-capture` Arkime. Analyst extracts the DES challenge/response
   of the successful auth and recovers plaintext offline with
   [`scripts/observability/vnc-cred-tool.py crack`](../../scripts/observability/vnc-cred-tool.py).
2. **SIEM track (Wazuh endpoint).** Planted exfil receipt on the EWS
   endpoint surfaces the password hex blob through rule `100806`.
   Recovered with `vnc-cred-tool.py decode`.
3. **NSM track (Wazuh + OPNsense, new).** Suricata SIDs `2400001`,
   `2400002`, and `2400003` on the OPNsense MIRROR interface bridge to
   Wazuh rules `100810`/`100811`/`100816`. Rule `100812` confirms
   probe+failure; rule `100813` confirms failed auths followed by a
   successful login. Fallback path is pf `filterlog` rule `100815`.
   *Detection only* -- VNC RFB is
   challenge-response so the wire never carries plaintext, but this
   track tells the analyst WHO and WHEN and feeds them into tracks
   A or B.

```mermaid
flowchart LR
    Kali["Kali .50"] -->|"hydra TCP/5900"| EWS["EWS .20"]
    vmbr1["vmbr1"] --- Kali
    vmbr1 --- EWS
    vmbr1 -->|"tc-mirror"| Opn["OPNsense vtnet2 MIRROR"]
    Opn -->|"Suricata EVE -> :1514"| Wazuh["wazuh.manager .10"]
    Opn -->|"pf filterlog -> :514"|  Wazuh
    Opn -->|"tcpdump pcap"|  Crit["crit-capture .11"]
    EWS -->|"Wazuh agent endpoint trail"| Wazuh
    Wazuh --> Dash["dashboard https"]
    Crit  --> Viewer["Arkime :8005"]
```

## 0. Pre-requisites

| Component | Where | Check |
| --- | --- | --- |
| Proxmox host reachable | `192.168.60.1` | `ssh root@192.168.60.1 qm status 100` |
| OPNsense VM live | `192.168.61.253` | `curl -k https://192.168.61.253/api/core/firmware/status -u $KEY:$SECRET` |
| OPNsense `os-suricata` plugin installed | OPNsense UI -> System -> Firmware -> Plugins | `pkg info | grep os-suricata` |
| `vmbr1` tc-mirror up | host-side | `ssh root@192.168.60.1 'tc -s filter show dev vmbr1 ingress'` |
| OPNsense MIRROR sees frames | `vtnet2` | `./scripts/proxmox/opnsense-export-pcap.sh --probe` |
| Wazuh manager reachable | `192.168.61.10:1514` | `nc -z 192.168.61.10 1514` |
| `crit-capture` Arkime up | `192.168.61.11:8005` | `curl -sI http://192.168.61.11:8005` |
| `.env` populated | repo root | `PROXMOX_PASSWORD`, `OPNSENSE_API_KEY/SECRET`, `OPNSENSE_SSH_PASSWORD`, `ADMIN_PW` |
| Wordlist staged | repo | `provisioning/wordlists/vnc-betterdefaultpasslist.txt` (40 entries, contains `FELDTECH_VNC`) |
| Tools | `nix develop` | `tshark`, `hydra`, `tcpdump`, `python3`, `jq`, `sshpass` |

## 1. Pre-change snapshot (idempotent safety net)

Run BEFORE any of the changes below. Disk-only snapshot of OPNsense
and Wazuh manager; recorded under `artifacts/opnsense-vnc/<run-id>/snapshots.json`
for the rollback script.

```bash
./scripts/proxmox/snapshot-before-mirror.sh
# Resolves OPNsense VMID via 'qm list | grep -i opnsense',
# snapshots VMID <opnsense> and VMID 110 (wazuh-siem),
# writes artifacts/opnsense-vnc/pre-vmbr1-mirror-<TS>/snapshots.json.
```

Rollback any time:

```bash
./scripts/proxmox/rollback-vmbr1-mirror.sh           # latest manifest
./scripts/proxmox/rollback-vmbr1-mirror.sh --run-id  pre-vmbr1-mirror-<TS>
```

## 2. Bring up the host-side mirror

```bash
./scripts/proxmox/enable-vmbr1-mirror.sh
# Auto-resolves OPNsense VMID. Creates dummy bridge 'vmbrmirror',
# attaches OPNsense net2 (reboots OPNsense once so vtnet2 surfaces),
# installs ingress+egress 'mirred egress mirror' filters on vmbr1,
# sets the tap MTU + promisc, and installs the systemd unit
# vmbr1-mirror.service so the filters re-apply on host boot.
```

Verify:

```bash
ssh root@192.168.60.1 'tc -s filter show dev vmbr1 ingress'
ssh root@192.168.60.1 'tc -s filter show dev vmbr1 root'
# Both should show 'matchall action mirred egress mirror dev tap<VMID>i2'
```

Tear down (host-side only; leaves OPNsense config alone):

```bash
./scripts/proxmox/disable-vmbr1-mirror.sh
```

## 3. Configure OPNsense (one-time GUI/API)

Follow [`provisioning/opnsense/setup-instructions.md`](../../provisioning/opnsense/setup-instructions.md):

1. Interfaces -> Assignments: assign `vtnet2` as `MIRROR`.
2. Firewall -> Rules -> MIRROR: block-all so it can never leak.
3. Services -> Intrusion Detection: enable Suricata on `MIRROR`,
   IDS-only, hyperscan, home networks `192.168.61.0/24`, custom
   rules path `/usr/local/etc/suricata/rules/secretcon.rules`.
4. System -> Settings -> Logging / Targets: add two TCP4 RFC5424
   syslog targets:
   - Suricata EVE -> `192.168.61.10:1514` facility `local1`.
   - filterlog ----> `192.168.61.10:514`  facility `local0`.
5. Firewall -> Settings -> Logging: enable "Log packets matched from
   default pass rules" so filterlog actually emits.
6. Interfaces -> Diagnostics -> Packet Capture: save a profile
   `vnc-brute-5900` (interface MIRROR, port 5900, snaplen 16384).

Then push the custom rules + reload Suricata:

```bash
./scripts/proxmox/opnsense-apply-config.sh
# Validates API auth, SCPs provisioning/opnsense/suricata/secretcon.rules
# to /usr/local/etc/suricata/rules/secretcon.rules, POSTs
# /api/ids/service/reload, and verifies "status":"running".
```

After this works once, snapshot the OPNsense config to tree:

```bash
./provisioning/opnsense/scripts/export-config.sh
# Pulls /conf/config.xml, sanitizes secrets, writes provisioning/opnsense/config.xml.
git diff provisioning/opnsense/config.xml   # review and commit if happy
```

## 4. Push Wazuh rules

Local edits to `infrastructure/wazuh-docker/config/wazuh_cluster/local_rules.xml`
(rules `100810/100811/100812/100813/100815/100816`) are already in tree. Push to the
production manager:

```bash
./scripts/proxmox/sync-wazuh-rules.sh
# scp local_rules.xml + ews/agent.conf to the manager, install with
# correct ownership, and restart wazuh-manager via wazuh-control.
```

Spot-check the parse landed cleanly:

```bash
ssh dadmin@192.168.61.10 \
    'sudo tail -200 /var/ossec/logs/ossec.log | grep -E "loaded|CRITICAL|local_rules"'
# expect: 'INFO: (1245): Rules file ... local_rules.xml loaded.'
# NO 'CRITICAL' lines.
```

Wazuh-logtest smoke test for rule 100810 (synthetic EVE alert):

```bash
ssh dadmin@192.168.61.10 \
    "sudo /var/ossec/bin/wazuh-logtest <<'EOF'
{\"timestamp\":\"$(date -u +%FT%T.000Z)\",\"event_type\":\"alert\",\"src_ip\":\"192.168.61.50\",\"dest_ip\":\"192.168.61.20\",\"dest_port\":5900,\"proto\":\"TCP\",\"alert\":{\"action\":\"allowed\",\"signature_id\":2400001,\"signature\":\"SECRETCON VNC RFB connection burst\",\"category\":\"attempted-recon\",\"severity\":2}}
EOF"
# expect: Rule id: '100810', level 10
```

## 5. Run the challenge

```bash
./scripts/observability/opnsense-vnc-challenge.sh \
    --target 192.168.61.20 \
    --vnc-port 5900 \
    --winrm-port 5985 \
    --duration 180 \
    --max-packets 50000
```

What it does, in order:

1. Preflight: tc-mirror frames, Wazuh `:1514` open, Arkime `:8005`
   open, EWS WinRM open, EWS VNC open.
2. Starts an OPNsense MIRROR packet capture in the background
   (`scripts/proxmox/opnsense-export-pcap.sh`, BPF `tcp port 5900`,
   duration-bounded).
3. Runs the existing live brute force (`vnc-adversary-emulation.sh`
   with `--skip-arkime --skip-export`; the orchestrator owns the
   Arkime push and the alerts pull instead of the per-script paths).
4. Waits for the capture, downloads the pcap, pushes to crit-capture
   Arkime tagged `opnsense-mirror` and `challenge:<run-id>`.
5. Pulls a manager-side `alerts.json` slice over the run window, then
   jq-filters to per-rule files (100810/100811/100812/100816/100813
   /100815/100804/100805/100806/100807).
6. Writes `artifacts/opnsense-vnc/<run-id>/INDEX.md` and
   `summary.json`.

Result artefacts:

```
artifacts/opnsense-vnc/<run-id>/
    INDEX.md                          # participant-facing
    summary.json                      # machine-readable
    orchestrator.log
    opnsense-mirror.pcap              # SPAN'd pcap
    capture.log                       # tcpdump-on-OPNsense output
    sync-arkime.log
    emulation.log                     # hydra + WinRM payload output
    emulation-summary.json
    alerts-during-window.json
    alerts-rule-10081X.json           # per-rule slices
```

## 6. Verify (acceptance test)

Run the validator. Pass = every assertion in `results.txt` is PASS.

```bash
./scripts/validate/validate-opnsense-vnc-pipeline.sh \
    --run-id <run-id>   # reuse the orchestrator's run-id
# or one-shot end-to-end:
./scripts/observability/opnsense-vnc-challenge.sh --validate
```

Assertions:

| # | What | Source | Pass criterion |
| --- | --- | --- | --- |
| 1 | OPNsense pcap captured the full BF | tshark on `opnsense-mirror.pcap` | `vnc.security_type==2` count `>= 40` |
| 2 | Exactly one successful auth in pcap | tshark | `vnc.security_result==0` count == 1 |
| 3 | At least 35 failed auths in pcap | tshark | `vnc.security_result==1` count `>= 35` |
| 4 | Successful pair decodes to `FELDTECH_VNC` | `vnc-cred-tool.py crack` | stdout == `FELDTECH_VNC` |
| 5 | Arkime indexed the session | `curl arkime opensearch _count` | `>= 1` |
| 6 | Wazuh `100810` fired (Suricata burst) | alerts.json slice | `>= 1` |
| 7 | Wazuh `100811` fired (failed-auth burst) | alerts.json slice | `>= 1` (typically `>= 35`) |
| 8 | Wazuh `100812` velocity correlator fired | alerts.json slice | exactly 1 per src |
| 9 | Wazuh `100816` success alert fired | alerts.json slice | `>= 1` |
| 10 | Wazuh `100813` fail-then-success correlator fired | alerts.json slice | exactly 1 per src |
| 11 | Wazuh `100815` pf filterlog fired | alerts.json slice | `>= 1` |
| 12 | Endpoint trail still fires | alerts.json slice | `100804`/`100805`/`100806`/`100807` each `>= 1` |

## 7. Participant decoding path

This is the analyst experience the challenge ships. Reproduce it
manually to sanity-check the deliverable.

### Track A (PCAP)

```bash
# Open the OPNsense pcap in Arkime
open "http://192.168.61.11:8005/sessions?expression=tags%3D%3D%22opnsense-mirror%22%20%26%26%20destination.port%3D%3D5900"

# Pull the successful auth (challenge, response) pair
tshark -r artifacts/opnsense-vnc/<run-id>/opnsense-mirror.pcap -Y 'vnc' \
    -T fields -e frame.number -e vnc.auth_challenge -e vnc.auth_response -e vnc.security_result \
    | awk -F'\t' '$4=="0"{print prev; exit} {prev=$0}'
# Last line prints the (challenge, response) pair of the success.

# Recover plaintext
python3 scripts/observability/vnc-cred-tool.py crack \
    --challenge <CHAL_HEX> --response <RESP_HEX> \
    --wordlist provisioning/wordlists/vnc-betterdefaultpasslist.txt
# -> FELDTECH_VNC
```

### Track B (SIEM endpoint)

```bash
ssh dadmin@192.168.61.10 \
    'sudo grep "\"id\":\"100806\"" /var/ossec/logs/alerts/alerts.json | tail -1' \
    | jq -r .full_log
# -> "VNC password blob (hex): XX-XX-XX-XX-XX-XX-XX-XX ..."

python3 scripts/observability/vnc-cred-tool.py decode \
    --hex <HEX> --wordlist provisioning/wordlists/vnc-betterdefaultpasslist.txt
# -> FELDTECH_VNC
```

### Track C (NSM, detection-only)

```bash
ssh dadmin@192.168.61.10 \
    'sudo grep "\"id\":\"100813\"" /var/ossec/logs/alerts/alerts.json | tail -1' \
    | jq '{ts: .timestamp, src: .data.src_ip, dst: .data.dest_ip}'
# -> shows the src IP whose failed auths were followed by a successful login.
# Pivot to track A or B for plaintext.
```

## 8. Troubleshoot (failure mode table)

| Symptom | Likely root cause | Fix |
| --- | --- | --- |
| 0 RFB attempts in pcap | tc mirror not active OR tap is down | `tc -s filter show dev vmbr1 ingress` + `ip link show tap<VMID>i2` |
| `<40` attempts but `>0` | Hydra rate-limited by TightVNC `BlacklistThreshold` or parallel tasks | Run `./scripts/proxmox/converge-ews.sh`; use `hydra -t 1`; role default `BlacklistThreshold=100`, `ews-prod` uses `10000`. Note: the registry threshold only defeats the per-IP blacklist; the separate in-memory pace limiter needs slower attempts (`BRUTEFORCE_SPEED 0` / `--delay-seconds`) — see [registry blacklist vs in-memory pace limiter](ews-vnc-adversary-emulation.md#two-distinct-rate-limiters-registry-blacklist-vs-in-memory-pace-limiter) |
| Attempts present, no success row | Wordlist missing `FELDTECH_VNC` | `grep -c FELDTECH_VNC provisioning/wordlists/vnc-betterdefaultpasslist.txt` |
| Success present but decode fails | `vnc-cred-tool.py` bug or wrong wordlist | `python3 scripts/observability/vnc-cred-tool.py self-test` |
| PCAP green but no Wazuh `100810` | OPNsense Suricata down OR EVE syslog blocked | `ssh root@192.168.61.253 'service suricata status'`; `ssh dadmin@.10 'sudo tcpdump -ni any port 1514'` |
| `100810` fires, `100811` doesn't | Failed-auth SID 2400002 didn't match | Mirror is one-way; verify BOTH ingress qdisc AND egress prio root from Section 2 |
| `100812` velocity doesn't fire | Window / `same_source_ip` mismatch | `wazuh-logtest` replay 100810 and 100811 events under the same `src_ip` |
| `100813` fail-then-success doesn't fire | Success SID 2400003 missing or source mismatch | Confirm the pcap has one `vnc.security_result==0`, then replay 100811 and 100816 events under the same `src_ip` |
| `100815` pf doesn't fire | filterlog not shipped, or pf not logging passes on MIRROR | OPNsense -> Firewall -> Settings -> Logging "Log packets matched from default pass rules" |

## 9. Regenerate (or wipe and rebuild)

Rerun the orchestrator any time -- it stamps a new `run-id` per call
so old datasets stay intact under `artifacts/opnsense-vnc/`.

To start over from a clean OPNsense + Wazuh:

```bash
./scripts/proxmox/rollback-vmbr1-mirror.sh             # disk-rollback both VMs + tear down host mirror
./scripts/proxmox/snapshot-before-mirror.sh            # fresh snapshot at the clean baseline
./scripts/proxmox/enable-vmbr1-mirror.sh
# (Reapply OPNsense GUI steps if not restored from config.xml.)
./scripts/proxmox/opnsense-apply-config.sh
./scripts/proxmox/sync-wazuh-rules.sh
./scripts/observability/opnsense-vnc-challenge.sh --validate
```

## References

- Pre-existing endpoint flow: [`docs/runbooks/ews-vnc-adversary-emulation.md`](ews-vnc-adversary-emulation.md)
- Architecture: [`docs/architecture.md`](../architecture.md) capture pipeline section
- OPNsense skill: [`.claude/skills/opnsense/SKILL.md`](../../.claude/skills/opnsense/SKILL.md)
- OPNsense discovery baseline: [`docs/notes/opnsense-discovery-2026-05-14.md`](../notes/opnsense-discovery-2026-05-14.md)
- Wazuh skill: [`.claude/skills/wazuh/SKILL.md`](../../.claude/skills/wazuh/SKILL.md)
- Cred tool: [`scripts/observability/vnc-cred-tool.py`](../../scripts/observability/vnc-cred-tool.py)

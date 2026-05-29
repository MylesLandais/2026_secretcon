# EWS — VNC PCAP analysis with Wireshark

Operator guide for the TightVNC brute-force captures produced by
[`scripts/observability/vnc-public-attack.sh`](../../scripts/observability/vnc-public-attack.sh)
and the player-facing bundle under
[`targets/ews-vnc-pcap-forensics/`](../../targets/ews-vnc-pcap-forensics/README.md).

## Which file to open

| PCAP | When to use |
|------|-------------|
| [`targets/ews-vnc-pcap-forensics/vnc_auth.pcap`](../../targets/ews-vnc-pcap-forensics/vnc_auth.pcap) | Canonical lab capture (~69 KB, 41 auth attempts, one success). Best for walkthroughs. |
| `artifacts/ews/vnc-foothold/<run-id>/vnc_auth.pcap` | Trimmed capture from your last `vnc-adversary-emulation.sh` / `vnc-public-attack.sh` run. |
| `artifacts/ews/vnc-foothold/<run-id>/vnc-attack-raw.pcap` | Full `tcpdump` before `tshark` trim (extra TCP noise). |
| `artifacts/opnsense-vnc/<run-id>/opnsense-mirror.pcap` | SPAN/mirror path (NSM analyst track; same RFB auth, plus Suricata context). |
| [`infrastructure/arkime-docker/pcaps/vnc_auth.pcap`](../../infrastructure/arkime-docker/pcaps/vnc_auth.pcap) | Copy staged for local Arkime import (may be a short synthetic proof). |

Open from the repo root:

```bash
nix develop
wireshark targets/ews-vnc-pcap-forensics/vnc_auth.pcap
# or, if wireshark is not in the dev shell:
nix shell nixpkgs#wireshark --command wireshark targets/ews-vnc-pcap-forensics/vnc_auth.pcap
```

Helper script:

```bash
./scripts/open-ews-vnc-pcap.sh                    # canonical bundle
./scripts/open-ews-vnc-pcap.sh artifacts/ews/vnc-foothold/<run-id>/vnc_auth.pcap
```

## What you should see (canonical PCAP)

Rough statistics from `tshark -q -z io,phs`:

- **873** frames, all **TCP/5900** (VNC).
- **453** frames decoded as **VNC/RFB** (remainder are TCP setup/teardown around auth).
- **41** distinct authentication exchanges (hydra wordlist size).
- Attacker → victim in the reference capture: `192.168.2.12` → `192.168.60.109:5900`
  (your live run may show Kali on `192.168.61.50` → EWS `192.168.61.20`).

Expected outcome: **one** TCP stream where the server accepts credentials
(`SecurityResult` success); the password cracks to **`FELDTECH_VNC`**
with the in-tree wordlist.

## Wireshark workflow

### 1. Baseline filters

Apply these display filters in the filter bar (not capture filters):

| Filter | Purpose |
|--------|---------|
| `tcp.port == 5900` | All VNC traffic |
| `vnc` | RFB messages only |
| `vnc.auth_challenge` | Server 16-byte challenges |
| `vnc.auth_response` | Client 16-byte DES responses |
| `vnc.auth_result` | Server pass/fail (see caveat below) |

**Statistics → Conversations → TCP** — sort by packets; you should see dozens
of short-lived streams (one per hydra attempt) plus one that proceeds past auth.

### 2. Find the successful login

**Caveat (TightVNC):** `vnc.auth_result == 0` alone matches **41** frames, not one.
On failed auths, TightVNC sends extra bytes after the result byte; Wireshark may
decode garbage as additional `auth_result` lines. Use **per-stream** logic.

**GUI method**

1. Filter: `vnc.auth_result`
2. Add column: **tcp.stream** (right-click column header → Customize → tcp.stream).
3. For each stream, look at the **first** `Authentication result` line in that stream.
4. The winning stream shows **OK** / `0` on the first result only — in the reference
   PCAP this is **tcp.stream == 1** (second wordlist entry).

**CLI equivalent** (matches instructor solution):

```bash
tshark -r targets/ews-vnc-pcap-forensics/vnc_auth.pcap -Y 'vnc.auth_result' \
  -T fields -e tcp.stream -e vnc.auth_result \
| awk -F'\t' '!seen[$1]++ { if ($2 == "False" || $2 == "0") print "stream", $1 }'
```

### 3. Follow the winning TCP stream

1. Pick a packet in the successful stream (e.g. filter `tcp.stream == 1`).
2. Right-click → **Follow → TCP Stream**.
3. You should see the RFB dance:
   - `RFB 003.008` version banner
   - Security types → client selects **VNC Authentication (type 2)**
   - **16-byte challenge** (server → client)
   - **16-byte response** (client → server)
   - **SecurityResult** `0` (OK) on success; failed attempts show `1` and often RST.

### 4. Extract challenge and response

With stream **1** selected:

```bash
tshark -r targets/ews-vnc-pcap-forensics/vnc_auth.pcap \
  -Y 'tcp.stream == 1 and (vnc.auth_challenge or vnc.auth_response)' \
  -T fields -e vnc.auth_challenge -e vnc.auth_response
```

Example output (your bytes will differ per capture):

```
ccd03faca6a6cd118ee85bb013788db3
8361102fb04a6fddae7676935c46665c
```

In Wireshark: click the challenge packet → expand **VNC** → note
**Challenge** and **Response** hex in the packet details pane.

### 5. Recover the password offline

Password is **not** plaintext on the wire — only DES-encrypted challenge/response.
Use the bundled wordlist and repo tool:

```bash
nix develop --command python3 scripts/observability/vnc-cred-tool.py crack \
  --challenge <CHAL_HEX> \
  --response  <RESP_HEX> \
  --wordlist  targets/ews-vnc-pcap-forensics/wordlist.txt
# -> FELDTECH_VNC
```

Player flag format: `flag{FELDTECH_VNC}`.

Decode-only check (registry blob from endpoint forensics, rule `100806`):

```bash
python3 scripts/observability/vnc-cred-tool.py decode \
  --hex 52-E6-65-4C-7A-A1-88-5F \
  --wordlist provisioning/wordlists/vnc-betterdefaultpasslist.txt
```

### 6. Count brute-force volume (defender metrics)

Validators expect ~**40+** failed auths and **1** success:

```bash
tshark -r targets/ews-vnc-pcap-forensics/vnc_auth.pcap -Y 'vnc.security_type==2' 2>/dev/null | wc -l
tshark -r targets/ews-vnc-pcap-forensics/vnc_auth.pcap \
  -Y 'vnc.auth_result' -T fields -e tcp.stream -e vnc.auth_result \
| awk -F'\t' '!seen[$1]++' | awk -F'\t' '$2==1 || $2=="True"' | wc -l   # failed (first result per stream)
```

For OPNsense mirror captures, use the same filters on
`artifacts/opnsense-vnc/<run-id>/opnsense-mirror.pcap` and cross-check
Wazuh rules `100810`–`100815` per
[`docs/runbooks/opnsense-vnc-brute-analyst-challenge.md`](../runbooks/opnsense-vnc-brute-analyst-challenge.md).

## Arkime (optional)

If the capture was synced to crit-capture:

```text
http://192.168.61.11:8005
expression: tags == "ews-vnc-foothold" && destination.port == 5900
```

Import locally:

```bash
./scripts/arkime-import-pcap.sh targets/ews-vnc-pcap-forensics/vnc_auth.pcap
```

## Related docs

- [defend-faq-walkthrough.md](defend-faq-walkthrough.md) — Wazuh rules and reproduction scripts
- [ews-vnc-adversary-emulation.md](../runbooks/ews-vnc-adversary-emulation.md) — how the PCAP is generated
- [targets/ews-vnc-pcap-forensics/README.md](../../targets/ews-vnc-pcap-forensics/README.md) — player challenge brief
- [targets/ews-vnc-pcap-forensics/solution.md](../../targets/ews-vnc-pcap-forensics/solution.md) — instructor solution (do not ship to players)

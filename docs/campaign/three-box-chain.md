# Three-box campaign runbook

Operator guide for the integrated red/blue chain:

**CysVulnServer** (workgroup) → **EWS** (workgroup, shared local admin) → **secretcon.local DC** (AS-REP → DA flags).

## Topology (Proxmox vmbr1)

| VM | VMID | IP | Agent group |
|---|---|---|---|
| Wazuh SIEM | 110 | 192.168.61.10 | manager |
| EWS | 109 | 192.168.61.20 | ews |
| CysVulnServer | 119 | 192.168.61.51 | cysvuln |
| ASREP DC | 112 | 192.168.61.52 | asrep |

Gateway: `192.168.61.1`. Challenge VMs use DNS `192.168.61.52,192.168.61.10` (DC + Wazuh).

## Required environment

Copy [example.env](../../example.env) and set at minimum:

```bash
PROXMOX_PASSWORD=...
WAZUH_API_PASSWORD=...
SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD=PizzaMan123!
SECRETCON_USER_FLAG=...
SECRETCON_ROOT_FLAG=...
SECRETCON_DC_USER_FLAG=...
SECRETCON_DC_ROOT_FLAG=...
SECRETCON_ASREP_ENITE_DA=1   # set 0 for standalone ASREP teaching box
```

## Deploy order

```bash
# 1. SIEM + rules (local docker or production VM 110)
./scripts/proxmox/sync-wazuh-rules.sh   # or ./scripts/wazuh-docker-up.sh locally

# 2. ASREP DC first (DNS for the forest)
export SECRETCON_DC_USER_FLAG='...' SECRETCON_DC_ROOT_FLAG='...'
./scripts/proxmox/deploy-asrep.sh --vmid 112 --ip 192.168.61.52

# 3. Challenge boxes (shared local Administrator password)
export SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD='PizzaMan123!'
./scripts/proxmox/deploy-cysvuln.sh --vmid 119 --ip 192.168.61.51
# EWS: rebuild/redeploy Win10 template with updated bootstrap_win.ps1 + autounattend render

# 4. DNS check + chain validation
./scripts/proxmox/configure-chain-dns.sh
./scripts/validate-three-box-chain.sh
./scripts/validate-three-box-chain.sh --siem   # after live red run
```

## Red path (player)

1. **CysVulnServer** — EFS foothold (`User_Joe`) → AIE → SYSTEM → dump local Administrator NTLM hash.
2. **EWS** — Pass-the-Hash as local `Administrator` (same password as CysVuln; deliberate misconfig). VNC/`patrick` remains a separate entry.
3. **DC** — `GetNPUsers secretcon.local/` → crack `enite` / `stud87` → read `C:\Users\Public\user.txt` → as DA read `C:\Users\Administrator\Desktop\root.txt`.

## Flag points (documentation)

| Host | Flag | ACL | Pts |
|---|---|---|---|
| CysVuln | user.txt / root.txt | User_Joe / Administrators | 10 / 20 |
| EWS | flag.txt / root.txt | patrick / Administrators | 10 / 20 |
| DC | user.txt / root.txt | Domain Users / Domain Admins | 15 / 30 |

## Misconfigurations (intentional)

- **Shared local Administrator password** on CysVuln + EWS (`SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD`).
- **`enite`**: AS-REP roastable, weak password `stud87`, RC4, member of **Domain Admins** when `SECRETCON_ASREP_ENITE_DA=1`.
- **No domain join** required on CysVuln/EWS for roasting — only L3 + DNS to the DC.

## Observability

- Wazuh chain rules: `100710`–`100715` (see [defend-track-rubric.md](defend-track-rubric.md)).
- Stress campaign: `./scripts/observability/stress-campaign-chain.sh --iterations 5`

## Standalone boxes

Each challenge still runs independently:

- CysVuln only: [docs/cysvulnserver/walkthrough.md](../cysvulnserver/walkthrough.md)
- EWS only: [docs/runbooks/ews-vnc-adversary-emulation.md](../runbooks/ews-vnc-adversary-emulation.md)
- ASREP only: [docs/asrep/walkthrough.md](../asrep/walkthrough.md) — set `SECRETCON_ASREP_ENITE_DA=0` and omit DC root flag requirement.

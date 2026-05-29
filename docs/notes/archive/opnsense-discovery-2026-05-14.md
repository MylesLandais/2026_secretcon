# OPNsense Firewall Discovery — 2026-05-14

**Summary:** OPNsense at `192.168.61.253` is fully operational but has **zero firewall rules**. It does not route between management VLAN (vmbr0) and challenge VLAN (vmbr1). The Proxmox host (192.168.61.1) acts as the de-facto challenge VLAN gateway, not OPNsense.

## Interface Assignment

| Interface | Bridge | VLAN | Role | OPNsense IP | Notes |
|-----------|--------|------|------|-------------|-------|
| vtnet0 | vmbr1 | 192.168.61.0/24 | LAN | 192.168.61.253 | Challenge VLAN |
| vtnet1 | vmbr0 | 192.168.60.0/24 | WAN | 192.168.60.66 | Management VLAN |

**Key finding:** OPNsense labels vmbr1 as "LAN" and vmbr0 as "WAN", opposite to what the architecture.md design intended (Proxmox host on vmbr0 mgmt, OPNsense as challenge gateway).

## ARP Table (from OPNsense diagnostics)

**vtnet0 (LAN / vmbr1):**
- `192.168.61.1` — Proxmox host (Dell, gateway for challenge VLAN in practice)
- `192.168.61.10` — Wazuh SIEM
- `192.168.61.25` — Unknown Proxmox VM
- `192.168.61.50` — Kali (eth1, just added)
- `192.168.61.253` — OPNsense itself (permanent)
- `192.168.61.254` — UniFi OS gateway

**vtnet1 (WAN / vmbr0):**
- `192.168.60.1` — Proxmox host
- `192.168.60.66` — OPNsense itself (permanent)
- `192.168.60.254` — UniFi OS gateway

## Firewall Rules

**Status: ZERO rules configured.**

- Filter rules: empty (`rule: []`)
- NAT rules: empty
- Port forwards: empty
- NPT rules: empty

**Implication:** All inter-VLAN traffic is dropped by default. OPNsense is not forwarding between vmbr0 (mgmt) and vmbr1 (challenge).

## PF Firewall State

- Current active states: **39**
- State limit: **408300**

## API Access

- Endpoint: `https://192.168.61.253/api/`
- Auth: HTTP Basic (API key + secret)
- User: `dadmin` (WebUI + API)
- Status: **Working**

Note: Many endpoints returned `"errorMessage": "Endpoint not found"` (404) — API path structure differs from OPNsense documentation. Core diagnostics endpoints work (`system/status`, `diagnostics/interface/getArp`).

## Caveats

1. **No inter-VLAN routing:** Kali on vmbr1 cannot reach mgmt services on vmbr0 (e.g., Proxmox WebUI at 192.168.60.1:8006) without explicitly adding a vmbr0 NIC or static route.
2. **No DHCP on vmbr1:** No DHCP server configured; vmbr1 hosts must use static IPs or rely on Proxmox cloud-init.
3. **Cert is fresh (May 14 11:14 UTC):** Self-signed, no HSTS, browsers can override the warning.
4. **OPNsense role is currently network isolation, not gateway.** Treat it as a passive bridge/mirror point; all active gateway duty falls to Proxmox host's vmbr1 address.

## Recommendation

If inter-VLAN traffic is needed:
- Add firewall rules to allow traffic (e.g., vtnet0 LAN any → vtnet1 WAN any, NAT if needed)
- Or configure OPNsense's interface IPs and routing properly
- Or adjust architecture to rely on Proxmox bridging + separate ACLs (current state)

Current state is **not broken for the CTF** — challenge VLAN and operator access are working. But OPNsense's role should be clarified in docs: is it a firewall enforcing rules, or a telemetry/inspection point?

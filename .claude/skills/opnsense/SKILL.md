---
name: opnsense
description: OPNsense firewall + router for the SecretCon lab, deployed as a Proxmox VM in front of vmbr1
---

# OPNsense

## Status

**Planned, not yet deployed.** The current lab uses Proxmox bridge
firewalling on `vmbr1` with `192.168.61.1` served directly off the host.
OPNsense is the target topology under discussion at the firewall + Wazuh
working group. Treat references here as the design we are building
toward, not the current production state. Update this section when the
VM is live.

## When this skill applies

- Any firewall rule, NAT, or inter-VLAN routing change.
- DHCP, DNS resolver, or static lease changes for lab VMs.
- Forwarding firewall logs or Suricata EVE alerts into Wazuh.
- Backing up or restoring the OPNsense config (XML export).
- Adding a new VLAN or segment to the lab.

If you are creating the OPNsense VM itself on Proxmox, that is a Proxmox
task. See `proxmox/SKILL.md`, especially the Virtual networking section.

## Target topology

OPNsense runs as a Proxmox VM on node `manage`:

- WAN interface on `vmbr0` (management VLAN, gets DHCP from upstream).
- LAN interface on `vmbr1` (challenge VLAN, OPNsense owns `192.168.61.1`).
- Additional taps on future bridges (OT, lab-internal) attach as
  new interfaces.

Challenge VMs on `vmbr1` set their default route to `192.168.61.1`
(OPNsense) instead of relying on the Proxmox host bridge. The Proxmox
host stops needing an IP on `vmbr1` once OPNsense takes over routing.

VMID will be allocated in the 100s range (the challenge-VM range) since
OPNsense sits on the challenge data path. Reserve a stable VMID at
deploy time and pin it in `docs/architecture.md`.

## Conventions in this repo

- Config-as-data: the authoritative OPNsense config is the XML export
  under `provisioning/opnsense/config.xml` (planned). Restore from this
  file on a fresh VM rather than clicking through the UI.
- Firewall rule aliases are named by role, not by IP. `wazuh_manager`,
  `ews_hosts`, `operator_workstations`. Aliases live in the same XML.
- Log shipping target is the Wazuh manager at `192.168.61.10:1514/tcp`.
  See the Wazuh integration section below.

## Wazuh integration

Two log streams feed into Wazuh:

1. `filterlog` — OPNsense's pf firewall log. Ship via syslog-ng or
   rsyslog to `192.168.61.10:1514/tcp`. Wazuh has built-in decoders for
   pf format.
2. Suricata EVE JSON — OPNsense ships Suricata as an IDS plugin. Point
   the EVE output at `tcp://192.168.61.10:1514`. Custom rules `86600`
   through `86604` (already seeded by the Wazuh bootstrap) match the
   EVE event schema.

Dashboard side: a "Firewall" tab in the Wazuh dashboard surfaces the
filterlog stream; "Threat Hunting" surfaces the EVE alerts. No extra
Wazuh-side configuration beyond confirming the agent group `ews` exists
and the rules are in place. See `wazuh/SKILL.md`.

## Backup and restore

- UI: System -> Configuration -> Backups -> Download configuration.
- CLI: `/conf/config.xml` on the OPNsense VM is the source of truth.
- Copy to `provisioning/opnsense/config.xml` in this repo (sanitized,
  no API keys). Rebuild flow: install OPNsense from ISO, accept default
  setup, then System -> Configuration -> Backups -> Restore configuration.

Do not commit the unsanitized config. Run it through a scrubber that
strips API keys, certificate private keys, and any operator emails first.

## Common pitfalls

- VLAN-aware bridges on Proxmox vs OPNsense VLAN tagging on a flat
  bridge: pick one. Doing both makes traffic disappear silently. The
  cleaner default is a flat `vmbr1`, with OPNsense doing tagging on its
  LAN interface for any sub-VLANs.
- NAT reflection: if a challenge VM tries to reach a service by its
  external IP, OPNsense by default will not hairpin the traffic.
  Enable NAT reflection per-rule, not globally.
- Asymmetric routing during cutover: while the Proxmox host still has
  an IP on `vmbr1`, some VMs will route through the host and some
  through OPNsense. Remove the host's `vmbr1` address as part of the
  same cutover that installs OPNsense.
- The default OPNsense "anti-lockout" rule on LAN is permissive. Tighten
  it for the challenge VLAN once the deploy is stable, or operators
  will accidentally hit the OPNsense web UI from challenge VMs.

## Debugging tips

- Live firewall logs: Firewall -> Log Files -> Live View.
- Suricata alerts: Services -> Intrusion Detection -> Alerts.
- States table: Firewall -> Diagnostics -> States. Useful when a flow
  starts working "out of nowhere" — usually a stale state.
- From the OPNsense shell: `tcpdump -ni <iface>` and `pfctl -s rules`.

## References

- OPNsense docs: https://docs.opnsense.org/
- Wazuh OPNsense integration notes (filterlog decoders) live in the
  Wazuh manager rules; see `/var/ossec/ruleset/rules/0235-pf_rules.xml`.
- See also `proxmox/SKILL.md` Virtual networking section.
- See also `wazuh/SKILL.md` for the manager side.

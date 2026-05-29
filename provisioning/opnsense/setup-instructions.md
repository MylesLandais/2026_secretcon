# OPNsense MIRROR + Suricata + filterlog setup

One-time OPNsense configuration for the SecretCon vmbr1 SPAN-to-OPNsense
pipeline. After this is applied, OPNsense sees all `vmbr1` traffic on
its `MIRROR` interface and ships Suricata EVE + pf `filterlog` events
into the production Wazuh manager (`192.168.61.10:1514`).

The host-side `tc` mirror and the OPNsense third NIC attach are handled
by [`scripts/proxmox/enable-vmbr1-mirror.sh`](../../scripts/proxmox/enable-vmbr1-mirror.sh).
This document covers everything that has to be done **inside** the
OPNsense web UI / shell once the new `vtnet2` NIC is present.

When you are done, export `/conf/config.xml` and commit it as
`provisioning/opnsense/config.xml` (sanitized) so a future rebuild can
restore the same state in one shot via System -> Configuration -> Backups.

## 0. Prerequisites

- `scripts/proxmox/enable-vmbr1-mirror.sh` has been run; OPNsense has a
  third NIC `vtnet2` enslaved to the `vmbrmirror` bridge on the host,
  with the host-side `tc` mirror active.
- An OPNsense API key + secret exists for user `dadmin` (System ->
  Access -> Users -> dadmin -> API keys). Add to `.env`:

  ```
  OPNSENSE_API_KEY=<base64>
  OPNSENSE_API_SECRET=<base64>
  OPNSENSE_HOST=192.168.61.253
  ```

- `os-suricata` plugin installed (System -> Firmware -> Plugins).

## 1. Assign MIRROR interface (GUI)

Interfaces -> Assignments

| Field | Value |
| --- | --- |
| Available network ports | `vtnet2` |
| Click `+` to add it as a new interface |  |
| Resulting label | `OPT2` (auto). Rename in the next step. |

Interfaces -> [OPT2] (the new assignment)

| Field | Value |
| --- | --- |
| Description | `MIRROR` |
| Enable | checked |
| Block private networks | unchecked (we want to see private) |
| Block bogon networks | unchecked |
| IPv4 Configuration Type | None |
| IPv6 Configuration Type | None |
| MAC address | leave blank |
| MTU | match `vmbr1` (usually 1500) |
| Promiscuous mode | checked (per-interface flag; this is what makes Suricata see SPAN'd frames) |

Save + Apply.

## 2. Block-all filter on MIRROR (passive only, prevent leaks)

Firewall -> Rules -> MIRROR

Single rule:

| Field | Value |
| --- | --- |
| Action | Block |
| Interface | MIRROR |
| Direction | in |
| TCP/IP Version | IPv4+IPv6 |
| Protocol | any |
| Source | any |
| Destination | any |
| Log packets matched by the rule | checked |
| Description | `SECRETCON: MIRROR is SPAN-only; block all in/out` |

Save + Apply. This guarantees OPNsense itself never sends or accepts
anything on `vtnet2` even if a stray daemon binds it.

## 3. Suricata: enable on MIRROR (GUI)

Services -> Intrusion Detection -> Administration -> Settings

| Field | Value |
| --- | --- |
| Enabled | yes |
| IPS mode | NO (SPAN port; can't drop) |
| Promiscuous mode | yes |
| Pattern matcher | hyperscan |
| Detect profile | medium |
| Log payload as bytes | yes |
| Home networks | `192.168.61.0/24` |
| External networks | `!$HOME_NET` |

Services -> Intrusion Detection -> Administration -> Interfaces

Click `+` -> add row:

| Field | Value |
| --- | --- |
| Interface | MIRROR |
| Promiscuous | yes |
| Checksum check | OFF (SPAN-mirrored frames frequently have bad checksums) |
| Stream depth | 12 mb |

Services -> Intrusion Detection -> Administration -> Schedule

- Enable ET Open ruleset for baseline coverage (the cron downloads the
  ruleset on a schedule; pick daily).
- Add custom rules file: `/usr/local/etc/suricata/rules/secretcon.rules`.
  This file is shipped by
  [`scripts/proxmox/opnsense-apply-config.sh`](../../scripts/proxmox/opnsense-apply-config.sh)
  on every push.

Save + Apply. Start the service.

## 4. EVE JSON syslog target -> Wazuh

System -> Settings -> Logging / Targets

Click `+` to add target:

| Field | Value |
| --- | --- |
| Enabled | yes |
| Transport | tcp4 |
| Application | suricata-eve (or 'IDS') |
| Level | informational |
| Facility | local1 |
| Hostname | `192.168.61.10` |
| Port | 1514 |
| RFC5424 | yes |
| Certificate | (leave blank; Wazuh manager accepts plain TCP) |
| Description | `SECRETCON: Suricata EVE -> wazuh.manager:1514` |

OPNsense routes Suricata's EVE output through its syslog subsystem when
the IDS settings have `Log to syslog` enabled. The Wazuh decoder strips
the syslog header and parses the JSON body; rules `86600-86604` then
classify it and rules `100810/100811/100812` child off `86601` for the
VNC-brute SIDs.

## 5. filterlog (pf) syslog target -> Wazuh

System -> Settings -> Logging / Targets

Click `+` to add a second target:

| Field | Value |
| --- | --- |
| Enabled | yes |
| Transport | tcp4 |
| Application | filterlog |
| Level | informational |
| Facility | local0 |
| Hostname | `192.168.61.10` |
| Port | 514 |
| RFC5424 | yes |
| Description | `SECRETCON: pf filterlog -> wazuh.manager:514` |

The Wazuh `:514` syslog listener is plumbed by
[`scripts/proxmox/enable-wazuh-replay-listener.sh`](../../scripts/proxmox/enable-wazuh-replay-listener.sh)
and the built-in `0235-pf_rules.xml` decoder parses pf format. Rule
`100815` will fire on `>=20 pass/60s to dstport 5900` from the same src.

Firewall -> Settings -> Logging

- Log packets matched from the default pass rules: checked
- Log packets blocked by the default block rule: checked

Otherwise `filterlog` won't emit anything on the MIRROR interface where
we have a block-all rule.

## 6. Packet capture profile (saved state)

Interfaces -> Diagnostics -> Packet Capture

Save a profile named `vnc-brute-5900`:

| Field | Value |
| --- | --- |
| Interface | MIRROR |
| Host address | (blank) |
| Port | 5900 |
| Packet count | 50000 |
| Packet length | 16384 |
| Description | `SECRETCON: VNC brute capture (SPAN)` |

Triggered on-demand via
[`scripts/proxmox/opnsense-export-pcap.sh`](../../scripts/proxmox/opnsense-export-pcap.sh).

## 7. Verify end-to-end

```bash
# From operator workstation:
./scripts/proxmox/opnsense-apply-config.sh
# Should write secretcon.rules and reload Suricata.

# From the manager:
ssh dadmin@192.168.61.10 'sudo tcpdump -nni any -c 5 port 1514'
# Trigger one SID 2400001 by hitting EWS:5900 from a non-EWS src 10x
# in 60s; you should see the JSON arrive.

# Or run the orchestrator that does the whole loop:
./scripts/observability/opnsense-vnc-challenge.sh
./scripts/validate/validate-opnsense-vnc-pipeline.sh
```

## 8. Backup the config (do this after you've applied the above)

System -> Configuration -> Backups -> Download configuration

Sanitize (strip API keys + certificate private keys) and commit to
`provisioning/opnsense/config.xml`. A future rebuild restores via
System -> Configuration -> Backups -> Restore configuration in one shot.

## References

- [`provisioning/opnsense/suricata/secretcon.rules`](suricata/secretcon.rules)
- [`provisioning/opnsense/suricata/suricata-mirror.yaml`](suricata/suricata-mirror.yaml) (config-as-code reference; UI is canonical)
- [`scripts/proxmox/enable-vmbr1-mirror.sh`](../../scripts/proxmox/enable-vmbr1-mirror.sh)
- [`scripts/proxmox/opnsense-apply-config.sh`](../../scripts/proxmox/opnsense-apply-config.sh)
- [`scripts/proxmox/opnsense-export-pcap.sh`](../../scripts/proxmox/opnsense-export-pcap.sh)
- [`scripts/observability/opnsense-vnc-challenge.sh`](../../scripts/observability/opnsense-vnc-challenge.sh)
- [`docs/runbooks/opnsense-vnc-brute-analyst-challenge.md`](../../docs/runbooks/opnsense-vnc-brute-analyst-challenge.md)

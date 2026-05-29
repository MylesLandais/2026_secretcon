# OPNsense provisioning assets

This directory holds the config-as-data artifacts for the SecretCon
OPNsense VM (LAN=`vmbr1`/192.168.61.253, WAN=`vmbr0`/192.168.60.66).
See [`docs/notes/opnsense-discovery-2026-05-14.md`](../../docs/notes/opnsense-discovery-2026-05-14.md)
for the deployed-state baseline and
[`.claude/skills/opnsense/SKILL.md`](../../.claude/skills/opnsense/SKILL.md)
for operator conventions.

## Layout

```
provisioning/opnsense/
    README.md                       (this file)
    config.xml                      (sanitized /conf/config.xml export -- created on first apply)
    setup-instructions.md           (one-time GUI/API setup for SPAN sensor mode)
    suricata/
        secretcon.rules             (custom Suricata signatures, SIDs 2400001-2400002)
        suricata-mirror.yaml        (config-as-code reference; UI is canonical)
    scripts/
        export-config.sh            (pull /conf/config.xml, sanitize, commit-ready)
```

## Workflow

1. One-time provisioning:
   - Run [`scripts/proxmox/enable-vmbr1-mirror.sh`](../../scripts/proxmox/enable-vmbr1-mirror.sh)
     (host-side tc mirror + OPNsense net2 attach).
   - Apply OPNsense-side GUI steps from [`setup-instructions.md`](setup-instructions.md).
   - Run [`scripts/proxmox/opnsense-apply-config.sh`](../../scripts/proxmox/opnsense-apply-config.sh)
     to push `suricata/secretcon.rules` and reload Suricata.
2. Snapshot the config:
   - Run [`scripts/export-config.sh`](scripts/export-config.sh) to pull the
     sanitized `/conf/config.xml` and stage it as `config.xml` here.
   - Review the diff (`git diff provisioning/opnsense/config.xml`) and
     commit if the only changes are intentional.
3. Rebuild-from-zero (disaster recovery):
   - Install OPNsense from ISO with default LAN/WAN assignments.
   - System -> Configuration -> Backups -> Restore configuration ->
     upload `config.xml`.
   - Reboot.
   - Re-apply API key + secret in `.env` (these are stripped on export).
   - Re-run `scripts/proxmox/opnsense-apply-config.sh` to re-load the
     Suricata custom rules into the live ruleset.

## What gets sanitized

The export script strips, replacing each occurrence with a placeholder
comment so the structure is preserved:

| XML path | Why |
| --- | --- |
| `//apikeys/item/key` and `//apikeys/item/secret` | API credentials (operator regenerates on import) |
| `//cert/prv` (any certificate private key) | TLS private keys for the WebGUI cert |
| `//openvpn-server//tls` | OpenVPN TLS auth keys (if present) |
| `//system/user/password` | Local user password hashes |
| `//ipsec//pre-shared-key` | IPsec PSKs (if present) |
| `//snmpd//rocommunity` | SNMP community string (if present) |
| Operator email addresses in `//system/user/email` | PII |

Run `scripts/export-config.sh --dry-run` to see the exact XPaths that
will be touched before committing.

## Why config.xml lives in tree

OPNsense's UI mutates `/conf/config.xml` directly; there is no
intermediate Ansible/Salt-shaped state. Committing a sanitized snapshot
gives us a reproducible rollback target that is independent of the
qm-snapshot mechanism (those snapshots can chain badly on LVM-thin and
expire after the first major-version upgrade).

# Wazuh local-lab docker stack

Single-node Wazuh stack (manager + indexer + dashboard) pinned to 4.14.5,
intended for the SecretCon CysVuln SIEM capture loop. Adapted from
[wazuh/wazuh-docker v4.14.5/single-node](https://github.com/wazuh/wazuh-docker/tree/v4.14.5/single-node).

This is the **local-lab tier**. The production-lab tier is a Proxmox VM
deployed via `provisioning/bash/bootstrap-wazuh-ubuntu.sh`. They are
peers, not redundant: use this stack when you want a fast, disposable
SIEM next to a `run-local-cysvuln.sh` QEMU VM.

## Quick start

```
./scripts/wazuh-docker-up.sh           # bring stack up + create ews group
./scripts/observability-loop.sh        # full SIEM capture loop
./scripts/wazuh-docker-down.sh         # stop (or --wipe to nuke volumes)
```

Dashboard: <https://127.0.0.1:1443> (override with `WAZUH_DASHBOARD_PORT`).
Default creds: `admin` / `SecretPassword` (override via `.env`).

## Topology

```
host:1514       -> wazuh.manager:1514   (agent events, TCP)
host:1515       -> wazuh.manager:1515   (authd enrollment, TCP)
host:55000      -> wazuh.manager:55000  (Wazuh API, HTTPS)
host:1443       -> wazuh.dashboard:5601 (HTTPS UI)
host:9200       -> wazuh.indexer:9200   (raw OpenSearch, HTTPS)
```

The CysVuln Windows VM runs under QEMU user-mode networking and dials the
docker manager via the QEMU NAT gateway:

```
guest:5985 -> host fwd 15985 (WinRM)
host       <- guest 10.0.2.2:1514 (Wazuh agent events; outbound from guest)
```

No extra port forwards on the QEMU side are needed; the agent only
opens outbound connections.

## SecretCon overlays vs. upstream

1. Dashboard exposed on host `:1443` instead of `:443` (host :443 may be
   in use; override via `WAZUH_DASHBOARD_PORT`).
2. `config/wazuh_cluster/local_rules.xml` - 13 custom rules
   (`100501-100517`) for CysVuln walkthrough phases, with the msiexec
   deep-dive coverage (`100510-100517`) called out in
   [docs/cysvulnserver/blue-faq-walkthrough.md](../../docs/cysvulnserver/blue-faq-walkthrough.md).
3. `config/wazuh_cluster/shared/ews/agent.conf` - subscribes the
   `ews`-group agents to `Microsoft-Windows-Sysmon/Operational`,
   `Microsoft-Windows-MSI/Operational`, and the
   `C:\Users\Public\aie-*.log` verbose msiexec log. Without this, the
   manager only sees the default Security/System/Application channels
   and the entire Sysmon stream is silently dropped.

## First-time bring-up

The indexer/dashboard need certificates produced by the upstream
`wazuh/wazuh-certs-generator` one-shot. `scripts/wazuh-docker-up.sh`
handles this transparently - run it once and it will populate
`config/wazuh_indexer_ssl_certs/` if missing.

To wipe the stack (including all alerts and the indexer index state):

```
./scripts/wazuh-docker-down.sh --wipe
```

## Files

- `docker-compose.yml` - manager + indexer + dashboard.
- `generate-indexer-certs.yml` - one-shot cert generator.
- `config/certs.yml` - hostnames passed to the cert generator.
- `config/wazuh_cluster/wazuh_manager.conf` - upstream manager config
  (verbatim from `v4.14.5`).
- `config/wazuh_cluster/local_rules.xml` - SecretCon custom rules.
- `config/wazuh_cluster/shared/ews/agent.conf` - shared group config
  for the `ews` agent group.
- `config/wazuh_indexer/*.yml` - upstream indexer config (verbatim).
- `config/wazuh_dashboard/*.yml` - upstream dashboard config (verbatim).
- `.env.template` - copy to `.env` and tune.
- `config/wazuh_indexer_ssl_certs/` - generated, gitignored.

## Related skill

[.claude/skills/wazuh/SKILL.md](../../.claude/skills/wazuh/SKILL.md)

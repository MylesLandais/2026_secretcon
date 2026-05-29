# Arkime local-lab docker stack

Single-node Arkime stack (`v5-latest`) over an isolated OpenSearch
2.18 backend. Used by the SecretCon EWS challenge to host the
pre-staged TightVNC auth PCAP that participants crack offline with
[`vncpasswd.py -d`](https://github.com/trinitronx/vncpasswd.py).

This is the **local-lab tier**, parallel to
[`infrastructure/wazuh-docker/`](../wazuh-docker/). The
production-lab tier (a Proxmox `crit-capture` VM with port-mirrored
sensors on `vmbr1`) is documented as a follow-up in
[`docs/architecture.md`](../../docs/architecture.md) but not deployed.

## Quick start

```
./scripts/arkime-docker-up.sh                                   # bring stack up
./scripts/arkime-import-pcap.sh infrastructure/arkime-docker/pcaps/vnc_auth.pcap
# open https://127.0.0.1:8005 (admin / SecretCon123! by default)
./scripts/arkime-docker-down.sh                                 # stop (or --wipe)
```

## Topology

```
host:9201 -> arkime.opensearch:9200  (raw OpenSearch, plaintext, single-node)
host:8005 -> arkime.viewer:8005      (HTTP UI; reverse-proxy with TLS if exposed)
```

Both ports bind to `127.0.0.1` only; the stack is meant to live next
to the operator workstation, not be reachable from the challenge VLAN.

## Staging a PCAP

PCAPs are not live-captured by this stack -- they are generated once
by [`scripts/observability/vnc-adversary-emulation.sh`](../../scripts/observability/vnc-adversary-emulation.sh)
(Kali-driven hydra+vncdo run against the EWS) and committed-by-reference
into `pcaps/` here. The directory is git-ignored (regenerable, not source).

After dropping a PCAP into `pcaps/`, ingest it with:

```
./scripts/arkime-import-pcap.sh infrastructure/arkime-docker/pcaps/vnc_auth.pcap
```

The import script wraps `arkime-capture -r <file>` inside the viewer
container and prints the viewer search URL.

## Why a separate OpenSearch from Wazuh

The Wazuh indexer (`infrastructure/wazuh-docker/`) is the SIEM index
and has retention + ILM rules tuned for alerts. Mixing Arkime session
data into that index would either corrupt its lifecycle or force
shared schema decisions. Keeping the two stores apart means either
lifecycle can be wiped (`*-down.sh --wipe`) without affecting the
other.

## Files

- `docker-compose.yml` -- OpenSearch + Arkime viewer.
- `config/config.ini` -- Arkime node configuration (parsers, plugins,
  viewer host/port). Bind-mounted read-only.
- `.env.template` -- copy to `.env` and tune.
- `pcaps/` -- staged PCAP corpus (gitignored, regenerable).

## Related

- [`scripts/arkime-docker-up.sh`](../../scripts/arkime-docker-up.sh)
- [`scripts/arkime-import-pcap.sh`](../../scripts/arkime-import-pcap.sh)
- [`scripts/observability/vnc-adversary-emulation.sh`](../../scripts/observability/vnc-adversary-emulation.sh)
- [`docs/runbooks/ews-vnc-adversary-emulation.md`](../../docs/runbooks/ews-vnc-adversary-emulation.md)

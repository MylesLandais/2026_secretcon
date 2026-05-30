# Tailscale per-user connection PoC (Card 5)

Feeds the web-service broker stub (`docs/architecture/webservice-access-layer.md`).

## Topology

```
Player laptop (tailscale client)
    -> tailnet ACL (tag:player-test)
    -> cerberus-nix subnet router (advertises 192.168.61.0/24)
    -> EWS challenge VM 192.168.61.20
```

## Committed artifacts

- `acl.hujson.example` — test player sees only `192.168.61.20/32`
- NixOS snippet: `subnet-router.nix.example`

## Auth key issuance (manual PoC)

1. Admin creates reusable auth key in Tailscale admin with tag `tag:player-test`
2. Player installs Tailscale, `tailscale up --auth-key=...`
3. Verify: `tailscale ping 192.168.61.20` (when subnet route approved)

## Automation path (future)

```
CTF portal webhook -> broker POST /sessions -> Tailscale API preauth key per user
```

## Fallback

If Tailscale ACLs cannot express per-challenge isolation: evaluate **WireGuard + wg-easy**
(self-hosted, committed under `infrastructure/wireguard/` when triaged).

## External dependency

Requires an existing tailnet and admin access — not provisioned from this repo overnight.

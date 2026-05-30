# Web-service access layer — architecture stub

## Problem

SecretCon wants a **HackTheBox-class** experience:

1. Player authenticates to a portal
2. Portal issues a **per-user connection** (VPN/tunnel) scoped to their instance
3. Scoreboard reflects progress without coupling challenge VM images to the portal

CTFd and RootTheBox cover (3) partially but not (1)+(2) in an integrated way.

## Decision (pending implementation)

| Option | Pros | Cons |
|--------|------|------|
| Fork RootTheBox | Python, game-oriented | Large codebase; still needs tunnel broker |
| Fork CTFd | Mature plugins | Same tunnel gap |
| Greenfield broker + thin UI | Clean separation (this repo’s model) | Highest upfront cost |

**Current direction:** greenfield **connection broker** behind a thin scoring UI; keep Tier A boxes portal-agnostic.

## Broker interface contract (BIG TODO)

```
POST /api/v1/sessions
  Authorization: Bearer <player_token>
  Body: { "challenge_id": "ews", "team_id": "..." }
  Response: { "connection": { "type": "tailscale|wireguard", "credential": "...", "endpoint": "..." } } }

GET /api/v1/scoreboard
  (delegates to scoring backend or static event config)
```

Implementations:

- Card 5 Tailscale PoC feeds `type=tailscale`
- Fallback: WireGuard + wg-easy

## Network placement

- Broker + portal: management VLAN or public edge
- Challenge VMs: `192.168.61.0/24` (vmbr1) — reachable only via broker-issued ACL

## References

- Tier A resilience: `docs/runbooks/ops-challenge-reset.md`
- Tailscale spike: `infrastructure/tailscale/README.md`

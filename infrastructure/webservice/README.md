# SecretCon player web-service (Tier B)

Scoring and authenticated access are **separate** from challenge boxes (Tier A).
Challenge VMs are VulnHub-publishable with no portal dependency.

## Status

| Component | Status |
|-----------|--------|
| Challenge boxes + watchdog | Tier A — in repo |
| Scoring portal | **STUB** — see `docker-compose.yml` placeholder |
| Per-user connection broker | **BIG TODO** — see `docs/architecture/webservice-access-layer.md` |

## Platform evaluation (HackTheBox-style gap)

Neither CTFd nor RootTheBox provides:

- Authenticated per-user connection to an isolated challenge instance
- Integrated tunnel/key issuance tied to scoreboard identity
- The “your own box” HTB player experience

**Recommendation:** treat CTFd/RootTheBox as reference scoring UIs only; plan a **fork or refactor**
of an access broker (see decision doc). Do not block Tier A resilience on this.

## Local dev

```bash
# Placeholder compose — no challenge VM coupling
docker compose -f infrastructure/webservice/docker-compose.yml config
```

Production deploy target: external edge host (OCI Nanode or campaign NixOS), not challenge VLAN.

---
name: bloodhound-local
description: Optional BloodHound CE docker stack for AD analysis (Chain 8 WIP). Scripts are gitignored.
---

# BloodHound local (WIP)

BloodHound CE compose stack for AD path analysis during Chain 8 development.

Scripts (gitignored): `scripts/bloodhound-docker-up.sh`, `scripts/bloodhound-docker-down.sh`.

Infrastructure template: `infrastructure/bloodhound-docker/` (also gitignored).

Not used by the shipped CysVuln → EWS → AS-REP campaign. Start here only when working Chain 8 graph analysis.

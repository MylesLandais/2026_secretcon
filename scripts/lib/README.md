# scripts/lib

Bash helpers sourced by verify and build scripts. Not executable on their own.

| File | Purpose | Sourced by |
|------|---------|------------|
| check-harness.sh | `check_init`, `check`, `check_summary` PASS/FAIL accumulator | `verify-cysvuln.sh`, `verify-ews.sh` |
| check-wazuh-agent.sh | Wazuh manager API agent status | verify scripts (after `check` exists) |
| read-provision-manifest.sh | `read_provision_manifest` — repo-relative paths from manifest txt | `test-local.sh`, `build-provision-iso.sh` |

## Sourcing contract

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/check-harness.sh"
check_init
check "example" PASS "detail"
check_summary "my verify run"
```

`check-wazuh-agent.sh` requires `check` to be defined first (from `check-harness.sh`).

Manifest reader parity with `scripts/build-provision-iso.ps1` `Read-ManifestLines` is documented in both build scripts.

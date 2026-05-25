# CysVuln CTF issues log

Living list of reproducibility, fairness, and observability issues
surfaced by the stress campaigns and the baseline observability tour.
Add new entries as you find them; mark `status: closed` rather than
deleting so the history is intact.

## Open issues

### CTF-001: EFS callback path unreachable on QEMU user-net

- Audience: red (and indirectly blue)
- Severity: medium
- First observed: 10x stress campaign, every iteration (Phase 04a auto-skip)
- Repro: `python3 scripts/validate/check_efs69_response.py --target 127.0.0.1 --port 18080 --service-port 80 --mode callback --lhost 10.0.2.2 --cmd whoami`
  fails because the QEMU user-net stack cannot route guest -> host
  without an explicit hostfwd reverse-mapping.
- Impact: CTF players who learn the technique from
  [`exploit-db/42256`](https://www.exploit-db.com/exploits/42256)
  expect the callback path to work; the lab forces them onto the exec
  stager (404-on-first-try is fine, but a callback timeout is
  confusing). Blue team also loses the 100507 EFS crash receipt
  because the exec stager is too clean to crash `fswsService.exe`.
- Mitigation in tree: `stress-campaign.sh` skips 04a unless `CB_LHOST`
  is provided so the scorecard does not falsely report failure.
- Fix candidates:
  - Document the callback workaround in `walkthrough.md` Phase 4 (use
    a tap interface or run the exploit from the Proxmox EWS box).
  - Add a portfwd reverse mapping to `run-local-cysvuln.sh` so the
    callback can reach the host on a known port.
- Status: open

### CTF-002: audit_aie reports HKCU AlwaysInstallElevated = None

- Audience: both
- Severity: medium
- First observed: smoke and 10x campaign, every iteration of Phase 06
- Repro: `python3 scripts/validate/audit_aie.py --target 127.0.0.1
  --port 15985 --user Administrator --password PizzaMan123! --profile-user User_Joe`
  prints `AIE HKCU = None    FAIL` even though
  [`bootstrap_cysvuln.ps1`](../../provisioning/powershell/bootstrap_cysvuln.ps1)
  pre-seeds the value into `User_Joe\NTUSER.DAT`.
- Impact: scorecard says `aie_chain_expected: false` for all 10 iters
  even though Phase 07 succeeds with exit 0 every time. Either the
  pre-seed is being clobbered before the audit reads it, or the
  audit's `reg load` of `User_Joe\NTUSER.DAT` is not loading the
  expected hive content (perhaps the profile got initialised between
  bootstrap and the snapshot).
- Fix candidates:
  - Inspect a freshly-booted VM for the actual HKCU value (load
    `User_Joe\NTUSER.DAT` from a recovery shell, query
    `HKU\<sid>\Software\Policies\Microsoft\Windows\Installer\AlwaysInstallElevated`).
  - If pre-seed is lost, move it to a logon script that re-applies on
    first interactive logon.
- Status: open

### CTF-003: audit-aie JSON not yet flowing into Wazuh archives

- Audience: blue
- Severity: low
- First observed: 10x campaign
- Repro: search the campaign dataset for `audit-aie` references in
  `dataset/archives/archives.json`; zero hits despite each iteration
  successfully writing
  `C:\Users\Public\audit-aie-<UTC-ts>.json` to the VM.
- Root cause: the in-tree
  [`agent.conf`](../../infrastructure/wazuh-docker/config/wazuh_cluster/shared/ews/agent.conf)
  now subscribes the `ews` group to that file, but the live QCOW
  baseline snapshot pre-dates the change. The agent's `merged.mg`
  carries the old config until a `wazuh-agent` restart following a
  manager push with the new shared config.
- Fix candidates:
  - Rebuild + re-baseline so the snapshot includes an agent that has
    already merged the latest shared config.
  - Or, add a `--restart-agent` flag to `wait_for_winrm.sh` that
    bounces the Wazuh agent after a snapshot revert.
- Status: open

### CTF-004: Sysmon EID 11 doesn't fire on `Get-Content` flag reads

- Audience: blue
- Severity: low
- First observed: rule 100520 never fires across 10 iters
- Root cause: Sysmon EID 11 is `FileCreate`, not file access; reads
  via `Get-Content` only generate EID 1 (PowerShell process spawn) and
  the EID 1 does not carry the file path in `cmdLine` (the runspace
  hides the script body).
- Fix candidates:
  - Enable ScriptBlock logging (event 4104 in `Microsoft-Windows-PowerShell/Operational`)
    in the bootstrap and add a rule chaining off `script_block_text`
    containing `user.txt` / `root.txt`.
  - Or, replace `read_user_flag.sh` with a `cmd /c type` invocation so
    the cmd image lands in EID 1 with the path in `cmdLine`.
- Status: open

### CTF-005: Per-manager-restart 100530 cold-start gap

- Audience: blue
- Severity: low (informational)
- First observed: smoke test on first iteration with a freshly
  restarted manager
- Root cause: rule 100530 (enum -> AIE correlation) requires that
  rule 100510 has already fired within the prior 15 min. On a
  freshly-restarted Wazuh manager (or a manager that has been idle
  for >15 min), the first iteration produces 100508/100509 directly
  rather than 100530.
- Impact: the scorecard's per-iter "fired_100530" flag may show
  `false` for iter 1 on a cold manager. Subsequent iters within the
  same campaign always show `true`. This is correct semantics, not a
  bug.
- Mitigation in tree: blue scorecard credits 100508/100509 when 100530
  fires (chained-rule shadowing), so coverage rate is reported
  correctly regardless of which leg matched.
- Status: closed (documented behaviour)

## Closed issues

### Iter 2/3 PsExec missing on snapshot restore (closed by validator hardening)

- Pre-dates current campaign
- Root cause: previous `validate-cysvuln-chain.sh` invoked
  `cysvuln_local_prep.py` per iter, which races WinRM on a freshly
  reverted snapshot.
- Fix: PsExec is now persisted at `C:\Users\Public\PsExec.exe` by
  both [`cysvuln_local_prep.py`](../../scripts/cysvuln_local_prep.py)
  and [`bootstrap_cysvuln.ps1`](../../provisioning/powershell/bootstrap_cysvuln.ps1),
  so the snapshot carries the binary and the chain has nothing to
  re-stage. `stress-campaign.sh` also gates on
  [`wait_for_winrm.sh`](../../scripts/lib/wait_for_winrm.sh) which
  blocks until WinRM accepts `whoami` and the agent reports `active`.
- Status: closed (10/10 iters succeeded in the campaign without any
  PsExec staging step inside the iteration)

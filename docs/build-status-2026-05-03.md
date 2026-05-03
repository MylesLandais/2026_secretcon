# Win10 LTSC Image Build — Status & Troubleshooting Log

Date: 2026-05-03
Owner: warby
Pipeline: `infrastructure/packer/local-qemu.pkr.hcl` → qemu/KVM → qcow2

## TL;DR

Win10 LTSC 2021 install + AutoLogon work. **No build has yet completed** because the OpenSSH bootstrap (the bridge between OOBE and Packer's first provisioner) never comes up, so Packer always times out at "Waiting for SSH" after 90 min and Packer wipes the qcow2 before we can inspect it. Three delivery mechanisms for the bootstrap have been tried; none have produced a successful SSH handshake. The Sysmon/Wazuh/pycomm3 bake work is implemented and waiting downstream of this blocker.

---

## What works

- Win11 → Win10 LTSC pivot decision (memory: `project_win10_ltsc_pivot.md`).
- ISO + checksum staged: `en-us_windows_10_enterprise_ltsc_2021_x64_dvd_d289cf96.iso` (sha256 verified).
- Packer template `local-qemu.pkr.hcl` validates clean. KVM accelerator, q35, e1000e NIC, IDE disk (chosen for Win10 setup compat per prior commit `bc77945`).
- `autounattend.xml` is honored from the floppy: disk partitioning, en-US locale, ComputerName `WIN10-EWS`, Admin password set, AutoLogon (LogonCount=9), `packer` local user, OOBE pages hidden.
- VNC display works (Packer rotates through 59xx ports). Confirmed in earlier session via Remmina that the Win10 desktop reaches AutoLogon and shows the Networks discovery prompt.
- `nix shell nixpkgs#xorriso -c packer build …` correctly supplies xorriso for `cd_files`. CD ISO is built and attached (label `PROVISION`).
- HTTP server on port 8888 starts and stays up the entire build window — verified by Packer log entry `Starting HTTP server on port 8888`.
- SSH keypair generated: `provisioning/ssh/packer_ed25519{,.pub}`, fingerprint `packer@secretcon-build`.
- OpenSSH bundle staged: `provisioning/openssh/OpenSSH-Win64.zip` (5.4 MB, sha256 `23f50f3458c4c5d0b12217c6a5ddfde0137210a30fa870e98b29827f7b43aba5`).

## What's implemented but un-exercised (blocked behind the SSH issue)

- `provisioning/powershell/bootstrap_win.ps1`:
  - Dead WinRM hardening lines (orig 31–36) removed.
  - Sysmon ruleset now fetched from SwiftOnSecurity raw GitHub (no local file dependency).
  - Sysmon binary name corrected to `Sysmon64.exe`.
  - Final assertion block: build fails (`exit 1`) if `Sysmon64`/`WazuhSvc` services are missing/not running, or `python -c "import pycomm3"` fails.
  - Wazuh manager default `192.168.61.10`, overridable via `$env:WAZUH_MANAGER`.
- `infrastructure/packer/local-qemu.pkr.hcl` build block: runs `bootstrap_win.ps1` with `WAZUH_MANAGER=192.168.61.10`, then a final inline validation provisioner.
- `infrastructure/wazuh/docker-compose.yml`: single-node `wazuh-manager:4.8.0`, ports 1514/udp, 1515/tcp, 514/udp, 55000/tcp; matches agent version baked in bootstrap. **Not yet brought up.**

---

## The blocker: SSH never comes up

### Symptom (consistent across all three attempts)

- Packer log: `Starting HTTP server on port 8888` ✓
- Packer log: `Attempting SSH connection to 127.0.0.1:<port>...` repeated for 90 min
- Packer log: `SSH handshake err: Timeout during SSH handshake`
- Final: `Build … errored after 1 hour 30 minutes: Timeout waiting for SSH.`
- HTTP access log: **zero GETs** in 90 min — strong evidence that whatever was supposed to fetch `setup-openssh.ps1` from the host never reached `Invoke-WebRequest`. (Applies to attempts 1–2; attempt 3 deliberately removed the HTTP path.)
- Behavioral note: TCP connect to host:guest-22 forward succeeds (otherwise log would say `connection refused`). "Handshake timeout" = QEMU usermode accepts the host-side TCP but no service in the guest is speaking SSH on port 22. So sshd was never up.

### Tried and failed

#### Attempt 1 — `Add-WindowsCapability OpenSSH.Server` in FLC

- FLC order 3 ran `Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0`, then `Start-Service sshd`.
- Failed: 90 min timeout, no SSH. Screendump showed Networks discovery prompt blocking. Theory: the inbox capability install requires WU/network, and Network classification hadn't completed yet. AutoLogon may also have been gated behind the modal.

#### Attempt 2 — Bundled OpenSSH via HTTP (`http://10.0.2.2:8888/setup-openssh.ps1`)

- Replaced FLC order 3 with `Invoke-WebRequest http://10.0.2.2:8888/setup-openssh.ps1` → execute.
- `setup-openssh.ps1` downloads `OpenSSH-Win64.zip` from the same HTTP root, expands, runs `install-sshd.ps1`, sets ACL on `administrators_authorized_keys`, sets DefaultShell to powershell.exe, starts sshd.
- Failed: 90 min timeout. **Zero GETs in HTTP log.** Whatever ran in FLC order 3 never reached `Invoke-WebRequest`. qcow2 wiped on Packer cleanup before we could mount it. Could not get root cause from this attempt.
- Attempted to mount the qcow2 via `qemu-nbd` after failure to read `C:\Windows\Panther\setupact.log` and `C:\Windows\Temp\setup-openssh.log` — failed because Packer's auto-cleanup deleted the disk before mount succeeded. Fish shell also broke a chained sudo command at line wrap.

#### Attempt 3 — CD-ISO delivery + specialize-pass NewNetworkWindowOff (current state)

- `cd_files` in Packer ships `setup-openssh.ps1`, `OpenSSH-Win64.zip`, `packer_ed25519.pub` on a labeled CD (`PROVISION`). Eliminates HTTP dependency from guest.
- `setup-openssh.ps1` rewritten to find the CD by volume label or by probing for the script file, then install from there.
- `autounattend.xml` specialize pass adds `Microsoft-Windows-Deployment/RunSynchronousCommand`: `reg add HKLM\SYSTEM\CurrentControlSet\Control\Network\NewNetworkWindowOff /f` — runs **before** OOBE classifies the network, so the modal cannot block FLC.
- FLC order 3 writes `C:\Windows\Temp\flc-fired.txt` (proof FLC even ran).
- FLC order 4: `Set-NetConnectionProfile -NetworkCategory Private` (best-effort).
- FLC order 5: locate CD by label, copy script local, run with all output → `C:\Windows\Temp\setup-openssh.out` (survives crash; `Stop-Transcript` no longer required).
- Failed: same 90 min timeout, same no-SSH symptom. qcow2 wiped again — couldn't read `flc-fired.txt`.

### Root-cause hypotheses still open (priority order)

1. **OOBE never reaches AutoLogon → FLC never fires.** Some pass after `specialize` is hanging silently. Needs visible-console + persisted-disk debugging.
2. **AutoLogon fires but FLC encounters a different blocking modal** (e.g., "Setup is preparing your PC for first use" if any RunSynchronous in specialize errored). Visible to VNC if we keep the disk.
3. **Sysprep/generalize was run by an earlier autounattend draft and the image is in audit mode** — would skip our oobeSystem FLC entirely. Unlikely but worth ruling out by checking `C:\Windows\Setup\State\State.ini` if we get a disk.
4. **`cd_files` ISO not actually attached** — qemu builder default attaches as second cdrom, but iso_url is also a cdrom; need to confirm both mount inside Win10. If only one shows, FLC order 5's CD probe finds nothing → script failure → no sshd.

---

## What we have NOT tried (suggested next steps, ranked)

1. **`keep_failed_build = true` on the qemu source** (Packer 1.15+) so the qcow2 survives a timeout. Combined with `pause_before_connecting` and a non-headless run, lets us VNC in and read the marker files (`flc-fired.txt`, `setup-openssh.out`, `setupact.log`) from inside the guest while it's still up.
2. **Run the build with `headless = false`** so the user can watch OOBE/AutoLogon progress live in the SDL window — much faster diagnosis than VNC port-hunting.
3. **Drop a `<RunSynchronousCommand>` in specialize** that writes a marker (`echo specialize-ok > C:\specialize.txt`) — confirms specialize completed. Pair with the FLC marker to triangulate where execution stops.
4. **Stop using `cd_files` and instead use a dedicated second floppy or use Packer's `qemuargs` to attach a writable scratch volume.** If `cd_files` isn't actually mounting in Win10 (hypothesis 4), this is the workaround.
5. **Try a known-working community Win10 LTSC autounattend** (e.g., StefanScherer/packer-windows for Win10) as a baseline. If theirs works in our env, diff against ours; if theirs also fails, the issue is qemu/host, not our XML.
6. **Switch communicator to `none`** for one experimental build — no SSH expectation; let it run unattended and inspect the qcow2 manually (would need shutdown_command to be triggered some other way, e.g. shutdown timer in FLC).

---

## Anti-loop guardrails (read this before you re-attempt)

- **Do NOT do another silent 90-minute wait.** Every failed build so far burned 90 min and produced no diagnostic info. Cap the next attempt at 15 min OR keep the disk on failure. No more black-box runs.
- **Do NOT propose another "different download mechanism" for the OpenSSH bootstrap until you have proof FLC actually runs.** All three attempts above changed the delivery method without first verifying the upstream stage (FLC firing). The HTTP→CD pivot was a guess; it failed because the prerequisite was the same. Verify FLC fires before changing delivery again.
- **Do NOT rely on `Set-NetConnectionProfile` inside FLC to suppress the Networks modal.** The modal can appear before FLC runs. The reg key MUST land in specialize (it does now); confirm via marker file before assuming this is fixed.
- **Do NOT mount the qcow2 with `qemu-nbd` after a Packer failure unless `keep_failed_build = true` is set.** Packer deletes the output dir as part of failure cleanup; you will race it and lose.
- **Do NOT re-derive any of the above by re-reading old transcripts.** This file is the source of truth for the build history.

---

## File inventory (current state on disk)

| Path | Purpose | State |
|---|---|---|
| `infrastructure/packer/local-qemu.pkr.hcl` | Packer template, qemu builder, SSH communicator, cd_files+floppy_files+http_directory | Modified — has `cd_files`, build block runs `bootstrap_win.ps1` |
| `provisioning/autounattend.xml` | Win10 unattend; specialize NewNetworkWindowOff; FLC marker + Set-NetConnectionProfile + setup-openssh launcher | Modified |
| `provisioning/setup-openssh.ps1` | OpenSSH installer; reads from CD by label `PROVISION` | Modified |
| `provisioning/openssh/OpenSSH-Win64.zip` | Win32-OpenSSH 10.0.0.0p2-Preview bundle | Staged |
| `provisioning/ssh/packer_ed25519{,.pub}` | SSH keypair for Packer auth | Staged |
| `provisioning/powershell/bootstrap_win.ps1` | Sysmon (SwiftOnSecurity from upstream) + Wazuh + patrick + flag + pycomm3 + assertion gate | Modified, not yet exercised |
| `infrastructure/wazuh/docker-compose.yml` | Single-node `wazuh-manager:4.8.0` | New, not brought up |
| `provisioning/scripts/sysmon-config.xml` | Local Sysmon config (was referenced by old plan) | **Does not exist** — bootstrap fetches from upstream instead |

---

## Memory references

- `project_win11_24h2_modern_setup.md` — why we're not on Win11
- `project_win10_ltsc_pivot.md` — Win10 + SSH decision

## Next action (when work resumes)

1. Add `keep_failed_build = true` and `headless = false` to `local-qemu.pkr.hcl`. Optionally cut `ssh_timeout` to `20m` to fail fast.
2. Re-run build with `nix shell nixpkgs#xorriso -c packer build local-qemu.pkr.hcl`.
3. When it fails (or if it succeeds), preserve the qcow2 and read `C:\Windows\Temp\flc-fired.txt`, `C:\Windows\Temp\setup-openssh.out`, `C:\Windows\Panther\setupact.log`. Decide root cause from evidence, not theory.
4. Bring up Wazuh manager (`cd infrastructure/wazuh && docker compose up -d`) — independent of the build, useful for end-to-end validation later.

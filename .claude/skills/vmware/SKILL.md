---
name: vmware
description: VMware Workstation/Fusion native Packer builds for SecretCon Windows images
---

# VMware Workstation / Fusion

## When this skill applies

Reach for this skill when building or running challenge VMs on a Windows or macOS host with VMware Workstation 16+ or VMware Fusion 12+, instead of QEMU (Nix), Hyper-V, or Proxmox.

VMware recipes (both under target directories):

- EWS Win10 LTSC: `infrastructure/packer/ews/win10-ews-vmware.pkr.hcl`
- CysVuln Server 2016: `infrastructure/packer/cysvuln/vmware-cysvuln.pkr.hcl`

All EWS builders (QEMU, Proxmox, Hyper-V, VMware) live in `infrastructure/packer/ews/`.

ESXi / vCenter is **not wired**. Both recipes target the local `vmware-iso` driver. Remote builds would require a `vmware-iso` source that declares `remote_host`, `remote_datastore`, `remote_username`, `skip_export`, etc. — out of scope today.

## Conventions in this repo

- `vmware-iso` consumes `cd_files` directly, like QEMU. No pre-baked PROVISION ISO needed (Hyper-V is the outlier on that front).
- SSH login is `packer` / `packer`. Both autounattends create the account:
  - EWS uses `provisioning/local/autounattend.xml`.
  - CysVuln uses `provisioning/cysvuln/autounattend.xml`, which got a `<LocalAccounts>` block adding the `packer` admin so the VMware (and Hyper-V) source's `ssh_username = "packer"` actually resolves.
- DHCP via the VMware NAT vmnet (`vmnet8` by default on Workstation, `vmnet8` equivalent on Fusion). No static-IP overlay — that lives only on the Proxmox path (`setup-openssh.ps1` only applies when `proxmox-static-ip.txt` is present on PROVISION media).
- `bootstrap_cysvuln.ps1` and `bootstrap_win.ps1` are hypervisor-agnostic. They locate the PROVISION payload by scanning every mounted drive, so VMware's CD/floppy mounts work the same way as Hyper-V's secondary ISO or QEMU's `cd_files`.
- `open-vm-tools` is **not** installed by the bootstrap. Operators who want clean shutdown, clipboard, or `vmrun getGuestIPAddress` advertisement can add it post-boot: `winget install Broadcom.VMwareTools` (Workstation) or VMware Tools ISO via the GUI (Fusion).
- Both Hyper-V and VMware CysVuln recipes pass `WAZUH_ENROLLMENT_OPTIONAL=1` to the bootstrap (alongside the QEMU recipe). A reachable Wazuh manager is *preferred* but not *required* — the build completes either way. Override `cysvuln_wazuh_manager` if you want a fully-enrolled agent pointing at a host-local docker SIEM.

## Canonical examples

- [infrastructure/packer/cysvuln/vmware-cysvuln.pkr.hcl](infrastructure/packer/cysvuln/vmware-cysvuln.pkr.hcl)
- [infrastructure/packer/ews/win10-ews-vmware.pkr.hcl](infrastructure/packer/ews/win10-ews-vmware.pkr.hcl)
- [docs/runbooks/deploy-cysvuln-multi-hypervisor.md](docs/runbooks/deploy-cysvuln-multi-hypervisor.md)

## Build commands

CysVuln (Server 2016):

```
cd infrastructure/packer/cysvuln
packer init .
packer build \
  -only=vmware-iso.cysvuln-vmware \
  -var "cysvuln_iso_url=file:///path/to/Windows_Server_2016.ISO" \
  -var "cysvuln_iso_checksum=sha256:<your-pin>" \
  -var "cysvuln_wazuh_manager=192.168.<vmnet8>.2" \
  .
```

EWS (Win10 LTSC):

```
cd infrastructure/packer/ews
packer init .
packer build \
  -only=vmware-iso.win10-ews-vmware \
  -var "iso_url=file:///path/to/en-us_windows_10_enterprise_ltsc_2021_x64_dvd_d289cf96.iso" \
  .
```

Outputs land under `output/cysvuln-vmware/` and `output/win10-ews-vmware/` respectively, as a `.vmx` + `.vmdk` pair (no `.ovf` unless you pass `-format=ovf` to the builder).

## Run commands

Open the resulting `.vmx` in Workstation/Fusion, or drive it headlessly:

```
vmrun start output/cysvuln-vmware/cysvuln.vmx nogui
vmrun -gu packer -gp packer getGuestIPAddress output/cysvuln-vmware/cysvuln.vmx -wait
vmrun stop  output/cysvuln-vmware/cysvuln.vmx soft
```

`getGuestIPAddress -wait` requires VMware Tools or `open-vm-tools` running inside the guest. Without it, fall back to ARP scanning the host vmnet (`arp -a | findstr 192.168`).

## Wazuh-manager network on Workstation/Fusion

The VMware NAT host gateway sits at `192.168.<vmnet8-subnet>.2` (the `.1` is the DHCP server). To point the guest agent at a local docker SIEM running on the host:

```
packer build -var "cysvuln_wazuh_manager=192.168.<vmnet8>.2" ...
```

The local Wazuh stack (`infrastructure/wazuh-docker/`) binds `1514`/`1515` on the host; Docker Desktop typically publishes those on `0.0.0.0` by default, so they are reachable from any VMware vmnet without additional port-proxy.

See "Manager-IP per hypervisor" in `infrastructure/wazuh-docker/readme.md` and the "Wazuh-manager network override" section of `docs/runbooks/deploy-cysvuln-multi-hypervisor.md` for the full table of gateway addresses across QEMU / Hyper-V / VMware / Proxmox.

## Snapshot lifecycle

`vmrun snapshot` is the native equivalent of `qemu-img snapshot`:

```
vmrun snapshot       output/cysvuln-vmware/cysvuln.vmx baseline
vmrun revertToSnapshot output/cysvuln-vmware/cysvuln.vmx baseline
vmrun listSnapshots  output/cysvuln-vmware/cysvuln.vmx
```

The in-tree observability and 10x stress-campaign loops (`scripts/observability-loop.sh`, `scripts/observability/*.sh`) **only orchestrate the QEMU `qemu-img snapshot` path today.** A VMware operator can run the validation chain manually (`scripts/verify-cysvuln.sh`, `scripts/validate-cysvuln-chain.sh`) against the guest IP from `vmrun getGuestIPAddress`, but the loop scripts will not work without a hypervisor adapter (out of scope; see the multi-hypervisor runbook for the documented caveat).

## Common pitfalls

- **VMware Tools is not installed by default.** Without it, `vmrun getGuestIPAddress` will return nothing, snapshot `quiesce` will fall back to a non-quiesced disk dump, and there is no clean ACPI shutdown. Install post-boot if needed.
- **Guest hardware version mismatch.** The recipes pin `version = 19` (Workstation 17 / Fusion 13). Older hosts must override `-var vmware_hardware_version=18` (Workstation 16) or `17` (Workstation 15). Newer hosts can leave it.
- **`guest_os_type` differs between EWS and CysVuln.** EWS uses `windows9-64` (Win10/11 desktop family), CysVuln uses `windows9srv-64` (Server family). Do not cross them.
- **VMware Workstation NAT subnet is host-specific.** `vmnet8` defaults to `192.168.x.0/24` where `x` varies per install. Discover the host gateway via `Get-NetIPAddress` (Windows) or `cat /Library/Preferences/VMware\ Fusion/networking` (Fusion) before setting `cysvuln_wazuh_manager`.
- **ESXi / vCenter is unwired.** Adding `remote_*` source attributes is a future enhancement; do not attempt to `-var vmware_host=esxi.lab` against the current recipes.

## References

- HashiCorp vmware plugin: <https://developer.hashicorp.com/packer/integrations/hashicorp/vmware>
- VMware vmrun reference: <https://docs.vmware.com/en/VMware-Workstation-Pro/17/com.vmware.ws.using.doc/GUID-1AEC8B4E-2E20-4BFB-A5E1-3F0DC52A1C2D.html>
- See also `packer/SKILL.md`, `windows-bootstrap/SKILL.md`, `hyperv/SKILL.md`

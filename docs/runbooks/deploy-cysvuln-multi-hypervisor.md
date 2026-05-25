# Deploy CysVulnServer — multi-hypervisor

The CysVulnServer challenge (Windows Server 2016 + EFS Easy File Sharing 6.9 + AlwaysInstallElevated) builds from a single bootstrap (`provisioning/powershell/bootstrap_cysvuln.ps1`) against four Packer sources. Pick the one that matches your build host.

| Target | Source file | Output |
|---|---|---|
| Proxmox VE | `infrastructure/packer/cysvuln/proxmox-vm-cysvuln.pkr.hcl` | Proxmox VM template (VMID 118) |
| QEMU/KVM (Nix host) | `infrastructure/packer/cysvuln/local-qemu-cysvuln.pkr.hcl` | `cysvuln.qcow2` |
| Hyper-V (Windows host) | `infrastructure/packer/cysvuln/hyperv-cysvuln.pkr.hcl` | `cysvuln.vhdx` |
| VMware Workstation/Fusion | `infrastructure/packer/cysvuln/vmware-cysvuln.pkr.hcl` | `cysvuln.vmx` + `cysvuln.vmdk` |

All four feed `bootstrap_cysvuln.ps1` and the same PROVISION payload (`infrastructure/artifacts/cysvuln/*` + OpenSSH + autounattend + SSH key). The Proxmox path is the original and unchanged; the rest are new.

## Common prerequisites

1. **Server 2016 ISO** — see [docs/windows-image-inputs.md](../windows-image-inputs.md):

       ./scripts/fetch-iso.sh server-2016 <url>

   Pin the observed SHA-256 in `scripts/fetch-iso.sh` after the first good download.

2. **CysVuln artifacts** (EFS installer, validation MSI, scenario text):

       ./scripts/fetch-cysvuln-artifacts.sh
       # optional: ./scripts/fetch-cysvuln-artifacts.sh --generate-msi

   Details: `infrastructure/artifacts/cysvuln/readme.md`

3. **Environment** — copy `example.env` to `.env` for Proxmox/Wazuh deploys.

4. **Flag variables** (optional):

       export SECRETCON_USER_FLAG='flag{...}'
       export SECRETCON_ROOT_FLAG='flag{...}'

5. **SSH key** — generate `provisioning/ssh/packer_ed25519` locally if missing
   (private key is gitignored; `.pub` may be committed).

## QEMU/KVM on Nix

Prereqs: Linux host with KVM, the project devShell.

    nix develop
    ./scripts/fetch-iso.sh server-2016 <url>
    nix build .#cysvuln-local

The flake derivation runs `packer init` + `packer build -only=qemu.cysvuln-local`. Result: `./result/cysvuln.qcow2`. Boot with:

    qemu-system-x86_64 \
      -enable-kvm -m 2048 -smp 1 \
      -machine pc -nic user,model=e1000,hostfwd=tcp::5985-:5985 \
      -drive file=./result/cysvuln.qcow2,if=ide,format=qcow2

Or import into libvirt with `virt-install --import --disk path=...`. The bootstrap configures static `192.168.60.51` on Proxmox; local QEMU uses user networking with host forwards (see [docs/cysvulnserver/readme.md](../cysvulnserver/readme.md)).

Boot locally:

    ./scripts/run-local-cysvuln.sh
    WINRM_PORT=15985 ./scripts/cysvuln-local-prep.sh 127.0.0.1

## Hyper-V on Windows

Prereqs: Windows 10/11 Pro or Server with Hyper-V role, Packer, Windows ADK Deployment Tools (provides `oscdimg.exe`).

    # PowerShell, repo root
    .\scripts\build-provision-iso.ps1
    # Output: infrastructure\packer\cysvuln\provision.iso

    cd infrastructure\packer\cysvuln
    packer init .
    packer build `
      -only=hyperv-iso.cysvuln-hyperv `
      -var cysvuln_iso_url=file:///C:/path/to/server-2016.iso `
      -var cysvuln_provision_iso=$PWD\provision.iso `
      .

Result: `output\cysvuln-hyperv\Virtual Hard Disks\cysvuln.vhdx`. Import:

    Import-VM -Path 'output\cysvuln-hyperv\*.vmcx' -Copy -GenerateNewId
    # or attach the VHDX to a hand-rolled VM:
    New-VM -Name CysVulnServer -MemoryStartupBytes 2GB `
        -VHDPath 'output\cysvuln-hyperv\Virtual Hard Disks\cysvuln.vhdx' `
        -Generation 1 -SwitchName 'Default Switch'

Network caveat: the autounattend does **not** set a static IP for Hyper-V (the Proxmox `setstatic.ps1` path is intentionally not on this PROVISION ISO). The booted VM grabs DHCP. Either pin a reservation on your switch or pass `-var build_ssh_host=<assigned-ip>` after first boot.

## VMware Workstation / Fusion

Prereqs: VMware Workstation 16+ (Windows/Linux) or Fusion 12+ (macOS), Packer, optionally `ovftool` if you want a portable `.ovf`.

    nix develop  # or any shell with packer installed
    cd infrastructure/packer/cysvuln
    packer init .
    packer build \
      -only=vmware-iso.cysvuln-vmware \
      -var cysvuln_iso_url=file:///path/to/server-2016.iso \
      .

Result: `output/cysvuln-vmware/cysvuln.vmx` + `cysvuln.vmdk`. Open the `.vmx` directly in Workstation/Fusion. For a portable OVF:

    ovftool output/cysvuln-vmware/cysvuln.vmx output/cysvuln-vmware/cysvuln.ovf

ESXi remote builds: pass `-var "vmware_host=esxi.lab"` plus the additional `remote_*` variables documented in the [vmware-iso plugin reference](https://developer.hashicorp.com/packer/integrations/hashicorp/vmware/latest/components/builder/iso). Not wired by default.

## Per-hypervisor IP discovery

The validation chain (`scripts/verify-cysvuln.sh`, `scripts/validate-cysvuln-chain.sh`) takes a `<target-ip>` argument. How you obtain that IP depends on the hypervisor:

| Hypervisor | Discovery command | Default IP |
|---|---|---|
| QEMU local | host-forwarded loopback | `127.0.0.1` (WinRM `:15985`, EFS `:18080`, RDP `:13389`) |
| Proxmox | static IP applied by `setup-openssh.ps1` | `192.168.61.51` |
| Hyper-V | `Get-VMNetworkAdapter -VMName CysVulnServer \| Select -ExpandProperty IPAddresses` | DHCP via `Default Switch` (typically `172.x.x.x/28`) |
| VMware | `vmrun -gu packer -gp packer getGuestIPAddress output/cysvuln-vmware/cysvuln.vmx -wait` | DHCP via `vmnet8` (typically `192.168.<x>.0/24`) |

VMware's `getGuestIPAddress` needs VMware Tools or `open-vm-tools` inside the guest (not installed by default). Without Tools, ARP-scan the vmnet8 subnet (`arp -a` on the host) or set a DHCP reservation on the vmnet8 NAT.

## Wazuh-manager network override

The default `cysvuln_wazuh_manager` is the lab Proxmox-side address `192.168.61.10`. On any other build host the agent will not be able to enroll, and the bootstrap relies on `WAZUH_ENROLLMENT_OPTIONAL=1` to keep going (set by every recipe except the Proxmox one). To get a *fully-enrolled* agent dialing a host-local docker SIEM (`infrastructure/wazuh-docker/`), override the variable at build time:

| Hypervisor | Reachable manager IP from inside the guest | Build flag |
|---|---|---|
| QEMU SLIRP | host gateway `10.0.2.2` | `-var cysvuln_wazuh_manager=10.0.2.2` |
| Proxmox `vmbr1` | static lab IP `192.168.61.10` | `-var cysvuln_wazuh_manager=192.168.61.10` (default) |
| Hyper-V `Default Switch` | NAT gateway typically `172.x.x.1` (varies per host) | `-var cysvuln_wazuh_manager=172.x.x.1` |
| VMware vmnet8 | NAT gateway typically `192.168.<vmnet8>.2` | `-var cysvuln_wazuh_manager=192.168.<x>.2` |

Discover the Hyper-V Default-Switch gateway with `Get-NetIPAddress -InterfaceAlias 'vEthernet (Default Switch)' -AddressFamily IPv4`. Discover the VMware vmnet8 gateway with `ipconfig` on Windows (`VMware Network Adapter VMnet8`) or by reading `/Library/Preferences/VMware Fusion/networking` on macOS.

Docker Desktop on Windows publishes `0.0.0.0:1514`/`:1515`/`:55000` by default, so the agent in the guest can reach the manager without extra port-proxy as long as the discovered gateway is the Windows host. If Docker Desktop is configured to bind loopback only, enable "Expose daemon on tcp://localhost:2375 without TLS" or add explicit `0.0.0.0` bindings to [`infrastructure/wazuh-docker/docker-compose.yml`](../../infrastructure/wazuh-docker/docker-compose.yml).

## Snapshot lifecycle and observability scope

Each hypervisor has its own snapshot API; the in-tree observability loops only orchestrate one of them.

| Hypervisor | Snapshot create | Revert | List | Used by `scripts/observability/*` |
|---|---|---|---|---|
| QEMU | `qemu-img snapshot -c baseline cysvuln.qcow2` | `qemu-img snapshot -a baseline cysvuln.qcow2` | `qemu-img snapshot -l cysvuln.qcow2` | **yes** |
| Hyper-V | `Checkpoint-VM -Name CysVulnServer -SnapshotName baseline` | `Restore-VMSnapshot -VMName CysVulnServer -Name baseline -Confirm:$false` | `Get-VMSnapshot -VMName CysVulnServer` | no |
| VMware | `vmrun snapshot output/cysvuln-vmware/cysvuln.vmx baseline` | `vmrun revertToSnapshot output/cysvuln-vmware/cysvuln.vmx baseline` | `vmrun listSnapshots output/cysvuln-vmware/cysvuln.vmx` | no |

[`scripts/observability-loop.sh`](../../scripts/observability-loop.sh), [`scripts/observability/run-baseline-tour.sh`](../../scripts/observability/run-baseline-tour.sh), and [`scripts/observability/stress-campaign.sh`](../../scripts/observability/stress-campaign.sh) drive the QEMU `qemu-img snapshot` lifecycle plus `pkill qemu-system-x86_64` for stop/start. They do not have Hyper-V or VMware backends.

Hyper-V and VMware operators get full coverage of the build and validation paths but run the SIEM capture manually:

```
# After booting and discovering the guest IP per above
./scripts/check-cysvuln-tooling.sh --default
./scripts/verify-cysvuln.sh <guest-ip>
./scripts/validate-cysvuln-chain.sh <guest-ip>
```

The exported `dataset.tar.zst` from a QEMU loop is hypervisor-agnostic; replay onto any Wazuh manager via [`scripts/wazuh-replay-to-proxmox.sh`](../../scripts/wazuh-replay-to-proxmox.sh) to exercise the rule pack against a Hyper-V or VMware-hosted manager. See [`docs/cysvulnserver/blue-faq-walkthrough.md`](../cysvulnserver/blue-faq-walkthrough.md) for the analyst story and [`docs/runbooks/wazuh-dataset-export-and-replay.md`](wazuh-dataset-export-and-replay.md) for the replay procedure.

A future hypervisor adapter for `scripts/lib/loop_lib.sh` (`vm_take_snapshot`, `vm_revert_snapshot`, `vm_stop` with QEMU / Hyper-V / VMware backends) would close this gap; it is tracked as future work and not in scope for the current docs.

## Smoke validation

After any build, boot the artifact and run from your attacker box:

    nix develop
    ./scripts/check-cysvuln-tooling.sh --default
    ./scripts/verify-cysvuln.sh <target-ip>

For local QEMU user-networking: `WINRM_PORT=15985 ./scripts/verify-cysvuln.sh 127.0.0.1`

The script checks WinRM, AIE/UAC registry levers, User_Joe presence, and both flag files. It does not execute the EFS or MSI exploit chains — see [docs/cysvulnserver/walkthrough.md](../cysvulnserver/walkthrough.md).

## Maintenance

All builders read `infrastructure/packer/cysvuln/provision-manifest-shared.txt`
(QEMU/VMware via `cysvuln-shared.pkr.hcl`, Proxmox via `cysvuln/proxmox-vm-cysvuln.pkr.hcl`,
Hyper-V via `scripts/build-provision-iso.sh`). When adding a PROVISION file, edit
the manifest once and re-run `./scripts/test-local.sh`.

## Recipe sharing, not artifact sharing

Packer source files + flake derivation (`packages.cysvuln-local`) are the recommended cross-hypervisor sharing path. Direct qcow2-to-vhdx conversion introduces registry-hive and disk-sector drift that can alter AIE-flag behavior; avoid it. Build fresh on each hypervisor from the same Packer source.

# Deploy CysVulnServer — multi-hypervisor

The CysVulnServer challenge (Windows Server 2016 + EFS Easy File Sharing 6.9 + AlwaysInstallElevated) builds from a single bootstrap (`provisioning/powershell/bootstrap_cysvuln.ps1`) against four Packer sources. Pick the one that matches your build host.

| Target | Source file | Output |
|---|---|---|
| Proxmox VE | `infrastructure/packer/proxmox-vm-cysvuln.pkr.hcl` | Proxmox VM template (VMID 118) |
| QEMU/KVM (Nix host) | `infrastructure/packer/cysvuln/local-qemu-cysvuln.pkr.hcl` | `cysvuln.qcow2` |
| Hyper-V (Windows host) | `infrastructure/packer/cysvuln/hyperv-cysvuln.pkr.hcl` | `cysvuln.vhdx` |
| VMware Workstation/Fusion | `infrastructure/packer/cysvuln/vmware-cysvuln.pkr.hcl` | `cysvuln.vmx` + `cysvuln.vmdk` |

All four feed `bootstrap_cysvuln.ps1` and the same PROVISION payload (`infrastructure/artifacts/cysvuln/*` + OpenSSH + autounattend + SSH key). The Proxmox path is the original and unchanged; the rest are new.

## Common prerequisites

1. **Server 2016 ISO**. Resolve a Microsoft eval-center URL, then:

       ./scripts/fetch-iso.sh server-2016 <url>

   On the first run the sha256 is recorded; pin it in `scripts/fetch-iso.sh` for repeatability. Output lands at `infrastructure/packer/iso/`.

2. **Flag environment variables** (optional — placeholders are used if unset):

       export SECRETCON_USER_FLAG='flag{...}'
       export SECRETCON_ROOT_FLAG='flag{...}'

3. **SSH key**. `provisioning/ssh/packer_ed25519{,.pub}` is the Packer communicator key; it is already committed.

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

Or import into libvirt with `virt-install --import --disk path=...`. The bootstrap configures static `192.168.60.51`; if you run on a NAT bridge with a different subnet, override via `-var build_ssh_host=<dhcp-assigned>` on the packer invocation.

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

## Smoke validation

After any build, boot the artifact and run from your attacker box:

    pip install pywinrm
    ./scripts/verify-cysvuln.sh <target-ip>

The script probes the four AIE levers (HKLM AIE = 1, `ConsentPromptBehaviorAdmin = 0`, `PromptOnSecureDesktop = 0`, User_Joe present) plus user/root flag files. Exit 0 means the box is ready for the chain proven in `[[2026-05-19-cysvuln-live-state]]`.

## Maintenance

The four sources share `cysvuln-shared.pkr.hcl` (locals: provisioning file list, bootstrap script path, env). When `bootstrap_cysvuln.ps1` or any artifact under `infrastructure/artifacts/cysvuln/` changes, all four builds pick it up; no per-source edit needed.

The Proxmox recipe stays at the top of `infrastructure/packer/` and does not share locals with the new sources — its provisioning file list lives inline. If you change the artifact set, update both `proxmox-vm-cysvuln.pkr.hcl` and `cysvuln/cysvuln-shared.pkr.hcl`.

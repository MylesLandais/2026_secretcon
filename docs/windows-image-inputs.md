# Windows image inputs

SecretCon Packer builds require Windows installation media that cannot be
redistributed from this repository. Operators fetch or supply ISOs locally.

## Purpose

Document the bring-your-own-ISO contract for each challenge target and
hypervisor path.

## win10-ltsc (EWS challenge)

| Field | Value |
|-------|-------|
| Edition | Windows 10 Enterprise LTSC 2021 x64 en-us |
| Filename | `en-us_windows_10_enterprise_ltsc_2021_x64_dvd_d289cf96.iso` |
| Placement | `infrastructure/packer/iso/` |
| SHA-256 | `c90a6df8997bf49e56b9673982f3e80745058723a707aef8f22998ae6479597d` |

Fetch:

```
./scripts/fetch-iso.sh win10-ltsc <direct-url>
```

Also need `virtio-win.iso` in `~/Downloads/` for local QEMU.

Platform notes:

- QEMU: `nix build .#win10-ews-local`
- Proxmox: copy ISO to `local:iso/` on the node; `cd infrastructure/packer/ews && packer build -only=proxmox-iso.win10-ews .`
- Hyper-V: see `scripts/hyperv/` and `infrastructure/packer/ews/win10-ews-hyperv.pkr.hcl`
- VMware Workstation/Fusion: `cd infrastructure/packer/ews && packer build -only=vmware-iso.win10-ews-vmware -var iso_url=file:///path/to/<filename> .`; see [`.claude/skills/vmware/SKILL.md`](../.claude/skills/vmware/SKILL.md)

## server-2016 (CysVuln challenge)

| Field | Value |
|-------|-------|
| Edition | Windows Server 2016 Standard Evaluation x64 en-us |
| Filename | `14393.0.160715-1616.RS1_RELEASE_SERVER_EVAL_X64FRE_EN-US.ISO` |
| Placement | `infrastructure/packer/iso/` |
| SHA-256 | not pinned until an operator records one in `scripts/fetch-iso.sh` |

Fetch:

```
./scripts/fetch-iso.sh server-2016 <direct-url>
```

On first download the script prints the observed SHA-256. Add it to the
`server-2016` case in `scripts/fetch-iso.sh` for your event image.

Platform notes:

- QEMU: `nix build .#cysvuln-local` (pass ISO via flake/packer vars)
- Proxmox: stage as `local:iso/windows-server-2016.iso`; see `deploy-cysvulnserver.md`
- VMware Workstation/Fusion: `cd infrastructure/packer/cysvuln && packer build -only=vmware-iso.cysvuln-vmware -var cysvuln_iso_url=file://... .`; see [`.claude/skills/vmware/SKILL.md`](../.claude/skills/vmware/SKILL.md)
- Hyper-V: build `provision.iso` via `scripts/build-provision-iso.ps1`, then `packer build -only=hyperv-iso.cysvuln-hyperv -var cysvuln_iso_url=... -var cysvuln_provision_iso=...`; see [`.claude/skills/hyperv/SKILL.md`](../.claude/skills/hyperv/SKILL.md)

## CysVuln non-ISO artifacts

After the Server 2016 ISO is in place:

```
./scripts/fetch-cysvuln-artifacts.sh
```

See `infrastructure/artifacts/cysvuln/readme.md`.

## Validate

```
./scripts/test-local.sh
```

After a VM is built, use the target-specific verify script (for example
`scripts/verify-cysvuln.sh` or `scripts/verify-ews.sh`).

## Troubleshoot

- `fetch-iso.sh` exits 2: no URL and no cached ISO. Resolve a mirror URL from
  Microsoft Eval Center or Archive.org (documented in the script help).
- SHA mismatch: wrong edition or corrupted download; do not relax the pin.
- Proxmox path uses username/password (`PROXMOX_USERNAME`, `PROXMOX_PASSWORD`),
  not API tokens.

## Cleanup

ISOs under `infrastructure/packer/iso/` are local-only unless you choose to
commit them (not recommended). Remove qcow2/vhdx under `artifacts/` before
`git add`.

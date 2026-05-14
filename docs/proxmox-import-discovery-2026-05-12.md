# Proxmox Import Discovery - 2026-05-12

Scope: move the locally baked EWS qcow2 into the shared SecretCon Proxmox lab.

## Current Local Artifact

- Path: `infrastructure/packer/output/win10-ews-local/win10-ews-local.qcow2`
- Format: qcow2
- Virtual size: 128 GiB
- Current disk size: about 20 GiB
- Local validation ports when booted under QEMU:
  - VNC: `127.0.0.1:5900`
  - SSH: `127.0.0.1:2222`
  - RDP: `127.0.0.1:3389`
  - WinRM: `127.0.0.1:5985`

## VPN / Reachability

NetworkManager profile `wg-ctf` is active and scoped; it is not a default route.

Routes now present:

- `192.168.2.0/24`
- `192.168.60.0/24`
- `192.168.61.0/24`
- `172.16.30.0/24`
- `172.16.130.0/27`

The `192.168.61.0/24` route was missing and was added with:

```bash
nmcli connection modify wg-ctf +ipv4.routes "192.168.61.0/24"
nmcli connection up wg-ctf
```

Observed from workstation:

- `192.168.60.1` responds to ping and has TCP `22` and `8006` open.
- `192.168.60.253` responds to ping and has TCP `22` open.
- `192.168.60.254` responds to ping and has TCP `22`, `80`, and `443` open.
- `192.168.61.1` did not respond from the workstation despite the local route being present.

## Proxmox Inventory

- URL: `https://192.168.60.1:8006`
- Node: `manage`
- Proxmox version: `9.1`
- Storage:
  - `local`: `dir`, content `backup,import,iso,vztmpl`
  - `local-lvm`: `lvmthin`, content `images,rootdir`
- Network:
  - `vmbr0`: `192.168.60.1/24`, gateway `192.168.60.254`, port `nic0`
  - `vmbr1`: `192.168.61.1/24`, port `nic1`

Current VMs:

| VMID | Name | Status | Notes |
|---:|---|---|---|
| 100 | `opnsense-fw` | running | `net0=vmbr1`, `net1=vmbr0`; note this reverses the old deployment script comments. |
| 101 | `wazuh-siem` | stopped | No disk size reported by cluster inventory. |
| 102 | `win11-ics-rockwell` | stopped | Existing placeholder with `scsi0=local-lvm:vm-102-disk-0,size=80G`, BIOS/seabios, `net0=vmbr0`. |
| 103 | `zentyal-prim-dns-local` | running | DNS-related VM. |
| 104 | `kali-2025` | running | Already attached to `vmbr1`. |
| 105 | `win11-ics-rockwell-uefi` | running | Existing Windows UEFI VM, `sata0=150G`, `net0=vmbr0`. |
| 106 | `wind-2012-dc-bios` | running | Domain controller style VM. |
| 107 | `rules-information-page` | running | Rules/info service. |

QEMU guest agent queries did not provide usable interface data:

- VM 100: agent configured but not running.
- VM 104 and VM 105: no guest agent configured.

## Recommended Import Path

Do not overwrite VM 105. It is running and appears to be an existing UEFI Windows build.

For first shared-lab testing, either:

1. Create a new VMID, for example `108`, and import the qcow2 there.
2. Reuse VM 102 only after confirming its current stopped disk is disposable.

Recommended first pass is a new VMID to avoid destroying existing work.

High-level operator flow on the Proxmox host:

```bash
# From workstation, after stopping the local QEMU process that locks the qcow2:
scp infrastructure/packer/output/win10-ews-local/win10-ews-local.qcow2 \
  root@192.168.60.1:/var/lib/vz/import/win10-ews-local.qcow2

# On Proxmox:
qm create 108 \
  --name secretcon-ews-vnc-unquoted-path \
  --memory 8192 \
  --cores 4 \
  --cpu host \
  --ostype win10 \
  --machine q35 \
  --net0 e1000=auto,bridge=vmbr1,firewall=1 \
  --agent enabled=1

qm importdisk 108 /var/lib/vz/import/win10-ews-local.qcow2 local-lvm --format qcow2

qm set 108 \
  --sata0 local-lvm:vm-108-disk-0,ssd=1 \
  --boot order=sata0

qm start 108
```

The local image was built with IDE/e1000e for Windows setup compatibility. If Windows fails to boot after attaching as SATA, attach the imported disk as IDE for the first boot:

```bash
qm set 108 --delete sata0
qm set 108 --ide0 local-lvm:vm-108-disk-0
qm set 108 --boot order=ide0
qm start 108
```

## Validation Checklist

From Kali VM 104 or another host on `vmbr1`:

```bash
nmap -Pn -p 5900,3389,5985,22 <ews-ip>
```

Expected for the challenge target:

- VNC exposed on TCP `5900`.
- VNC password is from the SecLists default VNC credential list path used by the challenge notes.
- Low-privileged desktop user is `patrick`.
- User flag: `C:\Users\patrick\Desktop\flag.txt`.
- Privilege escalation service: `SecretConEwsSync`.
- Root flag: `C:\Users\Administrator\Desktop\root.txt`.

Open issue before participant testing:

- Confirm `192.168.61.0/24` routing from the WireGuard client into the challenge subnet. The route exists locally now, but `192.168.61.1` did not answer from the workstation.

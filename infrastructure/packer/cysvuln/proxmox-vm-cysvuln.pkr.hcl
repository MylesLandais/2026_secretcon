packer {
  required_plugins {
    proxmox = {
      version = ">= 1.2.3"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

variable "vm_id" {
  type    = number
  default = 118
}

variable "vm_name" {
  type    = string
  default = "secretcon-cysvuln-efs-alwaysinstallelevated"
}

variable "win_iso_file" {
  type    = string
  default = "local:iso/windows-server-2016.iso"
}

variable "build_bridge" {
  type    = string
  default = "vmbr0"
}

variable "build_ssh_host" {
  type    = string
  default = "192.168.60.118"
}

variable "final_bridge" {
  type    = string
  default = "vmbr0"
}

locals {
  _shared_files = [
    for p in local._shared_lines :
    "${local.repo_root}/${p}"
  ]
  _proxmox_prefix = [
    "${local.repo_root}/provisioning/proxmox/autounattend.xml",
    "${local.repo_root}/provisioning/proxmox/setstatic.ps1",
    "${local.repo_root}/provisioning/proxmox-static-ip.txt",
  ]
  proxmox_provision_files = concat(local._proxmox_prefix, local._shared_files)
}

source "proxmox-iso" "win2016-cysvuln" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_username
  password                 = var.proxmox_password
  insecure_skip_tls_verify = true

  node                 = var.proxmox_node
  vm_id                = var.vm_id
  vm_name              = var.vm_name
  template_description = "SecretCon 2026 CysVulnServer: Easy File Sharing Web Server 6.9 foothold (EDB-42256) chained with AlwaysInstallElevated SYSTEM privesc (T1574.009)."

  os              = "win10"
  machine         = "pc-i440fx-10.1"
  bios            = "seabios"
  qemu_agent      = false
  scsi_controller = "lsi"

  boot_iso {
    iso_file = var.win_iso_file
    type     = "ide"
    index    = 2
    unmount  = true
  }

  additional_iso_files {
    cd_label         = "PROVISION"
    cd_files         = local.proxmox_provision_files
    iso_storage_pool = "local"
    type             = "ide"
    index            = 3
    unmount          = true
  }

  disks {
    disk_size           = "32G"
    storage_pool        = "local-lvm"
    type                = "sata"
    format              = "raw"
    cache_mode          = "writeback"
    discard             = true
    exclude_from_backup = true
  }

  memory   = 2048
  cores    = 1
  sockets  = 1
  cpu_type = "host"

  network_adapters {
    bridge   = var.build_bridge
    model    = "e1000"
    firewall = false
  }

  boot_wait    = local.boot_wait
  boot_command = local.boot_command_installer

  communicator           = "ssh"
  ssh_host               = var.build_ssh_host
  ssh_username           = local.ssh_username
  ssh_password           = local.ssh_password
  ssh_private_key_file   = local.ssh_private_key_file
  ssh_timeout            = local.ssh_timeout
  ssh_handshake_attempts = local.ssh_handshake_attempts

  task_timeout = "30m"
}

build {
  name    = "proxmox-win2016-cysvuln"
  sources = ["source.proxmox-iso.win2016-cysvuln"]

  provisioner "powershell" {
    inline = [
      "Write-Host '[*] SSH connected. Win2016 CysVulnServer build reached provisioner stage.'",
      "Get-Service sshd | Format-List Name,Status,StartType"
    ]
  }

  provisioner "powershell" {
    script           = local.bootstrap_script
    environment_vars = local.bootstrap_env
  }

  provisioner "powershell" {
    inline = [
      "Get-Service sshd, Sysmon64, WazuhSvc, fswsService | Format-Table Name, Status, StartType",
      "Get-LocalUser | Select-Object Name, Enabled",
      "Get-CimInstance Win32_Service -Filter \"Name='fswsService'\" | Select-Object Name, StartName, State"
    ]
  }

  post-processor "shell-local" {
    inline = [
      "echo 'CysVulnServer build complete.'",
      "echo 'VMID ${var.vm_id} is the BUILT replica; Cys live box remains at 108. Do not collide.'",
      "echo 'If a final-bridge swap is needed: qm set ${var.vm_id} --net0 e1000=auto,bridge=${var.final_bridge},firewall=0'"
    ]
  }
}

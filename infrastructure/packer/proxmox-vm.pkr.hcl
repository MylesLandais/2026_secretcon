packer {
  required_plugins {
    proxmox = {
      version = ">= 1.2.3"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

variable "proxmox_url" {
  type    = string
  default = env("PROXMOX_URL")
}

variable "proxmox_username" {
  type    = string
  default = env("PROXMOX_USERNAME")
}

variable "proxmox_password" {
  type      = string
  default   = env("PROXMOX_PASSWORD")
  sensitive = true
}

variable "proxmox_node" {
  type    = string
  default = "manage"
}

variable "vm_id" {
  type    = number
  default = 109
}

variable "vm_name" {
  type    = string
  default = "secretcon-ews-vnc-unquoted-path"
}

variable "win_iso_file" {
  type    = string
  default = "local:iso/en-us_windows_10_enterprise_ltsc_2021_x64_dvd_d289cf96.iso"
}

variable "build_bridge" {
  type    = string
  default = "vmbr0"
}

variable "build_ssh_host" {
  type    = string
  default = "192.168.60.109"
}

variable "final_bridge" {
  type    = string
  default = "vmbr1"
}

source "proxmox-iso" "win10-ews" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_username
  password                 = var.proxmox_password
  insecure_skip_tls_verify = true

  node                 = var.proxmox_node
  vm_id                = var.vm_id
  vm_name              = var.vm_name
  template_description = "SecretCon 2026 Windows workstation lab: VNC foothold and unquoted service path privilege escalation."

  os              = "win10"
  machine         = "q35"
  bios            = "seabios"
  qemu_agent      = false
  scsi_controller = "virtio-scsi-single"

  boot_iso {
    iso_file = var.win_iso_file
    type     = "ide"
    index    = 2
    unmount  = true
  }

  additional_iso_files {
    cd_label         = "PROVISION"
    cd_files         = [
      "${path.root}/../../provisioning/proxmox/autounattend.xml",
      "${path.root}/../../provisioning/proxmox/setstatic.ps1",
      "${path.root}/../../provisioning/openssh/setup-openssh.ps1",
      "${path.root}/../../provisioning/proxmox-static-ip.txt",
      "${path.root}/../../provisioning/openssh/OpenSSH-Win64.zip",
      "${path.root}/../../provisioning/tightvnc/tightvnc-2.8.87-gpl-setup-64bit.msi",
      "${path.root}/../../provisioning/ssh/packer_ed25519.pub"
    ]
    iso_storage_pool = "local"
    type             = "ide"
    index            = 3
    unmount          = true
  }

  disks {
    disk_size         = "128G"
    storage_pool      = "local-lvm"
    type              = "sata"
    format            = "raw"
    cache_mode        = "writeback"
    discard           = true
    exclude_from_backup = true
  }

  memory = 8192
  cores  = 4
  cpu_type = "host"

  network_adapters {
    bridge   = var.build_bridge
    model    = "e1000"
    firewall = true
  }

  boot_wait = "3s"
  boot_command = [
    "<spacebar><spacebar>"
  ]

  communicator           = "ssh"
  ssh_host               = var.build_ssh_host
  ssh_username           = "packer"
  ssh_password           = "packer"
  ssh_private_key_file   = "${path.root}/../../provisioning/ssh/packer_ed25519"
  ssh_timeout            = "30m"
  ssh_handshake_attempts = 1000

  task_timeout = "30m"
}

build {
  name    = "proxmox-win10-ews"
  sources = ["source.proxmox-iso.win10-ews"]

  provisioner "powershell" {
    inline = [
      "Write-Host '[*] SSH connected. Win10 LTSC build reached provisioner stage.'",
      "Get-Service sshd | Format-List Name,Status,StartType"
    ]
  }

  provisioner "powershell" {
    script           = "${path.root}/../../provisioning/powershell/bootstrap_win.ps1"
    environment_vars = ["WAZUH_MANAGER=192.168.61.10"]
  }

  provisioner "powershell" {
    inline = [
      "Get-Service sshd, Sysmon64, WazuhSvc, tvnserver, SecretConEwsSync | Format-Table Name, Status, StartType",
      "Get-LocalUser | Select-Object Name, Enabled"
    ]
  }

  post-processor "shell-local" {
    inline = [
      "echo 'Build completed. Move the VM to the challenge bridge after Packer exits:'",
      "echo 'qm set ${var.vm_id} --net0 e1000=auto,bridge=${var.final_bridge},firewall=1'"
    ]
  }
}

packer {
  required_plugins {
    proxmox = {
      version = ">= 1.1.6"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

variable "proxmox_url" {
  type    = string
  default = env("PROXMOX_URL")
}

variable "proxmox_token_id" {
  type    = string
  default = env("PROXMOX_TOKEN_ID")
}

variable "proxmox_token_secret" {
  type      = string
  default   = env("PROXMOX_TOKEN_SECRET")
  sensitive = true
}

variable "win_iso_url" {
  type    = string
  default = "local:iso/Win11_23H2_English_x64.iso"
}

source "proxmox-iso" "win11-ews" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_token_id
  token                    = var.proxmox_token_secret
  node                     = "pve"
  vm_id                    = 102
  vm_name                  = "win11-ews"
  template_description     = "Win11 Engineering Workstation — SecretCon 2026"

  iso_file                 = var.win_iso_url
  os                       = "win11"

  qemu_agent               = true
  scsi_controller          = "virtio-scsi-single"

  disks {
    disk_size    = "80G"
    storage_pool = "local-zfs"
    type         = "virtio"
  }

  memory = 8192
  cores  = 4

  network_adapters {
    bridge   = "vmbr10"
    vlan_tag = "10"
    model    = "virtio"
  }

  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_password = env("WINRM_PASSWORD")
  winrm_insecure = true
  winrm_use_ssl  = false

  additional_iso_files {
    iso_file = "local:iso/virtio-win.iso"
  }

  http_directory = "${path.root}/../../provisioning"
}

build {
  name = "win11-ews"
  sources = ["source.proxmox-iso.win11-ews"]

  provisioner "powershell" {
    script = "${path.root}/../../provisioning/powershell/bootstrap_win.ps1"
  }

  provisioner "windows-restart" {}

  provisioner "powershell" {
    inline = [
      "Write-Host 'EWS provisioning complete'",
      "Get-LocalUser | Select-Object Name,Enabled"
    ]
  }
}

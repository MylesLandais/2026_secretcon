# Proxmox + SSH locals for DC Proxmox builds (this directory scope only).

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

locals {
  repo_root              = "${path.root}/../../.."
  ssh_private_key_file   = "${local.repo_root}/provisioning/ssh/packer_ed25519"
  ssh_username           = "packer"
  ssh_password           = "packer"
  ssh_timeout            = "30m"
  ssh_handshake_attempts = 1000
  boot_wait              = "3s"
  boot_command_installer = ["<spacebar><spacebar>"]

  proxmox_sata_disk_defaults = {
    storage_pool        = "local-lvm"
    type                = "sata"
    format              = "raw"
    cache_mode          = "writeback"
    discard             = true
    exclude_from_backup = true
  }

  openssh_bundle = [
    "${local.repo_root}/provisioning/openssh/setup-openssh.ps1",
    "${local.repo_root}/provisioning/openssh/OpenSSH-Win64.zip",
    "${local.repo_root}/provisioning/ssh/packer_ed25519.pub",
    "${local.repo_root}/provisioning/powershell/assets/sysmonconfig.xml",
    "${local.repo_root}/provisioning/powershell/lib/SecretCon.Bootstrap.psm1",
  ]
}

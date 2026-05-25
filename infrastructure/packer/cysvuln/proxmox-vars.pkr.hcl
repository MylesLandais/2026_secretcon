# Proxmox + SSH locals for CysVuln Proxmox builds (this directory scope only).

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
  ssh_private_key_file   = "${local.repo_root}/provisioning/ssh/packer_ed25519"
  ssh_username           = "packer"
  ssh_password           = "packer"
  ssh_timeout            = "30m"
  ssh_handshake_attempts = 1000
  boot_wait              = "3s"
  boot_command_installer = ["<spacebar><spacebar>"]
}

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
  default = 112
}

variable "vm_name" {
  type    = string
  default = "secretcon-asrep-dc-secretcon"
}

variable "win_iso_file" {
  type    = string
  default = "local:iso/windows-server-2016.iso"
}

variable "build_bridge" {
  type    = string
  default = "vmbr1"
}

variable "build_ssh_host" {
  type    = string
  default = "192.168.60.112"
}

variable "final_bridge" {
  type    = string
  default = "vmbr1"
}

variable "proxmox_static_ip_file" {
  type    = string
  default = ""
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

locals {
  _static_ip_file = (
    var.proxmox_static_ip_file != "" ?
    var.proxmox_static_ip_file :
    "${local.repo_root}/provisioning/proxmox-static-ip.txt"
  )
  _proxmox_prefix = [
    "${local.repo_root}/provisioning/proxmox/autounattend.xml",
    "${local.repo_root}/provisioning/proxmox/setstatic.ps1",
    local._static_ip_file,
  ]
  proxmox_provision_files = concat(local._proxmox_prefix, local.provision_files)

  proxmox_bootstrap_env = concat([
    for e in local.bootstrap_env :
    startswith(e, "WAZUH_MANAGER=") ? "WAZUH_MANAGER=192.168.61.10" : e
  ], ["WAZUH_ENROLLMENT_OPTIONAL=1"])

  ssh_private_key_file   = "${local.repo_root}/provisioning/ssh/packer_ed25519"
  ssh_username           = "packer"
  ssh_password           = "packer"
  ssh_timeout            = "30m"
  ssh_handshake_attempts = 1000
  boot_wait              = "3s"
  boot_command_installer = ["<spacebar><spacebar>"]
}

source "proxmox-iso" "win2016-asrep" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_username
  password                 = var.proxmox_password
  insecure_skip_tls_verify = true

  node                 = var.proxmox_node
  vm_id                = var.vm_id
  vm_name              = var.vm_name
  template_description = "SecretCon 2026 ASREP demo DC (secretcon.local / enite AS-REP roast)."

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
    disk_size           = "40G"
    storage_pool        = "local-lvm"
    type                = "sata"
    format              = "raw"
    cache_mode          = "writeback"
    discard             = true
    exclude_from_backup = true
  }

  memory   = 8192
  cores    = 2
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

  task_timeout = "45m"
}

build {
  name    = "proxmox-win2016-asrep"
  sources = ["source.proxmox-iso.win2016-asrep"]

  provisioner "powershell" {
    script           = local.bootstrap_script
    environment_vars = local.proxmox_bootstrap_env
  }

  provisioner "windows-restart" {
    restart_timeout = "45m"
  }

  provisioner "powershell" {
    inline = [
      "$env:SECRETCON_ASREP_PACKER = '1'",
      "& C:\\secretcon\\asrep-bootstrap.ps1"
    ]
    environment_vars = local.proxmox_bootstrap_env
  }

  provisioner "windows-restart" {
    restart_timeout = "45m"
  }

  provisioner "powershell" {
    inline = [
      "$env:SECRETCON_ASREP_PACKER = '1'",
      "& C:\\secretcon\\asrep-bootstrap.ps1"
    ]
    environment_vars = local.proxmox_bootstrap_env
  }

  provisioner "powershell" {
    script = "${local.repo_root}/provisioning/asrep/verify-post-promote.ps1"
    environment_vars = [
      "AD_DOMAIN=${var.ad_domain}",
      "SECRETCON_ASREP_USER=${var.asrep_user}",
      "SECRETCON_ASREP_FLAG=${var.asrep_flag}",
    ]
  }

  post-processor "shell-local" {
    inline = [
      "echo 'ASREP DC build complete.'",
      "echo 'VMID ${var.vm_id} — do not collide with live range VMs.'"
    ]
  }
}

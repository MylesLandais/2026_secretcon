packer {
  required_plugins {
    proxmox = {
      version = ">= 1.2.3"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

variable "win_iso_file" {
  type    = string
  default = "local:iso/windows-server-2016.iso"
}

variable "build_bridge" {
  type    = string
  default = "vmbr1"
}

variable "ad_domain" {
  type    = string
  default = "heliumsupply.local"
}

variable "ad_netbios" {
  type    = string
  default = "HELIUM"
}

variable "ad_safemode_password" {
  type      = string
  default   = env("AD_SAFEMODE_PASSWORD")
  sensitive = true
}

variable "ad_admin_password" {
  type      = string
  default   = env("AD_ADMIN_PASSWORD")
  sensitive = true
}

variable "replica_source_dc" {
  type    = string
  default = "192.168.61.20"
}

variable "wazuh_manager" {
  type    = string
  default = "192.168.61.10"
}

variable "wazuh_agent_version" {
  type    = string
  default = "4.14.5"
}

locals {
  dc_provision_prefix = {
    primary = [
      "${local.repo_root}/provisioning/proxmox/dc1/autounattend.xml",
      "${local.repo_root}/provisioning/proxmox/dc1/setstatic.ps1",
    ]
    replica = [
      "${local.repo_root}/provisioning/proxmox/dc2/autounattend.xml",
      "${local.repo_root}/provisioning/proxmox/dc2/setstatic.ps1",
    ]
  }
  dc_provision_files = {
    primary = concat(local.dc_provision_prefix.primary, local.openssh_bundle)
    replica = concat(local.dc_provision_prefix.replica, local.openssh_bundle)
  }
}

source "proxmox-iso" "dc-primary" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_username
  password                 = var.proxmox_password
  insecure_skip_tls_verify = true

  node                 = var.proxmox_node
  vm_id                = 120
  vm_name              = "secretcon-dc1-heliumsupply-primary"
  template_description = "SecretCon 2026 DC1 (primary): heliumsupply.local forest root, Wazuh+Sysmon telemetry from boot."

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
    cd_files         = local.dc_provision_files.primary
    iso_storage_pool = "local"
    type             = "ide"
    index            = 3
    unmount          = true
  }

  disks {
    disk_size           = "60G"
    storage_pool        = local.proxmox_sata_disk_defaults.storage_pool
    type                = local.proxmox_sata_disk_defaults.type
    format              = local.proxmox_sata_disk_defaults.format
    cache_mode          = local.proxmox_sata_disk_defaults.cache_mode
    discard             = local.proxmox_sata_disk_defaults.discard
    exclude_from_backup = local.proxmox_sata_disk_defaults.exclude_from_backup
  }

  memory   = 4096
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
  ssh_host               = "192.168.61.20"
  ssh_username           = local.ssh_username
  ssh_password           = local.ssh_password
  ssh_private_key_file   = local.ssh_private_key_file
  ssh_timeout            = local.ssh_timeout
  ssh_handshake_attempts = local.ssh_handshake_attempts

  task_timeout = "45m"
}

source "proxmox-iso" "dc-replica" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_username
  password                 = var.proxmox_password
  insecure_skip_tls_verify = true

  node                 = var.proxmox_node
  vm_id                = 121
  vm_name              = "secretcon-dc2-heliumsupply-replica"
  template_description = "SecretCon 2026 DC2 (replica): heliumsupply.local additional DC, replicates from DC1."

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
    cd_files         = local.dc_provision_files.replica
    iso_storage_pool = "local"
    type             = "ide"
    index            = 3
    unmount          = true
  }

  disks {
    disk_size           = "60G"
    storage_pool        = local.proxmox_sata_disk_defaults.storage_pool
    type                = local.proxmox_sata_disk_defaults.type
    format              = local.proxmox_sata_disk_defaults.format
    cache_mode          = local.proxmox_sata_disk_defaults.cache_mode
    discard             = local.proxmox_sata_disk_defaults.discard
    exclude_from_backup = local.proxmox_sata_disk_defaults.exclude_from_backup
  }

  memory   = 4096
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
  ssh_host               = "192.168.61.21"
  ssh_username           = local.ssh_username
  ssh_password           = local.ssh_password
  ssh_private_key_file   = local.ssh_private_key_file
  ssh_timeout            = local.ssh_timeout
  ssh_handshake_attempts = local.ssh_handshake_attempts

  task_timeout = "45m"
}

build {
  name    = "proxmox-dc-primary"
  sources = ["source.proxmox-iso.dc-primary"]

  provisioner "powershell" {
    inline = [
      "Write-Host '[*] SSH connected. DC1 build reached provisioner stage.'",
      "Get-Service sshd | Format-List Name,Status,StartType"
    ]
  }

  provisioner "powershell" {
    script = "${local.repo_root}/provisioning/powershell/bootstrap_dc.ps1"
    environment_vars = [
      "DC_ROLE=primary",
      "AD_DOMAIN=${var.ad_domain}",
      "AD_NETBIOS=${var.ad_netbios}",
      "AD_SAFEMODE_PASSWORD=${var.ad_safemode_password}",
      "WAZUH_MANAGER=${var.wazuh_manager}",
      "WAZUH_AGENT_VERSION=${var.wazuh_agent_version}"
    ]
  }

  post-processor "shell-local" {
    inline = [
      "echo 'DC1 build complete. VM 120 is on ${var.build_bridge} at 192.168.61.20.'",
      "echo 'Next: deploy-dc.sh --dc1 will reset VM to trigger forest promotion scheduled task.'"
    ]
  }
}

build {
  name    = "proxmox-dc-replica"
  sources = ["source.proxmox-iso.dc-replica"]

  provisioner "powershell" {
    inline = [
      "Write-Host '[*] SSH connected. DC2 build reached provisioner stage.'",
      "Get-Service sshd | Format-List Name,Status,StartType"
    ]
  }

  provisioner "powershell" {
    script = "${local.repo_root}/provisioning/powershell/bootstrap_dc.ps1"
    environment_vars = [
      "DC_ROLE=replica",
      "AD_DOMAIN=${var.ad_domain}",
      "AD_NETBIOS=${var.ad_netbios}",
      "AD_SAFEMODE_PASSWORD=${var.ad_safemode_password}",
      "AD_ADMIN_PASSWORD=${var.ad_admin_password}",
      "REPLICA_SOURCE_DC=${var.replica_source_dc}",
      "WAZUH_MANAGER=${var.wazuh_manager}",
      "WAZUH_AGENT_VERSION=${var.wazuh_agent_version}"
    ]
  }

  post-processor "shell-local" {
    inline = [
      "echo 'DC2 build complete. VM 121 is on ${var.build_bridge} at 192.168.61.21.'",
      "echo 'Next: deploy-dc.sh --dc2 will reset VM to trigger replica promotion scheduled task.'"
    ]
  }
}

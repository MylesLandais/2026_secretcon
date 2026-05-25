packer {
  required_plugins {
    hyperv = {
      version = ">= 1.1.4"
      source  = "github.com/hashicorp/hyperv"
    }
  }
}

variable "cysvuln_hyperv_switch" {
  type    = string
  default = "Default Switch"
}

variable "cysvuln_provision_iso" {
  type        = string
  default     = ""
  description = "Path to a PROVISION ISO built via scripts/build-provision-iso.ps1. Hyper-V cannot consume cd_files directly."
}

locals {
  cysvuln_provision_iso = (
    var.cysvuln_provision_iso != ""
    ? var.cysvuln_provision_iso
    : "${path.root}/stubs/provision-validate.iso"
  )
}

source "hyperv-iso" "cysvuln-hyperv" {
  iso_url      = var.cysvuln_iso_url
  iso_checksum = var.cysvuln_iso_checksum

  output_directory = "output/cysvuln-hyperv"
  vm_name          = "cysvuln"

  generation                       = 1
  disk_size                        = 32768
  memory                           = 2048
  cpus                             = 1
  switch_name                      = var.cysvuln_hyperv_switch
  enable_secure_boot               = false
  enable_dynamic_memory            = false
  enable_virtualization_extensions = false

  floppy_files = [
    "${path.root}/../../../provisioning/cysvuln/autounattend.xml"
  ]

  secondary_iso_images = [
    local.cysvuln_provision_iso
  ]

  boot_wait = "3s"
  boot_command = [
    "<spacebar><spacebar>"
  ]

  communicator           = "ssh"
  ssh_username           = "packer"
  ssh_password           = "packer"
  ssh_private_key_file   = "${path.root}/../../../provisioning/ssh/packer_ed25519"
  ssh_timeout            = "30m"
  ssh_handshake_attempts = 1000

  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer Shutdown\""
  shutdown_timeout = "30m"
}

build {
  name    = "cysvuln-hyperv"
  sources = ["source.hyperv-iso.cysvuln-hyperv"]

  provisioner "powershell" {
    inline = [
      "Write-Host '[*] SSH connected. CysVulnServer (Hyper-V) build reached provisioner stage.'",
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
      "Get-LocalUser | Select-Object Name, Enabled"
    ]
  }
}

packer {
  required_plugins {
    hyperv = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/hyperv"
    }
  }
}

variable "iso_url" {
  type        = string
  description = "file:/// URL to the LTSC ISO. Build-SecretConEwsVhdx.ps1 passes this via -var-file."
}

variable "iso_checksum" {
  type    = string
  default = "sha256:c90a6df8997bf49e56b9673982f3e80745058723a707aef8f22998ae6479597d"
}

variable "hyperv_switch_name" {
  type        = string
  default     = "Default Switch"
  description = "Existing Hyper-V virtual switch (e.g. Default Switch)."
}

variable "secretcon_kasm_desktop" {
  type        = bool
  default     = false
  description = "If true, bootstrap installs Kasm Desktop Service (SHA-pinned) for Kasm Workspaces 1.18.x."
}

variable "kasm_api_host" {
  type        = string
  default     = ""
  description = "Kasm API / web hostname or IP (e.g. kasm.example.com). Leave empty to skip agent registration during bake."
}

variable "kasm_api_port" {
  type        = string
  default     = "443"
  description = "Kasm web/API port (use 8443 if install.sh -L 8443)."
}

variable "kasm_registration_token" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Per-server registration token from Kasm Admin (optional; prefer registering after clone)."
}

locals {
  ews_bootstrap_env = concat(
    ["WAZUH_MANAGER=10.0.2.2", format("SECRETCON_KASM_DESKTOP=%s", var.secretcon_kasm_desktop ? "1" : "0")],
    var.kasm_api_host != "" ? ["KASM_API_HOST=${var.kasm_api_host}"] : [],
    ["KASM_API_PORT=${var.kasm_api_port}"],
    var.kasm_registration_token != "" ? ["KASM_REGISTRATION_TOKEN=${var.kasm_registration_token}"] : []
  )
}

source "hyperv-iso" "win10-ews-hyperv" {
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  vm_name          = "win10-ews-hyperv"
  output_directory = "output/win10-ews-hyperv"

  switch_name = var.hyperv_switch_name
  generation  = 1
  cpus        = 4
  memory      = 8192
  disk_size   = 131072

  headless = true

  communicator           = "ssh"
  ssh_username           = "packer"
  ssh_password           = "packer"
  ssh_private_key_file   = "${path.root}/../../../provisioning/ssh/packer_ed25519"
  ssh_timeout            = "20m"
  ssh_handshake_attempts = 1000

  boot_wait = "3s"
  boot_command = [
    "<spacebar><spacebar>"
  ]

  floppy_files = [
    "${path.root}/../../../provisioning/local/autounattend.xml"
  ]

  cd_label = "PROVISION"
  cd_files = [
    "${path.root}/../../../provisioning/openssh/setup-openssh.ps1",
    "${path.root}/../../../provisioning/openssh/OpenSSH-Win64.zip",
    "${path.root}/../../../provisioning/tightvnc/tightvnc-2.8.87-gpl-setup-64bit.msi",
    "${path.root}/../../../provisioning/ssh/packer_ed25519.pub"
  ]

  http_directory = "${path.root}/../../../provisioning"
  http_port_min  = 8888
  http_port_max  = 8888

  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer Shutdown\""
  shutdown_timeout = "30m"

  skip_compaction = true
}

build {
  name    = "win10-ews-hyperv"
  sources = ["source.hyperv-iso.win10-ews-hyperv"]

  provisioner "powershell" {
    inline = [
      "Write-Host '[*] SSH connected. Win10 LTSC Hyper-V build reached provisioner stage.'",
      "Get-Service sshd | Format-List Name,Status,StartType"
    ]
  }

  provisioner "powershell" {
    script           = "${path.root}/../../../provisioning/powershell/bootstrap_win.ps1"
    environment_vars = local.ews_bootstrap_env
  }

  provisioner "powershell" {
    inline = [
      "Get-Service sshd, Sysmon64, WazuhSvc, tvnserver, SecretConEwsSync | Format-Table Name, Status, StartType",
      "Get-LocalUser | Select-Object Name, Enabled"
    ]
  }
}

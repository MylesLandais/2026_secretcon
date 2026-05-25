packer {
  required_plugins {
    vmware = {
      version = ">= 1.0.11"
      source  = "github.com/hashicorp/vmware"
    }
  }
}

variable "vmware_guest_os_type" {
  type        = string
  default     = "windows9-64"
  description = "VMware guest OS identifier. windows9-64 covers Windows 10/11 desktop SKUs on Workstation 16+ / Fusion 12+."
}

variable "vmware_hardware_version" {
  type        = number
  default     = 19
  description = "VMware virtual hardware version. 19 == Workstation 17 / Fusion 13; older hosts can drop to 18 or 17."
}

variable "vmware_ews_kasm_desktop" {
  type        = bool
  default     = false
  description = "If true, bootstrap installs Kasm Desktop Service (SHA-pinned) for Kasm Workspaces 1.18.x."
}

variable "vmware_ews_kasm_api_host" {
  type        = string
  default     = ""
  description = "Kasm API / web hostname or IP. Leave empty to skip agent registration during bake."
}

variable "vmware_ews_kasm_api_port" {
  type        = string
  default     = "443"
  description = "Kasm web/API port (use 8443 if install.sh -L 8443)."
}

variable "vmware_ews_kasm_registration_token" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Per-server registration token from Kasm Admin (optional; prefer registering after clone)."
}

locals {
  vmware_ews_bootstrap_env = concat(
    ["WAZUH_MANAGER=10.0.2.2", format("SECRETCON_KASM_DESKTOP=%s", var.vmware_ews_kasm_desktop ? "1" : "0")],
    var.vmware_ews_kasm_api_host != "" ? ["KASM_API_HOST=${var.vmware_ews_kasm_api_host}"] : [],
    ["KASM_API_PORT=${var.vmware_ews_kasm_api_port}"],
    var.vmware_ews_kasm_registration_token != "" ? ["KASM_REGISTRATION_TOKEN=${var.vmware_ews_kasm_registration_token}"] : []
  )
}

source "vmware-iso" "win10-ews-vmware" {
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  vm_name          = "win10-ews-vmware"
  output_directory = "output/win10-ews-vmware"

  guest_os_type = var.vmware_guest_os_type
  version       = var.vmware_hardware_version

  cpus      = 4
  cores     = 1
  memory    = 8192
  disk_size = 131072

  disk_type_id         = "0"
  disk_adapter_type    = "lsilogic"
  network_adapter_type = "e1000e"

  vmx_data = {
    "ethernet0.virtualDev"      = "e1000e"
    "ethernet0.connectionType"  = "nat"
    "RemoteDisplay.vnc.enabled" = "FALSE"
  }

  headless = true

  communicator           = "ssh"
  ssh_username           = local.ssh_username
  ssh_password           = local.ssh_password
  ssh_private_key_file   = local.ssh_private_key_file
  ssh_timeout            = "20m"
  ssh_handshake_attempts = local.ssh_handshake_attempts

  boot_wait    = local.boot_wait
  boot_command = local.boot_command_installer

  floppy_files = [local.qemu_autounattend]

  cd_label = "PROVISION"
  cd_files = local.qemu_provision_files

  http_directory = "${local.repo_root}/provisioning"
  http_port_min  = 8888
  http_port_max  = 8888

  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer Shutdown\""
  shutdown_timeout = "30m"

  skip_compaction = true
}

build {
  name    = "win10-ews-vmware"
  sources = ["source.vmware-iso.win10-ews-vmware"]

  provisioner "powershell" {
    inline = [
      "Write-Host '[*] SSH connected. Win10 LTSC VMware build reached provisioner stage.'",
      "Get-Service sshd | Format-List Name,Status,StartType"
    ]
  }

  provisioner "powershell" {
    script           = local.bootstrap_script
    environment_vars = local.vmware_ews_bootstrap_env
  }

  provisioner "powershell" {
    inline = [
      "Get-Service sshd, Sysmon64, WazuhSvc, tvnserver, SecretConEwsSync | Format-Table Name, Status, StartType",
      "Get-LocalUser | Select-Object Name, Enabled"
    ]
  }
}

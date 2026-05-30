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
    [
      "WAZUH_MANAGER=10.0.2.2",
      "SECRETCON_USER_FLAG=${var.secretcon_user_flag}",
      "SECRETCON_ROOT_FLAG=${var.secretcon_root_flag}",
      "SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD=${var.secretcon_shared_local_admin_password != "" ? var.secretcon_shared_local_admin_password : "PizzaMan123!"}",
      format("SECRETCON_KASM_DESKTOP=%s", var.secretcon_kasm_desktop ? "1" : "0"),
    ],
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
  name    = "win10-ews-hyperv"
  sources = ["source.hyperv-iso.win10-ews-hyperv"]

  provisioner "powershell" {
    inline = [
      "Write-Host '[*] SSH connected. Win10 LTSC Hyper-V build reached provisioner stage.'",
      "Get-Service sshd | Format-List Name,Status,StartType"
    ]
  }

  provisioner "powershell" {
    script           = local.bootstrap_script
    environment_vars = local.ews_bootstrap_env
  }

  provisioner "ansible" {
    playbook_file      = local.ansible_playbook
    ansible_env_vars   = concat(local.ews_bootstrap_env, ["ANSIBLE_CONFIG=${local.ansible_cfg}"])
    inventory_file_template = local.ansible_inventory_template
    inventory_directory     = "${local.repo_root}/ansible/inventory"
    user               = local.ssh_username
    use_proxy          = false
    extra_arguments = [
      "--extra-vars",
      "ansible_shell_type=powershell wazuh_manager=10.0.2.2 secretcon_packer_build=true",
    ]
  }

  provisioner "powershell" {
    inline = [
      "Get-Service sshd, Sysmon64, WazuhSvc, tvnserver, SecretConEwsSync | Format-Table Name, Status, StartType",
      "Get-LocalUser | Select-Object Name, Enabled"
    ]
  }
}

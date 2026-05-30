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
  qemu_agent      = true
  scsi_controller = "virtio-scsi-single"

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
    disk_size           = "128G"
    storage_pool        = "local-lvm"
    type                = "sata"
    format              = "raw"
    cache_mode          = "writeback"
    discard             = true
    exclude_from_backup = true
  }

  memory   = 8192
  cores    = 4
  cpu_type = "host"

  network_adapters {
    bridge   = var.build_bridge
    model    = "e1000"
    firewall = true
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
    script           = local.bootstrap_script
    environment_vars = local.proxmox_bootstrap_env
  }

  provisioner "ansible" {
    playbook_file      = local.ansible_playbook
    ansible_env_vars   = concat(local.proxmox_bootstrap_env, ["ANSIBLE_CONFIG=${local.ansible_cfg}"])
    inventory_file_template = local.ansible_inventory_template
    inventory_directory     = "${local.repo_root}/ansible/inventory"
    user               = local.ssh_username
    use_proxy          = false
    extra_arguments = [
      "--extra-vars",
      "ansible_shell_type=powershell wazuh_manager=192.168.61.10 secretcon_packer_build=true",
    ]
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

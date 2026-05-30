variable "virtio_iso" {
  type    = string
  default = "file:///home/warby/Downloads/virtio-win.iso"
}

source "qemu" "win10-ews-local" {
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  output_directory = "output/win10-ews-local"
  vm_name          = "win10-ews-local.qcow2"
  format           = "qcow2"

  accelerator  = "kvm"
  machine_type = "q35"
  headless     = true
  cpus         = 4
  memory       = 8192

  disk_size      = "128G"
  disk_interface = "ide"

  net_device             = "e1000e"
  communicator           = "ssh"
  ssh_username           = local.ssh_username
  ssh_password           = local.ssh_password
  ssh_private_key_file   = local.ssh_private_key_file
  ssh_timeout            = "20m"
  ssh_handshake_attempts = local.ssh_handshake_attempts
  skip_compaction        = true

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

  qemuargs = [
    ["-monitor", "unix:/tmp/win10-mon.sock,server,nowait"]
  ]
}

build {
  name    = "win10-ews-local"
  sources = ["source.qemu.win10-ews-local"]

  provisioner "powershell" {
    inline = [
      "Write-Host '[*] SSH connected. Win10 LTSC build reached provisioner stage.'",
      "Get-Service sshd | Format-List Name,Status,StartType"
    ]
  }

  provisioner "powershell" {
    script           = local.bootstrap_script
    environment_vars = local.qemu_bootstrap_env
  }

  provisioner "ansible" {
    playbook_file      = local.ansible_playbook
    ansible_env_vars   = concat(local.qemu_bootstrap_env, ["ANSIBLE_CONFIG=${local.ansible_cfg}"])
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

packer {
  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

source "qemu" "cysvuln-local" {
  iso_url      = var.cysvuln_iso_url
  iso_checksum = var.cysvuln_iso_checksum

  output_directory = "output/cysvuln-local"
  vm_name          = "cysvuln.qcow2"
  format           = "qcow2"

  accelerator  = "kvm"
  machine_type = "pc"
  headless     = true
  cpus         = 1
  memory       = 2048

  disk_size      = "32G"
  disk_interface = "ide"

  net_device             = "e1000"
  communicator           = "ssh"
  ssh_username           = "packer"
  ssh_password           = "packer"
  ssh_private_key_file   = "${path.root}/../../../provisioning/ssh/packer_ed25519"
  ssh_timeout            = "30m"
  ssh_handshake_attempts = 1000
  skip_compaction        = true

  boot_wait = "3s"
  boot_command = [
    "<spacebar><spacebar>"
  ]

  floppy_files = [
    "${path.root}/../../../provisioning/cysvuln/autounattend.xml"
  ]

  cd_label = "PROVISION"
  cd_files = local.provision_files

  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer Shutdown\""
  shutdown_timeout = "30m"
}

build {
  name    = "cysvuln-local"
  sources = ["source.qemu.cysvuln-local"]

  provisioner "powershell" {
    inline = [
      "Write-Host '[*] SSH connected. CysVulnServer (qemu) build reached provisioner stage.'",
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
      "Get-LocalUser | Select-Object Name, Enabled",
      "Get-CimInstance Win32_Service -Filter \"Name='fswsService'\" | Select-Object Name, StartName, State"
    ]
  }
}

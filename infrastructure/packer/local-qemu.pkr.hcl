packer {
  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "iso_url" {
  type    = string
  default = "file:///home/warby/Downloads/en-us_windows_10_enterprise_ltsc_2021_x64_dvd_d289cf96.iso"
}

variable "iso_checksum" {
  type    = string
  default = "sha256:c90a6df8997bf49e56b9673982f3e80745058723a707aef8f22998ae6479597d"
}

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
  ssh_username           = "packer"
  ssh_password           = "packer"
  ssh_private_key_file   = "${path.root}/../../provisioning/ssh/packer_ed25519"
  ssh_timeout            = "20m"
  ssh_handshake_attempts = 1000
  skip_compaction        = true

  boot_wait = "3s"
  boot_command = [
    "<spacebar><spacebar>"
  ]

  floppy_files = [
    "${path.root}/../../provisioning/local/autounattend.xml"
  ]

  cd_label = "PROVISION"
  cd_files = [
    "${path.root}/../../provisioning/openssh/setup-openssh.ps1",
    "${path.root}/../../provisioning/openssh/OpenSSH-Win64.zip",
    "${path.root}/../../provisioning/tightvnc/tightvnc-2.8.87-gpl-setup-64bit.msi",
    "${path.root}/../../provisioning/ssh/packer_ed25519.pub"
  ]

  http_directory = "${path.root}/../../provisioning"
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
    script           = "${path.root}/../../provisioning/powershell/bootstrap_win.ps1"
    environment_vars = ["WAZUH_MANAGER=10.0.2.2"]
  }

  provisioner "powershell" {
    inline = [
      "Get-Service sshd, Sysmon64, WazuhSvc, tvnserver, SecretConEwsSync | Format-Table Name, Status, StartType",
      "Get-LocalUser | Select-Object Name, Enabled"
    ]
  }
}

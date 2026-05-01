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
  default = "file:///home/warby/Downloads/26100.1742.240906-0331.ge_release_svc_refresh_CLIENT_LTSC_EVAL_x64FRE_en-us.iso"
}

variable "iso_checksum" {
  type    = string
  default = "none"
}

variable "virtio_iso" {
  type    = string
  default = "file:///home/warby/Downloads/virtio-win.iso"
}

source "qemu" "win11-ews-local" {
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  output_directory = "output/win11-ews-local"
  vm_name          = "win11-ews-local.qcow2"
  format           = "qcow2"

  accelerator  = "kvm"
  machine_type = "q35"
  headless     = true
  cpus         = 4
  memory       = 8192

  disk_size    = "80G"
  disk_interface = "ide"

  net_device     = "e1000e"
  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_password = "packer"
  winrm_insecure = true
  winrm_use_ssl  = false
  winrm_timeout  = "60m"

  boot_wait = "5s"
  boot_command = [
    "<enter>"
  ]

  floppy_files = [
    "${path.root}/../../provisioning/autounattend.xml"
  ]

  http_directory = "${path.root}/../../provisioning"

  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer Shutdown\""
  shutdown_timeout = "30m"
}

build {
  name = "win11-ews-local"
  sources = ["source.qemu.win11-ews-local"]

  provisioner "powershell" {
    script = "${path.root}/../../provisioning/powershell/bootstrap_win.ps1"
  }

  provisioner "windows-restart" {}

  provisioner "powershell" {
    inline = [
      "Write-Host '[*] Local EWS build complete'",
      "Get-LocalUser | Select-Object Name,Enabled"
    ]
  }
}

packer {
  required_plugins {
    vmware = {
      version = ">= 1.0.11"
      source  = "github.com/hashicorp/vmware"
    }
  }
}

source "vmware-iso" "cysvuln-vmware" {
  iso_url      = var.cysvuln_iso_url
  iso_checksum = var.cysvuln_iso_checksum

  output_directory = "output/cysvuln-vmware"
  vm_name          = "cysvuln"

  guest_os_type = "windows9srv-64"
  version       = 19

  disk_size            = 32768
  disk_type_id         = "0"
  disk_adapter_type    = "lsilogic"
  network_adapter_type = "e1000"
  cpus                 = 1
  cores                = 1
  memory               = 2048

  vmx_data = {
    "ethernet0.virtualDev"      = "e1000"
    "ethernet0.connectionType"  = "nat"
    "RemoteDisplay.vnc.enabled" = "FALSE"
  }

  floppy_files = local.provision_files

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
  name    = "cysvuln-vmware"
  sources = ["source.vmware-iso.cysvuln-vmware"]

  provisioner "powershell" {
    inline = [
      "Write-Host '[*] SSH connected. CysVulnServer (VMware) build reached provisioner stage.'",
      "Get-Service sshd | Format-List Name,Status,StartType"
    ]
  }

  provisioner "powershell" {
    script           = local.bootstrap_script
    environment_vars = concat(local.bootstrap_env, ["WAZUH_ENROLLMENT_OPTIONAL=1"])
  }

  provisioner "powershell" {
    inline = [
      "Get-Service sshd, Sysmon64, WazuhSvc, fswsService | Format-Table Name, Status, StartType",
      "Get-LocalUser | Select-Object Name, Enabled"
    ]
  }
}

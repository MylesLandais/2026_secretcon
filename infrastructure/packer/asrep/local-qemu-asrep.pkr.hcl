packer {
  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

source "qemu" "asrep-local" {
  iso_url      = var.asrep_iso_url
  iso_checksum = var.asrep_iso_checksum

  output_directory = "${path.root}/packer-output/asrep-local"
  vm_name          = "asrep.qcow2"
  format           = "qcow2"

  accelerator  = "kvm"
  machine_type = "pc"
  headless     = true
  cpus         = 4
  memory       = 4096

  disk_size      = "40G"
  disk_interface = "ide"

  net_device             = "e1000"
  communicator           = "ssh"
  ssh_username           = "Administrator"
  ssh_password           = "PizzaMan123!"
  ssh_private_key_file   = "${path.root}/../../../provisioning/ssh/packer_ed25519"
  ssh_timeout            = "120m"
  ssh_handshake_attempts = 1000
  skip_compaction        = true

  boot_wait = "3s"
  boot_command = [
    "<spacebar><spacebar>"
  ]

  floppy_files = [
    "${path.root}/../../../provisioning/asrep/autounattend.xml"
  ]

  cd_label = "PROVISION"
  cd_files = local.provision_files

  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer Shutdown\""
  shutdown_timeout = "30m"
}

build {
  name    = "asrep-local"
  sources = ["source.qemu.asrep-local"]

  provisioner "powershell" {
    inline = [
      "Write-Host '[*] SSH connected. ASREP demo DC (qemu) build reached provisioner stage.'",
      "Get-Service sshd | Format-List Name,Status,StartType"
    ]
  }

  provisioner "powershell" {
    script           = local.bootstrap_script
    environment_vars = concat(local.bootstrap_env, ["WAZUH_ENROLLMENT_OPTIONAL=1"])
  }

  provisioner "windows-restart" {
    restart_timeout = "45m"
  }

  provisioner "powershell" {
    inline = [
      "Write-Host '[*] Running ASREP bootstrap pass 1 (forest promotion if needed)'",
      "$env:SECRETCON_ASREP_PACKER = '1'",
      "$env:AD_DOMAIN = '${var.ad_domain}'",
      "$env:AD_NETBIOS = '${var.ad_netbios}'",
      "$env:AD_SAFEMODE_PASSWORD = '${var.ad_safemode_password}'",
      "$env:SECRETCON_ASREP_USER = '${var.asrep_user}'",
      "$env:SECRETCON_ASREP_PASSWORD = '${var.asrep_password}'",
      "$env:SECRETCON_ASREP_FLAG = '${var.asrep_flag}'",
      "$env:SECRETCON_DC_USER_FLAG = '${local.dc_user_flag_resolved}'",
      "$env:SECRETCON_DC_ROOT_FLAG = '${var.dc_root_flag}'",
      "$env:SECRETCON_ASREP_ENITE_DA = '${local.enite_da_resolved}'",
      "& C:\\secretcon\\asrep-bootstrap.ps1"
    ]
  }

  provisioner "windows-restart" {
    restart_timeout = "45m"
  }

  provisioner "powershell" {
    inline = [
      "Write-Host '[*] Running ASREP bootstrap pass 2 (domain seed)'",
      "$env:SECRETCON_ASREP_PACKER = '1'",
      "$env:AD_DOMAIN = '${var.ad_domain}'",
      "$env:AD_NETBIOS = '${var.ad_netbios}'",
      "$env:AD_SAFEMODE_PASSWORD = '${var.ad_safemode_password}'",
      "$env:SECRETCON_ASREP_USER = '${var.asrep_user}'",
      "$env:SECRETCON_ASREP_PASSWORD = '${var.asrep_password}'",
      "$env:SECRETCON_ASREP_FLAG = '${var.asrep_flag}'",
      "$env:SECRETCON_DC_USER_FLAG = '${local.dc_user_flag_resolved}'",
      "$env:SECRETCON_DC_ROOT_FLAG = '${var.dc_root_flag}'",
      "$env:SECRETCON_ASREP_ENITE_DA = '${local.enite_da_resolved}'",
      "& C:\\secretcon\\asrep-bootstrap.ps1"
    ]
  }

  provisioner "powershell" {
    script = "${local.repo_root}/provisioning/asrep/verify-post-promote.ps1"
    environment_vars = [
      "AD_DOMAIN=${var.ad_domain}",
      "SECRETCON_ASREP_USER=${var.asrep_user}",
      "SECRETCON_ASREP_FLAG=${var.asrep_flag}",
    ]
  }

  provisioner "powershell" {
    inline = [
      "Get-Service sshd, Sysmon64, WazuhSvc | Format-Table Name, Status, StartType",
      "Get-ADDomain | Select-Object DNSRoot, DomainMode, ForestMode",
      "Get-ADUser -Identity $env:SECRETCON_ASREP_USER -Properties DoesNotRequirePreAuth,KerberosEncryptionType | Format-List"
    ]
  }

  post-processor "shell-local" {
    inline = [
      "echo '========================================'",
      "echo '  ASREP Demo DC Build Complete'",
      "echo '========================================'",
      "echo ''",
      "echo '  Post-build: ./scripts/run-local-asrep.sh'",
      "echo '              ./scripts/validate-asrep.sh 127.0.0.1'",
      "echo ''",
      "echo '  Output: ${path.root}/packer-output/asrep-local/asrep.qcow2'",
      "echo '========================================'"
    ]
  }
}

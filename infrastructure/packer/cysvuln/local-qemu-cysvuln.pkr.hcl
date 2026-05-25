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

  output_directory = "${path.root}/packer-output/cysvuln-local"
  vm_name          = "cysvuln.qcow2"
  format           = "qcow2"

  accelerator  = "kvm"
  machine_type = "pc"
  headless     = true
  cpus         = 4
  memory       = 4096

  disk_size      = "32G"
  disk_interface = "ide"

  net_device             = "e1000"
  communicator           = "ssh"
  ssh_username           = "Administrator"
  ssh_password           = "PizzaMan123!"
  ssh_private_key_file   = "${path.root}/../../../provisioning/ssh/packer_ed25519"
  ssh_timeout            = "90m"
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
    environment_vars = concat(local.bootstrap_env, ["WAZUH_ENROLLMENT_OPTIONAL=1"])
  }

  provisioner "powershell" {
    inline = [
      "Get-Service sshd, Sysmon64, WazuhSvc, fswsService | Format-Table Name, Status, StartType",
      "Get-LocalUser | Select-Object Name, Enabled",
      "Get-CimInstance Win32_Service -Filter \"Name='fswsService'\" | Select-Object Name, StartName, State"
    ]
  }

  provisioner "powershell" {
    inline = [
      "# Final flag verification — read both flags and confirm non-placeholder",
      "$userFlagPath = 'C:\\Users\\User_Joe\\Desktop\\user.txt'",
      "$rootFlagPath = 'C:\\Users\\Administrator\\Desktop\\root.txt'",
      "",
      "$userFlag = Get-Content $userFlagPath -Raw -ErrorAction SilentlyContinue",
      "$rootFlag = Get-Content $rootFlagPath -Raw -ErrorAction SilentlyContinue",
      "",
      "if ($userFlag -and $userFlag.Trim().Length -gt 0) {",
      "  $userHash = (Get-FileHash -Algorithm SHA256 -Path $userFlagPath).Hash",
      "  Write-Host \"[+] User flag present (SHA256: $userHash)\"",
      "} else {",
      "  throw 'User flag missing or empty'",
      "}",
      "",
      "if ($rootFlag -and $rootFlag.Trim().Length -gt 0) {",
      "  $rootHash = (Get-FileHash -Algorithm SHA256 -Path $rootFlagPath).Hash",
      "  Write-Host \"[+] Root flag present (SHA256: $rootHash)\"",
      "} else {",
      "  throw 'Root flag missing or empty'",
      "}",
      "",
      "if ($userFlag -eq 'cysvuln-user-flag-placeholder') {",
      "  Write-Warning 'User flag is the default placeholder - did you set SECRETCON_USER_FLAG?'",
      "}",
      "if ($rootFlag -eq 'cysvuln-root-flag-placeholder') {",
      "  Write-Warning 'Root flag is the default placeholder - did you set SECRETCON_ROOT_FLAG?'",
      "}",
      "",
      "Write-Host '[+] All flags present and readable'"
    ]
  }

  post-processor "shell-local" {
    inline = [
      "echo '========================================'",
      "echo '  CysVulnServer Build Complete'",
      "echo '========================================'",
      "echo ''",
      "echo '  Post-build: run scripts/validate-cysvuln-chain.sh for AIE proof'",
      "echo '  Flags: both present and readable'",
      "echo '  Defender: disabled (GPO + service)'",
      "echo '  AppLocker/SRP: not active'",
      "echo ''",
      "echo '  Output: ${path.root}/packer-output/cysvuln-local/cysvuln.qcow2'",
      "echo '========================================'"
    ]
  }
}

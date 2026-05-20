variable "cysvuln_iso_url" {
  type    = string
  default = ""
}

variable "cysvuln_iso_checksum" {
  type    = string
  default = "none"
}

variable "cysvuln_wazuh_manager" {
  type    = string
  default = "192.168.61.10"
}

variable "secretcon_user_flag" {
  type    = string
  default = env("SECRETCON_USER_FLAG")
}

variable "secretcon_root_flag" {
  type    = string
  default = env("SECRETCON_ROOT_FLAG")
}

locals {
  repo_root = "${path.root}/../../.."

  provision_files = [
    "${path.root}/../../../provisioning/cysvuln/autounattend.xml",
    "${path.root}/../../../provisioning/openssh/setup-openssh.ps1",
    "${path.root}/../../../provisioning/openssh/OpenSSH-Win64.zip",
    "${path.root}/../../../provisioning/ssh/packer_ed25519.pub",
    "${path.root}/../../../infrastructure/artifacts/cysvuln/60f3ff1f3cd34dec80fba130ea481f31-efssetup.exe",
    "${path.root}/../../../infrastructure/artifacts/cysvuln/joe-notes.txt",
    "${path.root}/../../../infrastructure/artifacts/cysvuln/admin-notes.txt",
    "${path.root}/../../../infrastructure/artifacts/cysvuln/option.ini"
  ]

  bootstrap_script = "${path.root}/../../../provisioning/powershell/bootstrap_cysvuln.ps1"

  bootstrap_env = [
    "WAZUH_MANAGER=${var.cysvuln_wazuh_manager}",
    "SECRETCON_USER_FLAG=${var.secretcon_user_flag}",
    "SECRETCON_ROOT_FLAG=${var.secretcon_root_flag}"
  ]
}

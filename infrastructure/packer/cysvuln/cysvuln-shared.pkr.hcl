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

  _cysvuln_lines = compact([
    for line in split("\n", file("${path.root}/provision-manifest-cysvuln.txt")) :
    trimspace(line)
    if length(trimspace(line)) > 0 && !startswith(trimspace(line), "#")
  ])
  _shared_lines = compact([
    for line in split("\n", file("${path.root}/provision-manifest-shared.txt")) :
    trimspace(line)
    if length(trimspace(line)) > 0 && !startswith(trimspace(line), "#")
  ])

  provision_files = [
    for p in concat(local._cysvuln_lines, local._shared_lines) :
    "${local.repo_root}/${p}"
  ]

  bootstrap_script = "${local.repo_root}/provisioning/powershell/bootstrap_cysvuln.ps1"

  bootstrap_env = [
    "WAZUH_MANAGER=${var.cysvuln_wazuh_manager}",
    "SECRETCON_USER_FLAG=${var.secretcon_user_flag}",
    "SECRETCON_ROOT_FLAG=${var.secretcon_root_flag}"
  ]
}

variable "asrep_iso_url" {
  type    = string
  default = ""
}

variable "asrep_iso_checksum" {
  type    = string
  default = "none"
}

variable "asrep_wazuh_manager" {
  type    = string
  default = "10.0.3.2"
}

variable "ad_domain" {
  type    = string
  default = "secretcon.local"
}

variable "ad_netbios" {
  type    = string
  default = "SECRETCON"
}

variable "ad_safemode_password" {
  type      = string
  default   = env("AD_SAFEMODE_PASSWORD")
  sensitive = true
}

variable "asrep_user" {
  type    = string
  default = env("SECRETCON_ASREP_USER")
}

variable "asrep_password" {
  type      = string
  default   = env("SECRETCON_ASREP_PASSWORD")
  sensitive = true
}

variable "asrep_flag" {
  type    = string
  default = env("SECRETCON_ASREP_FLAG")
}

variable "dc_user_flag" {
  type    = string
  default = env("SECRETCON_DC_USER_FLAG")
}

variable "dc_root_flag" {
  type    = string
  default = "asrep-root-flag-placeholder"
}

variable "asrep_enite_da" {
  type    = string
  default = env("SECRETCON_ASREP_ENITE_DA")
}

locals {
  repo_root = "${path.root}/../../.."

  _asrep_lines = compact([
    for line in split("\n", file("${path.root}/provision-manifest-asrep.txt")) :
    trimspace(line)
    if length(trimspace(line)) > 0 && !startswith(trimspace(line), "#")
  ])
  _shared_lines = compact([
    for line in split("\n", file("${path.root}/provision-manifest-shared.txt")) :
    trimspace(line)
    if length(trimspace(line)) > 0 && !startswith(trimspace(line), "#")
  ])

  provision_files = [
    for p in concat(local._asrep_lines, local._shared_lines) :
    "${local.repo_root}/${p}"
  ]

  bootstrap_script = "${local.repo_root}/provisioning/powershell/bootstrap_asrep.ps1"

  dc_user_flag_resolved = var.dc_user_flag != "" ? var.dc_user_flag : var.asrep_flag
  enite_da_resolved     = var.asrep_enite_da != "" ? var.asrep_enite_da : "1"

  bootstrap_env = [
    "WAZUH_MANAGER=${var.asrep_wazuh_manager}",
    "AD_DOMAIN=${var.ad_domain}",
    "AD_NETBIOS=${var.ad_netbios}",
    "AD_SAFEMODE_PASSWORD=${var.ad_safemode_password}",
    "SECRETCON_ASREP_USER=${var.asrep_user}",
    "SECRETCON_ASREP_PASSWORD=${var.asrep_password}",
    "SECRETCON_ASREP_FLAG=${var.asrep_flag}",
    "SECRETCON_DC_USER_FLAG=${local.dc_user_flag_resolved}",
    "SECRETCON_DC_ROOT_FLAG=${var.dc_root_flag}",
    "SECRETCON_ASREP_ENITE_DA=${local.enite_da_resolved}",
  ]
}

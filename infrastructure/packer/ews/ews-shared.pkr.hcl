# Shared locals and variables for all EWS Packer recipes in this directory.

variable "iso_url" {
  type    = string
  default = "file:///home/warby/Downloads/en-us_windows_10_enterprise_ltsc_2021_x64_dvd_d289cf96.iso"
}

variable "iso_checksum" {
  type    = string
  default = "sha256:c90a6df8997bf49e56b9673982f3e80745058723a707aef8f22998ae6479597d"
}

variable "secretcon_user_flag" {
  type    = string
  default = env("SECRETCON_USER_FLAG")
}

variable "secretcon_root_flag" {
  type    = string
  default = env("SECRETCON_ROOT_FLAG")
}

variable "secretcon_shared_local_admin_password" {
  type      = string
  default   = env("SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD")
  sensitive = true
}

locals {
  repo_root = "${path.root}/../../.."

  _qemu_manifest_lines = compact([
    for line in split("\n", file("${path.root}/provision-manifest-qemu.txt")) :
    trimspace(line)
    if length(trimspace(line)) > 0 && !startswith(trimspace(line), "#")
  ])
  qemu_provision_files = [
    for p in local._qemu_manifest_lines :
    "${local.repo_root}/${p}"
  ]

  _proxmox_manifest_lines = compact([
    for line in split("\n", file("${path.root}/provision-manifest-proxmox.txt")) :
    trimspace(line)
    if length(trimspace(line)) > 0 && !startswith(trimspace(line), "#")
  ])
  proxmox_provision_files = [
    for p in local._proxmox_manifest_lines :
    "${local.repo_root}/${p}"
  ]

  qemu_autounattend = "${local.repo_root}/provisioning/local/autounattend.xml"
  bootstrap_script  = "${local.repo_root}/provisioning/powershell/bootstrap_win.ps1"

  qemu_bootstrap_env = [
    "WAZUH_MANAGER=10.0.2.2",
    "SECRETCON_USER_FLAG=${var.secretcon_user_flag}",
    "SECRETCON_ROOT_FLAG=${var.secretcon_root_flag}",
    "SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD=${var.secretcon_shared_local_admin_password != "" ? var.secretcon_shared_local_admin_password : "PizzaMan123!"}",
    "WAZUH_AGENT_ENROLLMENT_OPTIONAL=true",
  ]

  proxmox_bootstrap_env = [
    "WAZUH_MANAGER=192.168.61.10",
    "SECRETCON_USER_FLAG=${var.secretcon_user_flag}",
    "SECRETCON_ROOT_FLAG=${var.secretcon_root_flag}",
    "SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD=${var.secretcon_shared_local_admin_password != "" ? var.secretcon_shared_local_admin_password : "PizzaMan123!"}",
  ]

  ansible_playbook = "${local.repo_root}/ansible/playbooks/ews.yml"
  ansible_cfg      = "${local.repo_root}/ansible/ansible.cfg"
  ansible_inventory_template = <<-EOT
[ews]
packer-build ansible_host={{ .Host }} ansible_user={{ .User }} ansible_password={{ .Password }} ansible_connection=ssh ansible_port={{ .Port }} ansible_shell_type=powershell ansible_become_method=runas
EOT
}

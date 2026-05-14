variable "wazuh_vm_id" {
  type    = number
  default = 110
}

variable "wazuh_vm_name" {
  type    = string
  default = "wazuh-siem"
}

variable "ubuntu_iso_file" {
  type    = string
  default = "local:iso/ubuntu-22.04.5-live-server-amd64.iso"
}

variable "wazuh_bridge" {
  type    = string
  default = "vmbr1"
}

source "proxmox-iso" "wazuh-ubuntu" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_username
  password                 = var.proxmox_password
  insecure_skip_tls_verify = true

  node                 = var.proxmox_node
  vm_id                = var.wazuh_vm_id
  vm_name              = var.wazuh_vm_name
  template_description = "SecretCon 2026 Wazuh SIEM (manager + indexer + dashboard, all-in-one)."

  os              = "l26"
  machine         = "q35"
  bios            = "seabios"
  qemu_agent      = true
  scsi_controller = "virtio-scsi-single"

  boot_iso {
    iso_file = var.ubuntu_iso_file
    type     = "ide"
    index    = 2
    unmount  = true
  }

  cloud_init              = false
  http_directory          = "${path.root}/../../provisioning/cloud-init/wazuh"
  http_port_min           = 8800
  http_port_max           = 8900

  disks {
    disk_size    = "100G"
    storage_pool = "local-lvm"
    type         = "scsi"
    format       = "raw"
    discard      = true
    ssd          = true
  }

  memory   = 8192
  cores    = 4
  cpu_type = "host"

  network_adapters {
    bridge   = var.wazuh_bridge
    model    = "virtio"
    firewall = true
  }

  boot_wait = "5s"
  boot_command = [
    "c<wait>",
    "linux /casper/vmlinuz autoinstall ds=nocloud-net;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ ---<enter><wait>",
    "initrd /casper/initrd<enter><wait>",
    "boot<enter>"
  ]

  communicator           = "ssh"
  ssh_username           = "dadmin"
  ssh_private_key_file   = "${path.root}/../../provisioning/ssh/packer_ed25519"
  ssh_timeout            = "45m"
  ssh_handshake_attempts = 1000

  task_timeout = "45m"
}

build {
  name    = "proxmox-wazuh-ubuntu"
  sources = ["source.proxmox-iso.wazuh-ubuntu"]

  provisioner "shell" {
    inline = [
      "echo '[*] SSH connected. Ubuntu autoinstall reached provisioner stage.'",
      "lsb_release -a",
      "ip -4 addr show"
    ]
  }

  provisioner "shell" {
    script          = "${path.root}/../../provisioning/bash/bootstrap-wazuh-ubuntu.sh"
    execute_command = "sudo -E bash '{{ .Path }}'"
  }

  provisioner "shell" {
    inline = [
      "systemctl --no-pager status wazuh-manager wazuh-indexer wazuh-dashboard | head -n 40",
      "ss -tlnp | grep -E ':(1514|1515|55000|443|9200)\\b' || true"
    ]
  }
}

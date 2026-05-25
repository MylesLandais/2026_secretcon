# Optional Packer variable overrides. Copy and pass: packer build -var-file=local.pkrvars.hcl ...
# Real secrets belong in .env, not in committed pkrvars files.

cysvuln_iso_url          = "file:///path/to/windows-server-2016.iso"
cysvuln_iso_checksum     = "none"
cysvuln_wazuh_manager    = "192.168.61.10"
cysvuln_provision_iso    = "infrastructure/packer/cysvuln/provision.iso"
cysvuln_hyperv_switch    = "Default Switch"

proxmox_url      = "https://192.168.60.1:8006/api2/json"
proxmox_username = "root@pam"
# proxmox_password — set via env PROXMOX_PASSWORD, not in this file

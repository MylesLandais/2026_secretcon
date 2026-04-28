packer {
  required_plugins {
    amazon = {
      version = ">= 1.2.8"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

source "amazon-ebs" "win11-ews" {
  ami_name      = "win11-ews-secretcon-{{timestamp}}"
  instance_type = "t3.xlarge"
  region        = var.aws_region

  source_ami_filter {
    filters = {
      name                = "Windows_Server-2022-English-Full-Base-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["801119661308"]
  }

  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_use_ssl  = true
  winrm_insecure = true
  winrm_timeout  = "15m"

  user_data_file = "${path.root}/../../provisioning/powershell/aws_bootstrap.ps1"
}

build {
  name    = "win11-ews-aws"
  sources = ["source.amazon-ebs.win11-ews"]

  provisioner "powershell" {
    script = "${path.root}/../../provisioning/powershell/bootstrap_win.ps1"
  }

  provisioner "windows-restart" {}
}

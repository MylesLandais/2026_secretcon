{ config, pkgs, ... }:

{
  # Enable KVM + QEMU for local Windows VM testing
  boot.kernelModules = [ "kvm-amd" "kvm-intel" ];
  boot.extraModprobeConfig = "options kvm ignore_msrs=1";

  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu_kvm;
      ovmf.enable = true;
      ovmf.packages = [ pkgs.OVMFFull.fd ];
    };
  };

  virtualisation.docker.enable = true;

  # Quick local QEMU runs without libvirt
  environment.systemPackages = with pkgs; [
    qemu_kvm
    qemu
    packer
    virtiofsd
  ];

  users.users.warby.extraGroups = [ "libvirtd" "docker" "kvm" ];

  # Optional: dockur/windows rapid test container
  virtualisation.oci-containers.containers = {
    win11-test = {
      image = "dockurr/windows";
      autoStart = false;
      ports = [ "8006:8006" "3389:3389/tcp" "3389:3389/udp" ];
      environment = {
        VERSION = "win11";
        RAM_SIZE = "8G";
        CPU_CORES = "4";
      };
      volumes = [
        "/var/lib/windows-test:/storage"
      ];
      extraOptions = [
        "--device=/dev/kvm"
        "--cap-add=NET_ADMIN"
      ];
    };
  };
}

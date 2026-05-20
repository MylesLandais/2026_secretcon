{
  description = "2026 SecretCon CTF Infrastructure";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            packer
            terraform
            jq
            sops
            age
            git
            openssl
            qemu
            xorriso
            cdrkit
            msitools
            pkgsCross.mingwW64.buildPackages.gcc
          ];

          shellHook = ''
            echo "[secretcon] dev shell active"
            if [ ! -f .env ] || [ ! -s .env ]; then
              echo "[warn] .env missing or empty — secrets not loaded"
            fi
          '';
        };

        packages.win10-ews-local = pkgs.stdenv.mkDerivation {
          name = "win10-ews-local";
          src = ./infrastructure/packer;
          nativeBuildInputs = [ pkgs.packer pkgs.qemu ];

          buildPhase = ''
            export HOME=$(mktemp -d)
            export PACKER_LOG=1
            packer init .
            packer build -only=qemu.win10-ews-local .
          '';

          installPhase = ''
            mkdir -p $out
            cp -r output/win10-ews-local/*.qcow2 $out/
          '';
        };

        packages.win10-ews-proxmox = pkgs.stdenv.mkDerivation {
          name = "win10-ews-proxmox";
          src = ./infrastructure/packer;
          nativeBuildInputs = [ pkgs.packer ];

          buildPhase = ''
            export HOME=$(mktemp -d)
            export PACKER_LOG=1
            packer init .
            packer build -only=proxmox-iso.win10-ews .
          '';

          installPhase = ''
            mkdir -p $out
            cp -r output-* $out/ || true
          '';
        };

        packages.cysvuln-local = pkgs.stdenv.mkDerivation {
          name = "cysvuln-local";
          src = ./.;
          nativeBuildInputs = [ pkgs.packer pkgs.qemu ];

          buildPhase = ''
            export HOME=$(mktemp -d)
            export PACKER_LOG=1
            cd infrastructure/packer/cysvuln
            packer init .
            packer build -only=qemu.cysvuln-local .
          '';

          installPhase = ''
            mkdir -p $out
            cp -r output/cysvuln-local/*.qcow2 $out/
          '';
        };

        packages.wazuh-siem-proxmox = pkgs.stdenv.mkDerivation {
          name = "wazuh-siem-proxmox";
          src = ./.;
          nativeBuildInputs = [ pkgs.packer ];

          buildPhase = ''
            export HOME=$(mktemp -d)
            export PACKER_LOG=1
            cd infrastructure/packer
            packer init .
            packer build -only=proxmox-wazuh-ubuntu.proxmox-iso.wazuh-ubuntu .
          '';

          installPhase = ''
            mkdir -p $out
            echo "wazuh-siem deployed to Proxmox VMID 110" > $out/README
          '';
        };
      });
}

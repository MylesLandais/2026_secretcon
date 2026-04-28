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
          ];

          shellHook = ''
            echo "[secretcon] dev shell active"
            if [ ! -f .env ] || [ ! -s .env ]; then
              echo "[warn] .env missing or empty — secrets not loaded"
            fi
          '';
        };

        packages.win11-ews-local = pkgs.stdenv.mkDerivation {
          name = "win11-ews-local";
          src = ./infrastructure/packer;
          nativeBuildInputs = [ pkgs.packer pkgs.qemu ];

          buildPhase = ''
            export HOME=$(mktemp -d)
            export PACKER_LOG=1
            packer init .
            packer build -only=qemu.win11-ews-local .
          '';

          installPhase = ''
            mkdir -p $out
            cp -r output/win11-ews-local/*.qcow2 $out/
          '';
        };

        packages.win11-ews-proxmox = pkgs.stdenv.mkDerivation {
          name = "win11-ews-proxmox";
          src = ./infrastructure/packer;
          nativeBuildInputs = [ pkgs.packer ];

          buildPhase = ''
            export HOME=$(mktemp -d)
            export PACKER_LOG=1
            packer init .
            packer build -only=proxmox-iso.win11-ews .
          '';

          installPhase = ''
            mkdir -p $out
            cp -r output-* $out/ || true
          '';
        };
      });
}

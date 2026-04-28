{
  description = "2026 SecretCon CTF Infrastructure";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            packer
            terraform
            awscli2
            jq
            sops
            age
            git
            openssl
          ];

          shellHook = ''
            echo "[secretcon] dev shell active"
            if [ ! -f .env ] || [ ! -s .env ]; then
              echo "[warn] .env missing or empty — secrets not loaded"
            fi
          '';
        };

        packages.win11-ews-artifact = pkgs.stdenv.mkDerivation {
          name = "win11-ews-artifact";
          src = ./infrastructure/packer;
          buildInputs = [ pkgs.packer ];

          buildPhase = ''
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

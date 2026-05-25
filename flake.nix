# SecretCon lab flake: dev shells + optional Packer derivations for local QEMU builds.
#
#   nix develop          — default toolchain (packer, qemu, validation Python)
#   nix develop .#kali   — adds nmap/msfvenom/evil-winrm/exploitdb (see kali.nix)
#   nix build .#win10-ews-local   — QEMU Win10 EWS qcow2
#   nix build .#cysvuln-local     — QEMU CysVuln qcow2 (needs staged Server 2016 ISO)
#   nix build .#win10-ews-proxmox — Proxmox EWS (live PROXMOX_* creds)
#   nix build .#wazuh-siem-proxmox — Proxmox Wazuh SIEM bake
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

        kali = import ./kali.nix { inherit pkgs; };

        defaultShellInputs = with pkgs; [
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
          python3
          curl
          netcat
          pkgsCross.mingwW64.buildPackages.gcc
          python3Packages.pywinrm
          python3Packages.pytest
          python3Packages.jinja2
          python3Packages.keystone-engine
          freerdp
        ];
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = defaultShellInputs;

          shellHook = ''
            echo "[secretcon] dev shell active"
            if [ ! -f .env ] || [ ! -s .env ]; then
              echo "[warn] .env missing or empty — secrets not loaded"
            fi
          '';
        };

        devShells.kali = pkgs.mkShell {
          buildInputs = defaultShellInputs ++ kali.packages;

          shellHook = ''
            echo "[secretcon] dev shell active (kali-parity)"
            if [ ! -f .env ] || [ ! -s .env ]; then
              echo "[warn] .env missing or empty — secrets not loaded"
            fi
          '';
        };

        # QEMU: Win10 LTSC EWS challenge (local iteration path)
        packages.win10-ews-local = pkgs.stdenv.mkDerivation {
          name = "win10-ews-local";
          src = ./.;
          nativeBuildInputs = [ pkgs.packer pkgs.qemu ];

          buildPhase = ''
            export HOME=$(mktemp -d)
            export PACKER_LOG=1
            cd infrastructure/packer/ews
            packer init .
            packer build -only=qemu.win10-ews-local .
          '';

          installPhase = ''
            mkdir -p $out
            cp infrastructure/packer/ews/output/win10-ews-local/*.qcow2 $out/
          '';
        };

        # Proxmox-native: same EWS target on node manage
        packages.win10-ews-proxmox = pkgs.stdenv.mkDerivation {
          name = "win10-ews-proxmox";
          src = ./.;
          nativeBuildInputs = [ pkgs.packer ];

          buildPhase = ''
            export HOME=$(mktemp -d)
            export PACKER_LOG=1
            cd infrastructure/packer/ews
            packer init .
            packer build -only=proxmox-iso.win10-ews .
          '';

          installPhase = ''
            mkdir -p $out
            cp -r infrastructure/packer/ews/output-* $out/ || true
          '';
        };

        # QEMU: CysVuln Server 2016 (set CYSVULN_ISO_STORE or CYSVULN_ISO for impure builds)
        packages.cysvuln-local = let
          isoStore = builtins.getEnv "CYSVULN_ISO_STORE";
          isoEnv = builtins.getEnv "CYSVULN_ISO";
          isoInput = if isoStore != "" then isoStore
            else if isoEnv != "" then isoEnv
            else null;
          isoFile = if isoInput == null then null else pkgs.runCommand "cysvuln-server-2016-iso" { } ''
            mkdir -p $out
            cp ${isoInput} $out/cysvuln-server-2016.iso
          '';
        in if isoFile == null then pkgs.runCommand "cysvuln-local-no-iso" { } ''
          echo "[!] Set CYSVULN_ISO_STORE or CYSVULN_ISO before building."
          exit 1
        '' else pkgs.stdenv.mkDerivation {
          name = "cysvuln-local";
          src = ./.;
          nativeBuildInputs = [ pkgs.packer pkgs.qemu ];

          patchPhase = ''
            mkdir -p infrastructure/packer/iso
            cp ${isoFile}/cysvuln-server-2016.iso infrastructure/packer/iso/cysvuln-server-2016.iso
          '';

          buildPhase = ''
            ISO="$src/infrastructure/packer/iso/cysvuln-server-2016.iso"
            if [ ! -f "$ISO" ]; then
              echo "[!] Missing $ISO"
              echo "    Run: ./scripts/stage-cysvuln-iso.sh /path/to/server-2016.iso"
              exit 1
            fi
            export HOME=$(mktemp -d)
            export PACKER_LOG=1
            cd infrastructure/packer/cysvuln
            rm -rf packer-output/cysvuln-local
            packer init .
            packer build -only=cysvuln-local.qemu.cysvuln-local \
              -var "cysvuln_iso_url=file://$ISO" \
              .
          '';

          installPhase = ''
            mkdir -p $out
            cp -r packer-output/cysvuln-local/*.qcow2 $out/
          '';
        };

        # Proxmox-native: all-in-one Wazuh SIEM VM
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

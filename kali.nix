# Kali-parity attacker tooling for CysVuln validation and walkthrough appendix.
# Consumed only by flake.nix devShells.kali (packages list). Do not import as a shell directly.
{ pkgs, ... }:
{
  packages = with pkgs; [
    nmap
    metasploit
    evil-winrm
    exploitdb
    python3Packages.impacket
    hashcat
    wordlists
  ];
}

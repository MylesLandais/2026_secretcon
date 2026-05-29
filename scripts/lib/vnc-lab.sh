#!/usr/bin/env bash
# shellcheck shell=bash
#
# vnc-lab.sh -- shared VNC lab defaults (wordlist, ports, env).
#
# Usage:
#   source scripts/lib/vnc-lab.sh
#   vnc_load_env
#   WORDLIST="$(vnc_resolve_wordlist)"

vnc_load_env() {
    local repo_root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
    REPO_ROOT="${repo_root}"
    # shellcheck source=scripts/lib/load_repo_env.sh
    source "${repo_root}/scripts/lib/load_repo_env.sh"
    load_repo_env "${repo_root}/.env"
    VNC_PORT="${VNC_PORT:-5900}"
    WINRM_PORT="${WINRM_PORT:-5985}"
    PASSWORD="${PASSWORD:-FELDTECH_VNC}"
}

vnc_resolve_wordlist() {
    local repo_root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
    if [ -n "${WORDLIST:-}" ] && [ -f "${WORDLIST}" ]; then
        printf '%s\n' "${WORDLIST}"
        return 0
    fi
    local candidate
    for candidate in \
        "${repo_root}/provisioning/wordlists/vnc-betterdefaultpasslist.txt" \
        /usr/share/seclists/Passwords/Default-Credentials/vnc-betterdefaultpasslist.txt \
        /usr/share/wordlists/seclists/Passwords/Default-Credentials/vnc-betterdefaultpasslist.txt; do
        if [ -f "${candidate}" ]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    echo "[!] VNC wordlist not found" >&2
    return 1
}

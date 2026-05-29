#!/usr/bin/env bash
# Phase 0 hot-test: baseline, manual registry fix, verified probes.
# See .cursor/plans/vnc_weak-cred_lab_brute-reliability_0999a490.plan.md
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

# shellcheck source=scripts/lib/vnc-lab.sh
source "${REPO_ROOT}/scripts/lib/vnc-lab.sh"
vnc_load_env

TARGET="${TARGET:-192.168.61.158}"
RUN_ID="${RUN_ID:-hot-test-$(date -u +%Y%m%dT%H%M%SZ)}"
VNC_PW="${VNC_PW:-${PASSWORD:-FELDTECH_VNC}}"
SSH_USER="${SSH_USER:-Administrator}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=15)
WORDLIST="$(vnc_resolve_wordlist)"

OUT="${REPO_ROOT}/artifacts/ews/${RUN_ID}"
mkdir -p "${OUT}/baseline" "${OUT}/applied" "${OUT}/verified"

ssh_win() {
    local script="$1"
    if [ -n "${ANSIBLE_ADMIN_PASSWORD:-}" ]; then
        sshpass -p "${ANSIBLE_ADMIN_PASSWORD}" ssh "${SSH_OPTS[@]}" \
            "${SSH_USER}@${TARGET}" "${script}"
    elif [ -n "${ADMIN_PW:-}" ]; then
        sshpass -p "${ADMIN_PW}" ssh "${SSH_OPTS[@]}" \
            "${SSH_USER}@${TARGET}" "${script}"
    else
        ssh "${SSH_OPTS[@]}" "${SSH_USER}@${TARGET}" "${script}"
    fi
}

phase="${1:-all}"
case "${phase}" in
    baseline|0a) phase=baseline ;;
    apply|0b) phase=apply ;;
    verify|0c) phase=verify ;;
    all) phase=all ;;
    *)
        echo "usage: $0 [baseline|apply|verify|all]" >&2
        exit 2
        ;;
esac

echo "[*] vnc-hot-test target=${TARGET} run_id=${RUN_ID} phase=${phase}"
echo "    out=${OUT}"

run_baseline() {
    if command -v nmap >/dev/null 2>&1; then
        nmap -p 5900 --script vnc-info "${TARGET}" \
            | tee "${OUT}/baseline/nmap-vnc-info.txt" || true
    else
        echo "[!] nmap not on PATH; skip vnc-info" | tee "${OUT}/baseline/nmap-vnc-info.txt"
    fi

    ssh_win 'reg query HKLM\SOFTWARE\ORL\WinVNC3' \
        | tee "${OUT}/baseline/reg-query.txt" || true

    python3 ansible/roles/ultravnc/files/check_vnc_auth.py \
        --host "${TARGET}" --password "${VNC_PW}" \
        --cred-tool scripts/observability/vnc-cred-tool.py --json \
        | tee "${OUT}/baseline/check-vnc-auth-single.json" || true

    if command -v msfconsole >/dev/null 2>&1; then
        msfconsole -q -x "use auxiliary/scanner/vnc/vnc_login; \
set RHOSTS ${TARGET}; set RPORT 5900; \
set PASS_FILE ${WORDLIST}; \
set STOP_ON_SUCCESS true; set BRUTEFORCE_SPEED 0; run; exit" \
            | tee "${OUT}/baseline/msf-vnc-login.txt" || true
    else
        echo "[!] msfconsole not on PATH" | tee "${OUT}/baseline/msf-vnc-login.txt"
    fi
}

run_apply() {
    local ps_script="${REPO_ROOT}/scripts/observability/vnc-hot-test-apply.ps1"
    ssh_win "powershell -NoProfile -ExecutionPolicy Bypass -Command -" \
        < "${ps_script}" | tee "${OUT}/applied/transcript.txt"
}

run_verify() {
    if command -v nmap >/dev/null 2>&1; then
        nmap -p 5900 --script vnc-info "${TARGET}" \
            | tee "${OUT}/verified/nmap-vnc-info.txt"
    fi

    ssh_win 'reg query HKLM\SOFTWARE\ORL\WinVNC3' \
        | tee "${OUT}/verified/reg-query.txt"

    python3 ansible/roles/ultravnc/files/check_vnc_auth.py \
        --host "${TARGET}" --port 5900 \
        --wordlist "${WORDLIST}" \
        --delay-seconds 0.5 \
        --cred-tool scripts/observability/vnc-cred-tool.py --json \
        | tee "${OUT}/verified/check-vnc-auth-wordlist.json"

    if command -v msfconsole >/dev/null 2>&1; then
        msfconsole -q -x "use auxiliary/scanner/vnc/vnc_login; \
set RHOSTS ${TARGET}; set RPORT 5900; \
set PASS_FILE ${WORDLIST}; \
set STOP_ON_SUCCESS true; set BRUTEFORCE_SPEED 0; \
set USER_AS_PASS false; set DB_ALL_CREDS false; run; exit" \
            | tee "${OUT}/verified/msf-vnc-login.txt"
    fi

    if command -v hydra >/dev/null 2>&1; then
        hydra -t 1 -V -f -P "${WORDLIST}" -s 5900 "${TARGET}" vnc \
            | tee "${OUT}/verified/hydra.txt" || true
    fi
}

case "${phase}" in
    baseline) run_baseline ;;
    apply) run_apply ;;
    verify) run_verify ;;
    all)
        run_baseline
        run_apply
        run_verify
        ;;
esac

echo "[+] done: ${OUT}"

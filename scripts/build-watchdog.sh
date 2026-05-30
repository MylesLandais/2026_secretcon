#!/usr/bin/env bash
# Cross-compile secretcon-watchdog for Windows amd64 into the Ansible role files/.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${REPO_ROOT}/ansible/roles/watchdog_agent/files/secretcon-watchdog.exe"
cd "${REPO_ROOT}/tools/watchdog"
go mod tidy
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -o "${OUT}" .
echo "[+] ${OUT}"

#!/usr/bin/env bash
# shellcheck shell=bash
#
# docker-stack.sh -- shared docker compose up/down helpers for local stacks.
#
# Usage:
#   source scripts/lib/docker-stack.sh
#   docker_stack_down "$STACK_DIR" "$COMPOSE_PROJECT" [--wipe]

docker_stack_down() {
    local stack_dir="$1"
    local compose_project="$2"
    local wipe=0
    shift 2 || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --wipe) wipe=1 ;;
            *) echo "[!] docker_stack_down: unknown arg: $1" >&2; return 2 ;;
        esac
        shift
    done
    if ! command -v docker >/dev/null 2>&1; then
        echo "[!] docker not on PATH (try: nix develop)" >&2
        return 2
    fi
    cd "$stack_dir"
    if [ "$wipe" -eq 1 ]; then
        echo "[*] Stopping ${compose_project} and removing volumes (--wipe)"
        docker compose -p "${compose_project}" down -v --remove-orphans
    else
        echo "[*] Stopping ${compose_project} (volumes preserved)"
        docker compose -p "${compose_project}" down --remove-orphans
    fi
}

docker_stack_up() {
    local stack_dir="$1"
    local compose_project="$2"
    if ! command -v docker >/dev/null 2>&1; then
        echo "[!] docker not on PATH (try: nix develop)" >&2
        return 2
    fi
    cd "$stack_dir"
    echo "[*] Bringing stack up (project: ${compose_project})"
    docker compose -p "${compose_project}" up -d
}

docker_stack_wait_http() {
    local url="$1"
    local max_attempts="${2:-60}"
    local sleep_secs="${3:-2}"
    local attempt=1
    while [ "${attempt}" -le "${max_attempts}" ]; do
        if curl -sf "${url}" >/dev/null 2>&1; then
            echo "[+] HTTP ready: ${url}"
            return 0
        fi
        sleep "${sleep_secs}"
        attempt=$((attempt + 1))
    done
    echo "[!] timed out waiting for ${url}" >&2
    return 1
}

#!/usr/bin/env bash
# shellcheck shell=bash
#
# load_repo_env.sh -- source the repo-root .env without clobbering exports.
#
# Usage:
#   REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
#   # shellcheck source=scripts/lib/load_repo_env.sh
#   . "${REPO_ROOT}/scripts/lib/load_repo_env.sh"
#   load_repo_env "${REPO_ROOT}"
#
# By default, variables already exported by the caller win over .env
# entries. Pass --force to let .env overwrite everything (legacy
# `set -a; source .env` behaviour).

load_repo_env() {
    local repo_root="${1:-${REPO_ROOT:-}}"
    local mode="preserve_exports"
    shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) mode="force" ;;
            -h|--help)
                cat <<'EOF'
load_repo_env [REPO_ROOT] [--force]

  preserve_exports (default)  do not overwrite caller-exported vars
  --force                     source .env with set -a (legacy behaviour)
EOF
                return 0
                ;;
            *)
                echo "[!] load_repo_env: unknown arg: $1" >&2
                return 2
                ;;
        esac
        shift
    done

    local env_file="${repo_root}/.env"
    [ -n "$repo_root" ] || {
        echo "[!] load_repo_env: REPO_ROOT not set" >&2
        return 2
    }
    [ -f "$env_file" ] || return 0

    if [ "$mode" = "force" ]; then
        set -a
        # shellcheck disable=SC1090
        . "$env_file"
        set +a
        return 0
    fi

    while IFS='=' read -r k v; do
        [ -z "$k" ] && continue
        case "$k" in \#*) continue ;; esac
        v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
        if [ -z "${!k:-}" ]; then
            export "${k}=${v}"
        fi
    done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$env_file" || true)
}

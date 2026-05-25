#!/usr/bin/env bash
# Read a provision manifest (repo-root-relative paths, one per line).
# Usage: source scripts/lib/read-provision-manifest.sh
#        read_provision_manifest /path/to/manifest.txt "$REPO_ROOT"

read_provision_manifest() {
    local manifest="$1"
    local repo_root="$2"
    if [ ! -f "$manifest" ]; then
        echo "[!] manifest not found: $manifest" >&2
        return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -z "$line" ] && continue
        printf '%s/%s\n' "$repo_root" "$line"
    done < "$manifest"
}

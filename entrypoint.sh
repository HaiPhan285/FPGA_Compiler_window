#!/usr/bin/env bash
set -e

args=("$@")

# Redirect .bat invocations to .ps1 for Linux containers
if [ ${#args[@]} -gt 0 ]; then
    first="${args[0]}"
    base="$(basename "$first")"
    dir="$(dirname "$first")"
    name="${base%.*}"
    ext="${base##*.}"

    if [ "$ext" = "bat" ] || [ "$ext" = "cmd" ]; then
        ps1="${dir}/${name}.ps1"
        if [ -f "$ps1" ]; then
            args[0]="$ps1"
        fi
    fi
fi

exec /usr/bin/pwsh -NoProfile -ExecutionPolicy Bypass -File "${args[@]}"

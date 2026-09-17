#!/bin/bash
# Deshace el último commit hecho por RepoWatch en un repo — solo si HEAD
# sigue siendo exactamente ese commit y nunca se pusheó (ver record_commit
# en lib_commit_safety.sh). $1 = ruta del repo.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib_discover_repos.sh"
source "$SCRIPT_DIR/lib_commit_safety.sh"

GIT_BIN="$(command -v git)"
LOG_FILE="$CONFIG_DIR/logs/check_git_repos.log"
dir="$1"
name="$(basename "$dir")"

[ -z "$dir" ] && exit 1

line="$(grep -F "$dir	" "$LAST_COMMITS_FILE" 2>/dev/null | tail -n1)"
if [ -z "$line" ]; then
    osascript -e "display alert \"Nada que deshacer en $name\"" >/dev/null 2>&1
    exit 1
fi

recorded_sha="$(echo "$line" | cut -f2)"
pushed="$(echo "$line" | cut -f3)"
current_sha="$("$GIT_BIN" -C "$dir" rev-parse HEAD 2>/dev/null)"

if [ "$pushed" = "1" ]; then
    osascript -e "display alert \"No se puede deshacer\" message \"El último commit en $name ya se subió al remoto.\"" >/dev/null 2>&1
    exit 1
fi

if [ "$current_sha" != "$recorded_sha" ]; then
    osascript -e "display alert \"No se puede deshacer\" message \"El HEAD de $name cambió desde el último commit de RepoWatch (hay commits más nuevos encima).\"" >/dev/null 2>&1
    exit 1
fi

if "$GIT_BIN" -C "$dir" reset --soft HEAD~1 >/dev/null 2>&1; then
    echo "[$(date "+%Y-%m-%d %H:%M:%S")] $name: commit deshecho ($recorded_sha)" >> "$LOG_FILE"
    grep -vF "$dir	" "$LAST_COMMITS_FILE" > "$LAST_COMMITS_FILE.tmp" 2>/dev/null
    mv "$LAST_COMMITS_FILE.tmp" "$LAST_COMMITS_FILE" 2>/dev/null
    osascript -e "display notification \"Commit deshecho en $name (los cambios siguen ahí, sin commitear)\" with title \"RepoWatch\"" >/dev/null 2>&1
else
    osascript -e "display alert \"Error deshaciendo el commit en $name\"" >/dev/null 2>&1
fi

#!/bin/bash
# Actualiza (fast-forward only) los repos vigilados que están detrás de su
# remoto. --ff-only: nunca crea un merge commit ni toca archivos locales
# sin commitear — si no puede hacer fast-forward, lo deja para revisión
# manual en vez de arriesgar un conflicto.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib_discover_repos.sh"
source "$SCRIPT_DIR/lib_repo_config.sh"

GIT_BIN="$(command -v git)"
LOG_FILE="$CONFIG_DIR/logs/check_git_repos.log"
ts="$(date "+%Y-%m-%d %H:%M:%S")"

ok=() failed=()

repos=()
while IFS= read -r repo_path; do
    repos+=("$repo_path")
done < <(discover_repos | awk '!seen[$0]++')

for dir in "${repos[@]}"; do
    [ "$(repo_get "$dir" enabled true)" = "false" ] && continue
    name="$(basename "$dir")"

    upstream="$("$GIT_BIN" -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
    [ -z "$upstream" ] && continue
    behind="$("$GIT_BIN" -C "$dir" rev-list --count 'HEAD..@{u}' 2>/dev/null)"
    [ -z "$behind" ] || [ "$behind" -eq 0 ] && continue

    if "$GIT_BIN" -C "$dir" pull --ff-only >/dev/null 2>/tmp/git_pull_pending_err; then
        ok+=("$name ($behind commit(s))")
    else
        failed+=("$name: $(tail -n1 /tmp/git_pull_pending_err)")
    fi
done

echo "[$ts] Actualizar pendientes — OK: $(IFS='; '; echo "${ok[*]:-ninguno}") | Falló: $(IFS='; '; echo "${failed[*]:-ninguno}")" >> "$LOG_FILE"

if [ ${#ok[@]} -eq 0 ] && [ ${#failed[@]} -eq 0 ]; then
    osascript -e 'display notification "No había nada pendiente de bajar." with title "RepoWatch"' >/dev/null 2>&1
else
    body="$(printf '%s\n' "${ok[@]}")"
    [ ${#failed[@]} -gt 0 ] && body="$body
Falló (revisar a mano): $(printf '%s; ' "${failed[@]}")"
    osascript - "$body" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
    display notification (item 1 of argv) with title "RepoWatch: pull" sound name "Ping"
end run
APPLESCRIPT
fi

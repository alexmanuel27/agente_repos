#!/bin/bash
# Pushea, en todos los repos vigilados, los commits locales que todavía no
# se subieron (probando cada remoto configurado hasta encontrar uno que
# responda). Disparado desde el botón "Pushear pendientes" del resumen, o
# manualmente desde el menú.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib_discover_repos.sh"
source "$SCRIPT_DIR/lib_repo_config.sh"
source "$SCRIPT_DIR/lib_commit_safety.sh"

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

    ahead="$(unpushed_count "$dir")"
    [ "$ahead" -eq 0 ] && continue

    push_remote=""
    for r in $("$GIT_BIN" -C "$dir" remote); do
        if "$GIT_BIN" -C "$dir" ls-remote --exit-code "$r" >/dev/null 2>&1; then
            push_remote="$r"
            break
        fi
    done

    if [ -z "$push_remote" ]; then
        failed+=("$name: ningún remoto disponible")
    elif "$GIT_BIN" -C "$dir" push "$push_remote" >/dev/null 2>/tmp/git_push_pending_err; then
        ok+=("$name ($ahead commit(s))")
    else
        failed+=("$name: $(tail -n1 /tmp/git_push_pending_err)")
    fi
done

echo "[$ts] Pushear pendientes — OK: $(IFS='; '; echo "${ok[*]:-ninguno}") | Falló: $(IFS='; '; echo "${failed[*]:-ninguno}")" >> "$LOG_FILE"

if [ ${#ok[@]} -eq 0 ] && [ ${#failed[@]} -eq 0 ]; then
    osascript -e 'display notification "No había nada pendiente de subir." with title "RepoWatch"' >/dev/null 2>&1
else
    body="$(printf '%s\n' "${ok[@]}")"
    [ ${#failed[@]} -gt 0 ] && body="$body
Falló: $(printf '%s; ' "${failed[@]}")"
    osascript - "$body" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
    display notification (item 1 of argv) with title "RepoWatch: push" sound name "Ping"
end run
APPLESCRIPT
fi

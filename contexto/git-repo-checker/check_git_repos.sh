#!/bin/bash
# Revisa si alguno de los repos en REPOS_DIR está desactualizado respecto a su remoto.
# Pensado para correr cada hora vía launchd (com.alex.checkgitrepos.plist).

REPOS_DIR="/Users/alex/Nube /repos"
LOG_FILE="/Users/alex/scripts/logs/check_git_repos.log"
GIT_BIN="$(command -v git)"

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }

outdated=()
errors=()

for dir in "$REPOS_DIR"/*/; do
    [ -d "${dir}.git" ] || continue
    name="$(basename "$dir")"

    if ! "$GIT_BIN" -C "$dir" fetch --quiet 2>/tmp/git_fetch_err; then
        errors+=("$name: fetch falló ($(tail -n1 /tmp/git_fetch_err))")
        continue
    fi

    upstream="$("$GIT_BIN" -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
    if [ -z "$upstream" ]; then
        continue
    fi

    behind="$("$GIT_BIN" -C "$dir" rev-list --count 'HEAD..@{u}' 2>/dev/null)"
    if [ -n "$behind" ] && [ "$behind" -gt 0 ]; then
        outdated+=("$name ($behind commit(s) detrás de $upstream)")
    fi
done

ts="$(timestamp)"

if [ ${#outdated[@]} -gt 0 ]; then
    log_msg="Repos desactualizados: $(IFS='; '; echo "${outdated[*]}")"
    echo "[$ts] $log_msg" >> "$LOG_FILE"

    notif_body="$(printf '%s\n' "${outdated[@]}")"
    notif_body="${notif_body%$'\n'}"
    notif_title="Git: ${#outdated[@]} repo(s) desactualizado(s)"

    osascript - "$notif_title" "$notif_body" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
    display notification (item 2 of argv) with title (item 1 of argv) sound name "Ping"
end run
APPLESCRIPT
else
    echo "[$ts] Todos los repos están actualizados." >> "$LOG_FILE"
fi

if [ ${#errors[@]} -gt 0 ]; then
    echo "[$ts] Errores: $(IFS='; '; echo "${errors[*]}")" >> "$LOG_FILE"
fi

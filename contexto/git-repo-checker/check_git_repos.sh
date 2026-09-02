#!/bin/bash
# Revisa si algún repo está desactualizado respecto a su remoto y/o tiene
# cambios sin commitear. Repos vigilados:
#   - todas las subcarpetas con .git dentro de REPOS_DIR
#   - las rutas listadas en EXTRA_REPOS_FILE (una por línea, líneas que
#     empiezan con # se ignoran)
# Pensado para correr cada hora vía launchd (com.alex.checkgitrepos.plist).

REPOS_DIR="/Users/alex/Nube /repos"
EXTRA_REPOS_FILE="/Users/alex/scripts/extra_repos.txt"
LOG_FILE="/Users/alex/scripts/logs/check_git_repos.log"
GIT_BIN="$(command -v git)"

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }

repos=()
for dir in "$REPOS_DIR"/*/; do
    [ -d "${dir}.git" ] && repos+=("${dir%/}")
done

if [ -f "$EXTRA_REPOS_FILE" ]; then
    while IFS= read -r line; do
        line="${line%%#*}"
        line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "$line" ] && continue
        if [ -d "$line/.git" ]; then
            repos+=("${line%/}")
        fi
    done < "$EXTRA_REPOS_FILE"
fi

outdated=()
dirty=()
errors=()

for dir in "${repos[@]}"; do
    name="$(basename "$dir")"

    if ! "$GIT_BIN" -C "$dir" fetch --quiet 2>/tmp/git_fetch_err; then
        errors+=("$name: fetch falló ($(tail -n1 /tmp/git_fetch_err))")
    else
        upstream="$("$GIT_BIN" -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
        if [ -n "$upstream" ]; then
            behind="$("$GIT_BIN" -C "$dir" rev-list --count 'HEAD..@{u}' 2>/dev/null)"
            if [ -n "$behind" ] && [ "$behind" -gt 0 ]; then
                outdated+=("$name ($behind commit(s) detrás de $upstream)")
            fi
        fi
    fi

    if [ -n "$("$GIT_BIN" -C "$dir" status --porcelain 2>/dev/null)" ]; then
        dirty+=("$name")
    fi
done

ts="$(timestamp)"

notif_lines=()
if [ ${#outdated[@]} -gt 0 ]; then
    notif_lines+=("Desactualizados:")
    notif_lines+=("${outdated[@]}")
fi
if [ ${#dirty[@]} -gt 0 ]; then
    notif_lines+=("Cambios sin commitear:")
    notif_lines+=("${dirty[@]}")
fi

if [ ${#notif_lines[@]} -gt 0 ]; then
    log_msg="Desactualizados: $(IFS='; '; echo "${outdated[*]:-ninguno}") | Sin commitear: $(IFS='; '; echo "${dirty[*]:-ninguno}")"
    echo "[$ts] $log_msg" >> "$LOG_FILE"

    notif_body="$(printf '%s\n' "${notif_lines[@]}")"
    notif_body="${notif_body%$'\n'}"
    notif_title="Git: repos con pendientes de revisión"

    osascript - "$notif_title" "$notif_body" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
    display notification (item 2 of argv) with title (item 1 of argv) sound name "Ping"
end run
APPLESCRIPT
else
    echo "[$ts] Todos los repos están actualizados y sin cambios pendientes." >> "$LOG_FILE"
fi

if [ ${#errors[@]} -gt 0 ]; then
    echo "[$ts] Errores: $(IFS='; '; echo "${errors[*]}")" >> "$LOG_FILE"
fi

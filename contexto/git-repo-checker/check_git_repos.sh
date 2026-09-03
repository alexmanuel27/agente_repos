#!/bin/bash
# Revisa si algún repo está desactualizado respecto a su remoto y/o tiene
# cambios sin commitear (ver lib_discover_repos.sh para qué repos vigila).
# Pensado para correr cada hora vía launchd (com.alex.checkgitrepos.plist).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib_discover_repos.sh"

LOG_FILE="/Users/alex/scripts/logs/check_git_repos.log"
STATE_FILE="/Users/alex/scripts/last_check_state.txt"
REVIEW_SCRIPT="$SCRIPT_DIR/review_and_commit.sh"
GIT_BIN="$(command -v git)"

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }

repos=()
while IFS= read -r repo_path; do
    repos+=("$repo_path")
done < <(discover_repos)

outdated=()
dirty=()
errors=()

for dir in "${repos[@]}"; do
    name="$(basename "$dir")"
    branch="$("$GIT_BIN" -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"

    if ! "$GIT_BIN" -C "$dir" fetch --quiet 2>/tmp/git_fetch_err; then
        errors+=("$name: fetch falló ($(tail -n1 /tmp/git_fetch_err))")
    else
        upstream="$("$GIT_BIN" -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
        if [ -n "$upstream" ]; then
            behind="$("$GIT_BIN" -C "$dir" rev-list --count 'HEAD..@{u}' 2>/dev/null)"
            if [ -n "$behind" ] && [ "$behind" -gt 0 ]; then
                outdated+=("• $name [$branch] — $behind commit(s) detrás de $upstream")
            fi
        fi
    fi

    status_output="$("$GIT_BIN" -C "$dir" status --porcelain 2>/dev/null)"
    if [ -n "$status_output" ]; then
        n_changes="$(echo "$status_output" | wc -l | tr -d ' ')"
        n_staged="$(echo "$status_output" | grep -c '^[MADRC]')"
        n_untracked="$(echo "$status_output" | grep -c '^??')"
        dirty+=("• $name [$branch] — $n_changes archivo(s) ($n_staged listo(s), $n_untracked sin trackear)")
    fi
done

ts="$(timestamp)"

notif_lines=()
if [ ${#outdated[@]} -gt 0 ]; then
    notif_lines+=("── Desactualizados ──")
    notif_lines+=("${outdated[@]}")
fi
if [ ${#dirty[@]} -gt 0 ]; then
    [ ${#notif_lines[@]} -gt 0 ] && notif_lines+=("")
    notif_lines+=("── Cambios sin commitear ──")
    notif_lines+=("${dirty[@]}")
fi

if [ ${#notif_lines[@]} -gt 0 ]; then
    log_msg="Desactualizados: $(IFS='; '; echo "${outdated[*]:-ninguno}") | Sin commitear: $(IFS='; '; echo "${dirty[*]:-ninguno}")"
    echo "[$ts] $log_msg" >> "$LOG_FILE"

    notif_body="$(printf '%s\n' "${notif_lines[@]}")"
    notif_body="${notif_body%$'\n'}"
    notif_title="Git: repos con pendientes de revisión"

    echo "$notif_body" > "$STATE_FILE"

    # Banner con sonido.
    osascript - "$notif_title" "$notif_body" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
    display notification (item 2 of argv) with title (item 1 of argv) sound name "Ping"
end run
APPLESCRIPT

    # Ventana flotante con el detalle. Si hay repos con cambios sin
    # commitear, ofrece pasar directo al flujo interactivo de add/commit/push.
    if [ ${#dirty[@]} -gt 0 ]; then
        choice="$(osascript - "$notif_title" "$notif_body" <<'APPLESCRIPT' 2>/dev/null
on run argv
    set theResult to display dialog (item 2 of argv) with title (item 1 of argv) buttons {"Cerrar", "Revisar y commitear"} default button "Revisar y commitear" with icon note
    return button returned of theResult
end run
APPLESCRIPT
)"
        if [ "$choice" = "Revisar y commitear" ]; then
            "$REVIEW_SCRIPT"
        fi
    else
        osascript - "$notif_title" "$notif_body" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
    display dialog (item 2 of argv) with title (item 1 of argv) buttons {"OK"} default button 1 with icon note
end run
APPLESCRIPT
    fi
else
    echo "[$ts] Todos los repos están actualizados y sin cambios pendientes." >> "$LOG_FILE"
    rm -f "$STATE_FILE"
fi

if [ ${#errors[@]} -gt 0 ]; then
    echo "[$ts] Errores: $(IFS='; '; echo "${errors[*]}")" >> "$LOG_FILE"
fi

#!/bin/bash
# Revisa si algún repo vigilado está desactualizado respecto a su remoto
# y/o tiene cambios sin commitear (repos vigilados: ver lib_discover_repos.sh;
# overrides por repo: ver lib_repo_config.sh). Repos en modo autosync se
# commitean/pushean en silencio aquí mismo (con guardas de seguridad); el
# resto entra a la notificación + ventana flotante de siempre.
# Disparado por RepoWatch.app según el intervalo elegido en Preferencias, o
# manualmente desde el menú ("Revisar ahora").

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib_discover_repos.sh"
source "$SCRIPT_DIR/lib_settings.sh"
source "$SCRIPT_DIR/lib_repo_config.sh"
source "$SCRIPT_DIR/lib_commit_safety.sh"
load_settings

# Evita que el Timer y un "Revisar ahora" manual corran a la vez.
LOCK_DIR="$CONFIG_DIR/.check.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT INT TERM

# GIT_TERMINAL_PROMPT=0: nunca colgarse pidiendo credenciales sin tty.
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND='ssh -oBatchMode=yes -oConnectTimeout=10'

LOG_FILE="$CONFIG_DIR/logs/check_git_repos.log"
STATE_FILE="$CONFIG_DIR/last_check_state.txt"
LAST_CHECK_FILE="$CONFIG_DIR/last_check.txt"
REVIEW_SCRIPT="$SCRIPT_DIR/review_and_commit.sh"
GIT_BIN="$(command -v git)"

mkdir -p "$CONFIG_DIR/logs"

# Log de hasta 1MB; si crece más, se recorta a las últimas 1000 líneas.
if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    tail -n 1000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
ts="$(timestamp)"

if [ -z "$GIT_BIN" ] || ! "$GIT_BIN" --version >/dev/null 2>&1; then
    echo "git no disponible — instala las Command Line Tools" > "$STATE_FILE"
    echo "[$ts] Error: git no disponible" >> "$LOG_FILE"
    date +%s > "$LAST_CHECK_FILE"
    osascript -e 'display notification "git no está disponible — instala las Command Line Tools" with title "RepoWatch" sound name "Ping"' >/dev/null 2>&1
    exit 0
fi

repos=()
while IFS= read -r repo_path; do
    repos+=("$repo_path")
done < <(discover_repos | awk '!seen[$0]++')

outdated=()
dirty=()
errors=()
autosynced=()

for dir in "${repos[@]}"; do
    name="$(basename "$dir")"

    if [ "$(repo_get "$dir" enabled true)" = "false" ]; then
        continue
    fi

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

    if [ "$(repo_get "$dir" untracked include)" = "ignore" ]; then
        status_output="$("$GIT_BIN" -C "$dir" status --porcelain -uno 2>/dev/null)"
    else
        status_output="$("$GIT_BIN" -C "$dir" status --porcelain --untracked-files=all 2>/dev/null)"
    fi

    if [ -n "$status_output" ]; then
        n_changes="$(echo "$status_output" | wc -l | tr -d ' ')"
        n_staged="$(echo "$status_output" | grep -c '^[MADRC]')"
        n_untracked="$(echo "$status_output" | grep -c '^??')"

        if [ "$(repo_get "$dir" mode review)" = "autosync" ] && \
           autosync_commit "$dir" "$status_output" 2>>"$LOG_FILE"; then
            autosynced+=("$name ($n_changes archivo(s))")
        else
            dirty+=("• $name [$branch] — $n_changes archivo(s) ($n_staged listo(s), $n_untracked sin trackear)")
        fi
    fi
done

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

# Tope de 8 líneas por sección para que el diálogo no se salga de pantalla.
if [ ${#notif_lines[@]} -gt 24 ]; then
    n_extra=$((${#notif_lines[@]} - 24))
    notif_lines=("${notif_lines[@]:0:24}" "… y $n_extra línea(s) más")
fi

if [ ${#notif_lines[@]} -gt 0 ]; then
    log_msg="Desactualizados: $(IFS='; '; echo "${outdated[*]:-ninguno}") | Sin commitear: $(IFS='; '; echo "${dirty[*]:-ninguno}")"
    echo "[$ts] $log_msg" >> "$LOG_FILE"

    notif_body="$(printf '%s\n' "${notif_lines[@]}")"
    notif_body="${notif_body%$'\n'}"
    notif_title="RepoWatch: repos con pendientes"

    echo "$notif_body" > "$STATE_FILE"

    osascript - "$notif_title" "$notif_body" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
    display notification (item 2 of argv) with title (item 1 of argv) sound name "Ping"
end run
APPLESCRIPT

    if [ ${#dirty[@]} -gt 0 ]; then
        choice="$(osascript - "$notif_title" "$notif_body" <<'APPLESCRIPT' 2>/dev/null
on run argv
    set theResult to display dialog (item 2 of argv) with title (item 1 of argv) buttons {"Cerrar", "Revisar y commitear"} default button "Revisar y commitear" giving up after 600 with icon note
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
    display dialog (item 2 of argv) with title (item 1 of argv) buttons {"OK"} default button 1 giving up after 600 with icon note
end run
APPLESCRIPT
    fi
else
    echo "[$ts] Todos los repos están actualizados y sin cambios pendientes." >> "$LOG_FILE"
    rm -f "$STATE_FILE"
fi

if [ ${#autosynced[@]} -gt 0 ]; then
    echo "[$ts] Autosync: $(IFS='; '; echo "${autosynced[*]}")" >> "$LOG_FILE"
    autosync_body="$(printf '%s\n' "${autosynced[@]}")"
    osascript - "$autosync_body" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
    display notification (item 1 of argv) with title "RepoWatch: sincronizado automáticamente"
end run
APPLESCRIPT
fi

if [ ${#errors[@]} -gt 0 ]; then
    echo "[$ts] Errores: $(IFS='; '; echo "${errors[*]}")" >> "$LOG_FILE"
fi

date +%s > "$LAST_CHECK_FILE"

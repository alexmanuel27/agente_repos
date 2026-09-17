#!/bin/bash
# Revisa si algún repo vigilado está desactualizado respecto a su remoto,
# tiene commits locales sin subir, y/o tiene cambios sin commitear (repos
# vigilados: ver lib_discover_repos.sh; overrides por repo: ver
# lib_repo_config.sh). Repos en modo autosync se commitean/pushean en
# silencio aquí mismo (con guardas de seguridad); el resto entra a la
# ventana flotante de siempre.
# Disparado por RepoWatch.app según el intervalo elegido en Preferencias, o
# manualmente desde el menú ("Revisar ahora").

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib_discover_repos.sh"
source "$SCRIPT_DIR/lib_settings.sh"
source "$SCRIPT_DIR/lib_repo_config.sh"
source "$SCRIPT_DIR/lib_commit_safety.sh"
load_settings

LOCK_DIR="$CONFIG_DIR/.check.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT INT TERM

export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND='ssh -oBatchMode=yes -oConnectTimeout=10'

LOG_FILE="$CONFIG_DIR/logs/check_git_repos.log"
STATE_FILE="$CONFIG_DIR/last_check_state.txt"
LAST_CHECK_FILE="$CONFIG_DIR/last_check.txt"
SNOOZE_FILE="$CONFIG_DIR/snooze_until.txt"
PENDING_NOTIF_FILE="$CONFIG_DIR/pending_notification.txt"
REVIEW_SCRIPT="$SCRIPT_DIR/review_and_commit.sh"
PUSH_SCRIPT="$SCRIPT_DIR/push_pending.sh"
PULL_SCRIPT="$SCRIPT_DIR/pull_pending.sh"
GIT_BIN="$(command -v git)"

mkdir -p "$CONFIG_DIR/logs"

if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    tail -n 1000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
ts="$(timestamp)"

if [ -z "$GIT_BIN" ] || ! "$GIT_BIN" --version >/dev/null 2>&1; then
    echo "git no disponible — instala las Command Line Tools" > "$STATE_FILE"
    echo "[$ts] Error: git no disponible" >> "$LOG_FILE"
    date +%s > "$LAST_CHECK_FILE"
    echo "git no está disponible — instala las Command Line Tools" > "$PENDING_NOTIF_FILE"
    exit 0
fi

snoozed=0
if [ -f "$SNOOZE_FILE" ]; then
    snooze_until="$(cat "$SNOOZE_FILE" 2>/dev/null)"
    now="$(date +%s)"
    if [ -n "$snooze_until" ] && [ "$now" -lt "$snooze_until" ]; then
        snoozed=1
    else
        rm -f "$SNOOZE_FILE"
    fi
fi

repos=()
while IFS= read -r repo_path; do
    repos+=("$repo_path")
done < <(discover_repos | awk '!seen[$0]++')

outdated=()
ahead=()
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
            ahead_n="$("$GIT_BIN" -C "$dir" rev-list --count '@{u}..HEAD' 2>/dev/null)"
            if [ -n "$ahead_n" ] && [ "$ahead_n" -gt 0 ]; then
                ahead+=("• $name [$branch] — $ahead_n commit(s) sin subir")
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
if [ ${#ahead[@]} -gt 0 ]; then
    [ ${#notif_lines[@]} -gt 0 ] && notif_lines+=("")
    notif_lines+=("── Sin subir ──")
    notif_lines+=("${ahead[@]}")
fi
if [ ${#dirty[@]} -gt 0 ]; then
    [ ${#notif_lines[@]} -gt 0 ] && notif_lines+=("")
    notif_lines+=("── Cambios sin commitear ──")
    notif_lines+=("${dirty[@]}")
fi

if [ ${#notif_lines[@]} -gt 24 ]; then
    n_extra=$((${#notif_lines[@]} - 24))
    notif_lines=("${notif_lines[@]:0:24}" "… y $n_extra línea(s) más")
fi

if [ ${#notif_lines[@]} -gt 0 ]; then
    log_msg="Desactualizados: $(IFS='; '; echo "${outdated[*]:-ninguno}") | Sin subir: $(IFS='; '; echo "${ahead[*]:-ninguno}") | Sin commitear: $(IFS='; '; echo "${dirty[*]:-ninguno}")"
    echo "[$ts] $log_msg" >> "$LOG_FILE"

    notif_body="$(printf '%s\n' "${notif_lines[@]}")"
    notif_body="${notif_body%$'\n'}"
    notif_title="RepoWatch: repos con pendientes"

    echo "$notif_body" > "$STATE_FILE"

    if [ "$snoozed" -eq 1 ]; then
        echo "[$ts] Notificación pospuesta." >> "$LOG_FILE"
    else
        echo "$notif_body" > "$PENDING_NOTIF_FILE"

        # Botón de acción principal según la categoría más urgente presente.
        if [ ${#dirty[@]} -gt 0 ]; then
            action_button="Revisar y commitear"
        elif [ ${#ahead[@]} -gt 0 ]; then
            action_button="Pushear pendientes"
        else
            action_button="Actualizar"
        fi

        choice="$(osascript - "$notif_title" "$notif_body" "$action_button" <<'APPLESCRIPT' 2>/dev/null
on run argv
    set theResult to display dialog (item 2 of argv) with title (item 1 of argv) buttons {"Posponer 1h", "Cerrar", (item 3 of argv)} default button (item 3 of argv) giving up after 600 with icon note
    return button returned of theResult
end run
APPLESCRIPT
)"
        case "$choice" in
            "Posponer 1h")
                echo "$(($(date +%s) + 3600))" > "$SNOOZE_FILE"
                echo "[$ts] Pospuesto 1 hora." >> "$LOG_FILE"
                ;;
            "Revisar y commitear") "$REVIEW_SCRIPT" ;;
            "Pushear pendientes") "$PUSH_SCRIPT" ;;
            "Actualizar") "$PULL_SCRIPT" ;;
        esac
    fi
else
    echo "[$ts] Todos los repos están actualizados y sin cambios pendientes." >> "$LOG_FILE"
    rm -f "$STATE_FILE"
fi

if [ ${#autosynced[@]} -gt 0 ]; then
    echo "[$ts] Autosync: $(IFS='; '; echo "${autosynced[*]}")" >> "$LOG_FILE"
    if [ "$snoozed" -eq 0 ]; then
        printf 'Sincronizado automáticamente: %s\n' "$(IFS='; '; echo "${autosynced[*]}")" >> "$PENDING_NOTIF_FILE"
    fi
fi

if [ ${#errors[@]} -gt 0 ]; then
    echo "[$ts] Errores: $(IFS='; '; echo "${errors[*]}")" >> "$LOG_FILE"
fi

date +%s > "$LAST_CHECK_FILE"

#!/bin/bash
# Recorre los repos vigilados en modo revisión (los de modo autosync ya se
# manejan solos en check_git_repos.sh) y, para cada uno con cambios sin
# commitear, muestra una ventana con el detalle + un campo para el mensaje
# de commit. Según el botón:
#   - Omitir: no toca el repo.
#   - Commit: git add (-A o -u según el override "stage") + git commit
#     (firmado con SSH si está activado, global o por repo), vía
#     -c gpg.format=ssh -c user.signingkey=... — no toca la config global.
#   - Commit + Push: lo anterior + push al primer remoto que responda
#     (salvo que el override "push" del repo sea "never").

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib_discover_repos.sh"
source "$SCRIPT_DIR/lib_settings.sh"
source "$SCRIPT_DIR/lib_repo_config.sh"
source "$SCRIPT_DIR/lib_commit_safety.sh"
load_settings

# Evita dos revisiones a la vez (ej. clic manual mientras corre otra).
LOCK_DIR="$CONFIG_DIR/.review.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    osascript -e 'display notification "Ya hay una revisión en curso." with title "RepoWatch"' >/dev/null 2>&1
    exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT INT TERM

export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND='ssh -oBatchMode=yes -oConnectTimeout=10'

GIT_BIN="$(command -v git)"
LOG_FILE="$CONFIG_DIR/logs/check_git_repos.log"
mkdir -p "$CONFIG_DIR/logs"

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }

show_alert() {
    osascript - "$1" "$2" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
    display alert (item 1 of argv) message (item 2 of argv)
end run
APPLESCRIPT
}

repos=()
while IFS= read -r repo_path; do
    repos+=("$repo_path")
done < <(discover_repos | awk '!seen[$0]++')

any_reviewed=0

for dir in "${repos[@]}"; do
    name="$(basename "$dir")"

    [ "$(repo_get "$dir" enabled true)" = "false" ] && continue
    [ "$(repo_get "$dir" mode review)" = "autosync" ] && continue

    if [ "$(repo_get "$dir" untracked include)" = "ignore" ]; then
        status_short="$("$GIT_BIN" -C "$dir" status --short -uno 2>/dev/null)"
    else
        status_short="$("$GIT_BIN" -C "$dir" status --short --untracked-files=all 2>/dev/null)"
    fi
    [ -z "$status_short" ] && continue

    any_reviewed=1
    ts="$(timestamp)"

    n_lines="$(printf '%s\n' "$status_short" | wc -l | tr -d ' ')"
    display_status="$(printf '%s\n' "$status_short" | head -20)"
    if [ "$n_lines" -gt 20 ]; then
        display_status="$display_status
… y $((n_lines - 20)) archivo(s) más"
    fi

    branch="$("$GIT_BIN" -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"

    sensitive_hits="$(find_sensitive_files "$status_short")"
    if [ -n "$sensitive_hits" ]; then
        warn_choice="$(osascript - "$name" "$sensitive_hits" <<'APPLESCRIPT' 2>/dev/null
on run argv
    set theResult to display alert ("⚠️ Posibles archivos sensibles en " & (item 1 of argv)) message ("Estos archivos cambiados parecen credenciales o llaves:" & return & return & (item 2 of argv) & return & return & "¿Continuar de todas formas?") buttons {"Omitir repo", "Continuar"} default button "Omitir repo"
    return button returned of theResult
end run
APPLESCRIPT
)"
        if [ "$warn_choice" != "Continuar" ]; then
            echo "[$ts] $name: omitido por archivos sensibles ($(echo "$sensitive_hits" | tr '\n' ' '))" >> "$LOG_FILE"
            continue
        fi
    fi

    large_hits="$(find_large_files "$status_short" "$dir")"
    if [ -n "$large_hits" ]; then
        warn_choice="$(osascript - "$name" "$large_hits" <<'APPLESCRIPT' 2>/dev/null
on run argv
    set theResult to display alert ("⚠️ Archivo(s) grande(s) en " & (item 1 of argv)) message ("Pesan más de 100MB — probablemente no deberían ir a git:" & return & return & (item 2 of argv) & return & return & "¿Continuar de todas formas?") buttons {"Omitir repo", "Continuar"} default button "Omitir repo"
    return button returned of theResult
end run
APPLESCRIPT
)"
        if [ "$warn_choice" != "Continuar" ]; then
            echo "[$ts] $name: omitido por archivo(s) grande(s) ($(echo "$large_hits" | tr '\n' ' '))" >> "$LOG_FILE"
            continue
        fi
    fi

    suggested_message="$(suggest_commit_message "$status_short" "$n_lines")"
    push_mode="$(repo_get "$dir" push ask)"

    prompt="Rama: $branch

Cambios ($n_lines archivo(s)):
$display_status

Mensaje de commit:"

    if [ "$push_mode" = "never" ]; then
        dialog_out="$(osascript - "$prompt" "Revisar: $name" "$suggested_message" <<'APPLESCRIPT' 2>/dev/null
on run argv
    set theResult to display dialog (item 1 of argv) default answer (item 3 of argv) with title (item 2 of argv) buttons {"Omitir", "Commit"} default button "Commit" cancel button "Omitir" giving up after 900 with icon note
    return (button returned of theResult) & "|||" & (text returned of theResult)
end run
APPLESCRIPT
)"
    else
        dialog_out="$(osascript - "$prompt" "Revisar: $name" "$suggested_message" <<'APPLESCRIPT' 2>/dev/null
on run argv
    set theResult to display dialog (item 1 of argv) default answer (item 3 of argv) with title (item 2 of argv) buttons {"Omitir", "Commit", "Commit + Push"} default button "Commit" cancel button "Omitir" giving up after 900 with icon note
    return (button returned of theResult) & "|||" & (text returned of theResult)
end run
APPLESCRIPT
)"
    fi
    status=$?

    if [ $status -ne 0 ]; then
        echo "[$ts] $name: omitido por el usuario" >> "$LOG_FILE"
        continue
    fi

    button="${dialog_out%%|||*}"
    message="${dialog_out#*|||}"
    [ -z "$message" ] && message="Update $name"

    # Para poder deshacer el add si el commit falla: solo si el índice
    # estaba limpio antes de tocarlo (si ya había algo stageado a mano, no
    # lo pisamos).
    was_index_clean=1
    "$GIT_BIN" -C "$dir" diff --cached --quiet 2>/dev/null || was_index_clean=0

    stage_mode="$(repo_get "$dir" stage all)"
    if [ "$stage_mode" = "tracked" ]; then
        add_ok=1; "$GIT_BIN" -C "$dir" add -u 2>/tmp/git_review_err || add_ok=0
    else
        add_ok=1; "$GIT_BIN" -C "$dir" add -A 2>/tmp/git_review_err || add_ok=0
    fi
    if [ "$add_ok" -ne 1 ]; then
        show_alert "Error en $name" "git add falló: $(tail -n1 /tmp/git_review_err)"
        echo "[$ts] $name: git add falló" >> "$LOG_FILE"
        continue
    fi

    sign_mode="$(repo_get "$dir" sign "$SIGN_COMMITS")"
    signing_key="$(repo_get "$dir" signing_key "$SIGNING_KEY")"
    commit_ok=1
    if [ "$sign_mode" = "true" ] && [ -n "$signing_key" ]; then
        "$GIT_BIN" -C "$dir" -c gpg.format=ssh -c "user.signingkey=$signing_key" commit -S -m "$message" 2>/tmp/git_review_err || commit_ok=0
    else
        "$GIT_BIN" -C "$dir" commit -m "$message" 2>/tmp/git_review_err || commit_ok=0
    fi
    if [ "$commit_ok" -ne 1 ]; then
        show_alert "Error en $name" "git commit falló: $(tail -n1 /tmp/git_review_err)"
        echo "[$ts] $name: git commit falló" >> "$LOG_FILE"
        if [ "$was_index_clean" -eq 1 ]; then
            "$GIT_BIN" -C "$dir" reset >/dev/null 2>&1
        fi
        continue
    fi
    echo "[$ts] $name: commit creado (\"$message\")" >> "$LOG_FILE"

    if [ "$button" = "Commit + Push" ]; then
        push_remote=""
        for r in $("$GIT_BIN" -C "$dir" remote); do
            if "$GIT_BIN" -C "$dir" ls-remote --exit-code "$r" >/dev/null 2>&1; then
                push_remote="$r"
                break
            fi
        done

        if [ -z "$push_remote" ]; then
            echo "[$ts] $name: push omitido, ningún remoto disponible" >> "$LOG_FILE"
        elif "$GIT_BIN" -C "$dir" push "$push_remote" 2>/tmp/git_review_err; then
            echo "[$ts] $name: push OK ($push_remote)" >> "$LOG_FILE"
        else
            show_alert "Error en $name" "git push $push_remote falló: $(tail -n1 /tmp/git_review_err)"
            echo "[$ts] $name: push falló ($push_remote)" >> "$LOG_FILE"
        fi
    fi
done

if [ "$any_reviewed" -eq 0 ]; then
    osascript -e 'display notification "No hay cambios sin commitear en ningún repo." with title "RepoWatch"' >/dev/null 2>&1
else
    osascript -e 'display notification "Revisión de repos completada." with title "RepoWatch" sound name "Ping"' >/dev/null 2>&1
fi

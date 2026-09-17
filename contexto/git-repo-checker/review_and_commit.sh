#!/bin/bash
# Recorre los repos vigilados y, para cada uno que tenga cambios sin
# commitear, muestra una ventana con el detalle de archivos modificados y un
# campo para el mensaje de commit. Según el botón elegido:
#   - Omitir: no toca el repo, pasa al siguiente.
#   - Commit: git add -A + git commit -S (firmado con la llave SSH configurada).
#   - Commit + Push: lo anterior + git push.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib_discover_repos.sh"

GIT_BIN="$(command -v git)"
LOG_FILE="/Users/alex/scripts/logs/check_git_repos.log"

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }

show_alert() {
    osascript - "$1" "$2" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
    display alert (item 1 of argv) message (item 2 of argv)
end run
APPLESCRIPT
}

# Nombres de archivo que podrían contener secretos. Coincide contra el
# basename de cada archivo con cambios, antes de hacer `git add -A`.
SENSITIVE_PATTERNS=(
    ".env" ".env.*" "*.pem" "*.key" "*.p12" "*.pfx" "*.keystore" "*.ppk"
    "id_rsa" "id_rsa.*" "id_ed25519" "id_ed25519.*" "id_ecdsa" "id_ecdsa.*"
    "*credentials*.json" "*credentials*.yml" "*credentials*.yaml"
    "*secrets*.json" "*secrets*.yml" "*secrets*.yaml" "*.asc"
)

find_sensitive_files() {
    local status="$1"
    local line path base pat
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        path="${line:3}"
        path="${path#* -> }"
        base="$(basename "$path")"
        for pat in "${SENSITIVE_PATTERNS[@]}"; do
            case "$base" in
                $pat) printf '%s\n' "$path"; break ;;
            esac
        done
    done <<< "$status"
}

# Sugiere un mensaje de commit a partir de los archivos cambiados: lista los
# nombres si son pocos, o las carpetas de nivel superior si son muchos.
suggest_commit_message() {
    local status="$1" n_lines="$2"
    local files dirs
    if [ "$n_lines" -le 3 ]; then
        files="$(printf '%s\n' "$status" | cut -c4- | sed 's/ -> .*//' | paste -sd ',' - | sed 's/,/, /g')"
        echo "Update $files"
    else
        dirs="$(printf '%s\n' "$status" | cut -c4- | sed 's/ -> .*//' | awk -F/ 'NF>1{print $1} NF==1{print "raíz"}' | sort -u | paste -sd ',' - | sed 's/,/, /g')"
        echo "Update $n_lines files ($dirs)"
    fi
}

repos=()
while IFS= read -r repo_path; do
    repos+=("$repo_path")
done < <(discover_repos)

any_reviewed=0

for dir in "${repos[@]}"; do
    name="$(basename "$dir")"
    status_short="$("$GIT_BIN" -C "$dir" status --short 2>/dev/null)"
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

    suggested_message="$(suggest_commit_message "$status_short" "$n_lines")"

    prompt="Rama: $branch

Cambios ($n_lines archivo(s)):
$display_status

Mensaje de commit:"

    dialog_out="$(osascript - "$prompt" "Revisar: $name" "$suggested_message" <<'APPLESCRIPT' 2>/dev/null
on run argv
    set theResult to display dialog (item 1 of argv) default answer (item 3 of argv) with title (item 2 of argv) buttons {"Omitir", "Commit", "Commit + Push"} default button "Commit" cancel button "Omitir" with icon note
    return (button returned of theResult) & "|||" & (text returned of theResult)
end run
APPLESCRIPT
)"
    status=$?

    if [ $status -ne 0 ]; then
        echo "[$ts] $name: omitido por el usuario" >> "$LOG_FILE"
        continue
    fi

    button="${dialog_out%%|||*}"
    message="${dialog_out#*|||}"
    [ -z "$message" ] && message="Update $name"

    if ! "$GIT_BIN" -C "$dir" add -A 2>/tmp/git_review_err; then
        show_alert "Error en $name" "git add falló: $(tail -n1 /tmp/git_review_err)"
        echo "[$ts] $name: git add falló" >> "$LOG_FILE"
        continue
    fi

    if ! "$GIT_BIN" -C "$dir" commit -S -m "$message" 2>/tmp/git_review_err; then
        show_alert "Error en $name" "git commit falló: $(tail -n1 /tmp/git_review_err)"
        echo "[$ts] $name: git commit falló" >> "$LOG_FILE"
        continue
    fi
    echo "[$ts] $name: commit creado (\"$message\")" >> "$LOG_FILE"

    if [ "$button" = "Commit + Push" ]; then
        if ! "$GIT_BIN" -C "$dir" ls-remote --exit-code origin >/dev/null 2>&1; then
            # Remoto no disponible ahora mismo (ej. disco externo desconectado)
            # → mismo trato silencioso que un fetch fallido, sin alerta.
            echo "[$ts] $name: push omitido, remoto no disponible" >> "$LOG_FILE"
        elif "$GIT_BIN" -C "$dir" push 2>/tmp/git_review_err; then
            echo "[$ts] $name: push OK" >> "$LOG_FILE"
        else
            show_alert "Error en $name" "git push falló: $(tail -n1 /tmp/git_review_err)"
            echo "[$ts] $name: push falló" >> "$LOG_FILE"
        fi
    fi
done

if [ "$any_reviewed" -eq 0 ]; then
    osascript -e 'display notification "No hay cambios sin commitear en ningún repo." with title "Git: revisión completa"' >/dev/null 2>&1
else
    osascript -e 'display notification "Revisión de repos completada." with title "Git: revisión completa" sound name "Ping"' >/dev/null 2>&1
fi

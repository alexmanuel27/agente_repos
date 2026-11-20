# Se debe cargar con `source`. Define discover_repos(), que imprime (una
# por línea) la ruta de cada repo vigilado: subcarpetas con .git dentro de
# cada carpeta en watch_folders.txt, + las rutas listadas en repos.txt.
# Config por usuario en ~/Library/Application Support/RepoWatch/, editable
# desde Preferencias en la app.

CONFIG_DIR="$HOME/Library/Application Support/RepoWatch"
WATCH_FOLDERS_FILE="$CONFIG_DIR/watch_folders.txt"
REPOS_FILE="$CONFIG_DIR/repos.txt"

# SSH sin preguntar y con UNA conexión reutilizada (ControlMaster) para todos
# los repos del mismo host: abrir una nueva por cada fetch/ls-remote/push hace
# que GitHub corte con «Connection reset by peer» y los repos salgan como
# «remoto no disponible». ControlPath corto y en /tmp (límite de ~100 bytes).
RW_SSH='ssh -oBatchMode=yes -oConnectTimeout=10 -oControlMaster=auto -oControlPath=/tmp/rw-ssh-%C -oControlPersist=120'
export GIT_SSH_COMMAND="$RW_SSH"

discover_repos() {
    local folder dir line
    if [ -f "$WATCH_FOLDERS_FILE" ]; then
        while IFS= read -r folder; do
            [ -z "$folder" ] && continue
            for dir in "$folder"/*/; do
                [ -d "${dir}.git" ] && printf '%s\n' "${dir%/}"
            done
        done < "$WATCH_FOLDERS_FILE"
    fi

    if [ -f "$REPOS_FILE" ]; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            [ -d "$line/.git" ] && printf '%s\n' "${line%/}"
        done < "$REPOS_FILE"
    fi
}

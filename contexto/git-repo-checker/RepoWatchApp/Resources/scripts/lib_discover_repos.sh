# Se debe cargar con `source`. Define discover_repos(), que imprime (una
# por línea) la ruta de cada repo vigilado: subcarpetas con .git dentro de
# cada carpeta en watch_folders.txt, + las rutas listadas en repos.txt.
# Config por usuario en ~/Library/Application Support/RepoWatch/, editable
# desde Preferencias en la app.

CONFIG_DIR="$HOME/Library/Application Support/RepoWatch"
WATCH_FOLDERS_FILE="$CONFIG_DIR/watch_folders.txt"
REPOS_FILE="$CONFIG_DIR/repos.txt"

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

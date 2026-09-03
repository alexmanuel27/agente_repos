# Se debe cargar con `source`, no ejecutar directamente.
# Define discover_repos(), que imprime (una por línea) la ruta de cada repo
# vigilado: las subcarpetas con .git de REPOS_DIR + las rutas listadas en
# EXTRA_REPOS_FILE.

REPOS_DIR="/Users/alex/Nube /repos"
EXTRA_REPOS_FILE="/Users/alex/scripts/extra_repos.txt"

discover_repos() {
    local dir line
    for dir in "$REPOS_DIR"/*/; do
        [ -d "${dir}.git" ] && printf '%s\n' "${dir%/}"
    done

    if [ -f "$EXTRA_REPOS_FILE" ]; then
        while IFS= read -r line; do
            line="${line%%#*}"
            line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            [ -z "$line" ] && continue
            [ -d "$line/.git" ] && printf '%s\n' "${line%/}"
        done < "$EXTRA_REPOS_FILE"
    fi
}

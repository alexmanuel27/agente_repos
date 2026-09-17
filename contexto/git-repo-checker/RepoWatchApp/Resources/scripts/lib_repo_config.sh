# Se debe cargar con `source` (después de lib_discover_repos.sh, que define
# CONFIG_DIR). Define repo_get(), que lee un override de repo_overrides.txt
# (ruta TAB clave TAB valor, una línea por override) o devuelve el default
# si no hay override para esa ruta+clave. Última línea gana.

OVERRIDES_FILE="$CONFIG_DIR/repo_overrides.txt"

repo_get() {
    local repo="$1" key="$2" default="$3" val=""
    if [ -f "$OVERRIDES_FILE" ]; then
        val="$(awk -F'\t' -v p="$repo" -v k="$key" '$1==p && $2==k { v=$3 } END { print v }' "$OVERRIDES_FILE")"
    fi
    if [ -n "$val" ]; then
        echo "$val"
    else
        echo "$default"
    fi
}

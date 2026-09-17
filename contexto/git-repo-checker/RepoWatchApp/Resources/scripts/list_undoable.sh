#!/bin/bash
# Imprime "ruta\tnombre" por cada repo cuyo último commit de RepoWatch
# todavía se puede deshacer (HEAD sin cambiar, no pusheado). Lo usa el menú
# de la app para armar el submenú "Deshacer…" dinámicamente.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib_discover_repos.sh"
source "$SCRIPT_DIR/lib_commit_safety.sh"

GIT_BIN="$(command -v git)"
[ -f "$LAST_COMMITS_FILE" ] || exit 0

while IFS=$'\t' read -r dir sha pushed; do
    [ -z "$dir" ] && continue
    [ "$pushed" = "1" ] && continue
    current="$("$GIT_BIN" -C "$dir" rev-parse HEAD 2>/dev/null)"
    [ "$current" = "$sha" ] && printf '%s\t%s\n' "$dir" "$(basename "$dir")"
done < "$LAST_COMMITS_FILE"

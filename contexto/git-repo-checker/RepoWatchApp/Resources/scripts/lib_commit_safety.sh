# Se debe cargar con `source`, después de lib_discover_repos.sh,
# lib_settings.sh (con load_settings ya llamado) y lib_repo_config.sh.
# Funciones compartidas por check_git_repos.sh (autosync headless) y
# review_and_commit.sh (revisión interactiva) — una sola implementación de
# cada chequeo de seguridad, no dos copias que puedan divergir.

# Nombres de archivo que podrían contener secretos. Coincide contra el
# basename de cada archivo con cambios.
LAST_COMMITS_FILE="$CONFIG_DIR/last_commits.txt"

SENSITIVE_PATTERNS=(
    ".env" ".env.*" "*.pem" "*.key" "*.p12" "*.pfx" "*.keystore" "*.ppk"
    "id_rsa" "id_rsa.*" "id_ed25519" "id_ed25519.*" "id_ecdsa" "id_ecdsa.*"
    "*credentials*.json" "*credentials*.yml" "*credentials*.yaml"
    "*secrets*.json" "*secrets*.yml" "*secrets*.yaml" "*.asc"
)

# $1 = salida de `git status --porcelain --untracked-files=all` (o -uno)
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

# $1 = salida de git status, $2 = directorio del repo. Archivos > 100MB.
find_large_files() {
    local status="$1" dir="$2"
    local line path full size
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        path="${line:3}"
        path="${path#* -> }"
        full="$dir/$path"
        [ -f "$full" ] || continue
        size="$(stat -f%z "$full" 2>/dev/null || echo 0)"
        if [ "$size" -gt 104857600 ]; then
            printf '%s (%d MB)\n' "$path" "$((size / 1048576))"
        fi
    done <<< "$status"
}

# $1 = directorio. Busca patrones de secretos en el CONTENIDO de lo ya
# stageado (`git diff --cached`), no solo en nombres de archivo — cubre el
# caso de una llave pegada dentro de un .md o .txt cualquiera.
find_secret_content() {
    local dir="$1"
    "$GIT_BIN" -C "$dir" diff --cached -U0 2>/dev/null | \
        grep -Eo 'AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----' | \
        sort -u
}

# Registra el último commit hecho por RepoWatch en un repo, para poder
# ofrecer "deshacer" después (solo válido mientras HEAD siga siendo ese sha
# y no se haya pusheado). Una línea por repo, sobreescribe la anterior.
record_commit() {
    local dir="$1" pushed="$2" sha
    sha="$("$GIT_BIN" -C "$dir" rev-parse HEAD 2>/dev/null)"
    [ -z "$sha" ] && return
    local tmp="$LAST_COMMITS_FILE.tmp"
    { [ -f "$LAST_COMMITS_FILE" ] && grep -v "^${dir}	" "$LAST_COMMITS_FILE"; \
      printf '%s\t%s\t%s\n' "$dir" "$sha" "$pushed"; } > "$tmp"
    mv "$tmp" "$LAST_COMMITS_FILE"
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

# Commit + push headless para repos en modo autosync. $1 = directorio,
# $2 = salida de git status (ya calculada por el caller). Devuelve 1 (y no
# toca el repo) si cualquier guarda de seguridad salta, para que el caller
# lo trate como un repo normal en modo revisión en vez de fallar en silencio.
autosync_commit() {
    local dir="$1" status="$2"
    local name; name="$(basename "$dir")"

    if [ -e "$dir/.git/MERGE_HEAD" ] || [ -d "$dir/.git/rebase-merge" ] || \
       [ -d "$dir/.git/rebase-apply" ] || [ -e "$dir/.git/CHERRY_PICK_HEAD" ]; then
        echo "autosync omitido ($name): merge/rebase/cherry-pick en curso" >&2
        return 1
    fi

    local branch; branch="$("$GIT_BIN" -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
        echo "autosync omitido ($name): HEAD separado" >&2
        return 1
    fi

    if [ -z "$("$GIT_BIN" -C "$dir" config user.email)" ] || [ -z "$("$GIT_BIN" -C "$dir" config user.name)" ]; then
        echo "autosync omitido ($name): falta user.name/user.email" >&2
        return 1
    fi

    if [ -n "$(find_sensitive_files "$status")" ]; then
        echo "autosync omitido ($name): posibles archivos sensibles" >&2
        return 1
    fi

    if [ -n "$(find_large_files "$status" "$dir")" ]; then
        echo "autosync omitido ($name): archivo(s) mayor(es) a 100MB" >&2
        return 1
    fi

    local stage_mode; stage_mode="$(repo_get "$dir" stage all)"
    if [ "$stage_mode" = "tracked" ]; then
        "$GIT_BIN" -C "$dir" add -u
    else
        "$GIT_BIN" -C "$dir" add -A
    fi

    if [ -n "$(find_secret_content "$dir")" ]; then
        echo "autosync omitido ($name): posible secreto en el contenido de un archivo" >&2
        "$GIT_BIN" -C "$dir" reset >/dev/null 2>&1
        return 1
    fi

    local msg commit_ok=1 sign_mode signing_key
    msg="Sync $(date "+%Y-%m-%d %H:%M")"
    sign_mode="$(repo_get "$dir" sign "$SIGN_COMMITS")"
    signing_key="$(repo_get "$dir" signing_key "$SIGNING_KEY")"

    if [ "$sign_mode" = "true" ] && [ -n "$signing_key" ]; then
        "$GIT_BIN" -C "$dir" -c gpg.format=ssh -c "user.signingkey=$signing_key" commit -S -m "$msg" >/dev/null 2>&1 || commit_ok=0
    else
        "$GIT_BIN" -C "$dir" commit -m "$msg" >/dev/null 2>&1 || commit_ok=0
    fi

    if [ "$commit_ok" -ne 1 ]; then
        echo "autosync: commit falló en $name" >&2
        "$GIT_BIN" -C "$dir" reset >/dev/null 2>&1
        return 1
    fi

    local pushed=0
    local push_mode; push_mode="$(repo_get "$dir" push auto)"
    if [ "$push_mode" != "never" ]; then
        local push_remote=""
        for r in $("$GIT_BIN" -C "$dir" remote); do
            if "$GIT_BIN" -C "$dir" ls-remote --exit-code "$r" >/dev/null 2>&1; then
                push_remote="$r"
                break
            fi
        done
        if [ -n "$push_remote" ] && "$GIT_BIN" -C "$dir" push "$push_remote" >/dev/null 2>&1; then
            pushed=1
        fi
    fi

    record_commit "$dir" "$pushed"
    return 0
}

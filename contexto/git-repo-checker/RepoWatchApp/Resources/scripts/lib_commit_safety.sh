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
        if [ "$size" -gt "${LARGE_FILE_BYTES:-104857600}" ]; then
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
# nombres si son pocos, o las carpetas de nivel superior (hasta 4) si son muchos.
suggest_commit_message() {
    local status="$1" n_lines="$2"
    local files dirs
    if [ "$n_lines" -le 3 ]; then
        files="$(printf '%s\n' "$status" | cut -c4- | sed 's/ -> .*//; s/^"//; s/"$//' | paste -sd ',' - | sed 's/,/, /g')"
        echo "Update $files"
    else
        dirs="$(printf '%s\n' "$status" | cut -c4- | sed 's/ -> .*//; s/^"//; s/"$//' | awk -F/ 'NF>1{print $1} NF==1{print "raíz"}' | sort -u)"
        if [ "$(printf '%s\n' "$dirs" | wc -l)" -gt 4 ]; then
            dirs="$(printf '%s\n' "$dirs" | head -n 4 | paste -sd ',' - | sed 's/,/, /g'), …"
        else
            dirs="$(printf '%s\n' "$dirs" | paste -sd ',' - | sed 's/,/, /g')"
        fi
        echo "Update $n_lines files ($dirs)"
    fi
}

# $1 = directorio. Imprime la ruta de la nota del vault que lista este repo
# (línea «- `ruta`» en su sección Repositorios); la más reciente si hay varias.
vault_project_note() {
    [ -n "$VAULT_DIR" ] && [ -d "$VAULT_DIR" ] || return 0
    local f best=""
    while IFS= read -r f; do
        case "$f" in */vault_backups/*|*"Mantenimiento del vault.md") continue ;; esac
        if [ -z "$best" ] || [ "$f" -nt "$best" ]; then best="$f"; fi
    done < <(grep -rlF --include='*.md' -- "- \`$1\`" "$VAULT_DIR" 2>/dev/null)
    printf '%s' "$best"
}

# Arma COMMIT_SUBJECT / COMMIT_BODY. Sin IA: el asunto sale de los archivos
# cambiados, con el título del proyecto del vault delante; el cuerpo cita la
# última línea del Registro de esa nota solo si es de los últimos 7 días
# (una nota vieja daría un contexto falso). $1 dir, $2 status, $3 nº de líneas.
vault_commit_message() {
    local dir="$1" status="$2" n="$3" note title reg d cutoff txt
    COMMIT_SUBJECT="$(suggest_commit_message "$status" "$n")"
    COMMIT_BODY=""
    note="$(vault_project_note "$dir")"
    [ -n "$note" ] || return 0
    title="$(sed -n 's/^# //p' "$note" | head -n 1)"
    [ -n "$title" ] && COMMIT_SUBJECT="$title: $COMMIT_SUBJECT"
    reg="$(grep -E '^- [0-9]{4}-[0-9]{2}-[0-9]{2}' "$note" | tail -n 1)"
    [ -n "$reg" ] || return 0
    d="${reg:2:10}"
    cutoff="$(date -v-7d +%Y-%m-%d)"
    [[ "$d" < "$cutoff" ]] && return 0
    txt="${reg#*— }"
    if [ "${#txt}" -gt 160 ]; then
        txt="$(printf '%s' "${txt:0:160}" | sed 's/ [^ ]*$//')…"
    fi
    COMMIT_BODY="Contexto (vault, $d): $txt"
}

# Sube al primer remoto que responda. 0 = subido, 1 = ningún remoto
# alcanzable (esperado con discos externos desconectados), 2 = el push
# falló con remoto alcanzable (AUTO_PUSH_ERR).
auto_push() {
    local dir="$1" r remote="" out
    AUTO_PUSH_ERR=""
    for r in $("$GIT_BIN" -C "$dir" remote); do
        if "$GIT_BIN" -C "$dir" ls-remote "$r" >/dev/null 2>&1; then
            remote="$r"
            break
        fi
    done
    [ -z "$remote" ] && return 1
    # Rama sin upstream válido (nunca se subió, o la rama remota ya no existe):
    # -u lo deja configurado. Con upstream válido se mantiene tal cual (no
    # mover el upstream de nube a un disco de respaldo).
    if "$GIT_BIN" -C "$dir" rev-parse --verify -q '@{u}' >/dev/null 2>&1; then
        out="$("$GIT_BIN" -C "$dir" push "$remote" 2>&1)" && return 0
    else
        out="$("$GIT_BIN" -C "$dir" push -u "$remote" HEAD 2>&1)" && return 0
    fi
    AUTO_PUSH_ERR="$(printf '%s\n' "$out" | grep -v '^$' | tail -n 1)"
    return 2
}

# Trae lo del upstream (el fetch ya se hizo). Sin commits locales por subir:
# fast-forward. Con commits por subir (divergido): merge, y si choca se
# aborta y se reporta como conflicto — nunca se deja el repo a medias.
# Deja AUTO_PULL_N (commits traídos) y AUTO_PULL_ERR. 0 = bien o nada que hacer.
auto_pull() {
    local dir="$1" behind ahead out rc key
    AUTO_PULL_N=0; AUTO_PULL_ERR=""
    behind="$("$GIT_BIN" -C "$dir" rev-list --count 'HEAD..@{u}' 2>/dev/null)"
    [ -z "$behind" ] || [ "$behind" -eq 0 ] && return 0
    if [ -e "$dir/.git/MERGE_HEAD" ] || [ -d "$dir/.git/rebase-merge" ] || [ -d "$dir/.git/rebase-apply" ]; then
        AUTO_PULL_ERR="hay un merge/rebase en curso"; return 1
    fi
    if [ -n "$("$GIT_BIN" -C "$dir" status --porcelain -uno 2>/dev/null)" ]; then
        AUTO_PULL_ERR="cambios sin commitear impiden el pull"; return 1
    fi
    ahead="$("$GIT_BIN" -C "$dir" rev-list --count '@{u}..HEAD' 2>/dev/null)"
    if [ "$ahead" -eq 0 ]; then
        out="$("$GIT_BIN" -C "$dir" pull --ff-only 2>&1)"; rc=$?
    else
        key="$(repo_get "$dir" signing_key "$SIGNING_KEY")"
        if [ "$(repo_get "$dir" sign "$SIGN_COMMITS")" = "true" ] && [ -n "$key" ]; then
            out="$("$GIT_BIN" -C "$dir" -c gpg.format=ssh -c "user.signingkey=$key" pull --no-rebase --no-edit -S 2>&1)"; rc=$?
        else
            out="$("$GIT_BIN" -C "$dir" pull --no-rebase --no-edit 2>&1)"; rc=$?
        fi
    fi
    if [ "$rc" -ne 0 ]; then
        if [ -e "$dir/.git/MERGE_HEAD" ]; then
            "$GIT_BIN" -C "$dir" merge --abort >/dev/null 2>&1
            AUTO_PULL_ERR="conflicto al traer cambios del remoto (se abortó el merge)"
        else
            AUTO_PULL_ERR="pull falló: $(printf '%s\n' "$out" | grep -v '^$' | tail -n 1)"
        fi
        return 1
    fi
    AUTO_PULL_N="$behind"
    return 0
}

# GitHub rechaza archivos de más de 100MB; otros remotos (discos locales,
# servidores propios) no tienen ese límite, así que la excepción de abajo
# (ignorar + reescribir commits sin subir) solo aplica a repos con remoto
# GitHub. SIZE_LIMIT_REMOTE_PATTERN / LARGE_FILE_BYTES existen para las pruebas.
has_size_limit() {
    "$GIT_BIN" -C "$1" remote -v 2>/dev/null | grep -qE "${SIZE_LIMIT_REMOTE_PATTERN:-github\.com}"
}

# Línea para .gitignore de una ruta exacta: ancla con «/» y escapa lo que git
# trata como comodín.
gitignore_entry() {
    printf '/%s\n' "$(printf '%s' "$1" | sed 's/[]\\[*?#!]/\\&/g')"
}

add_to_gitignore() {
    local dir="$1" path="$2" entry
    entry="$(gitignore_entry "$path")"
    touch "$dir/.gitignore"
    grep -qxF -- "$entry" "$dir/.gitignore" && return 0
    [ -s "$dir/.gitignore" ] && [ -n "$(tail -c1 "$dir/.gitignore")" ] && echo >> "$dir/.gitignore"
    printf '%s\n' "$entry" >> "$dir/.gitignore"
}

# Commit firmado (si corresponde) de lo ya stageado. $1 dir, $2 asunto.
_commit_staged() {
    local dir="$1" subject="$2" key
    key="$(repo_get "$dir" signing_key "$SIGNING_KEY")"
    if [ "$(repo_get "$dir" sign "$SIGN_COMMITS")" = "true" ] && [ -n "$key" ]; then
        "$GIT_BIN" -C "$dir" -c gpg.format=ssh -c "user.signingkey=$key" commit -S -m "$subject" >/dev/null 2>&1
    else
        "$GIT_BIN" -C "$dir" commit -m "$subject" >/dev/null 2>&1
    fi
}

# Archivos SIN TRACKEAR de más de 100MB: se agregan a .gitignore en vez de
# commitearlos. Los trackeados no se tocan (ya están en el historial).
# $1 dir, $2 status. Devuelve 0 si ignoró alguno. Avisa vía RW_NOTES.
ignore_large_untracked() {
    local dir="$1" status="$2" line path n=0 names=""
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        path="$(printf '%s' "$line" | sed 's/ ([0-9]* MB)$//')"
        "$GIT_BIN" -C "$dir" ls-files --error-unmatch -- "$path" >/dev/null 2>&1 && continue
        add_to_gitignore "$dir" "$path"
        n=$((n + 1)); names="${names:+$names, }$line"
    done < <(find_large_files "$status" "$dir")
    [ "$n" -eq 0 ] && return 1
    RW_NOTES+=("$(basename "$dir"): $n archivo(s) de más de 100MB añadidos a .gitignore, no se commitearon: $names")
    return 0
}

# Blobs de más de 100MB dentro de los commits SIN SUBIR (los que no están en
# ninguna ref remota): lo que haría que GitHub rechace el push. Un path por línea.
large_blobs_unpushed() {
    "$GIT_BIN" -C "$1" rev-list --objects HEAD --not --remotes 2>/dev/null | \
        "$GIT_BIN" -C "$1" cat-file --batch-check='%(objecttype) %(objectsize) %(rest)' 2>/dev/null | \
        awk -v lim="${LARGE_FILE_BYTES:-104857600}" '$1=="blob" && $2+0>lim { print substr($0, length($1)+length($2)+3) "\t" int($2/1048576) }' | sort -u
}

# Excepción de tamaño: si los commits sin subir llevan archivos de más de
# 100MB, los saca de ESOS commits (git filter-branch, solo lo no subido),
# los pone en .gitignore y deja el archivo en el disco. Antes guarda una copia
# del estado en refs/repowatch/backup/<fecha> (recuperable con git reset --hard).
# 0 = arreglado (RW_NOTES avisa), 1 = nada que arreglar, 2 = no se pudo
# (FIX_ERR; el repo queda como estaba).
fix_large_unpushed() {
    local dir="$1" name branch list tmp backup path size n=0 names="" ign=0
    FIX_ERR=""
    name="$(basename "$dir")"
    list="$(large_blobs_unpushed "$dir")"
    [ -z "$list" ] && return 1

    branch="$("$GIT_BIN" -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then FIX_ERR="HEAD separado: no se puede reescribir"; return 2; fi
    if [ -e "$dir/.git/MERGE_HEAD" ] || [ -d "$dir/.git/rebase-merge" ] || [ -d "$dir/.git/rebase-apply" ]; then
        FIX_ERR="hay un merge/rebase en curso"; return 2
    fi
    if [ -n "$("$GIT_BIN" -C "$dir" status --porcelain -uno 2>/dev/null)" ]; then
        FIX_ERR="hay cambios sin commitear: no se puede reescribir el historial"; return 2
    fi

    backup="refs/repowatch/backup/$(date +%Y%m%d-%H%M%S)"
    "$GIT_BIN" -C "$dir" update-ref "$backup" HEAD || { FIX_ERR="no se pudo guardar la copia de seguridad"; return 2; }

    tmp="$(mktemp)"
    printf '%s\n' "$list" | cut -f1 > "$tmp"
    if ! FILTER_BRANCH_SQUELCH_WARNING=1 "$GIT_BIN" -C "$dir" filter-branch -f --prune-empty \
        --index-filter "tr '\\n' '\\0' < '$tmp' | xargs -0 git rm --cached --ignore-unmatch -q --" \
        -- HEAD --not --remotes >/dev/null 2>&1; then
        "$GIT_BIN" -C "$dir" reset --hard "$backup" >/dev/null 2>&1
        rm -f "$tmp"
        FIX_ERR="falló la reescritura (el repo se dejó como estaba)"; return 2
    fi
    rm -f "$tmp"
    "$GIT_BIN" -C "$dir" for-each-ref --format='%(refname)' refs/original 2>/dev/null | \
        while IFS= read -r r; do "$GIT_BIN" -C "$dir" update-ref -d "$r"; done

    # filter-branch deja el árbol de trabajo igual al HEAD nuevo, o sea borra del
    # disco lo que ya no está trackeado: se restaura desde la copia.
    while IFS=$'\t' read -r path size; do
        [ -z "$path" ] && continue
        if "$GIT_BIN" -C "$dir" cat-file -e "$backup:$path" 2>/dev/null && [ ! -e "$dir/$path" ]; then
            mkdir -p "$(dirname "$dir/$path")"
            "$GIT_BIN" -C "$dir" cat-file blob "$backup:$path" > "$dir/$path"
        fi
        add_to_gitignore "$dir" "$path"
        n=$((n + 1)); names="${names:+$names, }$path (${size} MB)"
    done <<< "$list"

    "$GIT_BIN" -C "$dir" add .gitignore
    if [ -n "$("$GIT_BIN" -C "$dir" diff --cached --name-only 2>/dev/null)" ]; then
        _commit_staged "$dir" "Ignora archivos de más de 100MB (RepoWatch)" || ign=1
    fi
    [ "$ign" -eq 1 ] && "$GIT_BIN" -C "$dir" reset >/dev/null 2>&1

    RW_NOTES+=("$name: $n archivo(s) de más de 100MB sacados de los commits sin subir y añadidos a .gitignore (siguen en tu disco): $names. Copia del estado anterior: $backup")
    return 0
}

_as_skip() {
    AUTOSYNC_WHY="$2"
    echo "autosync omitido ($(basename "$1")): $2" >&2
}

# Commit headless (sin push: lo hace el caller tras el pull) para repos en
# modo autosync. $1 = directorio, $2 = salida de git status ya calculada.
# Devuelve 1 (sin tocar el repo, motivo en AUTOSYNC_WHY) si cualquier guarda
# de seguridad salta; el caller lo trata como problema a revisar a mano.
autosync_commit() {
    local dir="$1" status="$2" branch msg_args commit_ok=1 sign_mode signing_key out n_lines
    AUTOSYNC_WHY=""

    if [ -e "$dir/.git/MERGE_HEAD" ] || [ -d "$dir/.git/rebase-merge" ] || \
       [ -d "$dir/.git/rebase-apply" ] || [ -e "$dir/.git/CHERRY_PICK_HEAD" ]; then
        _as_skip "$dir" "hay un merge/rebase/cherry-pick en curso"; return 1
    fi

    branch="$("$GIT_BIN" -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
        _as_skip "$dir" "HEAD separado (sin rama)"; return 1
    fi

    if [ -z "$("$GIT_BIN" -C "$dir" config user.email)" ] || [ -z "$("$GIT_BIN" -C "$dir" config user.name)" ]; then
        _as_skip "$dir" "falta user.name/user.email"; return 1
    fi

    if [ -n "$(find_sensitive_files "$status")" ]; then
        _as_skip "$dir" "posibles archivos sensibles ($(find_sensitive_files "$status" | head -n 2 | paste -sd ',' -))"; return 1
    fi

    if [ -n "$(find_large_files "$status" "$dir")" ]; then
        if has_size_limit "$dir" && ignore_large_untracked "$dir" "$status"; then
            status="$("$GIT_BIN" -C "$dir" -c core.quotepath=false status --porcelain --untracked-files=all 2>/dev/null)"
        fi
        if [ -n "$(find_large_files "$status" "$dir")" ]; then
            _as_skip "$dir" "archivo(s) de más de 100MB"; return 1
        fi
    fi

    if [ "$(repo_get "$dir" stage all)" = "tracked" ]; then
        "$GIT_BIN" -C "$dir" add -u
    else
        "$GIT_BIN" -C "$dir" add -A
    fi

    if [ -n "$(find_secret_content "$dir")" ]; then
        "$GIT_BIN" -C "$dir" reset >/dev/null 2>&1
        _as_skip "$dir" "posible secreto dentro de un archivo"; return 1
    fi

    n_lines="$(printf '%s\n' "$status" | wc -l | tr -d ' ')"
    vault_commit_message "$dir" "$status" "$n_lines"
    msg_args=(-m "$COMMIT_SUBJECT")
    [ -n "$COMMIT_BODY" ] && msg_args+=(-m "$COMMIT_BODY")

    sign_mode="$(repo_get "$dir" sign "$SIGN_COMMITS")"
    signing_key="$(repo_get "$dir" signing_key "$SIGNING_KEY")"
    if [ "$sign_mode" = "true" ] && [ -n "$signing_key" ]; then
        out="$("$GIT_BIN" -C "$dir" -c gpg.format=ssh -c "user.signingkey=$signing_key" commit -S "${msg_args[@]}" 2>&1)" || commit_ok=0
    else
        out="$("$GIT_BIN" -C "$dir" commit "${msg_args[@]}" 2>&1)" || commit_ok=0
    fi

    if [ "$commit_ok" -ne 1 ]; then
        "$GIT_BIN" -C "$dir" reset >/dev/null 2>&1
        _as_skip "$dir" "el commit falló: $(printf '%s\n' "$out" | grep -v '^$' | tail -n 1)"; return 1
    fi

    record_commit "$dir" 0
    return 0
}

# $1 = directorio. Commits que no están en NINGUNA ref remota local (no en
# solo la del upstream): con varios remotos (origin desconectado + ssd), un
# push a ssd deja al repo "al día" aunque siga adelantado de origin. No usa
# red — compara contra las refs de tracking ya guardadas. 0 si no hay remotos.
unpushed_count() {
    local dir="$1"
    [ -z "$("$GIT_BIN" -C "$dir" remote 2>/dev/null)" ] && { echo 0; return; }
    "$GIT_BIN" -C "$dir" rev-list --count HEAD --not --remotes 2>/dev/null || echo 0
}

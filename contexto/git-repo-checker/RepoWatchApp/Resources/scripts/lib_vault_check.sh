# Se debe cargar con `source`, después de lib_discover_repos.sh y con GIT_BIN
# definido. Define vault_check <carpeta_vault>, que organiza y revisa un vault
# de Obsidian completo (todas sus carpetas, recursivo; los [[enlaces]] se
# resuelven por nombre en todo el vault, como hace Obsidian).
#
# Arregla solo lo mecánico, moviendo/añadiendo texto (nunca reescribe):
#   - Registro con más de 30 líneas -> las más viejas pasan a "## Registro (archivo)"
#   - Inicio.md: añade enlaces a notas de su carpeta sin enlazar; ⚠️ a los rotos
#   - Cada carpeta con índice (Inicio.md o un único MOC*.md) lo enlaza con los
#     índices de las demás carpetas ("## Otras carpetas del vault")
# Solo reporta (necesitan criterio): notas viejas o largas y Fichas largas
# (las que tienen `actualizado:`/Ficha; mover Ficha por posición se llevaba
# «Siguiente acción» y perdía texto), enlaces rotos, notas que nadie enlaza, nombres repetidos,
# repos sin AGENTS.md o con remoto vacío.
# Antes de tocar una nota guarda una copia en vault_backups/. Escribe
# "Mantenimiento del vault.md" en la raíz del vault y deja los avisos
# pendientes en $VAULT_WARNINGS_FILE y un resumen en $VAULT_LAST_FILE.

VAULT_BACKUPS_DIR="$CONFIG_DIR/vault_backups"
VAULT_WARNINGS_FILE="$CONFIG_DIR/vault_warnings.txt"
VAULT_LAST_FILE="$CONFIG_DIR/vault_last.txt"
VAULT_REPORT_NAME="Mantenimiento del vault"

read -r -d '' VAULT_ORGANIZE_AWK <<'AWK'
{
    n++
    line[n] = $0
    if ($0 ~ /^## /) {
        if (registro_start != 0 && registro_end == 0) registro_end = n
        if ($0 ~ /^## Registro \(archivo\)/) has_archivo = 1
        else if ($0 ~ /^## Registro[ \t]*$/ && registro_start == 0) registro_start = n
    }
}
END {
    if (registro_start != 0 && registro_end == 0) registro_end = n + 1

    reg_cut = 0
    if (registro_start != 0) {
        cnt = 0
        for (i = registro_start + 1; i < registro_end; i++) if (line[i] != "") cnt++
        if (cnt > maxreg) {
            seen = 0
            for (i = registro_end - 1; i > registro_start; i--) {
                if (line[i] == "") continue
                if (++seen == maxreg) { reg_cut = i; break }
            }
        }
    }

    registro_moved = 0; archive_buf = ""
    if (reg_cut != 0) for (i = registro_start + 1; i < reg_cut; i++)
        if (line[i] != "") { archive_buf = archive_buf line[i] "\n"; registro_moved++ }
    for (i = 1; i <= n; i++) {
        if (reg_cut != 0 && i > registro_start && i < reg_cut) continue
        print line[i]
    }
    if (archive_buf != "") {
        if (!has_archivo) { print ""; print "## Registro (archivo)"; print "" }
        printf "%s", archive_buf
    }
    printf "%d\n", registro_moved > "/dev/stderr"
}
AWK

# Imprime "destino<TAB>archivo" por cada [[enlace]] de los archivos (leídos de
# los argumentos). Ignora bloques y trozos de código, ![[incrustados]] y
# adjuntos (png, pdf...), y quita alias, #secciones y carpetas del destino.
read -r -d '' VAULT_LINKS_AWK <<'AWK'
FNR == 1 { fence = 0 }
/^[ \t]*(```|~~~)/ { fence = !fence; next }
fence { next }
{
    s = $0
    gsub(/`[^`]*`/, "", s)
    while (match(s, /!?\[\[[^]]+\]\]/)) {
        tok = substr(s, RSTART, RLENGTH)
        s = substr(s, RSTART + RLENGTH)
        if (substr(tok, 1, 1) == "!") continue
        t = substr(tok, 3, length(tok) - 4)
        sub(/[|#].*/, "", t)
        sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
        k = split(t, a, "/"); t = a[k]
        sub(/\.md$/, "", t)
        if (t == "") continue
        if (t ~ /\.(png|jpe?g|gif|svg|webp|pdf|mp[34]|csv|xlsx?|docx?|pptx?|zip|canvas)$/) continue
        print t "\t" FILENAME
    }
}
AWK

VAULT_ROOT=""

# Rutas de las notas (separadas por NUL): sin carpetas ocultas (.obsidian,
# .trash) ni el propio informe, que no debe contar como enlace ni como nota.
_vault_find_notes() {
    find "$VAULT_ROOT" -mindepth 1 -name '.*' -prune -o -type f -name '*.md' \
        ! -name "$VAULT_REPORT_NAME.md" -print0
}

_vault_links_of() { # archivos como argumentos
    awk "$VAULT_LINKS_AWK" "$@"
}

_vault_rel() { local r="${1#$VAULT_ROOT/}"; echo "${r%.md}"; }

_vault_backup() {
    local rel="${1#$VAULT_ROOT/}"
    mkdir -p "$VAULT_BACKUPS_DIR"
    cp "$1" "$VAULT_BACKUPS_DIR/${rel//\//__}" 2>/dev/null
}

# Notas "de contenido": no Inicio, ni índices MOC*, ni las instrucciones.
_vault_is_note() {
    case "$(basename "$1" .md)" in
        Inicio|MOC*|"INSTRUCCIONES IA"*|"$VAULT_REPORT_NAME") return 1 ;;
    esac
    return 0
}

# Archiva el Registro largo de una nota. Imprime las líneas archivadas.
_vault_organize_note() {
    local f="$1" tmp moved
    tmp="$(mktemp)"
    moved="$(awk -v maxreg=30 "$VAULT_ORGANIZE_AWK" "$f" 2>&1 >"$tmp")"
    if [ "${moved:-0}" -gt 0 ]; then
        _vault_backup "$f"
        cat "$tmp" > "$f"
        echo "$moved"
    else
        echo 0
    fi
    rm -f "$tmp"
}

# $1 = archivo de nombres de nota (uno por línea), $2 = Inicio.md. Añade a
# Inicio los enlaces a las notas de SU carpeta que no enlaza y marca con ⚠️
# los enlaces rotos. Deja el nº de añadidos en VAULT_ADDED.
_vault_fix_inicio() {
    local names="$1" inicio="$2" dir f base name added=() linked
    VAULT_ADDED=0
    dir="$(dirname "$inicio")"
    linked="$(mktemp)"
    _vault_links_of "$inicio" | cut -f1 | sort -u > "$linked"

    for f in "$dir"/*.md; do
        [ -f "$f" ] && _vault_is_note "$f" || continue
        base="$(basename "$f" .md)"
        grep -qxF "$base" "$linked" || added+=("- [[$base]]")
    done

    local broken=()
    while IFS= read -r name; do
        grep -qxF "$name" "$names" || broken+=("$name")
    done < "$linked"

    if [ ${#added[@]} -gt 0 ] || [ ${#broken[@]} -gt 0 ]; then _vault_backup "$inicio"; fi
    if [ ${#added[@]} -gt 0 ]; then
        grep -q '^## Sin clasificar' "$inicio" || printf '\n## Sin clasificar\n\n' >> "$inicio"
        printf '%s\n' "${added[@]}" >> "$inicio"
    fi
    for name in "${broken[@]}"; do
        grep -qF "⚠️ [[$name]]" "$inicio" && continue
        local esc; esc="$(printf '%s' "[[$name]]" | sed 's/[][\.*^$|&]/\\&/g')"
        sed -i '' "s|$esc|⚠️ [[$name]]|g" "$inicio"
    done
    VAULT_ADDED=${#added[@]}
    rm -f "$linked"
}

# Índice de cada carpeta del vault: Inicio.md, o su único MOC*.md. Rellena
# VAULT_HUBS (rutas). Incluye Inicio.md si está en la raíz del vault.
# shortcut: una carpeta con varios MOC en su raíz se considera sin índice.
_vault_find_hubs() {
    local z moc
    VAULT_HUBS=()
    [ -f "$VAULT_ROOT/Inicio.md" ] && VAULT_HUBS+=("$VAULT_ROOT/Inicio.md")
    for z in "$VAULT_ROOT"/*/; do
        case "$(basename "$z")" in .*) continue ;; esac
        if [ -f "${z}Inicio.md" ]; then
            VAULT_HUBS+=("${z}Inicio.md")
        else
            moc=("${z}"MOC*.md)
            [ ${#moc[@]} -eq 1 ] && [ -f "${moc[0]}" ] && VAULT_HUBS+=("${moc[0]}")
        fi
    done
}

# Cada índice enlaza a los índices de las otras carpetas. Devuelve por stdout
# una línea de "aplicado" por índice modificado.
# shortcut: los enlaces nuevos se añaden al final del archivo; si el usuario
# mueve a mano la sección «Otras carpetas del vault», un enlace borrado se
# repone al final, no dentro de la sección.
_vault_link_hubs() {
    local h o base missing
    [ ${#VAULT_HUBS[@]} -gt 1 ] || return 0
    for h in "${VAULT_HUBS[@]}"; do
        missing=()
        for o in "${VAULT_HUBS[@]}"; do
            [ "$o" = "$h" ] && continue
            base="$(basename "$o" .md)"
            grep -qF "[[$base" "$h" || missing+=("- [[$base]]")
        done
        [ ${#missing[@]} -eq 0 ] && continue
        _vault_backup "$h"
        grep -q '^## Otras carpetas del vault' "$h" || printf '\n## Otras carpetas del vault\n\n' >> "$h"
        printf '%s\n' "${missing[@]}" >> "$h"
        echo "$(_vault_rel "$h") — ${#missing[@]} enlace(s) a otras carpetas del vault"
    done
}

# Rellena VAULT_NO_AGENTS y VAULT_EMPTY_REMOTE.
_vault_check_repos() {
    local dir name agents token note_ok remote rc
    VAULT_NO_AGENTS=(); VAULT_EMPTY_REMOTE=()
    while IFS= read -r dir; do
        name="$(basename "$dir")"
        agents="$dir/AGENTS.md"
        if [ ! -f "$agents" ]; then
            VAULT_NO_AGENTS+=("$name — sin AGENTS.md")
        else
            note_ok=0
            while IFS= read -r token; do
                case "$token" in /*.md) [ -f "$token" ] && note_ok=1 ;; esac
            done < <(grep -oE '/[^`"]*\.md' "$agents" 2>/dev/null)
            [ "$note_ok" -eq 0 ] && VAULT_NO_AGENTS+=("$name — AGENTS.md no apunta a una nota que exista")
        fi
        remote="$("$GIT_BIN" -C "$dir" remote 2>/dev/null | head -1)"
        if [ -n "$remote" ]; then
            rc=0
            "$GIT_BIN" -C "$dir" ls-remote --exit-code --heads "$remote" >/dev/null 2>&1 || rc=$?
            [ "$rc" -eq 2 ] && VAULT_EMPTY_REMOTE+=("$name — remoto '$remote' vacío (nunca se hizo push)")
        fi
    done < <(discover_repos | awk '!seen[$0]++')
}

_vault_list() {
    if [ $# -eq 0 ]; then echo "- Ninguno."; else printf -- '- %s\n' "$@"; fi
}

vault_check() {
    VAULT_ROOT="${1%/}"
    local f base fecha fepoch days total counts name src
    [ -d "$VAULT_ROOT" ] || { echo 0 > "$VAULT_WARNINGS_FILE"; echo "$(date +%s) 0 0" > "$VAULT_LAST_FILE"; return 0; }
    local now; now="$(date +%s)"
    local stale=() long=() ficha=() applied=() broken=() orphans=() dups=()
    local names links targets
    names="$(mktemp)"; links="$(mktemp)"; targets="$(mktemp)"

    # 1. Organizar cada nota (solo actúa si tiene Ficha/Registro) y revisar
    # las que usan el formato de memoria (`actualizado:`).
    while IFS= read -r -d '' f; do
        _vault_is_note "$f" || continue
        # Solo las notas con formato de memoria (la mayoría del vault no lo tiene).
        grep -qE '^(## Ficha|## Registro|actualizado:)' "$f" || continue
        counts="$(_vault_organize_note "$f")"
        base="$(_vault_rel "$f")"
        [ "$counts" -gt 0 ] && applied+=("$base — $counts línea(s) viejas del Registro pasaron a «Registro (archivo)»")
        total="$(awk '/^## Ficha/{f=1;next} /^## /{f=0} f' "$f" | wc -w | tr -d ' ')"
        [ "$total" -gt 150 ] && ficha+=("$base — Ficha de $total palabras")

        fecha="$(awk -F': *' '/^actualizado:/{print $2; exit}' "$f" | tr -d '[:space:]')"
        [ -n "$fecha" ] || continue
        fepoch="$(date -j -f "%Y-%m-%d" "$fecha" +%s 2>/dev/null)"
        if [ -n "$fepoch" ]; then
            days=$(( (now - fepoch) / 86400 ))
            [ "$days" -gt 30 ] && stale+=("$base — hace $days días ($fecha)")
        fi
        total="$(wc -w < "$f" | tr -d ' ')"
        [ "$total" -gt 1500 ] && long+=("$base — $total palabras en total")
    done < <(_vault_find_notes)

    # 2. Índices: Inicio.md completo y enlazado con los índices de las demás carpetas.
    _vault_find_notes | tr '\0' '\n' | sed 's|.*/||; s|\.md$||' | sort -u > "$names"
    _vault_find_hubs
    for f in "${VAULT_HUBS[@]}"; do
        [ "$(basename "$f")" = "Inicio.md" ] || continue
        _vault_fix_inicio "$names" "$f"
        [ "$VAULT_ADDED" -gt 0 ] && applied+=("$(_vault_rel "$f") — $VAULT_ADDED enlace(s) nuevo(s) en «Sin clasificar»")
    done
    while IFS= read -r name; do [ -n "$name" ] && applied+=("$name"); done < <(_vault_link_hubs)

    # 3. Enlaces de todo el vault (ya con los índices arreglados).
    _vault_find_notes | xargs -0 awk "$VAULT_LINKS_AWK" > "$links"
    cut -f1 "$links" | sort -u > "$targets"
    while IFS=$'\t' read -r name src; do
        broken+=("$(_vault_rel "$src") → «$name»")
    done < <(awk -F'\t' 'NR==FNR{n[$0]=1;next} !($1 in n){print $1 "\t" $2}' "$names" "$links" | sort -u -t$'\t' -k2,2 -k1,1)
    while IFS= read -r -d '' f; do
        _vault_is_note "$f" || continue
        base="$(basename "$f" .md)"
        grep -qxF "$base" "$targets" || orphans+=("$(_vault_rel "$f")")
    done < <(_vault_find_notes)
    while IFS= read -r name; do dups+=("«$name»"); done \
        < <(_vault_find_notes | tr '\0' '\n' | sed 's|.*/||; s|\.md$||' | sort | uniq -d)
    rm -f "$names" "$links" "$targets"

    _vault_check_repos

    local n_warn=$(( ${#stale[@]} + ${#ficha[@]} + ${#long[@]} + ${#broken[@]} + ${#orphans[@]} + ${#dups[@]} + ${#VAULT_NO_AGENTS[@]} + ${#VAULT_EMPTY_REMOTE[@]} ))
    {
        echo "# $VAULT_REPORT_NAME"
        echo
        echo "Generado: $(date "+%Y-%m-%d %H:%M")"
        echo
        echo "## Cambios aplicados automáticamente"
        _vault_list "${applied[@]}"
        echo
        echo "## Pendiente de revisar ($n_warn)"
        echo
        echo "### Notas con más de 30 días sin actualizar"
        _vault_list "${stale[@]}"
        echo
        echo "### Fichas de más de 150 palabras (recórtalas a mano: Estado y Siguiente acción deben quedarse arriba)"
        _vault_list "${ficha[@]}"
        echo
        echo "### Notas de más de 1500 palabras"
        _vault_list "${long[@]}"
        echo
        echo "### Enlaces rotos (⚠️ en Inicio.md)"
        _vault_list "${broken[@]}"
        echo
        echo "### Notas que ninguna otra nota enlaza"
        _vault_list "${orphans[@]}"
        echo
        echo "### Nombres de nota repetidos (los enlaces son ambiguos)"
        _vault_list "${dups[@]}"
        echo
        echo "### Repos sin AGENTS.md o sin nota válida"
        _vault_list "${VAULT_NO_AGENTS[@]}"
        echo
        echo "### Repos con remoto vacío"
        _vault_list "${VAULT_EMPTY_REMOTE[@]}"
    } > "$VAULT_ROOT/$VAULT_REPORT_NAME.md"

    echo "$n_warn" > "$VAULT_WARNINGS_FILE"
    echo "$now $n_warn ${#applied[@]}" > "$VAULT_LAST_FILE"
}

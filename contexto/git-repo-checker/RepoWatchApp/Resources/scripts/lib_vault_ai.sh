# Se debe cargar con `source`, después de lib_vault_check.sh y load_settings.
# Corrige con Claude (CLI en modo no interactivo, con la sesión del usuario: sin
# API key) los avisos del vault que se arreglan sin criterio nuevo: Fichas
# largas, enlaces rotos y notas sin enlazar. Decisiones conservadoras y sin
# preguntar; la seguridad no depende de que Claude obedezca:
#   - copia completa del vault antes (vault_backups/ai_*, se guardan las 3 últimas)
#   - Claude solo tiene Read/Edit/Glob/Grep y trabaja dentro de la carpeta del vault
#   - después se compara con la copia y se REVIERTE todo lo que pierda texto
#     (-15 % de palabras), pierda el frontmatter, cambie «actualizado:», borre
#     archivos, toque algo que no sea .md o pase de 40 notas; los archivos nuevos
#     se apartan en la copia
# Cada 72 h (6 h si el último intento falló, p. ej. sesión caducada).

VAULT_AI_LAST_FILE="$CONFIG_DIR/vault_ai_last.txt"   # "epoch estado nº" (ok|fallo)
VAULT_AI_MODEL="${VAULT_AI_MODEL:-sonnet}"

read -r -d '' VAULT_AI_PROMPT <<'EOF'
Eres el mantenedor automático de este vault de Obsidian (tu carpeta de trabajo). Nadie te va a contestar: decide tú, de forma conservadora. Si dudas, no hagas el cambio.

Lee «Mantenimiento del vault.md» y corrige SOLO estos tres apartados:

1. «Fichas de más de 150 palabras»: en esa nota la sección «## Ficha» debe quedar en unas 150 palabras, con «Qué es», «Estado» y «Siguiente acción» arriba. Todo lo que saques de la Ficha lo pasas TAL CUAL (sin resumir, sin borrar, sin reescribir) a una sección «## Detalle» colocada justo después de la Ficha. Acortar una frase solo vale si no pierdes ningún dato concreto (cifras, fechas, rutas, nombres).
2. «Enlaces rotos»: si existe una nota cuyo nombre coincide claramente con el enlace (mayúsculas, acentos o errata evidente), corrige el enlace. Si hay cualquier duda, no toques nada.
3. «Notas que ninguna otra nota enlaza»: añade «- [[Nombre]]» al final del índice de su carpeta (Inicio.md o su único MOC), bajo «## Sin clasificar». Si la nota está en una carpeta sin índice, no hagas nada.

Prohibido: cambiar «actualizado:» o cualquier otro dato del frontmatter; tocar notas viejas, notas largas, nombres repetidos o repos; renombrar, mover, borrar o crear archivos; tocar archivos que no sean .md; editar «Mantenimiento del vault.md»; inventar contenido o datos.

Al terminar responde SOLO con una línea por nota modificada, con este formato exacto: «- <ruta de la nota sin .md> — <qué cambiaste>». Si no cambiaste nada, responde solo: «Sin cambios.»
EOF

vault_ai_due() {
    [ "$VAULT_AI" = "true" ] || return 1
    [ -f "$VAULT_AI_LAST_FILE" ] || return 0
    local epoch status n wait
    read -r epoch status n < "$VAULT_AI_LAST_FILE"
    wait=$((72 * 3600)); [ "$status" = "fallo" ] && wait=$((6 * 3600))
    [ $(( $(date +%s) - ${epoch:-0} )) -ge "$wait" ]
}

# Avisos del informe que Claude puede tratar (los 3 apartados del prompt).
_vault_ai_fixable() {
    awk '/^#/{s=($0 ~ /^### / && $0 ~ /Fichas de|Enlaces rotos|ninguna otra nota/)} s && /^- / && $0!="- Ninguno."{n++} END{print n+0}' \
        "$VAULT_ROOT/$VAULT_REPORT_NAME.md" 2>/dev/null
}

_vault_ai_find_claude() {
    local p
    for p in "$CLAUDE_BIN" /opt/homebrew/bin/claude "$HOME/.local/bin/claude" /usr/local/bin/claude "$HOME/.claude/local/claude"; do
        [ -n "$p" ] && [ -x "$p" ] && { echo "$p"; return 0; }
    done
    return 1
}

# $1 = motivo. Anota el fallo (reintento en 6 h) y avisa solo la primera vez seguida.
_vault_ai_fail() {
    local prev=""
    [ -f "$VAULT_AI_LAST_FILE" ] && read -r _ prev _ < "$VAULT_AI_LAST_FILE"
    echo "$(date +%s) fallo 0" > "$VAULT_AI_LAST_FILE"
    echo "[$(date "+%Y-%m-%d %H:%M:%S")] Corrección con Claude: falló — $1" >> "$LOG_FILE"
    [ "$prev" = "fallo" ] || echo "Vault: no pude corregir con Claude — $1" >> "$PENDING_NOTIF_FILE"
}

# $1 = copia previa. Deja en AI_KEPT las notas que se quedan modificadas y en
# AI_REVERTED lo que se deshizo (con el motivo).
_vault_ai_guard() {
    local snap="$1" f rel reason ow nw modified=()
    AI_KEPT=(); AI_REVERTED=()

    while IFS= read -r -d '' f; do
        rel="${f#$snap/}"
        [ -e "$VAULT_ROOT/$rel" ] && continue
        mkdir -p "$(dirname "$VAULT_ROOT/$rel")"; cp "$f" "$VAULT_ROOT/$rel"
        AI_REVERTED+=("$rel — era un borrado: restaurada")
    done < <(find "$snap" -mindepth 1 -name '.*' -prune -o -type f ! -name "$VAULT_REPORT_NAME.md" -print0)

    while IFS= read -r -d '' f; do
        rel="${f#$VAULT_ROOT/}"
        if [ ! -e "$snap/$rel" ]; then
            mkdir -p "$snap/_nuevos/$(dirname "$rel")"; mv "$f" "$snap/_nuevos/$rel"
            AI_REVERTED+=("$rel — archivo nuevo: apartado en la copia previa")
        elif ! cmp -s "$f" "$snap/$rel"; then
            modified+=("$rel")
        fi
    done < <(find "$VAULT_ROOT" -mindepth 1 -name '.*' -prune -o -type f ! -name "$VAULT_REPORT_NAME.md" -print0)

    for rel in ${modified[@]+"${modified[@]}"}; do
        reason=""
        [ ${#modified[@]} -gt 40 ] && reason="demasiadas notas modificadas (${#modified[@]})"
        case "$rel" in *.md) ;; *) reason="no es una nota .md" ;; esac
        if [ -z "$reason" ]; then
            ow="$(wc -w < "$snap/$rel")"; nw="$(wc -w < "$VAULT_ROOT/$rel")"
            [ $(( nw * 100 )) -lt $(( ow * 85 )) ] && reason="perdía texto ($ow → $nw palabras)"
            [ "$(head -1 "$snap/$rel")" = "---" ] && [ "$(head -1 "$VAULT_ROOT/$rel")" != "---" ] && reason="perdía el frontmatter"
            [ "$(grep -m1 '^actualizado:' "$snap/$rel")" = "$(grep -m1 '^actualizado:' "$VAULT_ROOT/$rel")" ] || reason="cambiaba «actualizado:»"
        fi
        if [ -n "$reason" ]; then
            cp "$snap/$rel" "$VAULT_ROOT/$rel"; AI_REVERTED+=("$rel — revertida: $reason")
        else
            AI_KEPT+=("$rel")
        fi
    done
}

vault_ai_fix() {
    local claude_bin snap out err rc name desc n_kept n_rev warn
    if [ "$(_vault_ai_fixable)" -eq 0 ]; then
        echo "$(date +%s) ok 0" > "$VAULT_AI_LAST_FILE"
        return 0
    fi
    claude_bin="$(_vault_ai_find_claude)" || { _vault_ai_fail "no encuentro el comando claude"; return 0; }

    snap="$VAULT_BACKUPS_DIR/ai_$(date +%Y%m%d-%H%M%S)_$$_$RANDOM"
    mkdir -p "$VAULT_BACKUPS_DIR"
    cp -R "$VAULT_ROOT" "$snap" || { _vault_ai_fail "no pude hacer la copia previa"; return 0; }
    ls -1d "$VAULT_BACKUPS_DIR"/ai_* 2>/dev/null | sort -r | tail -n +4 | while IFS= read -r d; do rm -rf "$d"; done

    out="$(mktemp)"; err="$(mktemp)"
    (
        cd "$VAULT_ROOT" || exit 1
        printf '%s' "$VAULT_AI_PROMPT" | PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" \
            perl -e 'alarm 900; exec @ARGV' "$claude_bin" -p --model "$VAULT_AI_MODEL" \
            --permission-mode acceptEdits --no-session-persistence --strict-mcp-config \
            --disallowedTools Bash WebFetch WebSearch --allowedTools Read Edit Glob Grep
    ) > "$out" 2> "$err"
    rc=$?

    _vault_ai_guard "$snap"
    n_kept=${#AI_KEPT[@]}; n_rev=${#AI_REVERTED[@]}

    {
        echo "## Última corrección con Claude ($(date '+%Y-%m-%d %H:%M'))"
        for rel in ${AI_KEPT[@]+"${AI_KEPT[@]}"}; do
            name="${rel%.md}"
            desc="$(grep -m1 -F -- "- $name — " "$out")"; desc="${desc#*— }"
            echo "- $name — ${desc:-modificada}"
        done
        for rel in ${AI_REVERTED[@]+"${AI_REVERTED[@]}"}; do echo "- $rel"; done
        [ $((n_kept + n_rev)) -eq 0 ] && echo "- Sin cambios."
    } > "$VAULT_AI_LOG"

    vault_check "$VAULT_ROOT"
    warn="$(cat "$VAULT_WARNINGS_FILE" 2>/dev/null || echo 0)"

    if [ "$rc" -ne 0 ]; then
        if cat "$out" "$err" | grep -qiE 'authenticate|login|expired'; then
            _vault_ai_fail "la sesión de Claude caducó: abre Terminal, ejecuta claude y escribe /login"
        else
            _vault_ai_fail "claude terminó con error $rc: $(head -c 120 "$err" | tr '\n' ' ')"
        fi
    else
        echo "$(date +%s) ok $n_kept" > "$VAULT_AI_LAST_FILE"
        echo "[$(date "+%Y-%m-%d %H:%M:%S")] Corrección con Claude: $n_kept nota(s) modificada(s), $n_rev revertida(s); $warn aviso(s)." >> "$LOG_FILE"
        echo "Vault: Claude corrigió $n_kept nota(s)$([ "$n_rev" -gt 0 ] && echo ", revirtió $n_rev por seguridad"); quedan $warn aviso(s)." >> "$PENDING_NOTIF_FILE"
    fi
    rm -f "$out" "$err"
}

#!/bin/bash
# Prueba de lib_vault_ai.sh con un `claude` FALSO (CLAUDE_BIN) que simula
# cambios buenos y malos. Comprueba el plazo de 72 h, que no se llame a Claude
# si no hay nada que corregir, y que las guardas deshagan todo lo peligroso.
# No usa la red ni la cuenta de nadie. Uso: bash tests/test_vault_ai.sh

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
mkdir -p "$HOME/Library/Application Support/RepoWatch"

source "$DIR/Resources/scripts/lib_discover_repos.sh"
source "$DIR/Resources/scripts/lib_settings.sh"
GIT_BIN="$(command -v git)"
source "$DIR/Resources/scripts/lib_vault_check.sh"
source "$DIR/Resources/scripts/lib_vault_ai.sh"
LOG_FILE="$T/log.txt"; PENDING_NOTIF_FILE="$T/notif.txt"

# claude falso: trabaja en su cwd (el vault); FAKE_MODE elige qué hace.
cat > "$T/fake_claude.sh" <<'EOF'
#!/bin/bash
cat > /dev/null
echo x >> "$FAKE_CALLS"
case "$FAKE_MODE" in
  good)     printf '\n## Detalle\n- movido\n' >> "IA compartida/Larga.md"; echo "- IA compartida/Larga — movió el exceso a Detalle" ;;
  shrink)   head -4 "IA compartida/Otra.md" > t && mv t "IA compartida/Otra.md"; echo "- IA compartida/Otra — recortada" ;;
  delete)   rm "IA compartida/Otra.md" ;;
  newfile)  echo nueva > "IA compartida/Nueva.md" ;;
  fecha)    sed -i '' 's/^actualizado:.*/actualizado: 2030-01-01/' "IA compartida/Otra.md" ;;
  nonmd)    echo "{}" >> Tablero.canvas ;;
  authfail) echo "Failed to authenticate: OAuth session expired and could not be refreshed"; exit 1 ;;
  none)     echo "Sin cambios." ;;
esac
EOF
chmod +x "$T/fake_claude.sh"
export CLAUDE_BIN="$T/fake_claude.sh" FAKE_CALLS="$T/calls"

V="$T/vault"; today="$(date +%Y-%m-%d)"
words() { for i in $(seq 1 "$1"); do printf 'palabra%s ' "$i"; done; }
fresh_vault() { # $1 = "largo" (Ficha de 200 palabras) o "corto"
    rm -rf "$V" "$VAULT_BACKUPS_DIR" "$VAULT_AI_LAST_FILE" "$VAULT_AI_LOG" "$T/calls" "$PENDING_NOTIF_FILE"
    mkdir -p "$V/IA compartida" "$V/.obsidian"
    local n=20; [ "$1" = "largo" ] && n=200
    { printf -- '---\nactualizado: %s\n---\n# Larga\n## Ficha\n- **Estado:** ' "$today"; words "$n"; printf '\n## Otra\ntexto\n'; } > "$V/IA compartida/Larga.md"
    { printf -- '---\nactualizado: %s\n---\n# Otra\n## Ficha\n- ok\n## Cuerpo\n' "$today"; words 60; echo; } > "$V/IA compartida/Otra.md"
    printf -- '# Inicio\n- [[Larga]]\n- [[Otra]]\n' > "$V/IA compartida/Inicio.md"
    echo "{}" > "$V/Tablero.canvas"
    cp "$V/IA compartida/Otra.md" "$T/Otra.orig"; cp "$V/Tablero.canvas" "$T/Tablero.orig"
    vault_check "$V"
}
run() { FAKE_MODE="$1" vault_ai_fix; }
snap_dir() { ls -1d "$VAULT_BACKUPS_DIR"/ai_* 2>/dev/null | head -1; }
last_status() { awk '{print $2}' "$VAULT_AI_LAST_FILE" 2>/dev/null; }

fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FALLA $1"; fail=1; fi; }

# --- plazo de 72 h -----------------------------------------------------------
now="$(date +%s)"; rm -f "$VAULT_AI_LAST_FILE"
VAULT_AI=false; check "interruptor apagado: no toca" "! vault_ai_due"
VAULT_AI=true;  check "sin registro previo: toca"    "vault_ai_due"
echo "$now ok 1" > "$VAULT_AI_LAST_FILE";                  check "recién hecho: no toca"       "! vault_ai_due"
echo "$((now - 100*3600)) ok 1" > "$VAULT_AI_LAST_FILE";   check "hace 100 h: toca"            "vault_ai_due"
echo "$((now - 71*3600)) ok 1" > "$VAULT_AI_LAST_FILE";    check "hace 71 h: aún no"           "! vault_ai_due"
echo "$((now - 7*3600)) fallo 0" > "$VAULT_AI_LAST_FILE";  check "fallo hace 7 h: reintenta"    "vault_ai_due"
echo "$((now - 2*3600)) fallo 0" > "$VAULT_AI_LAST_FILE";  check "fallo hace 2 h: espera"       "! vault_ai_due"

# --- nada que corregir: no se llama a Claude ---------------------------------
fresh_vault corto; run good
check "sin avisos corregibles: no llama a Claude" "[ ! -f '$T/calls' ] && [ \"\$(last_status)\" = ok ]"

# --- cambio bueno ------------------------------------------------------------
fresh_vault largo; run good
check "cambio bueno se conserva"            "grep -q '^## Detalle' '$V/IA compartida/Larga.md'"
check "copia previa completa creada"        "[ -f \"\$(snap_dir)/IA compartida/Otra.md\" ]"
check "informe con la sección de Claude"    "grep -q 'Última corrección con Claude' '$V/Mantenimiento del vault.md' && grep -q 'IA compartida/Larga — movió el exceso' '$V/Mantenimiento del vault.md'"
check "estado ok con 1 nota"                "[ \"\$(cat '$VAULT_AI_LAST_FILE' | cut -d' ' -f2-)\" = 'ok 1' ]"
check "aviso: Claude corrigió 1 nota"       "grep -q 'Claude corrigió 1 nota' '$PENDING_NOTIF_FILE'"

# --- guardas: lo peligroso se deshace ----------------------------------------
fresh_vault largo; run shrink
check "recorte >15 % se revierte"           "cmp -s '$V/IA compartida/Otra.md' '$T/Otra.orig' && grep -q 'revertida: perdía texto' '$V/Mantenimiento del vault.md'"
fresh_vault largo; run delete
check "borrado se restaura"                 "cmp -s '$V/IA compartida/Otra.md' '$T/Otra.orig'"
fresh_vault largo; run newfile
check "archivo nuevo se aparta"             "[ ! -e '$V/IA compartida/Nueva.md' ] && [ -f \"\$(snap_dir)/_nuevos/IA compartida/Nueva.md\" ]"
fresh_vault largo; run fecha
check "cambio de «actualizado:» se revierte" "cmp -s '$V/IA compartida/Otra.md' '$T/Otra.orig'"
fresh_vault largo; run nonmd
check "archivo que no es .md se revierte"   "cmp -s '$V/Tablero.canvas' '$T/Tablero.orig'"

# --- fallo de sesión ---------------------------------------------------------
fresh_vault largo; run authfail
check "sesión caducada: estado fallo"       "[ \"\$(last_status)\" = fallo ]"
check "sesión caducada: avisa de /login"    "grep -q '/login' '$PENDING_NOTIF_FILE'"
check "sesión caducada: notas intactas"     "cmp -s '$V/IA compartida/Otra.md' '$T/Otra.orig'"
: > "$PENDING_NOTIF_FILE"; run authfail
check "fallo repetido no vuelve a avisar"   "[ ! -s '$PENDING_NOTIF_FILE' ]"

# --- solo se guardan las 3 últimas copias ------------------------------------
fresh_vault largo
for i in 1 2 3 4 5; do FAKE_MODE=good vault_ai_fix; done
check "solo se guardan 3 copias"            "[ \$(ls -1d '$VAULT_BACKUPS_DIR'/ai_* | wc -l | tr -d ' ') -eq 3 ]"

exit $fail

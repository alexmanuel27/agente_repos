#!/bin/bash
# Prueba de lib_vault_check.sh con un vault de ejemplo de tres carpetas (como
# el real: memoria con Inicio.md, un registro con MOC y un export con
# subcarpetas) y repos de ejemplo, todo en un dir temporal.
# Falla (exit 1) si se rompe la detección o el arreglo de cualquier apartado,
# o si se pierde texto de alguna nota.
# Uso: bash tests/test_vault_check.sh

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
mkdir -p "$HOME/Library/Application Support/RepoWatch"

source "$DIR/Resources/scripts/lib_discover_repos.sh"
GIT_BIN="$(command -v git)"
source "$DIR/Resources/scripts/lib_vault_check.sh"

V="$T/vault"; M="$V/IA compartida"; R1="$V/Registro Claude"; Q="$V/Qwen Export/01 Area"
mkdir -p "$M" "$R1" "$Q" "$V/.obsidian"
today="$(date +%Y-%m-%d)"
words() { for i in $(seq 1 "$1"); do printf 'palabra%s ' "$i"; done; }

printf -- '---\nactualizado: 2020-01-01\n---\n# Vieja\n## Ficha\n- algo corto\n## Registro\n- x\n' > "$M/Vieja.md"
printf -- '---\nactualizado: %s\n---\n# Fresca\n## Ficha\n- ok\n## Registro\n- x\n' "$today" > "$M/Fresca.md"
{
    printf -- '---\nactualizado: %s\n---\n# Larga\n## Ficha\n- Estado: ok\n' "$today"
    for i in 1 2 3; do echo "- $(words 60)"; done
    echo "- **Siguiente acción:** hacer algo importante"
    printf '## Otra\ntexto\n## Registro\n'
    for i in $(seq 1 40); do printf -- '- 2026-01-%02d (t) — entrada %d\n' "$((i % 28 + 1))" "$i"; done
} > "$M/Larga.md"
{ printf -- '---\nactualizado: %s\n---\n# Enorme\n## Ficha\n- ok\n## Cuerpo\n' "$today"; words 1600; echo; } > "$M/Enorme.md"
printf -- '# Inicio\n- [[Fresca]]\n- [[Fantasma]]\n- [[Atomica]]\nUn `[[codigo]]` en línea.\n' > "$M/Inicio.md"

printf -- '# MOC Registro Claude\n- [[Nota R]]\n' > "$R1/MOC Registro Claude.md"
printf -- '# Nota R\n```\n[[enBloque]]\n```\n![[img.png]]\nEnlace [[Rota real]] y [[Atomica#sec|alias]].\n' > "$R1/Nota R.md"

printf -- '# MOC Qwen\n- [[Atomica]]\n' > "$V/Qwen Export/MOC Qwen.md"
printf -- '# Atomica\ntexto\n' > "$Q/Atomica.md"
printf -- '# Huerfana\ntexto\n' > "$Q/Huerfana.md"
printf -- '# Fresca duplicada\n' > "$Q/Fresca.md"
printf -- '[[nada]]\n' > "$V/.obsidian/oculta.md"

# repos: sin AGENTS.md y con remoto vacío / AGENTS.md roto / AGENTS.md válido
W="$T/repos"; mkdir -p "$W"
git init -q --bare "$T/vacio.git"
git init -q "$W/sin_agents"; git -C "$W/sin_agents" remote add origin "$T/vacio.git"
git init -q "$W/roto";       echo "nota: $M/NoExiste.md" > "$W/roto/AGENTS.md"
git init -q "$W/bueno";      echo "nota: \`$M/Fresca.md\`" > "$W/bueno/AGENTS.md"
echo "$W" > "$WATCH_FOLDERS_FILE"

fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FALLA $1"; fail=1; fi; }

cp "$M/Larga.md" "$T/Larga.orig"
vault_check "$V"
RP="$V/$VAULT_REPORT_NAME.md"

check "1 nota vieja detectada"            "grep -q '^- IA compartida/Vieja — hace' '$RP'"
check "1 nota fresca no se marca"         "! grep -q 'IA compartida/Fresca — hace' '$RP'"
check "2 Ficha larga reportada"           "grep -q '^- IA compartida/Larga — Ficha de' '$RP'"
check "2 Ficha no se toca"                "[ \"\$(awk '/^## Ficha/{f=1;next} /^## /{f=0} f&&NF' '$M/Larga.md' | wc -l)\" -eq 5 ]"
check "2 Registro queda en 30 líneas"     "[ \$(awk '/^## Registro\$/{f=1;next} /^## /{f=0} f&&NF' '$M/Larga.md' | wc -l) -eq 30 ]"
check "2 archivo con las 10 viejas"       "[ \$(awk '/^## Registro \(archivo\)/{f=1;next} /^## /{f=0} f&&NF' '$M/Larga.md' | wc -l) -eq 10 ]"
check "2 no se pierde ni una línea"       "[ -z \"\$(comm -23 <(sort '$T/Larga.orig') <(sort '$M/Larga.md'))\" ]"
check "2 copia de respaldo creada"        "[ -f '$VAULT_BACKUPS_DIR/IA compartida__Larga.md' ]"
check "2 nota enorme reportada"           "grep -q '^- IA compartida/Enorme — ' '$RP'"
check "3 repo sin AGENTS.md"              "grep -q '^- sin_agents — sin AGENTS.md' '$RP'"
check "3 AGENTS.md roto"                  "grep -q '^- roto — AGENTS.md no apunta' '$RP'"
check "3 AGENTS.md válido no se marca"    "! grep -q '^- bueno' '$RP'"
check "4 enlace roto marcado en Inicio"   "grep -q '⚠️ \[\[Fantasma\]\]' '$M/Inicio.md'"
check "4 roto de otra carpeta reportado"  "grep -q 'Registro Claude/Nota R → «Rota real»' '$RP'"
check "4 enlace entre carpetas resuelve"  "! grep -q 'Atomica»' '$RP' && ! grep -q '⚠️ \[\[Atomica' '$M/Inicio.md'"
check "4 código/incrustados/ocultos no cuentan" "! grep -qE 'enBloque|img.png|codigo|nada' '$RP'"
check "4 nota sin enlazar añadida a Inicio" "grep -q '^- \[\[Larga\]\]' '$M/Inicio.md'"
check "5 remoto vacío"                    "grep -q '^- sin_agents — remoto' '$RP'"
check "6 Inicio enlaza otras carpetas"    "grep -q '\[\[MOC Registro Claude\]\]' '$M/Inicio.md' && grep -q '\[\[MOC Qwen\]\]' '$M/Inicio.md'"
check "6 MOC Qwen enlaza Inicio"          "grep -q '\[\[Inicio\]\]' '$V/Qwen Export/MOC Qwen.md'"
check "7 nota huérfana reportada"         "grep -q '^- Qwen Export/01 Area/Huerfana' '$RP'"
check "7 nota enlazada no es huérfana"    "! grep -q 'Area/Atomica' '$RP'"
check "8 nombre repetido reportado"       "grep -q '«Fresca»' '$RP'"
check "contador de avisos"                "[ \"\$(cat '$VAULT_WARNINGS_FILE')\" -ge 9 ]"

snap() { (cd "$V" && find . -name '*.md' ! -name "$VAULT_REPORT_NAME.md" -print0 | sort -z | xargs -0 cat | cksum); }
before="$(snap)"
check "la huella de las notas no está vacía"    "[ \"$before\" != \"4294967295 0\" ]"
vault_check "$V"
check "idempotente (2ª pasada no cambia notas)" "[ \"$before\" = \"\$(snap)\" ]"

exit $fail

#!/bin/bash
# Prueba de la ruta automática de check_git_repos.sh con repos de juguete en
# un dir temporal (nunca toca repos reales): commit con mensaje desde el
# vault, pull ff, merge divergido, conflicto abortado, guarda de sensibles,
# sin remoto alcanzable, modo manual, y que solo se avise de problemas.
# Falla (exit 1) si cualquier comprobación no da lo esperado.
# Uso: bash tests/test_autosync.sh

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
C="$HOME/Library/Application Support/RepoWatch"; mkdir -p "$C"
export GIT_CONFIG_GLOBAL="$T/gitconfig"
git config --global user.email t@t; git config --global user.name t
git config --global init.defaultBranch main
S="$DIR/Resources/scripts/check_git_repos.sh"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: esperado «$3», salió «$2»"; fail=1; fi; }
has() { case "$2" in *"$3"*) echo "ok   $1";; *) echo "FAIL $1: no contiene «$3» en «$2»"; fail=1;; esac; }
row() { awk -F'\t' -v n="$1" '$1==n {print $2 "|" $3}' "$C/repo_status.tsv"; }
run() { rm -f "$C/pending_notification.txt"; bash "$S" "$@" >/dev/null 2>&1; }

mkrepo() {  # nombre → crea bare + clon con 1 commit empujado
    git init -q --bare "$T/$1.git"; git clone -q "$T/$1.git" "$T/w/$1" 2>/dev/null
    ( cd "$T/w/$1" && echo base > f && git add f && git commit -qm base && git push -q origin HEAD )
}
mkdir -p "$T/w" "$T/vault/Proyectos"
for r in alfa beta gamma delta eps; do mkrepo $r; done
printf '%s\n' "$T/w" > "$C/watch_folders.txt"
printf 'auto_mode=true\nvault_dir=%s\n' "$T/vault" > "$C/settings.txt"
today="$(date +%Y-%m-%d)"
printf '# Proyecto Alfa\n## Repositorios\n- `%s`\n## Registro\n- 2020-01-01 — vieja\n- %s (m) — Añadí el módulo de lectura\n' "$T/w/alfa" "$today" > "$T/vault/Proyectos/Alfa.md"

# alfa: cambio local → commit con mensaje del vault + push
echo nuevo > "$T/w/alfa/g"
# beta: el remoto avanzó (otro clon) → pull ff
git clone -q "$T/beta.git" "$T/other" && ( cd "$T/other" && echo r > r && git add r && git commit -qm remoto && git push -q )
# gamma: archivo sensible → problema, sin commit
echo x > "$T/w/gamma/.env"
# delta: divergido sin choque (remoto toca r2, local toca l2)
git clone -q "$T/delta.git" "$T/o2" && ( cd "$T/o2" && echo r > r2 && git add r2 && git commit -qm rem && git push -q )
( cd "$T/w/delta" && echo l > l2 && git add l2 && git commit -qm loc )
# eps: divergido con conflicto en f
git clone -q "$T/eps.git" "$T/o3" && ( cd "$T/o3" && echo remoto > f && git commit -qam rem && git push -q )
( cd "$T/w/eps" && echo local > f && git commit -qam loc )

run
check "alfa sincronizado" "$(row alfa)" "synced|commit de 1 archivo(s) · push de 1 commit(s)"
check "alfa: mensaje desde el vault (asunto)" "$(git -C "$T/w/alfa" log -1 --format=%s)" "Proyecto Alfa: Update g"
has   "alfa: mensaje desde el vault (cuerpo reciente)" "$(git -C "$T/w/alfa" log -1 --format=%b)" "Contexto (vault, $today): Añadí el módulo de lectura"
check "alfa: llegó al remoto" "$(git -C "$T/alfa.git" log -1 --format=%s main)" "Proyecto Alfa: Update g"
check "beta pull ff" "$(row beta)" "synced|pull de 1 commit(s)"
has   "beta: trajo el archivo" "$(ls "$T/w/beta")" "r"
has   "gamma problema por sensible" "$(row gamma)" "problem|posibles archivos sensibles (.env)"
check "gamma sin commit nuevo" "$(git -C "$T/w/gamma" log --oneline | wc -l | tr -d ' ')" "1"
check "delta merge + push" "$(row delta)" "synced|pull de 1 commit(s) · push de 2 commit(s)"
has   "eps conflicto reportado" "$(row eps)" "problem|conflicto al traer cambios del remoto"
check "eps quedó limpio (merge abortado)" "$(git -C "$T/w/eps" status --porcelain | wc -l | tr -d ' ')" "0"
n="$(cat "$C/pending_notification.txt")"
has   "aviso: 2 problemas" "$n" "2 problema(s)"
case "$n" in *alfa*|*beta*) echo "FAIL el aviso menciona repos sin problema"; fail=1;; *) echo "ok   el aviso no menciona lo que salió bien";; esac

run
check "mismo problema → no se vuelve a avisar" "$(ls "$C/pending_notification.txt" 2>/dev/null)" ""
run --manual
has   "manual: avisa siempre" "$(cat "$C/pending_notification.txt")" "problema(s)"

# sin remoto alcanzable: info, no problema ni aviso
git -C "$T/w/alfa" remote set-url origin /no/existe
echo mas > "$T/w/alfa/h"; run
has   "remoto caído: no es problema" "$(row alfa)" "synced|commit de 1 archivo(s) · 1 commit(s) sin subir — remoto no disponible"

# modo manual por repo: no commitea
printf '%s\tmode\treview\n' "$T/w/beta" > "$C/repo_overrides.txt"
echo m > "$T/w/beta/m"; run
has   "review: queda como problema" "$(row beta)" "problem|1 archivo(s) sin commitear (modo manual)"
check "review: no commiteó" "$(git -C "$T/w/beta" status --porcelain | wc -l | tr -d ' ')" "1"

[ "$fail" -eq 0 ] && echo "TODO OK" || { echo "HAY FALLOS"; exit 1; }

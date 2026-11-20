#!/bin/bash
# Prueba de VaultScan.swift (lo que lee el panel «Memoria del vault») con un
# vault de ejemplo. Falla (exit 1) si se rompe la lectura de notas o del informe.
# Uso: bash tests/test_vault_scan.sh

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
V="$T/vault"; mkdir -p "$V/IA compartida" "$V/.obsidian" "$V/Qwen"
words() { for i in $(seq 1 "$1"); do printf 'palabra%s ' "$i"; done; }
today="$(date +%Y-%m-%d)"

printf -- '---\nactualizado: 2020-01-01\n---\n# Vieja\n## Ficha\n- **Estado:** viejo\n## Registro\n- x\n' > "$V/IA compartida/Vieja.md"
printf -- '---\nactualizado: %s\n---\n# Fresca\n## Ficha\n- **Estado:** todo bien\n- **Siguiente acción:** seguir\n## Otra\nfuera de la ficha\n' "$today" > "$V/IA compartida/Fresca.md"
{ printf -- '---\nactualizado: %s\n---\n# Larga\n## Ficha\n- **Estado:** ' "$today"; words 200; echo; } > "$V/IA compartida/Larga.md"
printf -- '# MOC\n- [[Fresca]]\n' > "$V/Qwen/MOC Qwen.md"
printf -- '## Ficha\noculta\n' > "$V/.obsidian/oculta.md"

cat > "$T/informe.md" <<'EOF'
# Mantenimiento del vault

Generado: 2026-11-15 10:00

## Cambios aplicados automáticamente
- Inicio — 2 enlace(s) nuevo(s)

## Pendiente de revisar (1)

### Notas con más de 30 días sin actualizar
- Ninguno.

### Enlaces rotos
- Nota R → «Rota»

## Última corrección con Claude (2026-11-20 03:00)
- IA compartida/Larga — movió el exceso a Detalle
EOF

cp "$DIR/VaultScan.swift" "$T/VaultScan.swift"
cp "$DIR/tests/scan_main.swift" "$T/main.swift"
swiftc -O "$T/VaultScan.swift" "$T/main.swift" -o "$T/scan" 2>&1 | grep -E 'error' && exit 1
"$T/scan" "$V" "$T/informe.md"

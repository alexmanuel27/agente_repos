#!/bin/bash
# Tras /clear o compactar, reinyecta la Ficha de la nota del vault del proyecto
# (la ruta sale de AGENTS.md, línea "Nota del proyecto") para que el chat siga
# donde estaba sin releer la nota entera.
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
note="$(grep -m1 'Nota del proyecto' AGENTS.md 2>/dev/null | grep -oE '/[^`]*\.md' | head -1)"
[ -f "$note" ] || exit 0
echo "Memoria del proyecto (nota del vault: $note). El contexto se limpió o compactó; esto es lo que consta en la Ficha. Lee el resto de la nota solo si hace falta:"
echo
awk '/^## Ficha/{f=1;print;next} /^## /{f=0} f' "$note"

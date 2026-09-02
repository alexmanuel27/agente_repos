#!/bin/bash
# Muestra una ventana flotante con el detalle de repos con pendientes.
# La ejecuta terminal-notifier cuando el usuario toca la notificación
# generada por check_git_repos.sh.

STATE_FILE="/Users/alex/scripts/last_check_state.txt"

if [ -s "$STATE_FILE" ]; then
    body="$(cat "$STATE_FILE")"
else
    body="No hay pendientes registrados."
fi

osascript - "$body" <<'APPLESCRIPT'
on run argv
    display dialog (item 1 of argv) with title "Repos con pendientes" buttons {"OK"} default button 1 with icon note
end run
APPLESCRIPT

#!/bin/bash
# Organiza y revisa el vault de Obsidian (ver lib_vault_check.sh). Va aparte de
# check_git_repos.sh a propósito: aquel recorre todos los repos (fetch, status)
# y puede tardar minutos o quedar esperando un diálogo; esto es rápido y da su
# propia respuesta. Disparado por RepoWatch.app con el mismo intervalo, o a
# mano desde Preferencias → Vault (--manual: avisa siempre con el resultado).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib_discover_repos.sh"
source "$SCRIPT_DIR/lib_settings.sh"
load_settings
[ -n "$VAULT_DIR" ] || exit 0

LOCK_DIR="$CONFIG_DIR/.vault.lock"
mkdir "$LOCK_DIR" 2>/dev/null || exit 0
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT INT TERM

export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND='ssh -oBatchMode=yes -oConnectTimeout=10'
GIT_BIN="$(command -v git)"
LOG_FILE="$CONFIG_DIR/logs/check_git_repos.log"
PENDING_NOTIF_FILE="$CONFIG_DIR/pending_notification.txt"
mkdir -p "$CONFIG_DIR/logs"

source "$SCRIPT_DIR/lib_vault_check.sh"
vault_check "$VAULT_DIR" 2>>"$LOG_FILE"

read -r _ warn applied < "$VAULT_LAST_FILE"
echo "[$(date "+%Y-%m-%d %H:%M:%S")] Vault revisado: $applied cambio(s) aplicado(s), $warn aviso(s)." >> "$LOG_FILE"

if [ "$1" = "--manual" ]; then
    echo "Vault revisado: $applied cambio(s) aplicado(s), $warn aviso(s)." >> "$PENDING_NOTIF_FILE"
elif [ "$warn" -gt 0 ]; then
    printf 'Vault: %s aviso(s) — ver «Mantenimiento del vault»\n' "$warn" >> "$PENDING_NOTIF_FILE"
fi

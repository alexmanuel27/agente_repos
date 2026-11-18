#!/bin/bash
# Revisa todos los repos vigilados (lib_discover_repos.sh) y, en los que están
# en modo autosync (Preferencias → modo automático, o por repo), hace solo:
# commit (con mensaje armado desde el vault), pull (ff-only; merge si hay
# commits propios; se aborta si choca) y push (al primer remoto que responda).
# No pregunta nada. Avisa únicamente de PROBLEMAS (conflicto, guarda de
# seguridad, push rechazado...) y solo cuando el problema cambia o pasan 24h.
# Escribe repo_status.tsv (nombre, tipo, detalle, ruta) para el menú:
#   ok = al día · synced = se actuó solo · info = a la espera, no es problema
#   problem = necesita que lo mires
# Disparado por RepoWatch.app según el intervalo, o a mano ("Revisar ahora",
# con --manual: avisa siempre con el resultado).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib_discover_repos.sh"
source "$SCRIPT_DIR/lib_settings.sh"
source "$SCRIPT_DIR/lib_repo_config.sh"
source "$SCRIPT_DIR/lib_commit_safety.sh"
load_settings

LOCK_DIR="$CONFIG_DIR/.check.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT INT TERM

export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND='ssh -oBatchMode=yes -oConnectTimeout=10'

LOG_FILE="$CONFIG_DIR/logs/check_git_repos.log"
STATUS_FILE="$CONFIG_DIR/repo_status.tsv"
LAST_CHECK_FILE="$CONFIG_DIR/last_check.txt"
PENDING_NOTIF_FILE="$CONFIG_DIR/pending_notification.txt"
LAST_PROBLEM_FILE="$CONFIG_DIR/last_problem.txt"
GIT_BIN="$(command -v git)"

mkdir -p "$CONFIG_DIR/logs"

if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    tail -n 1000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi

ts="$(date "+%Y-%m-%d %H:%M:%S")"
manual=0; [ "$1" = "--manual" ] && manual=1

if [ -z "$GIT_BIN" ] || ! "$GIT_BIN" --version >/dev/null 2>&1; then
    printf 'git\tproblem\tgit no disponible — instala las Command Line Tools\t\n' > "$STATUS_FILE"
    echo "[$ts] Error: git no disponible" >> "$LOG_FILE"
    date +%s > "$LAST_CHECK_FILE"
    echo "git no está disponible — instala las Command Line Tools" > "$PENDING_NOTIF_FILE"
    exit 0
fi

repos=()
while IFS= read -r repo_path; do
    repos+=("$repo_path")
done < <(discover_repos | awk '!seen[$0]++')

ROWS_TMP="$STATUS_FILE.tmp"
: > "$ROWS_TMP"
problems=()
n_repos=0
n_acted=0

join_parts() { local out="" p; for p in "$@"; do out="${out:+$out · }$p"; done; echo "$out"; }

for dir in "${repos[@]}"; do
    [ "$(repo_get "$dir" enabled true)" = "false" ] && continue
    name="$(basename "$dir")"
    n_repos=$((n_repos + 1))
    mode="$(repo_mode "$dir")"
    probs=(); acts=(); infos=()
    committed=0; nofetch=0

    fetched=1
    "$GIT_BIN" -C "$dir" fetch --quiet 2>/dev/null || fetched=0

    if [ "$(repo_get "$dir" untracked include)" = "ignore" ]; then
        status_output="$("$GIT_BIN" -C "$dir" status --porcelain -uno 2>/dev/null)"
    else
        status_output="$("$GIT_BIN" -C "$dir" status --porcelain --untracked-files=all 2>/dev/null)"
    fi

    if [ -n "$status_output" ]; then
        n_changes="$(printf '%s\n' "$status_output" | wc -l | tr -d ' ')"
        if [ "$mode" = "autosync" ]; then
            if autosync_commit "$dir" "$status_output" 2>>"$LOG_FILE"; then
                acts+=("commit de $n_changes archivo(s)")
                committed=1
                echo "[$ts] $name: commit «$COMMIT_SUBJECT»${COMMIT_BODY:+ — $COMMIT_BODY}" >> "$LOG_FILE"
            else
                probs+=("$AUTOSYNC_WHY")
            fi
        else
            probs+=("$n_changes archivo(s) sin commitear (modo manual)")
        fi
    fi

    if [ "$fetched" -eq 1 ]; then
        behind="$("$GIT_BIN" -C "$dir" rev-list --count 'HEAD..@{u}' 2>/dev/null)"
        if [ -n "$behind" ] && [ "$behind" -gt 0 ]; then
            if [ "$mode" != "autosync" ]; then
                infos+=("$behind commit(s) detrás del remoto (modo manual)")
            elif [ ${#probs[@]} -eq 0 ]; then
                if auto_pull "$dir"; then
                    acts+=("pull de $AUTO_PULL_N commit(s)")
                    echo "[$ts] $name: pull de $AUTO_PULL_N commit(s)" >> "$LOG_FILE"
                else
                    probs+=("$AUTO_PULL_ERR")
                fi
            fi
        fi
    else
        nofetch=1
    fi

    unpushed="$(unpushed_count "$dir")"
    if [ "$unpushed" -gt 0 ]; then
        if [ "$mode" = "autosync" ] && [ ${#probs[@]} -eq 0 ] && [ "$(repo_get "$dir" push auto)" != "never" ]; then
            auto_push "$dir"; rc=$?
            case "$rc" in
                0) acts+=("push de $unpushed commit(s)")
                   echo "[$ts] $name: push de $unpushed commit(s)" >> "$LOG_FILE"
                   [ "$committed" -eq 1 ] && record_commit "$dir" 1 ;;
                1) infos+=("$unpushed commit(s) sin subir — remoto no disponible") ;;
                *) probs+=("el push falló: $AUTO_PUSH_ERR") ;;
            esac
        else
            infos+=("$unpushed commit(s) sin subir")
        fi
    fi

    [ "$nofetch" -eq 1 ] && [ ${#infos[@]} -eq 0 ] && infos+=("sin acceso al remoto")

    if [ ${#probs[@]} -gt 0 ]; then
        kind=problem
        detail="$(join_parts "${probs[@]}" ${acts[@]+"${acts[@]}"})"
        problems+=("$name: ${probs[0]}")
    elif [ ${#acts[@]} -gt 0 ]; then
        kind=synced
        n_acted=$((n_acted + 1))
        detail="$(join_parts "${acts[@]}" ${infos[@]+"${infos[@]}"})"
    elif [ ${#infos[@]} -gt 0 ]; then
        kind=info
        detail="$(join_parts "${infos[@]}")"
    else
        kind=ok
        detail="al día"
    fi
    printf '%s\t%s\t%s\t%s\n' "$name" "$kind" "$detail" "$dir" >> "$ROWS_TMP"
done

mv "$ROWS_TMP" "$STATUS_FILE"
date +%s > "$LAST_CHECK_FILE"
echo "[$ts] Revisión: $n_repos repo(s), $n_acted con acción automática, ${#problems[@]} problema(s)." >> "$LOG_FILE"

if [ ${#problems[@]} -gt 0 ]; then
    body="$(printf '%s\n' "${problems[@]}" | head -n 6)"
    sig="$(printf '%s' "$body" | cksum)"
    if [ "$manual" -eq 1 ] || [ "$sig" != "$(cat "$LAST_PROBLEM_FILE" 2>/dev/null)" ] || \
       [ -n "$(find "$LAST_PROBLEM_FILE" -mmin +1440 2>/dev/null)" ]; then
        printf '%s problema(s) por revisar:\n%s\n' "${#problems[@]}" "$body" > "$PENDING_NOTIF_FILE"
        echo "$sig" > "$LAST_PROBLEM_FILE"
    fi
else
    rm -f "$LAST_PROBLEM_FILE"
    [ "$manual" -eq 1 ] && echo "Todo en orden ✅ — $n_repos repo(s), $n_acted con acción automática." > "$PENDING_NOTIF_FILE"
fi

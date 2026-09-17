# Se debe cargar con `source`. Define load_settings(), que llena
# INTERVAL_MINUTES / SIGN_COMMITS / SIGNING_KEY desde settings.txt
# (escrito por Preferencias en la app).

CONFIG_DIR="$HOME/Library/Application Support/RepoWatch"
SETTINGS_FILE="$CONFIG_DIR/settings.txt"

INTERVAL_MINUTES=60
SIGN_COMMITS=false
SIGNING_KEY=""

load_settings() {
    [ -f "$SETTINGS_FILE" ] || return 0
    local key value
    while IFS='=' read -r key value; do
        case "$key" in
            interval_minutes) INTERVAL_MINUTES="$value" ;;
            sign_commits) SIGN_COMMITS="$value" ;;
            signing_key) SIGNING_KEY="$value" ;;
        esac
    done < "$SETTINGS_FILE"
}

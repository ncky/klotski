#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="${KLOTSKI_SERVICE_LABEL:-dev.klotski.wm}"
GUI_DOMAIN="gui/$(id -u)"
SERVICE_TARGET="$GUI_DOMAIN/$LABEL"

BUILD_BIN_PATH="$ROOT/bin/klotski"
REPO_DEFAULT_CONFIG="$ROOT/resources/default-config.kdl"
APP_DIR="${KLOTSKI_APP_DIR:-$HOME/Applications/Klotski.app}"
APP_BIN="$APP_DIR/Contents/MacOS/Klotski"
APP_RESOURCES="$APP_DIR/Contents/resources"
APP_DEFAULT_CONFIG="$APP_RESOURCES/default-config.kdl"
BIN_PATH="$APP_BIN"
DEFAULT_CONFIG="$APP_DEFAULT_CONFIG"
CONFIG_DIR="$HOME/.config/klotski"
CONFIG_FILE="$CONFIG_DIR/klotski.conf"
DISABLED_FILE="$CONFIG_DIR/disabled"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$PLIST_DIR/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/klotski"
OUT_LOG="$LOG_DIR/klotski.out.log"
ERR_LOG="$LOG_DIR/klotski.err.log"
SERVICE_PATH="${KLOTSKI_SERVICE_PATH:-${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}}"

usage() {
    cat <<EOF
Usage: scripts/klotski-service.sh <command>

Commands:
  install       Build Klotski, create the user config/log dirs, and write the LaunchAgent
  uninstall     Stop and remove the LaunchAgent plist; keep config and logs
  start         Install if needed, then load or restart the LaunchAgent
  stop          Unload the LaunchAgent without disabling future starts
  restart       Stop, install, then start
  status        Print service paths and launchd state
  logs          Tail stdout/stderr logs
  doctor        Check the binary, configs, yabai conflict, and launchd state
  disable       Stop the service and mark it disabled until enable is run
  enable        Clear the disabled marker and start the service
EOF
}

info() {
    printf '%s\n' "$*"
}

warn() {
    printf 'warning: %s\n' "$*" >&2
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

xml_escape() {
    printf '%s' "$1" | sed \
        -e 's/&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g'
}

ensure_dirs() {
    mkdir -p "$CONFIG_DIR" "$PLIST_DIR" "$LOG_DIR"
}

build_binary() {
    make -C "$ROOT" bin/klotski
}

install_app_bundle() {
    if [[ ! -x "$BUILD_BIN_PATH" ]]; then
        fail "built binary is missing or not executable: $BUILD_BIN_PATH"
    fi

    if [[ ! -r "$REPO_DEFAULT_CONFIG" ]]; then
        fail "default config is not readable: $REPO_DEFAULT_CONFIG"
    fi

    mkdir -p "$APP_DIR/Contents/MacOS" "$APP_RESOURCES"
    cp "$BUILD_BIN_PATH" "$APP_BIN"
    chmod 755 "$APP_BIN"
    cp "$REPO_DEFAULT_CONFIG" "$APP_DEFAULT_CONFIG"

    cat > "$APP_DIR/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Klotski</string>
    <key>CFBundleIdentifier</key>
    <string>dev.klotski.wm</string>
    <key>CFBundleName</key>
    <string>Klotski</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>0.1</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
EOF

    plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null
    info "installed app bundle: $APP_DIR"
}

bootstrap_config() {
    ensure_dirs

    if [[ ! -r "$DEFAULT_CONFIG" ]]; then
        fail "default config is not readable: $DEFAULT_CONFIG"
    fi

    if [[ ! -e "$CONFIG_FILE" ]]; then
        cp "$DEFAULT_CONFIG" "$CONFIG_FILE"
        info "created user config: $CONFIG_FILE"
    else
        info "using existing user config: $CONFIG_FILE"
    fi
}

write_plist() {
    ensure_dirs

    local tmp
    tmp="$PLIST_PATH.tmp.$$"

    local label app root home default_config config_file path out_log err_log
    label="$(xml_escape "$LABEL")"
    app="$(xml_escape "$APP_DIR")"
    root="$(xml_escape "$ROOT")"
    home="$(xml_escape "$HOME")"
    default_config="$(xml_escape "$DEFAULT_CONFIG")"
    config_file="$(xml_escape "$CONFIG_FILE")"
    path="$(xml_escape "$SERVICE_PATH")"
    out_log="$(xml_escape "$OUT_LOG")"
    err_log="$(xml_escape "$ERR_LOG")"

    {
        printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
        printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        printf '%s\n' '<plist version="1.0">'
        printf '%s\n' '<dict>'
        printf '%s\n' '    <key>Label</key>'
        printf '    <string>%s</string>\n' "$label"
        printf '%s\n' '    <key>ProgramArguments</key>'
        printf '%s\n' '    <array>'
        printf '%s\n' '        <string>/usr/bin/open</string>'
        printf '%s\n' '        <string>-gj</string>'
        printf '        <string>%s</string>\n' "$app"
        printf '%s\n' '    </array>'
        printf '%s\n' '    <key>WorkingDirectory</key>'
        printf '    <string>%s</string>\n' "$root"
        printf '%s\n' '    <key>EnvironmentVariables</key>'
        printf '%s\n' '    <dict>'
        printf '%s\n' '        <key>HOME</key>'
        printf '        <string>%s</string>\n' "$home"
        printf '%s\n' '        <key>PATH</key>'
        printf '        <string>%s</string>\n' "$path"
        printf '%s\n' '        <key>KLOTSKI_DEFAULT_CONFIG</key>'
        printf '        <string>%s</string>\n' "$default_config"
        printf '%s\n' '        <key>KLOTSKI_CONFIG</key>'
        printf '        <string>%s</string>\n' "$config_file"
        printf '%s\n' '    </dict>'
        printf '%s\n' '    <key>RunAtLoad</key>'
        printf '%s\n' '    <true/>'
        printf '%s\n' '    <key>KeepAlive</key>'
        printf '%s\n' '    <dict>'
        printf '%s\n' '        <key>SuccessfulExit</key>'
        printf '%s\n' '        <false/>'
        printf '%s\n' '    </dict>'
        printf '%s\n' '    <key>ThrottleInterval</key>'
        printf '%s\n' '    <integer>5</integer>'
        printf '%s\n' '    <key>ProcessType</key>'
        printf '%s\n' '    <string>Interactive</string>'
        printf '%s\n' '    <key>LimitLoadToSessionType</key>'
        printf '%s\n' '    <string>Aqua</string>'
        printf '%s\n' '    <key>StandardOutPath</key>'
        printf '    <string>%s</string>\n' "$out_log"
        printf '%s\n' '    <key>StandardErrorPath</key>'
        printf '    <string>%s</string>\n' "$err_log"
        printf '%s\n' '</dict>'
        printf '%s\n' '</plist>'
    } > "$tmp"

    plutil -lint "$tmp" >/dev/null
    mv "$tmp" "$PLIST_PATH"
    info "wrote LaunchAgent: $PLIST_PATH"
}

service_loaded() {
    launchctl print "$SERVICE_TARGET" >/dev/null 2>&1
}

install_service() {
    build_binary
    install_app_bundle
    bootstrap_config
    write_plist
}

start_service() {
    if [[ -e "$DISABLED_FILE" ]]; then
        fail "service is disabled by $DISABLED_FILE; run '$0 enable' to start it"
    fi

    install_service

    if service_loaded; then
        launchctl kickstart -k "$SERVICE_TARGET"
    else
        launchctl bootstrap "$GUI_DOMAIN" "$PLIST_PATH"
    fi

    info "started $LABEL"
}

stop_service() {
    if service_loaded; then
        if ! launchctl bootout "$SERVICE_TARGET" >/dev/null 2>&1; then
            launchctl bootout "$GUI_DOMAIN" "$PLIST_PATH" >/dev/null 2>&1 || \
                fail "failed to unload $LABEL"
        fi
        info "stopped $LABEL"
    else
        info "$LABEL is not loaded"
    fi

    local app_pids
    app_pids="$(pgrep -f "$APP_BIN" 2>/dev/null || true)"
    if [[ -n "$app_pids" ]]; then
        kill $app_pids >/dev/null 2>&1 || true
        info "stopped Klotski app pids:"
        printf '%s\n' "$app_pids"
    fi
}

restart_service() {
    stop_service
    install_service
    start_service
}

uninstall_service() {
    stop_service
    rm -f "$PLIST_PATH"
    info "removed LaunchAgent: $PLIST_PATH"
}

disable_service() {
    ensure_dirs
    printf 'disabled by klotski-service.sh at %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$DISABLED_FILE"
    launchctl disable "$SERVICE_TARGET" >/dev/null 2>&1 || true
    stop_service
    info "disabled $LABEL; config and logs are preserved"
}

enable_service() {
    rm -f "$DISABLED_FILE"
    launchctl enable "$SERVICE_TARGET" >/dev/null 2>&1 || true
    install_service
    start_service
}

status_service() {
    info "label:          $LABEL"
    info "target:         $SERVICE_TARGET"
    info "app:            $APP_DIR"
    info "binary:         $BIN_PATH"
    info "default config: $DEFAULT_CONFIG"
    info "user config:    $CONFIG_FILE"
    info "plist:          $PLIST_PATH"
    info "logs:           $OUT_LOG"
    info "                $ERR_LOG"

    if [[ -e "$DISABLED_FILE" ]]; then
        warn "service disabled marker exists: $DISABLED_FILE"
    fi

    if service_loaded; then
        info ""
        launchctl print "$SERVICE_TARGET"
    else
        info ""
        info "$LABEL is not loaded"
    fi

    local pids app_pids
    pids="$(pgrep -x klotski 2>/dev/null || true)"
    app_pids="$(pgrep -f "$APP_BIN" 2>/dev/null || true)"
    if [[ -n "$pids$app_pids" ]]; then
        info ""
        info "running klotski pids:"
        if [[ -n "$pids" ]]; then
            printf '%s\n' "$pids"
        fi
        if [[ -n "$app_pids" ]]; then
            printf '%s\n' "$app_pids"
        fi
    fi
}

doctor_service() {
    local failed=0

    status_service
    info ""

    if [[ -x "$BIN_PATH" ]]; then
        info "ok: binary is executable"
    else
        warn "binary is missing or not executable; run '$0 install'"
        failed=1
    fi

    if [[ -r "$DEFAULT_CONFIG" ]]; then
        info "ok: default config is readable"
    else
        warn "default config is not readable: $DEFAULT_CONFIG"
        failed=1
    fi

    if [[ -e "$CONFIG_FILE" ]]; then
        if [[ -r "$CONFIG_FILE" ]]; then
            info "ok: user config is readable"
        else
            warn "user config exists but is not readable: $CONFIG_FILE"
            failed=1
        fi
    else
        warn "user config is missing; install will copy the default config"
    fi

    if pgrep -x yabai >/dev/null 2>&1; then
        warn "yabai is running; Klotski will refuse to start unless KLOTSKI_ALLOW_WM_CONFLICT=1 is set"
        failed=1
    else
        info "ok: yabai is not running"
    fi

    if [[ -f "$PLIST_PATH" ]]; then
        if plutil -lint "$PLIST_PATH" >/dev/null; then
            info "ok: LaunchAgent plist is valid"
        else
            warn "LaunchAgent plist is invalid: $PLIST_PATH"
            failed=1
        fi
    else
        warn "LaunchAgent plist is not installed"
    fi

    info "note: macOS Accessibility/Input Monitoring permissions must be granted to the launched binary or parent terminal when prompted"

    return "$failed"
}

tail_logs() {
    ensure_dirs
    touch "$OUT_LOG" "$ERR_LOG"
    tail -n 100 -f "$ERR_LOG" "$OUT_LOG"
}

command="${1:-}"
case "$command" in
    install)
        install_service
        ;;
    uninstall)
        uninstall_service
        ;;
    start)
        start_service
        ;;
    stop)
        stop_service
        ;;
    restart)
        restart_service
        ;;
    status)
        status_service
        ;;
    logs)
        tail_logs
        ;;
    doctor)
        doctor_service
        ;;
    disable)
        disable_service
        ;;
    enable)
        enable_service
        ;;
    -h|--help|help|"")
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

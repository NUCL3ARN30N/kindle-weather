#!/bin/sh
# KUAL actions: enable | disable | refresh | preview | orientation <mode> | log | status

. "$(dirname "$0")/common.sh"

# Short on-screen notice through the full FBInk build, falling back to eips.
say() {
    "$FBINK" -q -p -m -M -S 3 -B WHITE -C BLACK -w "$1" 2>/dev/null || eips 2 20 "$1"
}

# The daemon runs from a copy on the internal partition (see common.sh).
install_app() {
    mkdir -p "$APP"
    sync_app
}

install_autostart() {
    mntroot rw > /dev/null 2>&1
    cp -f "$EXT/upstart/weatherscreen.conf" "$UPSTART_JOB" 2>> "$LOG"
    RC=$?
    mntroot ro > /dev/null 2>&1
    initctl reload-configuration > /dev/null 2>&1
    return $RC
}

remove_autostart() {
    [ -f "$UPSTART_JOB" ] || return 0
    mntroot rw > /dev/null 2>&1
    rm -f "$UPSTART_JOB"
    mntroot ro > /dev/null 2>&1
}

start_daemon() {
    [ -f "$UPSTART_JOB" ] && start weatherscreen >> "$LOG" 2>&1
    sleep 2
    if ! daemon_running; then
        log "upstart did not start the daemon, launching it directly (no respawn)"
        (cd / && setsid sh "$APP/weatherd.sh" > /dev/null 2>&1 < /dev/null &)
        sleep 2
    fi
    daemon_running
}

stop_daemon() {
    stop weatherscreen >> "$LOG" 2>&1
    # Also catches a daemon started directly (or by an older version).
    if daemon_running; then
        kill "$(cat "$PIDFILE")" 2>/dev/null
        T=0
        while daemon_running && [ "$T" -lt 5 ]; do sleep 1; T=$((T + 1)); done
    fi
}

preview() {
    render
    draw
    sleep "${1:-10}"
    "$FBINK" -q -k -f > /dev/null 2>&1
    DISPLAY=:0 xrefresh > /dev/null 2>&1
}

case "$1" in
    enable)
        touch "$DATA/enabled"
        install_app
        if install_autostart; then
            log "autostart installed"
        else
            log "ERROR: could not install autostart job"
        fi
        stop_daemon # restart so a new version takes over
        if start_daemon; then
            unload_stock_screensaver
            sh "$APP/update.sh" force > /dev/null 2>&1 &
            say "Weather screensaver ON"
        else
            say "Could not start - see log"
        fi
        ;;
    disable)
        rm -f "$DATA/enabled"
        stop_daemon
        remove_autostart
        unpark_wifi
        restore_stock_screensaver
        say "Weather screensaver OFF"
        ;;
    refresh)
        install_app
        say "Updating weather..."
        if sh "$APP/update.sh" force; then
            render && say "Weather updated"
        else
            say "Update failed - see log"
        fi
        ;;
    preview)
        install_app
        preview 10
        ;;
    orientation)
        MODE="$2"
        if [ "$MODE" = "next" ]; then
            case "$(orientation)" in
                auto) MODE=portrait ;;
                portrait) MODE=landscape ;;
                landscape) MODE=landscape-flipped ;;
                *) MODE=auto ;;
            esac
        fi
        case "$MODE" in
            auto | portrait | landscape | landscape-flipped) ;;
            *) echo "usage: $0 orientation auto|portrait|landscape|landscape-flipped|next" >&2; exit 1 ;;
        esac
        echo "$MODE" > "$ORIENTATION_FILE"
        log "orientation set to $MODE"
        say "Orientation: $MODE"
        sleep 2
        install_app
        preview 6
        ;;
    log)
        {
            echo "=== $(date)"
            echo "daemon: $(daemon_running && echo "running pid $(cat "$PIDFILE")" || echo stopped)"
            echo "upstart: $(status weatherscreen 2>&1)"
            echo "autostart job: $([ -f "$UPSTART_JOB" ] && echo installed || echo missing)"
            echo "enabled flag: $([ -f "$DATA/enabled" ] && echo yes || echo no)"
            echo "stock renderers loaded: $(stock_renderers_loaded | tr '\n' ' ')"
            echo "blanket modules: $(lipc-get-prop com.lab126.blanket load 2>&1 | tr '\n' ' ')"
            echo "powerd: $(lipc-get-prop com.lab126.powerd state 2>&1)"
            echo "orientation: $(orientation)"
            echo "fbink: $("$FBINK" -e 2>&1 | tr ';' '\n' | grep -E '^(viewWidth|viewHeight|currentRota|deviceName)=' | tr '\n' ' ')"
            echo "=== log"
            cat "$LOG"
        } > "$EXT/log.txt" 2>&1
        say "Log saved to extensions/weatherscreen/log.txt"
        ;;
    status)
        if daemon_running; then S="running"; else S="stopped"; fi
        LAST="$(cat "$DATA/last_fetch" 2>/dev/null)"
        [ -n "$LAST" ] && LAST="$(date -d "@$LAST" '+%H:%M' 2>/dev/null || echo "$LAST")"
        STOCK="$(stock_renderers_loaded | tr '\n' ' ')"
        say "Daemon $S, last update ${LAST:-never}, stock screensaver: ${STOCK:-removed}, $(orientation)"
        ;;
    *)
        echo "usage: $0 enable|disable|refresh|preview|orientation <mode>|log|status" >&2
        exit 1
        ;;
esac

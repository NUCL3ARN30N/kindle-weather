# Shared paths and helpers, sourced by every weatherscreen script.

# (WS_* overrides exist only for testing off-device.)
EXT="${WS_EXT:-/mnt/us/extensions/weatherscreen}"
KOREADER="${WS_KOREADER:-/mnt/us/koreader}"
FBINK="${WS_FBINK:-/mnt/us/libkh/bin/fbink}" # full FBInk build (KOReader's lacks PNG support)

# Runtime state and the running copy of the scripts live on the internal
# partition. /mnt/us disappears while the Kindle is exported over USB, and
# anything holding files open there gets killed.
DATA="${WS_DATA:-/var/local/weatherscreen}"
APP="$DATA/app"
LOG="$DATA/log.txt"
RENDERERS_FILE="$DATA/stock_renderers"
ORIENTATION_FILE="$DATA/orientation"
RUN="${WS_RUN:-/tmp/weatherscreen}"
PIDFILE="$RUN/daemon.pid"
SHIELD_PIDFILE="$RUN/shield.pid"
INSS_FILE="$RUN/in_screensaver"
LOCKDIR="$RUN/update.lock"
WIFI_PARKED="$DATA/wifi_parked"
CAPS_FILE="$RUN/daemon_caps"

UPSTART_JOB=/etc/upstart/weatherscreen.conf

LAT=52.5200
LON=13.4050
LABEL="Berlin"
INTERVAL_MIN=15
IGNORE_AIRPLANE_MODE=0
ORIENTATION=auto
if [ -f "$EXT/config.sh" ]; then
    . "$EXT/config.sh"
elif [ -f "$APP/config.sh" ]; then
    . "$APP/config.sh"
fi
INTERVAL=$((INTERVAL_MIN * 60))
[ "$INTERVAL" -ge 300 ] || INTERVAL=300

mkdir -p "$DATA" "$RUN"

log() {
    echo "$(date '+%m-%d %H:%M:%S') [$$] $*" >> "$LOG"
}

# Keep the log small; it lives on the internal flash.
trim_log() {
    if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 200000 ]; then
        tail -n 1000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    fi
}

now() { date +%s; }

in_screensaver() { [ -f "$INSS_FILE" ]; }

battery() { lipc-get-prop -i com.lab126.powerd battLevel 2>/dev/null; }

# ---------------------------------------------------------------------------
# Stock screensaver (Blanket renderer modules)
# ---------------------------------------------------------------------------

stock_renderers_loaded() {
    MODS="$(lipc-get-prop com.lab126.blanket load 2>/dev/null | tr '[:space:]' '\n')"
    for M in screensaver ad_screensaver; do
        echo "$MODS" | grep -qx "$M" && echo "$M"
    done
}

unload_stock_screensaver() {
    for M in $(stock_renderers_loaded); do
        # Remember what to restore, without forgetting earlier unloads.
        grep -qx "$M" "$RENDERERS_FILE" 2>/dev/null || echo "$M" >> "$RENDERERS_FILE"
        if lipc-set-prop com.lab126.blanket unload "$M" >> "$LOG" 2>&1; then
            log "stock renderer unloaded: $M"
        else
            log "ERROR: could not unload stock renderer $M"
        fi
    done
}

restore_stock_screensaver() {
    LOADED="$(stock_renderers_loaded)"
    for M in $(cat "$RENDERERS_FILE" 2>/dev/null || echo screensaver); do
        echo "$LOADED" | grep -qx "$M" && continue
        if lipc-set-prop com.lab126.blanket load "$M" >> "$LOG" 2>&1; then
            log "stock renderer restored: $M"
        else
            log "ERROR: could not restore stock renderer $M"
        fi
    done
    rm -f "$RENDERERS_FILE"
}

# ---------------------------------------------------------------------------
# Screen
# ---------------------------------------------------------------------------

orientation() {
    cat "$ORIENTATION_FILE" 2>/dev/null || echo "$ORIENTATION"
}

# Sets VW, VH (framebuffer view as currently rotated) and CUR (its rotation).
screen_info() {
    INFO="$("$FBINK" -e 2>/dev/null)"
    VW="$(echo "$INFO" | sed -n 's/.*viewWidth=\([0-9]*\).*/\1/p')"
    VH="$(echo "$INFO" | sed -n 's/.*viewHeight=\([0-9]*\).*/\1/p')"
    CUR="$(echo "$INFO" | sed -n 's/.*currentRota=\([0-9]*\).*/\1/p')"
    [ -n "$VW" ] && [ -n "$VH" ] || { VW=1072; VH=1448; }
    [ -n "$CUR" ] || CUR=0
}

render() {
    screen_info
    case "$(orientation)" in
        portrait) TARGET=0 ;;
        landscape) TARGET=1 ;;
        landscape-flipped) TARGET=3 ;;
        *) TARGET="$CUR" ;; # auto: however the Kindle is turned right now
    esac
    ROT=$(((TARGET - CUR + 4) % 4))
    (
        cd "$KOREADER" || exit 1
        WS_FONTS="$KOREADER/fonts" WS_JSON="$DATA/weather.json" WS_OUT="$DATA/screen.tmp.png" \
        WS_W="$VW" WS_H="$VH" WS_ROT="$ROT" WS_LABEL="$LABEL" WS_BATT="$(battery)" WS_STALE=$((INTERVAL * 4)) \
            ./luajit "$APP/render.lua" > /dev/null
    ) 2>> "$LOG" && mv "$DATA/screen.tmp.png" "$DATA/screen.png" && return 0
    log "ERROR: render failed (view ${VW}x${VH} rota $CUR, rot $ROT)"
    return 1
}

draw() {
    [ -f "$DATA/screen.png" ] || return 1
    "$FBINK" -q -f -W GC16 -g file="$DATA/screen.png" >> "$LOG" 2>&1 && return 0
    log "fbink failed, falling back to eips"
    eips -f -g "$DATA/screen.png" >> "$LOG" 2>&1
}

shield_up() {
    shield_down
    DISPLAY=:0 "$KOREADER/luajit" "$APP/shield.lua" >> "$LOG" 2>&1 &
    echo $! > "$SHIELD_PIDFILE"
    # Let the window map before anything is drawn on top of it.
    sleep 1
}

shield_down() {
    if [ -f "$SHIELD_PIDFILE" ]; then
        kill "$(cat "$SHIELD_PIDFILE")" 2>/dev/null
        rm -f "$SHIELD_PIDFILE"
    fi
}

# Seconds until the next update slot, aligned to the wall clock.
secs_to_next_slot() {
    N="$(now)"
    S=$((INTERVAL - N % INTERVAL + 20))
    [ "$S" -ge 60 ] || S=$((S + INTERVAL))
    echo "$S"
}

# True when the last successful fetch is from an earlier slot.
update_due() {
    LAST="$(cat "$DATA/last_fetch" 2>/dev/null || echo 0)"
    [ $(($(now) / INTERVAL)) -gt $((LAST / INTERVAL)) ]
}

# While asleep, Wi-Fi is switched off between updates ("parked") and
# switched on fresh for each one: on this firmware a sleeping Kindle never
# reconnects a Wi-Fi that is already on. Waking up restores it.
park_wifi() {
    [ "$(lipc-get-prop -i com.lab126.cmd wirelessEnable 2>/dev/null)" = "1" ] || return 0
    touch "$WIFI_PARKED"
    lipc-set-prop -i com.lab126.cmd wirelessEnable 0 2>> "$LOG" && log "wifi: parked until the next update"
}

unpark_wifi() {
    [ -f "$WIFI_PARKED" ] || return 0
    rm -f "$WIFI_PARKED"
    lipc-set-prop -i com.lab126.cmd wirelessEnable 1 2>> "$LOG" && log "wifi: switched back on"
}

# Picks up newer scripts/config from the extension folder, so fixes apply
# without re-enabling. (weatherd.sh itself only changes on restart.)
sync_app() {
    [ -d "$EXT/bin" ] || return 0 # /mnt/us not available (USB)
    for F in bin/common.sh bin/update.sh bin/render.lua bin/shield.lua bin/ctl.sh bin/weatherd.sh config.sh; do
        N="${F##*/}"
        cmp -s "$EXT/$F" "$APP/$N" 2>/dev/null && continue
        # Copy + rename: a running shell keeps reading its old file intact.
        cp -f "$EXT/$F" "$APP/$N.new" 2>> "$LOG" && mv -f "$APP/$N.new" "$APP/$N" && log "updated $N"
    done
}

daemon_running() {
    [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

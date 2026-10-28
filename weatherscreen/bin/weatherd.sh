#!/bin/sh
# Weather screensaver daemon.
#
# Replaces the stock sleep screen with the weather dashboard and, while the
# Kindle sleeps, has powerd wake it on every update slot to fetch new data.
#
#   goingToScreenSaver  shield the UI, draw the cached forecast, refresh if due
#   readyToSuspend      schedule the next RTC wakeup
#   wakeupFromSuspend   fetch + redraw (runs in the background)
#   goingToPasswdDlg    drop the shield so the PIN prompt can show
#   outOfScreenSaver    drop the shield and give the screen back to the UI
#
# Normally runs from $APP under upstart (respawned if it dies). Stopping it
# leaves the stock screensaver unloaded; "ctl.sh disable" restores it.

. "$(dirname "$0")/common.sh"
cd /

if daemon_running; then
    echo "already running"
    exit 0
fi
echo $$ > "$PIDFILE"
trim_log
log "daemon start"

# Right after boot, give the framework time to load its own screensaver
# modules first, so they are there to unload.
[ "$(cut -d. -f1 /proc/uptime)" -lt 300 ] && sleep "${WS_BOOT_WAIT:-30}"

FIFO="$RUN/events"
SHOWLOCK="$RUN/show.lock"
LISTENER=""

cleanup() {
    trap - EXIT HUP INT TERM
    log "daemon stop"
    [ -n "$LISTENER" ] && kill "$LISTENER" 2>/dev/null
    shield_down
    ticker_stop
    unpark_wifi
    rm -f "$FIFO" "$PIDFILE" "$INSS_FILE" "$CAPS_FILE"
}
for SIG in HUP INT TERM; do
    trap "log 'got SIG$SIG'; cleanup; exit 0" "$SIG"
done
trap cleanup EXIT

rm -f "$FIFO" "$INSS_FILE"
rmdir "$SHOWLOCK" "$LOCKDIR" 2>/dev/null
mkfifo "$FIFO" || { log "ERROR: mkfifo failed"; exit 1; }
exec 3<> "$FIFO"
lipc-wait-event -m com.lab126.powerd \
    goingToScreenSaver,outOfScreenSaver,readyToSuspend,wakeupFromSuspend,goingToPasswdDlg >&3 2>> "$LOG" &
LISTENER=$!

unload_stock_screensaver
unpark_wifi
# Tells update.sh this daemon switches parked Wi-Fi back on when waking.
echo unpark > "$CAPS_FILE"

# While the screensaver shows but the Kindle does not suspend (e.g. on USB
# power), no RTC wakeups happen: update on the clock slots from here instead.
# Across a real suspend the sleep just pauses; update.sh skips slots already
# fetched, so the two paths never double up.
TICKER_PIDFILE="$RUN/ticker.pid"
ticker_start() {
    ticker_stop
    (
        trap - EXIT HUP INT TERM
        while in_screensaver; do
            sleep "$(secs_to_next_slot)"
            in_screensaver && { sync_app; sh "$APP/update.sh"; }
        done
    ) &
    echo $! > "$TICKER_PIDFILE"
}
ticker_stop() {
    [ -f "$TICKER_PIDFILE" ] && kill "$(cat "$TICKER_PIDFILE")" 2>/dev/null
    rm -f "$TICKER_PIDFILE"
}

# Have something to show on the first sleep.
[ -f "$DATA/screen.png" ] || render

while read -r EVENT <&3; do
    log "event: $EVENT"
    case "$EVENT" in
        goingToScreenSaver*)
            touch "$INSS_FILE"
            # The framework can reload its renderers (e.g. after an OTA or
            # a settings change); keep them out of the way.
            unload_stock_screensaver
            # Drawing runs in the background so this loop never misses the
            # short readyToSuspend window.
            (
                trap - EXIT HUP INT TERM
                mkdir "$SHOWLOCK" 2>/dev/null
                shield_up
                # Woken up again within that second? Don't leave the UI covered.
                in_screensaver || shield_down
                render
                in_screensaver && draw
                rmdir "$SHOWLOCK"
                sync_app
                sh "$APP/update.sh"
            ) &
            ticker_start
            ;;
        readyToSuspend*)
            if [ -d "$LOCKDIR" ] || [ -d "$SHOWLOCK" ]; then
                # An update is still running: ask for more time, retry soon.
                lipc-set-prop -i com.lab126.powerd deferSuspend 30 >> "$LOG" 2>&1
                SECS=60
            else
                SECS="$(secs_to_next_slot)"
            fi
            lipc-set-prop -i com.lab126.powerd rtcWakeup "$SECS" >> "$LOG" 2>&1 \
                && log "rtc wakeup in ${SECS}s"
            ;;
        wakeupFromSuspend*)
            in_screensaver && { sync_app; sh "$APP/update.sh"; } &
            ;;
        goingToPasswdDlg*)
            shield_down
            unpark_wifi
            ;;
        outOfScreenSaver*)
            rm -f "$INSS_FILE"
            ticker_stop
            unpark_wifi
            shield_down
            # Clear the image so it doesn't ghost, then let X repaint the UI.
            "$FBINK" -q -k -f >> "$LOG" 2>&1
            DISPLAY=:0 xrefresh >> "$LOG" 2>&1
            # Make sure the next sleep starts clean.
            unload_stock_screensaver
            ;;
    esac
done

log "event listener ended"
exit 1 # let upstart respawn us

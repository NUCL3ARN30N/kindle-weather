#!/bin/sh
# Fetches the forecast from Open-Meteo and, if the Kindle is showing the
# weather screensaver, redraws it. Usage: update.sh [force]

. "$(dirname "$0")/common.sh"

if ! mkdir "$LOCKDIR" 2>/dev/null; then
    log "update already running"
    exit 0
fi
AIRPLANE_TOGGLED=0
finish() {
    if [ "$AIRPLANE_TOGGLED" = 1 ]; then
        lipc-set-prop -i com.lab126.cmd wirelessEnable 0
        log "wifi: airplane mode restored"
    fi
    rmdir "$LOCKDIR" 2>/dev/null
}
trap finish EXIT

wifi_connected() { [ "$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)" = "CONNECTED" ]; }

# wifid's status dump (property "711") lists the current AP ("2.3 AP: ...")
# and the saved networks in range ("3.n  id<TAB>essid<TAB>...").
wifi_status() { lipc-get-prop com.lab126.wifid 711 2>/dev/null; }

remember_network() {
    AP="$(wifi_status | awk '/^2\.3 AP:/ { sub(/^2\.3 AP:[ 	]*/, ""); print; exit }')"
    AP="${AP% (*)}" # drop the " (bssid)" suffix
    case "$AP" in
        "" | "--") ;;
        *)
            if [ "$AP" != "$(cat "$DATA/essid" 2>/dev/null)" ]; then
                echo "$AP" > "$DATA/essid"
                log "wifi: remembered network '$AP'"
            fi
            ;;
    esac
}

wait_connected() {
    T=0
    while [ "$T" -lt "$1" ]; do
        wifi_connected && return 0
        sleep 1
        T=$((T + 1))
    done
    return 1
}

ensure_wifi() {
    wifi_connected && return 0
    if [ "$(lipc-get-prop -i com.lab126.cmd wirelessEnable 2>/dev/null)" = "0" ] && [ ! -f "$WIFI_PARKED" ]; then
        if [ "$IGNORE_AIRPLANE_MODE" != 1 ]; then
            log "wifi: airplane mode is on, skipping update"
            return 1
        fi
        AIRPLANE_TOGGLED=1
    fi
    START="$(now)"
    # A fresh off -> on is what gets a sleeping Kindle to connect; reconnecting
    # a Wi-Fi that is still on is ignored (radio scans, never associates).
    if [ ! -f "$WIFI_PARKED" ] && [ "$AIRPLANE_TOGGLED" = 0 ]; then
        lipc-set-prop -i com.lab126.cmd wirelessEnable 0 2>> "$LOG"
        sleep 5
    fi
    rm -f "$WIFI_PARKED"
    lipc-set-prop -i com.lab126.cmd wirelessEnable 1 2>> "$LOG"
    lipc-set-prop -i com.lab126.wifid enable 1 2>> "$LOG"
    if wait_connected 30; then
        log "wifi: connected after $(($(now) - START))s"
        return 0
    fi

    NET="$(cat "$DATA/essid" 2>/dev/null)"
    if [ -n "$NET" ]; then
        log "wifi: still $(lipc-get-prop com.lab126.wifid cmState 2>/dev/null), asking for '$NET'"
        lipc-set-prop com.lab126.cmd ensureConnection "wifi:$NET" 2>> "$LOG"
        lipc-set-prop com.lab126.wifid cmConnect "$NET" 2>> "$LOG"
        if wait_connected 15; then
            log "wifi: connected to '$NET' after $(($(now) - START))s"
            return 0
        fi
    fi

    if command -v wpa_cli > /dev/null; then
        log "wifi: asking wpa_supplicant to reconnect"
        wpa_cli -i wlan0 reconnect >> "$LOG" 2>&1
        if wait_connected 15; then
            log "wifi: connected after $(($(now) - START))s (wpa_cli)"
            return 0
        fi
    fi

    log "wifi: not connected after $(($(now) - START))s (state: $(lipc-get-prop com.lab126.wifid cmState 2>/dev/null))"
    wifi_diagnostics
    return 1
}

# What the network stack looks like when connecting failed (kept short).
wifi_diagnostics() {
    {
        echo "--- wifi diagnostics: powerd $(lipc-get-prop com.lab126.powerd state 2>&1)"
        wifi_status | head -30
        ifconfig wlan0 2>&1 | head -4
        echo "wpa_cli: $(command -v wpa_cli || echo missing)"
        command -v wpa_cli > /dev/null && wpa_cli -i wlan0 status 2>&1 | grep -vE "^(passphrase|psk)" | head -12
        ps 2>/dev/null | grep -E "wpa_|wifid|dhcp" | grep -v grep
        echo "--- end diagnostics"
    } >> "$LOG"
}

QUERY="latitude=$LAT&longitude=$LON&timezone=auto&timeformat=unixtime&forecast_days=7\
&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day\
&hourly=temperature_2m,apparent_temperature,precipitation\
&daily=weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,uv_index_max,precipitation_probability_max"

# Right after connecting, DNS often isn't up yet: retry for ~15 s.
fetch() {
    for TRY in 1 2 3 4 5 6; do
        for URL in "https://api.open-meteo.com/v1/forecast?$QUERY" "http://api.open-meteo.com/v1/forecast?$QUERY"; do
            if ERR="$(curl -fsS -m 25 -o "$DATA/weather.tmp.json" "$URL" 2>&1)" && grep -q '"current"' "$DATA/weather.tmp.json"; then
                [ "$TRY" -gt 1 ] && log "fetch: ok on try $TRY"
                mv "$DATA/weather.tmp.json" "$DATA/weather.json"
                now > "$DATA/last_fetch"
                return 0
            fi
        done
        sleep 3
    done
    log "fetch: $ERR"
    rm -f "$DATA/weather.tmp.json"
    return 1
}

# Going to sleep is usually still online: note the network for later.
wifi_connected && remember_network

# Only when the daemon will switch Wi-Fi back on at wake-up (older daemons
# don't), and never with airplane mode toggled by us (finish() restores it).
can_park() {
    in_screensaver && grep -q unpark "$CAPS_FILE" 2>/dev/null && [ "$AIRPLANE_TOGGLED" = 0 ]
}

if [ "$1" != "force" ] && ! update_due; then
    can_park && park_wifi
    exit 0
fi

trim_log
OK=0
if ensure_wifi; then
    remember_network
    if fetch; then
        log "fetched forecast"
        OK=1
    else
        log "ERROR: fetch failed"
    fi
fi

# Redraw while asleep, so the clock marker and battery stay current even
# when the fetch failed (stale data gets an OFFLINE note).
if in_screensaver && render && in_screensaver; then
    draw
fi
can_park && park_wifi

[ "$OK" = 1 ]

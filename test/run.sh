#!/bin/sh
# Local test: render with the KOReader Linux build in WSL.
KO="${KOREADER_DIR:-$HOME/kotest/lib/koreader}" # KOReader Linux build (see README)
T="$(cd "$(dirname "$0")" && pwd)"
cd "$KO" || exit 1
WS_FONTS="$KO/fonts" WS_JSON="${WS_JSON:-$T/weather.json}" WS_OUT="${WS_OUT:-$T/out.png}" WS_BATT=82 \
  ./luajit "$T/../weatherscreen/bin/render.lua"

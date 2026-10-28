#!/bin/sh
# Simulates enable -> sleep/RTC wake/wake -> unexpected kill -> disable, in WSL.
KO="${KOREADER_DIR:-$HOME/kotest/lib/koreader}" # KOReader Linux build (see README)
T="$(cd "$(dirname "$0")" && pwd)"
export STUB_STATE=/tmp/ws_sim; rm -rf $STUB_STATE; mkdir -p $STUB_STATE/data $STUB_STATE/run
printf 'screensaver\nsomething_else\n' > $STUB_STATE/blanket
export PATH="$T/stubs:$PATH" WS_EXT="$T/../weatherscreen" WS_KOREADER="$KO" WS_FBINK="$T/stubs/fbink" \
       WS_DATA=$STUB_STATE/data WS_RUN=$STUB_STATE/run STUB_ROTA=${STUB_ROTA:-0} WS_BOOT_WAIT=0
sh "$T/../weatherscreen/bin/ctl.sh" enable
echo "--- after enable: app=$(ls $STUB_STATE/data/app | tr '\n' ' ')"
sleep 24
PID=$(cat $STUB_STATE/run/daemon.pid)
echo "--- killing daemon $PID unexpectedly"
kill $PID; sleep 2
echo "--- blanket after kill: $(cat $STUB_STATE/blanket | tr '\n' ' ')"
sh "$T/../weatherscreen/bin/ctl.sh" disable
echo "--- blanket after disable: $(cat $STUB_STATE/blanket | tr '\n' ' ')"
echo "--- log"; cat $STUB_STATE/data/log.txt
echo "--- calls"; grep -v '^fbink -q -p' $STUB_STATE/calls
cp $STUB_STATE/data/screen.png "$T/sim_screen_rota$STUB_ROTA.png"
pkill -f lipc-wait-event; pkill -f shield.lua

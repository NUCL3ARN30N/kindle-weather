#!/bin/sh
# Ticker logic with a 2 s slot: should run update while "in screensaver", then stop.
RUN=/tmp/tick; rm -rf $RUN; mkdir -p $RUN; INSS_FILE=$RUN/inss; APP=$RUN
in_screensaver() { [ -f "$INSS_FILE" ]; }
secs_to_next_slot() { echo 2; }
sync_app() { :; }
echo 'echo "update at $(date +%S)" >> /tmp/tick/out' > $RUN/update.sh
eval "$(sed -n '/^TICKER_PIDFILE=/,/^}$/p;/^ticker_stop() {/,/^}$/p' "$(dirname "$0")/../weatherscreen/bin/weatherd.sh")"
touch $INSS_FILE; ticker_start; sleep 7
rm -f $INSS_FILE; ticker_stop; sleep 4
echo "updates while asleep: $(wc -l < $RUN/out) (expect 3)"; cat $RUN/out

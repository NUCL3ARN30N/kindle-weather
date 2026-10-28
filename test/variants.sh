#!/bin/sh
# Renders layout/rotation variants: json rot width height name
T="$(cd "$(dirname "$0")" && pwd)"
while read -r J R VW VH N; do
    WS_JSON="$T/$J.json" WS_OUT="$T/o_$N.png" WS_ROT=$R WS_W=$VW WS_H=$VH timeout 60 sh "$T/run.sh" 2>&1 \
        | grep -v -e '^ffi\.' -e '^lib_' -e monolibtic
    echo "$N rc=$?"
done <<LIST
weather 0 1072 1448 portrait
weather 1 1072 1448 land_r1
rain 3 1072 1448 land_r3
weather 1 1236 1648 pw5_land
empty 1 1072 1448 empty_land
LIST

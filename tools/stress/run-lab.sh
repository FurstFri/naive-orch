#!/bin/sh
# run-lab.sh: memory stress lab for one naive-orch node (naive + sing-box UoT wrapper).
#
# Runs OUTSIDE procd (a plain Linux box, WSL, or an OpenWrt rootfs imported into
# WSL): renders the same configs init.d would, starts the two daemons, samples
# their memory every few seconds with tools/memwatch.sh and drives a fixed
# sequence of load phases with naive-orch-stress. Everything lands in $LAB.
#
# Required:  PROXY='https://user:pass@deX.example.com:443'
# Optional:  LAB=/tmp/naive-lab  BIN=/usr/bin  PORT=1106  OFFSET=1000  UOT_PORT=8389
#            PHASES="tcp:64:120 rest:60 udp:32:120 rest:60 idle:500:60 rest:60"
#            SB_ENV="GOGC=..."  (extra environment for sing-box, e.g. GOMEMLIMIT)
#            STRESS_ARGS="-tcp-target 127.0.0.1:8080"  (extra flags for every stress phase)
#            UDP_TIMEOUT=30s  (wrapper inbound udp_timeout; empty = sing-box default 5m)
#
# Phase syntax:  <mode>:<conc>:<seconds>   or   rest:<seconds>

set -eu
: "${PROXY:?set PROXY=https://user:pass@host:443}"
LAB="${LAB:-/tmp/naive-lab}"
BIN="${BIN:-/usr/bin}"
PORT="${PORT:-1106}"
OFFSET="${OFFSET:-1000}"
UOT_PORT="${UOT_PORT:-8389}"
PHASES="${PHASES:-tcp:64:120 rest:60 udp:32:120 rest:60 idle:500:60 rest:60 tcp:64:120 rest:60 udp:32:120 rest:90}"
SB_ENV="${SB_ENV:-}"
STRESS_ARGS="${STRESS_ARGS:-}"
UDP_TIMEOUT="${UDP_TIMEOUT:-}"
HERE="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
STRESS="${STRESS:-$HERE/naive-orch-stress}"

mkdir -p "$LAB"
inner=$((PORT + OFFSET))
de_host="${PROXY#https://}"; de_host="${de_host#*@}"; de_host="${de_host%%:*}"; de_host="${de_host%%/*}"

cat > "$LAB/node.json" <<EOF
{
  "listen": "socks://127.0.0.1:$inner",
  "padding": true,
  "proxy": "$PROXY"
}
EOF
udp_json=""
[ -z "$UDP_TIMEOUT" ] || udp_json=", \"udp_timeout\": \"$UDP_TIMEOUT\""
cat > "$LAB/node.wrap.json" <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [
    { "type": "mixed", "tag": "in", "listen": "127.0.0.1", "listen_port": $PORT$udp_json }
  ],
  "outbounds": [
    { "type": "socks", "tag": "naive", "server": "127.0.0.1", "server_port": $inner },
    { "type": "socks", "tag": "uot",
      "server": "$de_host", "server_port": $UOT_PORT,
      "udp_over_tcp": { "enabled": true, "version": 2 }, "detour": "naive" }
  ],
  "route": { "rules": [ { "network": "udp", "action": "route", "outbound": "uot" } ], "final": "naive" }
}
EOF
[ -f "$LAB/wrap.override.json" ] && cp "$LAB/wrap.override.json" "$LAB/node.wrap.json"

"$BIN/naive" "$LAB/node.json" >"$LAB/naive.log" 2>&1 &
NAIVE_PID=$!
env $SB_ENV "$BIN/sing-box" run -c "$LAB/node.wrap.json" >"$LAB/sing-box.log" 2>&1 &
SB_PID=$!
sleep 2
kill -0 "$NAIVE_PID" && kill -0 "$SB_PID" || { echo "daemons failed to start"; cat "$LAB"/*.log; exit 1; }

NO_PIDS="naive=$NAIVE_PID sing-box=$SB_PID" sh "$HERE/../memwatch.sh" 5 "$LAB/mem.csv" &
WATCH_PID=$!
cleanup() { kill "$WATCH_PID" "$NAIVE_PID" "$SB_PID" 2>/dev/null; }
trap cleanup 0 1 2 15

echo "lab: naive=$NAIVE_PID sing-box=$SB_PID watch=$WATCH_PID  csv=$LAB/mem.csv"
sleep 30
snap() { sh "$HERE/../memwatch.sh" --once 2>/dev/null; NO_PIDS="naive=$NAIVE_PID sing-box=$SB_PID" sh "$HERE/../memwatch.sh" --once | grep -v _sys; }
echo "== baseline"; snap

for ph in $PHASES; do
	mode="${ph%%:*}"; rest="${ph#*:}"
	echo "== $(date +%H:%M:%S) phase $ph"
	echo "$(date +%s),_phase,0,$ph,0,0,0" >> "$LAB/mem.csv"
	if [ "$mode" = "rest" ]; then
		sleep "$rest"
	else
		c="${rest%%:*}"; secs="${rest#*:}"
		"$STRESS" -socks "127.0.0.1:$PORT" -mode "$mode" -conc "$c" -duration "${secs}s" -quiet -report 30s $STRESS_ARGS 2>&1 | tail -3
	fi
	snap
done
echo "== $(date +%H:%M:%S) done"

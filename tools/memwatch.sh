#!/bin/sh
# memwatch: sample memory of every naive-orch process (and podkop's sing-box,
# when present) into a CSV. BusyBox-only, no dependencies, works on OpenWrt
# kernels without smaps_rollup (uses /proc/PID/status).
#
#   memwatch.sh [interval_sec] [out.csv]     default 30s, /tmp/naive-orch-mem.csv
#   memwatch.sh --once                       one sample to stdout
#
# Row:  ts,name,pid,rss_kb,anon_kb,fds,threads
# Plus one "_sys" row per sample:
#       ts,_sys,0,mem_available_kb,slab_unreclaim_kb,conntrack,sockets_used
#
# NO_PIDS="name=pid name2=pid2" adds arbitrary extra processes (used by the
# desktop/WSL stress harness where there are no procd pidfiles).

interval="${1:-30}"
out="${2:-/tmp/naive-orch-mem.csv}"
once=0
[ "$1" = "--once" ] && { once=1; out=/dev/stdout; }

sample_pid() {
	local name="$1" pid="$2" rss anon fds thr
	[ -d "/proc/$pid" ] || return 0
	rss=$(awk '/^VmRSS:/{print $2}' "/proc/$pid/status" 2>/dev/null)
	anon=$(awk '/^RssAnon:/{print $2}' "/proc/$pid/status" 2>/dev/null)
	fds=$(ls "/proc/$pid/fd" 2>/dev/null | wc -l)
	thr=$(awk '/^Threads:/{print $2}' "/proc/$pid/status" 2>/dev/null)
	printf '%s,%s,%s,%s,%s,%s,%s\n' "$ts" "$name" "$pid" "${rss:-0}" "${anon:-0}" "$fds" "${thr:-0}"
}

sample() {
	local f p n kv
	ts=$(date +%s)
	for f in /var/run/naive-orch-*.pid; do
		[ -f "$f" ] || continue
		p=$(cat "$f" 2>/dev/null); n=${f#/var/run/naive-orch-}; n=${n%.pid}
		sample_pid "$n" "$p"
	done
	for p in $(pidof sing-box 2>/dev/null); do
		if grep -q '/etc/sing-box/config.json' "/proc/$p/cmdline" 2>/dev/null; then
			sample_pid "podkop-sing-box" "$p"
		fi
	done
	for kv in $NO_PIDS; do
		sample_pid "${kv%%=*}" "${kv#*=}"
	done
	printf '%s,_sys,0,%s,%s,%s,%s\n' "$ts" \
		"$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)" \
		"$(awk '/^SUnreclaim:/{print $2}' /proc/meminfo)" \
		"$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)" \
		"$(awk '/^sockets:/{print $3}' /proc/net/sockstat)"
}

if [ "$once" = "1" ]; then sample; exit 0; fi
[ -s "$out" ] || echo 'ts,name,pid,rss_kb,anon_kb,fds,threads' > "$out"
while :; do
	sample >> "$out"
	sleep "$interval"
done

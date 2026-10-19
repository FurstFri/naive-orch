#!/bin/sh
# Shared helpers for naive-orch (sourced by init.d, healthcheck, status, sub-update)

NO_CFG="naive-orch"
NO_BIN="/usr/bin/naive"
NO_SB_BIN="/usr/bin/sing-box"
NO_RUNDIR="/var/etc/naive-orch"
NO_STATUSDIR="/var/run/naive-orch"
NO_STATUS="$NO_STATUSDIR/status.json"
NO_SERVERS="$NO_STATUSDIR/servers.txt"
NO_SUBOP="$NO_STATUSDIR/sub-update.json"
NO_SUBLOCK="$NO_STATUSDIR/sub-update.lock"
NO_HEALTHLOCK="$NO_STATUSDIR/healthcheck.lock"
NO_WRAP="$NO_RUNDIR/uot.json"
# podkop's main sing-box: its init script comes from the sing-box package
NO_SB_INIT="/etc/init.d/sing-box"
NO_SB_CONF="/etc/sing-box/config.json"
NO_NOFILE=65535

NO_PERSIST="/etc/naive-orch"
NO_PORTMAP="$NO_PERSIST/portmap"
NO_SUBSTATE="$NO_PERSIST/sub-state"

no_log() {
	logger -t naive-orch "$@"
}

# Escape a single-line value for use in the small JSON documents produced by
# the helper scripts. UCI labels are user-controlled, so writing them verbatim
# can otherwise make the whole status response invalid.
no_json_escape() {
	printf '%s' "$1" | tr '\r\n\t' '   ' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# proxy URL must start with https://
no_validate_proxy() {
	case "$1" in
		https://*) return 0 ;;
		*)         return 1 ;;
	esac
}

# is the argument a positive integer > 0 ?
no_is_pos_int() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
		0)           return 1 ;;
		*)           return 0 ;;
	esac
}

# render one node config.json
# args: id bind_host listen_port proxy concurrency padding
no_render_node() {
	local id="$1" bind="$2" port="$3" proxy="$4" conc="$5" padding="$6"
	local f="$NO_RUNDIR/$id.json"

	{
		printf '{\n'
		printf '  "listen": "socks://%s:%s",\n' "$bind" "$port"
		if no_is_pos_int "$conc"; then
			printf '  "insecure-concurrency": %s,\n' "$conc"
		fi
		if [ "$padding" = "1" ] || [ "$padding" = "true" ]; then
			printf '  "padding": true,\n'
		fi
		printf '  "proxy": "%s"\n' "$proxy"
		printf '}\n'
	} > "$f"
	chmod 0600 "$f"
}

# sing-box "UoT wrapper" (variant B). ONE sing-box process serves every node.
# The wrapper is what Podkop talks to on each node's public port; it splits:
#   TCP -> the node's naive SOCKS (direct, no double tunnel)
#   UDP -> a socks outbound with sing-box UoT v2, detoured THROUGH that same
#          naive, reaching the de-side plain socks receiver at <de_host>:<uot_port>.
# No key is involved: sing-box socks inbounds unwrap UoT automatically, and the
# receiver port is firewalled so only the de itself (i.e. traffic arriving
# through authenticated naive) can reach it. Everything is already inside TLS.
# NB: the receiver target is the de's PUBLIC host (not 127.0.0.1). naive's forward_proxy denies
# CONNECT to loopback by default, and the loopback-allowing ACL breaks NaiveProxy clients
# (NekoBox). Targeting the public host hairpins into the de's own receiver (firewalled so only
# the node itself can reach :uot_port), needs NO caddy ACL, and keeps de identical for phones.
#
# Why one process and not one per node: every sing-box instance carries its own
# Go runtime (~5 MB private when idle, 8-9 threads, 15-30 MB private under load)
# on top of the shared binary text. Six listeners in one process cost one runtime.
#
# udp_timeout: how long an idle UDP session (and with it the UoT TCP connection
# through naive, plus the relay buffers inside naive) is kept. Live flows refresh
# the timer. Sessions whose SOCKS client closed the association are torn down
# regardless of this value (measured: fds back to baseline within a minute at
# both 30s and 5m), so it only matters for clients that keep associations open.
#
# Usage: no_wrapper_reset; no_wrapper_add ... once per node; no_wrapper_write <file>
no_wrapper_reset() {
	WRAP_IN=""; WRAP_OUT=""; WRAP_RULES=""; WRAP_FINAL=""; WRAP_N=0
}

# args: id bind public_port naive_port de_host uot_port [udp_timeout]
no_wrapper_add() {
	local id="$1" bind="$2" pub="$3" inner="$4" de_host="$5" uot_port="$6" udp_timeout="${7:-5m}"
	local sep=""
	[ "$WRAP_N" = "0" ] || sep=",
"
	WRAP_IN="$WRAP_IN$sep    { \"type\": \"mixed\", \"tag\": \"in-$id\", \"listen\": \"$bind\", \"listen_port\": $pub, \"udp_timeout\": \"$udp_timeout\" }"
	WRAP_OUT="$WRAP_OUT$sep    { \"type\": \"socks\", \"tag\": \"naive-$id\", \"server\": \"127.0.0.1\", \"server_port\": $inner },
    { \"type\": \"socks\", \"tag\": \"uot-$id\",
      \"server\": \"$de_host\", \"server_port\": $uot_port,
      \"udp_over_tcp\": { \"enabled\": true, \"version\": 2 }, \"detour\": \"naive-$id\" }"
	WRAP_RULES="$WRAP_RULES$sep    { \"inbound\": [ \"in-$id\" ], \"network\": \"udp\", \"action\": \"route\", \"outbound\": \"uot-$id\" },
    { \"inbound\": [ \"in-$id\" ], \"action\": \"route\", \"outbound\": \"naive-$id\" }"
	[ -n "$WRAP_FINAL" ] || WRAP_FINAL="naive-$id"
	WRAP_N=$((WRAP_N + 1))
}

# args: file   (returns 1 and writes nothing when no node was added)
no_wrapper_write() {
	local f="$1"
	[ "${WRAP_N:-0}" -gt 0 ] || return 1
	cat > "$f" <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [
$WRAP_IN
  ],
  "outbounds": [
$WRAP_OUT
  ],
  "route": {
    "rules": [
$WRAP_RULES
    ],
    "final": "$WRAP_FINAL"
  }
}
EOF
	chmod 0600 "$f"
}

# is the argument a sing-box duration like 30s, 1m, 2m30s, 1h ?
no_is_duration() {
	case "$1" in
		''|*[!0-9smh]*|[!0-9]*|*[!smh]) return 1 ;;
		*) return 0 ;;
	esac
}

# --- podkop's main sing-box: file descriptor limit ---------------------------
# The sing-box package's init script sets no procd limits, so the daemon runs
# with procd's default hard nofile of 4096. podkop sends ALL LAN traffic through
# it (tproxy + direct-out), and a burst of connections exhausts that: sing-box
# logs "accept4: too many open files" and stops accepting new LAN connections
# while every upstream node is healthy. naive-orch keeps that init script
# patched. A sing-box package upgrade restores the stock script; the healthcheck
# re-applies the patch, and the next sing-box restart (podkop restarts it on
# every config/list change) picks it up.

# Patch the init script once. Returns 0 when it changed the file (the running
# sing-box needs a restart to get the new limit), 1 otherwise.
no_singbox_nofile_patch() {
	local f="${1:-$NO_SB_INIT}" tmp
	[ -f "$f" ] || return 1
	grep -q 'procd_set_param limits nofile=' "$f" && return 1
	grep -q 'procd_open_instance' "$f" || return 1

	# Healthcheck runs can overlap (loop + LuCI refresh): write a full copy next
	# to the file and rename it into place, so a reader never sees a partial
	# script. cp -p first, so the copy already has the original owner and mode.
	tmp="$f.naive-orch.$$"
	cp -p "$f" "$tmp" 2>/dev/null || return 1
	# Insert right before the first `procd_set_param respawn` (or, if the script
	# has none, before the first `procd_close_instance`), keeping its indentation.
	awk -v n="$NO_NOFILE" '
		!done && /^[[:space:]]*procd_set_param[[:space:]]+respawn/ { anchor = 1 }
		!done && !seen_respawn && /^[[:space:]]*procd_close_instance/ { anchor = 1 }
		/^[[:space:]]*procd_set_param[[:space:]]+respawn/ { seen_respawn = 1 }
		anchor {
			ind = $0; sub(/[^[:space:]].*$/, "", ind)
			print ind "# naive-orch: podkop routes all LAN traffic through this daemon;"
			print ind "# the procd default (4096) runs out under load (accept4: too many open files)"
			print ind "procd_set_param limits nofile=\"" n " " n "\""
			anchor = 0; done = 1
		}
		{ print }
		END { if (!done) exit 1 }
	' "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
	sh -n "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
	mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
	return 0
}

# pid of podkop's main sing-box (empty when it is not running)
no_singbox_main_pid() {
	local p
	for p in $(pidof sing-box 2>/dev/null); do
		grep -q "$NO_SB_CONF" "/proc/$p/cmdline" 2>/dev/null && { echo "$p"; return 0; }
	done
	return 1
}

# hard "Max open files" of a pid (empty when unknown)
no_pid_nofile() {
	awk '/^Max open files/ { print $5; exit }' "/proc/$1/limits" 2>/dev/null
}

# Is the running main sing-box below the wanted limit? (0 = yes, needs restart)
no_singbox_nofile_low() {
	local p lim
	p="$(no_singbox_main_pid)" || return 1
	lim="$(no_pid_nofile "$p")"
	case "$lim" in
		''|unlimited|*[!0-9]*) return 1 ;;
	esac
	[ "$lim" -lt "$NO_NOFILE" ]
}

# extract the host from a naive proxy URL (https://user:pass@host:port -> host)
no_proxy_host() {
	local u="${1#https://}"   # strip scheme
	u="${u#*@}"               # strip userinfo
	u="${u%%:*}"              # strip :port
	u="${u%%/*}"              # strip /path
	echo "$u"
}

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

# render a sing-box "UoT wrapper" for one node (variant B).
# The wrapper is what Podkop talks to on the public port; it splits:
#   TCP -> the node's naive SOCKS (direct, no double tunnel)
#   UDP -> shadowsocks-2022 with udp_over_tcp, detoured THROUGH that same naive,
#          reaching the de-side receiver at <de_host>:<uot_port>.
# NB: the ss-uot server is the de's PUBLIC host (not 127.0.0.1). naive's forward_proxy denies
# CONNECT to loopback by default, and the loopback-allowing ACL breaks NaiveProxy clients
# (NekoBox). Targeting the public host hairpins into the de's own receiver (firewalled so only
# the node itself can reach :uot_port), needs NO caddy ACL, and keeps de identical for phones.
# args: id bind public_port naive_port de_host uot_port method psk
no_render_wrapper() {
	local id="$1" bind="$2" pub="$3" inner="$4" de_host="$5" uot_port="$6" method="$7" psk="$8"
	local f="$NO_RUNDIR/$id.wrap.json"

	cat > "$f" <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [
    { "type": "mixed", "tag": "in", "listen": "$bind", "listen_port": $pub }
  ],
  "outbounds": [
    { "type": "socks", "tag": "naive", "server": "127.0.0.1", "server_port": $inner },
    { "type": "shadowsocks", "tag": "ss-uot",
      "server": "$de_host", "server_port": $uot_port,
      "method": "$method", "password": "$psk",
      "udp_over_tcp": { "enabled": true, "version": 2 }, "detour": "naive" }
  ],
  "route": { "rules": [ { "network": "udp", "outbound": "ss-uot" } ], "final": "naive" }
}
EOF
	chmod 0600 "$f"
}

# extract the host from a naive proxy URL (https://user:pass@host:port -> host)
no_proxy_host() {
	local u="${1#https://}"   # strip scheme
	u="${u#*@}"               # strip userinfo
	u="${u%%:*}"              # strip :port
	u="${u%%/*}"              # strip /path
	echo "$u"
}

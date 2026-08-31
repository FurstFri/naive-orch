#!/bin/sh
# uot-server-install.sh — UDP-over-TCP receiver for a naive (Caddy forward_proxy) node.
#
# Sets up a sing-box Shadowsocks-2022 inbound that unwraps UDP-over-TCP back into real UDP.
# Clients (the OpenWrt router's per-node wrapper, or a phone's NekoBox naive->ss-uot chain)
# reach it THROUGH naive: naive does CONNECT to this de's OWN public host:PORT, which hairpins
# into the local receiver. A firewall keeps PORT reachable ONLY from the node itself, so:
#   * nothing shadowsocks is reachable from the outside (port is firewalled / invisible),
#   * Caddy is NOT touched (no ACL) — so NaiveProxy clients incl. NekoBox keep working,
#   * on the wire there is only naive/HTTPS; the SS receiver lives behind the tunnel.
#
# Why public-host CONNECT and not 127.0.0.1: caddy-forwardproxy denies CONNECT to loopback by
# default, and the loopback-allowing ACL breaks NaiveProxy clients (observed: NekoBox could not
# connect). CONNECT to the node's public host is allowed by default and hairpins locally.
#
# Idempotent. Usage (root on each de* node):
#   PSK='<shared base64 16B>' sh uot-server-install.sh        # all nodes share one PSK
#   sh uot-server-install.sh                                  # generate+persist PSK on first run
#
# Env:
#   PSK       shared Shadowsocks-2022 key (16 bytes base64 for the default method)
#   PORT      receiver port (default 8388)
#   METHOD    SS method (default 2022-blake3-aes-128-gcm)
#   PUBIP     this node's public IP (default: auto-detected via default route)
#   NO_FW=1   skip the firewall step (NOT recommended — leaves the port world-open)

set -eu

PORT="${PORT:-8388}"
METHOD="${METHOD:-2022-blake3-aes-128-gcm}"
PSK_ENV="/etc/sing-box/uot-psk.env"
SB_CONF="/etc/sing-box/config.json"

log() { echo "[uot-install] $*"; }

# ---------------------------------------------------------------- sing-box
if ! command -v sing-box >/dev/null 2>&1; then
	log "installing sing-box ..."
	case "$(uname -m)" in
		x86_64|amd64) ARCH=amd64 ;;
		aarch64|arm64) ARCH=arm64 ;;
		*) log "ERROR: unsupported arch $(uname -m)"; exit 1 ;;
	esac
	VER="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest \
		| sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -1)"
	[ -n "$VER" ] || { log "ERROR: could not detect sing-box version"; exit 1; }
	curl -fsSL -o /tmp/sing-box.deb \
		"https://github.com/SagerNet/sing-box/releases/download/v${VER}/sing-box_${VER}_linux_${ARCH}.deb"
	dpkg -i /tmp/sing-box.deb
fi
log "sing-box $(sing-box version | head -1 | awk '{print $3}')"

# ---------------------------------------------------------------- PSK
mkdir -p /etc/sing-box
[ -f "$PSK_ENV" ] && . "$PSK_ENV"
[ -n "${PSK:-}" ] || PSK="$(openssl rand -base64 16)"
printf "PSK='%s'\n" "$PSK" > "$PSK_ENV"; chmod 600 "$PSK_ENV"

# ---------------------------------------------------------------- public IP
PUBIP="${PUBIP:-$(ip route get 8.8.8.8 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)}"
[ -n "$PUBIP" ] || { log "ERROR: could not detect public IP; set PUBIP=..."; exit 1; }
log "public IP: $PUBIP  (receiver $PUBIP:$PORT, firewalled to self only)"

# ---------------------------------------------------------------- sing-box config
[ -f "$SB_CONF" ] && cp "$SB_CONF" "$SB_CONF.bak.$(date +%s)"
cat > "$SB_CONF" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    { "type": "shadowsocks", "tag": "ss-uot",
      "listen": "0.0.0.0", "listen_port": $PORT,
      "method": "$METHOD", "password": "$PSK" }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF
sing-box check -c "$SB_CONF"
log "sing-box config valid"
systemctl enable --now sing-box >/dev/null 2>&1 || true
systemctl restart sing-box
sleep 1
ss -ltn 2>/dev/null | grep -qE "0.0.0.0:$PORT" && log "receiver up on 0.0.0.0:$PORT" || log "WARN not listening"

# ---------------------------------------------------------------- firewall (keep PORT private)
# Allow only the node itself (loopback + hairpin from own public IP); drop everything else.
if [ "${NO_FW:-0}" != "1" ]; then
	for proto in tcp udp; do
		# idempotent: clear any prior rules we added for this port/proto
		while iptables -C INPUT -i lo -p $proto --dport "$PORT" -j ACCEPT 2>/dev/null; do
			iptables -D INPUT -i lo -p $proto --dport "$PORT" -j ACCEPT; done
		while iptables -C INPUT -p $proto --dport "$PORT" -s "$PUBIP" -j ACCEPT 2>/dev/null; do
			iptables -D INPUT -p $proto --dport "$PORT" -s "$PUBIP" -j ACCEPT; done
		while iptables -C INPUT -p $proto --dport "$PORT" -j DROP 2>/dev/null; do
			iptables -D INPUT -p $proto --dport "$PORT" -j DROP; done
		iptables -A INPUT -i lo -p $proto --dport "$PORT" -j ACCEPT
		iptables -A INPUT -p $proto --dport "$PORT" -s "$PUBIP" -j ACCEPT
		iptables -A INPUT -p $proto --dport "$PORT" -j DROP
	done
	log "firewall: $PORT open only to self (lo + $PUBIP), dropped for the world"
	# persist across reboot (install iptables-persistent if needed, then save)
	if ! command -v netfilter-persistent >/dev/null 2>&1; then
		DEBIAN_FRONTEND=noninteractive apt-get install -y -q iptables-persistent >/dev/null 2>&1 || true
	fi
	if command -v netfilter-persistent >/dev/null 2>&1; then
		netfilter-persistent save >/dev/null 2>&1 && log "firewall persisted (netfilter-persistent)" \
			|| log "WARN netfilter-persistent save failed"
	else
		log "WARN could not install iptables-persistent — firewall NOT persisted across reboot"
	fi
fi

echo
log "DONE. Shared PSK (use the SAME on every de and in the router's naive-orch uot_psk):"
echo "    $PSK"

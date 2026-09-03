#!/bin/sh
# Install a private sing-box UoT receiver next to a NaiveProxy server.
# Supported server OS: Debian/Ubuntu with systemd and iptables.
#
# Installs TWO inbounds:
#   * a keyless plain socks receiver (SOCKS_PORT, default 8389) — used by the
#     naive-orch router wrapper; sing-box unwraps UoT v2 automatically;
#   * a legacy Shadowsocks-2022 receiver (PORT, default 8388) — kept for
#     mobile clients (NekoBox / v2rayN naive-UoT fork) that still speak SS.
# Both ports are firewalled to the server itself and only reachable through
# authenticated naive, so neither is exposed and no key is a secret.
#
# Usage on every proxy server:
#   sh uot-server-install.sh
#
# Optional environment:
#   SOCKS_PORT=8389
#   PORT=8388
#   METHOD=2022-blake3-aes-128-gcm
#   PSK='<custom base64 key>'           # only if your phones use a custom key
#   PUBIP=<server IPv4 detected by INPUT rules>

set -eu

PORT="${PORT:-8388}"
SOCKS_PORT="${SOCKS_PORT:-8389}"
METHOD="${METHOD:-2022-blake3-aes-128-gcm}"
PSK_ENV="/etc/sing-box/uot-psk.env"
SB_CONF="/etc/sing-box/uot-receiver.json"
FW_SCRIPT="/usr/local/libexec/naive-orch-uot-firewall"
UNIT_FILE="/etc/systemd/system/sing-box-uot.service"
TEMP_DIR=""

log() { printf '[uot-install] %s\n' "$*"; }
fail() { printf '[uot-install] ERROR: %s\n' "$*" >&2; exit 1; }
cleanup() { [ -z "$TEMP_DIR" ] || rm -rf "$TEMP_DIR"; }
trap cleanup 0
trap 'exit 1' 1 2 15

case "$PORT" in ''|*[!0-9]*) fail "PORT must be a number" ;; esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || fail "PORT must be between 1 and 65535"
case "$SOCKS_PORT" in ''|*[!0-9]*) fail "SOCKS_PORT must be a number" ;; esac
[ "$SOCKS_PORT" -ge 1 ] && [ "$SOCKS_PORT" -le 65535 ] || fail "SOCKS_PORT must be between 1 and 65535"
[ "$SOCKS_PORT" != "$PORT" ] || fail "SOCKS_PORT must differ from PORT"

case "$METHOD" in
	2022-blake3-aes-128-gcm) KEY_SIZE=16 ;;
	2022-blake3-aes-256-gcm) KEY_SIZE=32 ;;
	*) fail "unsupported METHOD: $METHOD" ;;
esac

missing=""
for command_name in curl ip ss iptables systemctl base64 sha256sum; do
	command -v "$command_name" >/dev/null 2>&1 || missing="$missing $command_name"
done
if [ -n "$missing" ]; then
	command -v apt-get >/dev/null 2>&1 || fail "missing commands:$missing; apt-get is unavailable"
	log "installing required system packages"
	apt-get update
	DEBIAN_FRONTEND=noninteractive apt-get install -y \
		curl ca-certificates iproute2 iptables coreutils
fi

install_sing_box() {
	local arch api_file version package_name package_url package_digest package_file
	command -v sing-box >/dev/null 2>&1 && return 0

	case "$(uname -m)" in
		x86_64|amd64) arch=amd64 ;;
		aarch64|arm64) arch=arm64 ;;
		*) fail "unsupported server architecture: $(uname -m)" ;;
	esac

	TEMP_DIR="$(mktemp -d /tmp/naive-orch-uot.XXXXXX)"
	api_file="$TEMP_DIR/release.json"
	log "downloading official sing-box package"
	curl -fsSL --retry 3 --connect-timeout 10 \
		-o "$api_file" https://api.github.com/repos/SagerNet/sing-box/releases/latest
	version="$(sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' "$api_file" | head -n 1)"
	[ -n "$version" ] || fail "could not detect the latest sing-box version"
	package_name="sing-box_${version}_linux_${arch}.deb"
	package_url="$(sed -n 's|.*"browser_download_url": "\([^"]*/'"$package_name"'\)".*|\1|p' "$api_file" | head -n 1)"
	package_digest="$(awk -v wanted="\"name\": \"$package_name\"" '
		index($0, wanted) { found=1 }
		found && /"digest": "sha256:/ {
			sub(/.*"digest": "sha256:/, ""); sub(/".*/, ""); print; exit
		}
		found && /"browser_download_url":/ { exit }
	' "$api_file")"
	[ -n "$package_url" ] && [ -n "$package_digest" ] || \
		fail "release metadata is missing the package URL or SHA-256"

	package_file="$TEMP_DIR/$package_name"
	curl -fL --retry 3 --connect-timeout 10 -o "$package_file" "$package_url"
	printf '%s  %s\n' "$package_digest" "$package_file" | sha256sum -c - >/dev/null || \
		fail "sing-box package checksum mismatch"
	dpkg -i "$package_file"
}

install_sing_box
SB_BIN="$(command -v sing-box)"
log "sing-box $($SB_BIN version | head -n 1 | awk '{print $3}')"

mkdir -p /etc/sing-box /usr/local/libexec

# Key priority: explicit PSK env > key persisted by an earlier install >
# built-in public key (matches the naive-orch router default).
DEFAULT_PSK16='bmFpdmUtb3JjaC11b3QtMQ=='
DEFAULT_PSK32='bmFpdmUtb3JjaC11b3QtZGVmYXVsdC1wc2stMjAyMiE='
PSK_SOURCE="custom"
if [ -z "${PSK:-}" ] && [ -f "$PSK_ENV" ]; then
	. "$PSK_ENV"
	PSK_SOURCE="persisted"
fi
if [ -z "${PSK:-}" ]; then
	case "$METHOD" in
		2022-blake3-aes-256-gcm) PSK="$DEFAULT_PSK32" ;;
		*)                       PSK="$DEFAULT_PSK16" ;;
	esac
	PSK_SOURCE="built-in"
fi
case "$PSK" in *[!A-Za-z0-9+/=]*) fail "PSK is not valid base64" ;; esac
decoded_size="$(printf '%s' "$PSK" | base64 -d 2>/dev/null | wc -c | tr -d ' ')"
[ "$decoded_size" = "$KEY_SIZE" ] || \
	fail "PSK must decode to $KEY_SIZE bytes for $METHOD"
# Persist only custom keys; the built-in key needs no state on disk.
if [ "$PSK_SOURCE" = "custom" ]; then
	printf "PSK='%s'\n" "$PSK" > "$PSK_ENV"
	chmod 0600 "$PSK_ENV"
fi
log "UoT key: $PSK_SOURCE"

PUBIP="${PUBIP:-$(ip route get 8.8.8.8 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)}"
[ -n "$PUBIP" ] || fail "could not detect server IPv4; set PUBIP explicitly"
case "$PUBIP" in *[!0-9.]*) fail "PUBIP must be an IPv4 address" ;; esac

# Apply the firewall before starting the receiver. The same script runs before
# every service start, so a reboot never starts the public listener first.
cat > "$FW_SCRIPT" <<EOF
#!/bin/sh
set -eu
PORTS='$PORT $SOCKS_PORT'
PUBIP='$PUBIP'
for fw_port in \$PORTS; do
	for proto in tcp udp; do
		while iptables -C INPUT -i lo -p "\$proto" --dport "\$fw_port" -j ACCEPT 2>/dev/null; do
			iptables -D INPUT -i lo -p "\$proto" --dport "\$fw_port" -j ACCEPT
		done
		while iptables -C INPUT -p "\$proto" --dport "\$fw_port" -s "\$PUBIP" -j ACCEPT 2>/dev/null; do
			iptables -D INPUT -p "\$proto" --dport "\$fw_port" -s "\$PUBIP" -j ACCEPT
		done
		while iptables -C INPUT -p "\$proto" --dport "\$fw_port" -j DROP 2>/dev/null; do
			iptables -D INPUT -p "\$proto" --dport "\$fw_port" -j DROP
		done
		iptables -I INPUT 1 -p "\$proto" --dport "\$fw_port" -j DROP
		iptables -I INPUT 1 -p "\$proto" --dport "\$fw_port" -s "\$PUBIP" -j ACCEPT
		iptables -I INPUT 1 -i lo -p "\$proto" --dport "\$fw_port" -j ACCEPT
	done
done
EOF
chmod 0700 "$FW_SCRIPT"
"$FW_SCRIPT"
log "firewall applied: ports $PORT and $SOCKS_PORT accept only loopback and $PUBIP"

cat > "$SB_CONF" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks-uot",
      "listen": "0.0.0.0",
      "listen_port": $SOCKS_PORT
    },
    {
      "type": "shadowsocks",
      "tag": "ss-uot",
      "listen": "0.0.0.0",
      "listen_port": $PORT,
      "method": "$METHOD",
      "password": "$PSK"
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF
chmod 0600 "$SB_CONF"
"$SB_BIN" check -c "$SB_CONF"

# Migrate installations made by the older script without touching unrelated
# sing-box configurations.
if [ -f /etc/sing-box/config.json ] && \
	grep -q '"tag"[[:space:]]*:[[:space:]]*"ss-uot"' /etc/sing-box/config.json; then
	systemctl disable --now sing-box >/dev/null 2>&1 || true
	cp /etc/sing-box/config.json "/etc/sing-box/config.json.legacy.$(date +%s)"
fi

cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Private sing-box UoT receiver for Naive Orchestrator
Wants=network-online.target
After=network-online.target nftables.service netfilter-persistent.service ufw.service firewalld.service

[Service]
Type=simple
ExecStartPre=$FW_SCRIPT
ExecStart=$SB_BIN run -c $SB_CONF
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box-uot
systemctl restart sing-box-uot
sleep 1
systemctl is-active --quiet sing-box-uot || fail "sing-box-uot did not start"
ss -ltn 2>/dev/null | grep -qE "(^|[[:space:]])0\.0\.0\.0:$PORT([[:space:]]|$)" || \
	fail "SS receiver is not listening on TCP port $PORT"
ss -ltn 2>/dev/null | grep -qE "(^|[[:space:]])0\.0\.0\.0:$SOCKS_PORT([[:space:]]|$)" || \
	fail "socks receiver is not listening on TCP port $SOCKS_PORT"

log "UoT receivers are ready and restricted to the server itself:"
log "  socks (keyless, for the router): $PUBIP:$SOCKS_PORT"
log "  shadowsocks (for mobile clients, key: $PSK_SOURCE): $PUBIP:$PORT"

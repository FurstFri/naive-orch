#!/bin/sh
# Install a private sing-box UoT receiver next to a NaiveProxy server.
# Supported server OS: Debian/Ubuntu with systemd and iptables.
#
# Usage on every proxy server:
#   PSK='<shared base64 key>' sh uot-server-install.sh
#
# Optional environment:
#   PORT=8388
#   METHOD=2022-blake3-aes-128-gcm
#   PUBIP=<server IPv4 detected by INPUT rules>

set -eu

PORT="${PORT:-8388}"
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

case "$METHOD" in
	2022-blake3-aes-128-gcm) KEY_SIZE=16 ;;
	2022-blake3-aes-256-gcm) KEY_SIZE=32 ;;
	*) fail "unsupported METHOD: $METHOD" ;;
esac

missing=""
for command_name in curl openssl ip ss iptables systemctl base64 sha256sum; do
	command -v "$command_name" >/dev/null 2>&1 || missing="$missing $command_name"
done
if [ -n "$missing" ]; then
	command -v apt-get >/dev/null 2>&1 || fail "missing commands:$missing; apt-get is unavailable"
	log "installing required system packages"
	apt-get update
	DEBIAN_FRONTEND=noninteractive apt-get install -y \
		curl ca-certificates openssl iproute2 iptables coreutils
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

# Reuse a persisted key unless PSK was explicitly supplied.
if [ -z "${PSK:-}" ] && [ -f "$PSK_ENV" ]; then
	. "$PSK_ENV"
fi
[ -n "${PSK:-}" ] || {
	if [ -r /dev/tty ]; then
		printf 'Shared UoT PSK from the OpenWrt installer: ' > /dev/tty
		IFS= read -r PSK < /dev/tty || true
	fi
}
[ -n "${PSK:-}" ] || PSK="$(openssl rand -base64 "$KEY_SIZE" | tr -d '\r\n')"
case "$PSK" in *[!A-Za-z0-9+/=]*) fail "PSK is not valid base64" ;; esac
decoded_size="$(printf '%s' "$PSK" | base64 -d 2>/dev/null | wc -c | tr -d ' ')"
[ "$decoded_size" = "$KEY_SIZE" ] || \
	fail "PSK must decode to $KEY_SIZE bytes for $METHOD"
printf "PSK='%s'\n" "$PSK" > "$PSK_ENV"
chmod 0600 "$PSK_ENV"

PUBIP="${PUBIP:-$(ip route get 8.8.8.8 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)}"
[ -n "$PUBIP" ] || fail "could not detect server IPv4; set PUBIP explicitly"
case "$PUBIP" in *[!0-9.]*) fail "PUBIP must be an IPv4 address" ;; esac

# Apply the firewall before starting the receiver. The same script runs before
# every service start, so a reboot never starts the public listener first.
cat > "$FW_SCRIPT" <<EOF
#!/bin/sh
set -eu
PORT='$PORT'
PUBIP='$PUBIP'
for proto in tcp udp; do
	while iptables -C INPUT -i lo -p "\$proto" --dport "\$PORT" -j ACCEPT 2>/dev/null; do
		iptables -D INPUT -i lo -p "\$proto" --dport "\$PORT" -j ACCEPT
	done
	while iptables -C INPUT -p "\$proto" --dport "\$PORT" -s "\$PUBIP" -j ACCEPT 2>/dev/null; do
		iptables -D INPUT -p "\$proto" --dport "\$PORT" -s "\$PUBIP" -j ACCEPT
	done
	while iptables -C INPUT -p "\$proto" --dport "\$PORT" -j DROP 2>/dev/null; do
		iptables -D INPUT -p "\$proto" --dport "\$PORT" -j DROP
	done
	iptables -I INPUT 1 -p "\$proto" --dport "\$PORT" -j DROP
	iptables -I INPUT 1 -p "\$proto" --dport "\$PORT" -s "\$PUBIP" -j ACCEPT
	iptables -I INPUT 1 -i lo -p "\$proto" --dport "\$PORT" -j ACCEPT
done
EOF
chmod 0700 "$FW_SCRIPT"
"$FW_SCRIPT"
log "firewall applied: port $PORT accepts only loopback and $PUBIP"

cat > "$SB_CONF" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
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
	fail "receiver is not listening on TCP port $PORT"

log "UoT receiver is ready on $PUBIP:$PORT and restricted to the server itself"
log "Shared PSK — use the same value on every server and in Naive Orchestrator:"
printf '%s\n' "$PSK"

#!/bin/sh
# naive-orch installer (run on the OpenWrt router).
# Copies files from ./root into /, fixes permissions, and optionally enables
# and starts the service.
#
# Usage (on the router):
#   sh install.sh            # install files and dependencies
#   sh install.sh --enable   # also enable and start the service
#   sh install.sh --enable --uot  # install sing-box and enable UDP over TCP
#   sh install.sh --skip-naive  # do not download the official naive binary
#
# Safe by design: binds only to 127.0.0.1, the sample node is disabled,
# nothing touches firewall / DNS / nftables. UDP over TCP is keyless: the
# de-side receiver is a plain socks inbound reachable only through naive.

set -e

SRC_DIR="$(cd "$(dirname "$0")" && pwd)/root"
ENABLE=0
INSTALL_NAIVE="${NAIVE_ORCH_INSTALL_NAIVE:-1}"
INSTALL_UOT="${NAIVE_ORCH_INSTALL_UOT:-0}"
PKG_UPDATED=0

for arg in "$@"; do
	case "$arg" in
		--enable) ENABLE=1 ;;
		--uot) INSTALL_UOT=1 ;;
		--skip-naive) INSTALL_NAIVE=0 ;;
		*) echo "ERROR: unknown option: $arg" >&2; exit 2 ;;
	esac
done

[ -d "$SRC_DIR" ] || { echo "ERROR: $SRC_DIR not found"; exit 1; }

msg() {
	printf '\033[1;32m%s\033[0m\n' "$1"
}

warn() {
	printf '\033[1;33mWARNING: %s\033[0m\n' "$1" >&2
}

pkg_installed() {
	if command -v apk >/dev/null 2>&1; then
		apk info -e "$1" >/dev/null 2>&1
	else
		opkg list-installed "$1" 2>/dev/null | grep -q "^$1 "
	fi
}

pkg_update_once() {
	[ "$PKG_UPDATED" = "1" ] && return 0
	msg "==> Updating OpenWrt package lists"
	if command -v apk >/dev/null 2>&1; then
		apk update
	elif command -v opkg >/dev/null 2>&1; then
		opkg update
	else
		echo "ERROR: neither apk nor opkg was found; this does not look like OpenWrt" >&2
		exit 1
	fi
	PKG_UPDATED=1
}

pkg_install() {
	pkg_update_once
	if command -v apk >/dev/null 2>&1; then
		apk add "$@"
	else
		opkg install "$@"
	fi
}

ensure_dependencies() {
	local missing=""
	pkg_installed curl || missing="$missing curl"
	pkg_installed ca-bundle || missing="$missing ca-bundle"
	pkg_installed rpcd-mod-file || missing="$missing rpcd-mod-file"
	pkg_installed luci-base || missing="$missing luci-base"
	[ "$INSTALL_NAIVE" = "1" ] && ! command -v xz >/dev/null 2>&1 && \
		missing="$missing xz-utils"

	if [ -n "$missing" ]; then
		msg "==> Installing dependencies:$missing"
		# The values above are fixed package names, not user input.
		# shellcheck disable=SC2086
		pkg_install $missing
	else
		msg "==> Dependencies are already installed"
	fi
}

download_naive() {
	local arch api_dir api_file asset_arch asset_name asset_url asset_digest
	local archive extract_dir binary

	[ "$INSTALL_NAIVE" = "1" ] || {
		warn "naive installation skipped by request"
		return 0
	}
	[ -x /usr/bin/naive ] && {
		msg "==> naive binary is already installed"
		return 0
	}

	arch=""
	[ -r /etc/openwrt_release ] && . /etc/openwrt_release
	arch="${DISTRIB_ARCH:-}"
	[ -n "$arch" ] || {
		echo "ERROR: cannot determine OpenWrt package architecture" >&2
		exit 1
	}

	api_dir="$(mktemp -d /tmp/naive-orch-naive.XXXXXX)"
	api_file="$api_dir/release.json"
	msg "==> Installing official naiveproxy binary for $arch"
	curl -fsSL --retry 3 --connect-timeout 10 \
		-o "$api_file" https://api.github.com/repos/klzgrad/naiveproxy/releases/latest

	# Prefer a static OpenWrt build when the release provides one, otherwise use
	# the exact OpenWrt architecture build. Never guess a CPU architecture.
	asset_arch="${arch}-static"
	asset_name="$(sed -n 's/.*"name": "\([^"]*openwrt-'"$asset_arch"'\.tar\.xz\)".*/\1/p' "$api_file" | head -n 1)"
	if [ -z "$asset_name" ]; then
		asset_arch="$arch"
		asset_name="$(sed -n 's/.*"name": "\([^"]*openwrt-'"$asset_arch"'\.tar\.xz\)".*/\1/p' "$api_file" | head -n 1)"
	fi
	if [ -z "$asset_name" ]; then
		rm -rf "$api_dir"
		echo "ERROR: the latest naiveproxy release has no OpenWrt build for '$arch'" >&2
		echo "Install /usr/bin/naive manually, then rerun with --skip-naive." >&2
		exit 1
	fi

	asset_url="$(sed -n 's|.*"browser_download_url": "\([^"]*/'"$asset_name"'\)".*|\1|p' "$api_file" | head -n 1)"
	asset_digest="$(awk -v wanted="\"name\": \"$asset_name\"" '
		index($0, wanted) { found=1 }
		found && /"digest": "sha256:/ {
			sub(/.*"digest": "sha256:/, ""); sub(/".*/, ""); print; exit
		}
		found && /"browser_download_url":/ { exit }
	' "$api_file")"
	[ -n "$asset_url" ] || {
		rm -rf "$api_dir"
		echo "ERROR: naiveproxy release metadata did not contain a download URL" >&2
		exit 1
	}

	archive="$api_dir/$asset_name"
	curl -fL --retry 3 --connect-timeout 10 -o "$archive" "$asset_url"
	if [ -n "$asset_digest" ]; then
		printf '%s  %s\n' "$asset_digest" "$archive" | sha256sum -c - >/dev/null || {
			rm -rf "$api_dir"
			echo "ERROR: naiveproxy archive checksum mismatch" >&2
			exit 1
		}
	fi

	extract_dir="$api_dir/unpacked"
	mkdir -p "$extract_dir"
	tar -xJf "$archive" -C "$extract_dir"
	binary="$(find "$extract_dir" -type f -name naive | head -n 1)"
	[ -n "$binary" ] && [ -s "$binary" ] || {
		rm -rf "$api_dir"
		echo "ERROR: naive binary was not found in $asset_name" >&2
		exit 1
	}
	cp "$binary" /usr/bin/naive
	chmod 0755 /usr/bin/naive
	/usr/bin/naive --version 2>/dev/null || /usr/bin/naive -version 2>/dev/null || true
	rm -rf "$api_dir"
}

download_sing_box() {
	local arch api_dir api_file package_ext package_name package_url package_digest package_file

	[ -x /usr/bin/sing-box ] && {
		msg "==> sing-box is already installed"
		return 0
	}

	# Prefer the configured OpenWrt repository. If it does not provide sing-box,
	# install the matching package from the official SagerNet release.
	if pkg_install sing-box; then
		[ -x /usr/bin/sing-box ] || {
			echo "ERROR: sing-box package installed but /usr/bin/sing-box is missing" >&2
			exit 1
		}
		return 0
	fi
	warn "sing-box is unavailable in the configured package feeds; using the official release"

	arch=""
	[ -r /etc/openwrt_release ] && . /etc/openwrt_release
	arch="${DISTRIB_ARCH:-}"
	[ -n "$arch" ] || {
		echo "ERROR: cannot determine OpenWrt package architecture for sing-box" >&2
		exit 1
	}

	if command -v apk >/dev/null 2>&1; then
		package_ext="apk"
	else
		package_ext="ipk"
	fi

	api_dir="$(mktemp -d /tmp/naive-orch-sing-box.XXXXXX)"
	api_file="$api_dir/release.json"
	curl -fsSL --retry 3 --connect-timeout 10 \
		-o "$api_file" https://api.github.com/repos/SagerNet/sing-box/releases/latest

	package_name="$(sed -n 's/.*"name": "\([^"]*_openwrt_'"$arch"'\.'"$package_ext"'\)".*/\1/p' "$api_file" | head -n 1)"
	[ -n "$package_name" ] || {
		rm -rf "$api_dir"
		echo "ERROR: the latest sing-box release has no OpenWrt package for '$arch'" >&2
		exit 1
	}

	package_url="$(sed -n 's|.*"browser_download_url": "\([^"]*/'"$package_name"'\)".*|\1|p' "$api_file" | head -n 1)"
	package_digest="$(awk -v wanted="\"name\": \"$package_name\"" '
		index($0, wanted) { found=1 }
		found && /"digest": "sha256:/ {
			sub(/.*"digest": "sha256:/, ""); sub(/".*/, ""); print; exit
		}
		found && /"browser_download_url":/ { exit }
	' "$api_file")"
	[ -n "$package_url" ] && [ -n "$package_digest" ] || {
		rm -rf "$api_dir"
		echo "ERROR: sing-box release metadata is missing URL or SHA-256" >&2
		exit 1
	}

	package_file="$api_dir/$package_name"
	curl -fL --retry 3 --connect-timeout 10 -o "$package_file" "$package_url"
	printf '%s  %s\n' "$package_digest" "$package_file" | sha256sum -c - >/dev/null || {
		rm -rf "$api_dir"
		echo "ERROR: sing-box package checksum mismatch" >&2
		exit 1
	}

	if [ "$package_ext" = "apk" ]; then
		# The package is verified against GitHub's release digest above.
		apk add --allow-untrusted "$package_file"
	else
		opkg install "$package_file"
	fi
	rm -rf "$api_dir"
	[ -x /usr/bin/sing-box ] || {
		echo "ERROR: /usr/bin/sing-box is missing after installation" >&2
		exit 1
	}
}

configure_uot() {
	[ "$INSTALL_UOT" = "1" ] || return 0

	uci set naive-orch.@global[0].udp_over_tcp='1'
	# Keyless UoT: the old SS-2022 options are no longer used by the router.
	uci -q delete naive-orch.@global[0].uot_psk 2>/dev/null || true
	uci -q delete naive-orch.@global[0].uot_method 2>/dev/null || true
	# 8388 could only mean the legacy SS receiver; the socks receiver is 8389.
	if [ "$(uci -q get naive-orch.@global[0].uot_port 2>/dev/null)" = "8388" ]; then
		uci -q delete naive-orch.@global[0].uot_port
	fi
	uci -q get naive-orch.@global[0].uot_port >/dev/null || \
		uci set naive-orch.@global[0].uot_port='8389'
	uci -q get naive-orch.@global[0].uot_offset >/dev/null || \
		uci set naive-orch.@global[0].uot_offset='1000'
	uci commit naive-orch
	chmod 0600 /etc/config/naive-orch
}

ensure_dependencies
download_naive
[ "$INSTALL_UOT" = "1" ] && download_sing_box

msg "==> Installing naive-orch from $SRC_DIR"

# /etc/config: do not clobber an existing user config
if [ -f /etc/config/naive-orch ]; then
	echo "    keep existing /etc/config/naive-orch (installing sample as .new)"
	cp "$SRC_DIR/etc/config/naive-orch" /etc/config/naive-orch.new
else
	cp "$SRC_DIR/etc/config/naive-orch" /etc/config/naive-orch
	chmod 0600 /etc/config/naive-orch
fi

cp "$SRC_DIR/etc/init.d/naive-orch" /etc/init.d/naive-orch
chmod 0755 /etc/init.d/naive-orch

mkdir -p /usr/libexec/naive-orch
for f in lib.sh render-config healthcheck status sub-update; do
	cp "$SRC_DIR/usr/libexec/naive-orch/$f" "/usr/libexec/naive-orch/$f"
done
chmod 0644 /usr/libexec/naive-orch/lib.sh
chmod 0755 /usr/libexec/naive-orch/render-config \
           /usr/libexec/naive-orch/healthcheck \
           /usr/libexec/naive-orch/status \
           /usr/libexec/naive-orch/sub-update

mkdir -p /etc/naive-orch
chmod 0700 /etc/naive-orch

# LuCI app (menu + ACL + JS views)
if [ -d "$SRC_DIR/usr/share/luci" ]; then
	echo "==> Installing LuCI app"
	mkdir -p /usr/share/luci/menu.d /usr/share/rpcd/acl.d \
	         /www/luci-static/resources/view/naive-orch
	cp "$SRC_DIR/usr/share/luci/menu.d/luci-app-naive-orch.json" /usr/share/luci/menu.d/
	cp "$SRC_DIR/usr/share/rpcd/acl.d/luci-app-naive-orch.json"  /usr/share/rpcd/acl.d/
	cp "$SRC_DIR/www/luci-static/resources/view/naive-orch/"*.js \
	   /www/luci-static/resources/view/naive-orch/
	# clear LuCI cache and reload rpcd so menu + ACL take effect
	rm -f /tmp/luci-indexcache* 2>/dev/null
	rm -rf /tmp/luci-modulecache 2>/dev/null
	/etc/init.d/rpcd restart 2>/dev/null
	echo "    LuCI: Services -> Naive Orchestrator (refresh browser)"
fi

configure_uot

msg "==> Checking installation"
[ -x /usr/bin/naive ] && echo "    naive binary: OK (/usr/bin/naive)" \
	|| warn "/usr/bin/naive is missing; nodes cannot start"
command -v curl >/dev/null 2>&1 && echo "    curl: OK"
# sing-box is only needed for variant B (UDP-over-TCP wrappers); podkop usually ships it.
if [ "$(uci -q get naive-orch.@global[0].udp_over_tcp)" = "1" ]; then
	[ -x /usr/bin/sing-box ] && echo "    sing-box: OK (UoT enabled)" \
		|| echo "    WARNING: udp_over_tcp=1 but /usr/bin/sing-box missing — UoT wrappers won't start"
	echo "    NOTE: UoT also needs a receiver on every de node — see server/uot-server-install.sh"
fi

if [ "$ENABLE" = "1" ]; then
	/etc/init.d/naive-orch enable
	/etc/init.d/naive-orch restart
	msg "==> Service enabled and started"
fi

echo ""
msg "Installation complete"
echo "Open LuCI -> Services -> Naive Orchestrator -> Settings"
echo "Add a subscription URL, save it, then update it on the Status tab."
if [ "$INSTALL_UOT" = "1" ]; then
	uot_port="$(uci -q get naive-orch.@global[0].uot_port 2>/dev/null)"
	[ -n "$uot_port" ] || uot_port='8389'
	uot_env=""
	[ "$uot_port" != "8389" ] && uot_env="SOCKS_PORT='$uot_port' "
	echo ""
	msg "UDP over TCP mode enabled (keyless)"
	echo "Run this ONE command on EVERY proxy server:"
	echo ""
	echo "  wget -qO- https://raw.githubusercontent.com/FurstFri/naive-orch/main/server/uot-server-install.sh | ${uot_env}sh"
	echo ""
	echo "The same command is shown in LuCI -> Naive Orchestrator -> Settings -> UDP over TCP."
fi

#!/bin/sh
# Verify that the download metadata parsers still match official release assets.

set -eu

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/naive-orch-release-test.XXXXXX")"
cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup 0
trap 'exit 1' 1 2 15

api_file="$TEST_DIR/sing-box.json"
curl -fsSL -o "$api_file" https://api.github.com/repos/SagerNet/sing-box/releases/latest

arch=x86_64
package_ext=ipk
package_name="$(sed -n 's/.*"name": "\([^"]*_openwrt_'"$arch"'\.'"$package_ext"'\)".*/\1/p' "$api_file" | head -n 1)"
[ -n "$package_name" ]

package_digest="$(awk -v wanted="\"name\": \"$package_name\"" '
	index($0, wanted) { found=1 }
	found && /"digest": "sha256:/ {
		sub(/.*"digest": "sha256:/, ""); sub(/".*/, ""); print; exit
	}
	found && /"browser_download_url":/ { exit }
' "$api_file")"
[ "${#package_digest}" -eq 64 ]

version="$(sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' "$api_file" | head -n 1)"
[ -n "$version" ]
server_package="sing-box_${version}_linux_amd64.deb"
grep -q "\"name\": \"$server_package\"" "$api_file"
server_digest="$(awk -v wanted="\"name\": \"$server_package\"" '
	index($0, wanted) { found=1 }
	found && /"digest": "sha256:/ {
		sub(/.*"digest": "sha256:/, ""); sub(/".*/, ""); print; exit
	}
	found && /"browser_download_url":/ { exit }
' "$api_file")"
[ "${#server_digest}" -eq 64 ]

printf 'release metadata: OK (%s, %s)\n' "$package_name" "$server_package"

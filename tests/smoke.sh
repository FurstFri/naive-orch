#!/bin/sh
# Desktop smoke tests for the OpenWrt shell helpers. Run with:
#   sh tests/smoke.sh

set -eu

PROJECT_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/naive-orch-test.XXXXXX")"

cleanup() {
	rm -rf "$TEST_DIR"
}
trap cleanup 0
trap 'exit 1' 1 2 15

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/run" "$TEST_DIR/etc"

cat > "$TEST_DIR/mock-openwrt.sh" <<EOF
. "$PROJECT_DIR/root/usr/libexec/naive-orch/lib.sh"

NO_STATUSDIR="$TEST_DIR/run"
NO_STATUS="$TEST_DIR/run/status.json"
NO_SERVERS="$TEST_DIR/run/servers.txt"
NO_SUBOP="$TEST_DIR/run/sub-update.json"
NO_SUBLOCK="$TEST_DIR/run/sub-update.lock"
NO_HEALTHLOCK="$TEST_DIR/run/healthcheck.lock"
NO_PERSIST="$TEST_DIR/etc"
NO_PORTMAP="$TEST_DIR/etc/portmap"
NO_SUBSTATE="$TEST_DIR/etc/sub-state"

config_load() { :; }
config_get() {
	local destination="\$1" section="\$2" option="\$3" default="\${4:-}" value
	case "\$section:\$option" in
		global1:health_url) value='https://health.example/204' ;;
		global1:bind_host) value='127.0.0.1' ;;
		node1:enabled|node2:enabled) value='1' ;;
		node1:listen_port) value='1100' ;;
		node2:listen_port) value='1101' ;;
		node1:label) value='Fast "node"' ;;
		node2:label) value='Down node' ;;
		*) value="\$default" ;;
	esac
	case "\$destination" in
		HEALTH_URL) HEALTH_URL="\$value" ;;
		BIND) BIND="\$value" ;;
		enabled) enabled="\$value" ;;
		port) port="\$value" ;;
		label) label="\$value" ;;
		*) eval "\$destination=\"\$value\"" ;;
	esac
}
config_get_bool() { config_get "\$@"; }
config_foreach() {
	local callback="\$1" type="\$2"
	case "\$type" in
		global) "\$callback" global1 ;;
		node) "\$callback" node1; "\$callback" node2 ;;
		subscription) : ;;
	esac
}
no_log() { :; }
EOF

cat > "$TEST_DIR/bin/curl" <<'EOF'
#!/bin/sh
case " $* " in
	*'127.0.0.1:1100'*) printf '0.125000'; exit 0 ;;
	*) echo 'mock connection refused' >&2; exit 7 ;;
esac
EOF
chmod 0755 "$TEST_DIR/bin/curl"

prepare_script() {
	sed \
		-e 's|^\. /lib/functions\.sh$|. "$TEST_MOCK"|' \
		-e 's|^\. /usr/libexec/naive-orch/lib\.sh$|. "$TEST_MOCK"|' \
		"$1" > "$2"
	chmod 0755 "$2"
}

export TEST_MOCK="$TEST_DIR/mock-openwrt.sh"
export PATH="$TEST_DIR/bin:$PATH"

prepare_script "$PROJECT_DIR/root/usr/libexec/naive-orch/healthcheck" "$TEST_DIR/healthcheck"
"$TEST_DIR/healthcheck"

node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
if (data.node1.status !== "healthy" || data.node1.latency_ms !== 125)
  throw new Error("healthy latency was not recorded");
if (data.node1.label !== "Fast \"node\"")
  throw new Error("JSON label escaping failed: " + JSON.stringify(data.node1.label));
if (data.node2.status !== "down" || !data.node2.last_error)
  throw new Error("failed node status was not recorded");
' "$TEST_DIR/run/status.json"

prepare_script "$PROJECT_DIR/root/usr/libexec/naive-orch/status" "$TEST_DIR/status"
status_output="$($TEST_DIR/status)"
printf '%s' "$status_output" | grep -q '125ms'

prepare_script "$PROJECT_DIR/root/usr/libexec/naive-orch/sub-update" "$TEST_DIR/sub-update"
"$TEST_DIR/sub-update" --start --all >/dev/null

attempt=0
while [ "$attempt" -lt 50 ]; do
	state="$($TEST_DIR/sub-update --status | node -e '
let input = "";
process.stdin.on("data", chunk => input += chunk);
process.stdin.on("end", () => process.stdout.write(JSON.parse(input).state));
')"
	[ "$state" = "error" ] && break
	attempt=$(( attempt + 1 ))
	sleep 0.1
done

[ "$state" = "error" ]
attempt=0
while [ -d "$TEST_DIR/run/sub-update.lock" ] && [ "$attempt" -lt 20 ]; do
	attempt=$(( attempt + 1 ))
	sleep 0.05
done
[ ! -d "$TEST_DIR/run/sub-update.lock" ]

echo "smoke tests: OK"

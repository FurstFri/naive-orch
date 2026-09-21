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

# --- UoT wrapper: one sing-box config for all nodes ---------------------------
sh -eu -c '
. "$1"
NO_RUNDIR="$2"; NO_WRAP="$2/uot.json"
no_wrapper_reset
no_wrapper_write "$NO_WRAP" && { echo "wrapper written with zero nodes"; exit 1; }
no_wrapper_add de1 127.0.0.1 1100 2100 "$(no_proxy_host https://u:p@de1.example.com:443)" 8389 1m
no_wrapper_add de2 127.0.0.1 1101 2101 de2.example.com 8389 30s
no_wrapper_write "$NO_WRAP"
for d in 30s 1m 2m30s 1h; do no_is_duration "$d" || { echo "duration $d rejected"; exit 1; }; done
for d in "" 0 5 m 1x 1m,; do no_is_duration "$d" && { echo "duration $d accepted"; exit 1; }; done
exit 0
' sh "$TEST_MOCK" "$TEST_DIR/run"
node -e '
const fs = require("fs");
const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const inb = j.inbounds.map(i => i.tag).join(",");
if (inb !== "in-de1,in-de2") throw new Error("wrapper inbounds: " + inb);
if (j.inbounds[1].udp_timeout !== "30s" || j.inbounds[0].listen_port !== 1100)
  throw new Error("wrapper inbound fields");
const out = Object.fromEntries(j.outbounds.map(o => [o.tag, o]));
if (out["uot-de1"].detour !== "naive-de1" || out["uot-de1"].server !== "de1.example.com")
  throw new Error("uot outbound must detour through its own naive");
if (out["naive-de2"].server_port !== 2101) throw new Error("naive outbound port");
const r = j.route.rules;
if (r.length !== 4 || r[0].network !== "udp" || r[0].outbound !== "uot-de1" ||
    r[1].inbound[0] !== "in-de1" || r[1].outbound !== "naive-de1" || r[3].outbound !== "naive-de2")
  throw new Error("route rules: " + JSON.stringify(r));
' "$TEST_DIR/run/uot.json"

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

#!/bin/bash
# Adversarial integration test for the PROTOTYPE egress broker.
# Unprivileged, loopback only. A Seatbelt-confined curl (outbound allowed ONLY
# to the broker port, no DNS) is the stand-in for the download tool tree.
# Upstreams are local fakes named *.shield.test; the only non-loopback
# traffic attempted is a CONNECT to www.youtube.com, which the broker must
# refuse (502, no resolver approved) and a direct 1.1.1.1 dial the sandbox
# must refuse. No root, hosts, service, or policy actions.
set -euo pipefail
umask 077
test "$(uname -s)" = Darwin || { echo 'Requires macOS.' >&2; exit 64; }
out=${1:?usage: test_egress_broker.sh <existing-output-directory>}
test -d "$out" || { echo "Not a directory: $out" >&2; exit 64; }
repo=$(cd "$(dirname "$0")/.." && pwd -P)
run=$(mktemp -d "$out/egress-broker.XXXXXX")
broker="$run/ShieldEgressBroker"
xcrun swiftc -swift-version 5 -O -o "$broker" "$repo/EgressBroker/main.swift" \
    "$repo/Kairos/EgressPolicy.swift" "$repo/Kairos/PolicyModels.swift" "$repo/Kairos/AppBlocking.swift" "$repo/Kairos/ConditionalRules.swift"
uport=47821; bport=47831; nport=47832; eport=47833
cred="Basic $(openssl rand -base64 33 | tr -d '\n')"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=upstream.shield.test' \
    -keyout "$run/upstream.key" -out "$run/upstream.crt" >/dev/null 2>&1
pids=()
cleanup() { for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done; }
trap cleanup EXIT

python3 -I - "$uport" "$run/upstream.crt" "$run/upstream.key" <<'EOF' &
import socket, ssl, sys, threading
port, cert, key = int(sys.argv[1]), sys.argv[2], sys.argv[3]
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(cert, key)
server = socket.socket(); server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", port)); server.listen(16)
def serve(conn):
    try:
        tls = context.wrap_socket(conn, server_side=True); tls.recv(4096)
        tls.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 18\r\nConnection: close\r\n\r\nSHIELD-UPSTREAM-OK")
        tls.close()
    except Exception:
        conn.close()
while True:
    c, _ = server.accept(); threading.Thread(target=serve, args=(c,), daemon=True).start()
EOF
pids+=($!)

start_broker() { # port seconds upstreams require_tls ports log
    env -i PATH=/usr/bin:/bin SHIELD_BROKER_PORT="$1" SHIELD_BROKER_SECONDS="$2" \
        SHIELD_BROKER_TEST_UPSTREAMS="$3" SHIELD_BROKER_REQUIRE_TLS="$4" SHIELD_BROKER_PORTS="$5" \
        SHIELD_BROKER_CREDENTIAL="$cred" "$broker" 2>"$6" &
    pids+=($!)
}
start_broker "$bport" 300 "upstream.shield.test=127.0.0.1,other.shield.test=127.0.0.1" 1 "$uport" "$run/broker.log"
start_broker "$nport" 300 "" 1 443 "$run/broker-noresolver.log"
start_broker "$eport" 2 "upstream.shield.test=127.0.0.1" 1 "$uport" "$run/broker-expiring.log"
# The "other" name is allowlisted only so the domain-fronting case has a
# second valid name; the not-allowlisted case uses a third name.
sleep 1

profile="$run/tool.sb"
cat > "$profile" <<EOF
(version 1)
(allow default)
(deny network-outbound)
(deny network-bind)
(deny network-inbound)
(allow network-outbound (remote ip "localhost:$bport"))
(allow network-outbound (remote ip "localhost:$nport"))
(allow network-outbound (remote ip "localhost:$eport"))
(deny mach-lookup (global-name "com.apple.dnssd.service"))
(deny mach-lookup (global-name "com.apple.mDNSResponder"))
EOF

failures=0
results="$run/results.txt"
confined_curl() { sandbox-exec -f "$profile" /usr/bin/curl -sS -k -m 8 "$@"; }
expect() { # name expected-substring-in-output|exit-nonzero  command...
    local name=$1 want=$2; shift 2
    local output status=0
    output=$("$@" 2>&1) || status=$?
    if [ "$want" = FAIL ] && [ "$status" != 0 ]; then
        echo "PASS  $name (refused: rc=$status ${output//$'\n'/ })" | cut -c1-200 | tee -a "$results"
    elif [ "$want" != FAIL ] && [[ "$output" == *"$want"* ]]; then
        echo "PASS  $name" | tee -a "$results"
    else
        echo "FAIL  $name (rc=$status) ${output//$'\n'/ }" | cut -c1-300 | tee -a "$results"
        failures=$((failures + 1))
    fi
}
via() { confined_curl --proxy "http://127.0.0.1:$1" --proxy-header "Proxy-Authorization: $2" "${@:3}"; }

expect "allowed host via broker returns upstream body" SHIELD-UPSTREAM-OK \
    via "$bport" "$cred" "https://upstream.shield.test:$uport/"
expect "wrong credential refused (407)" FAIL via "$bport" "Basic d3Jvbmc=" "https://upstream.shield.test:$uport/"
expect "missing credential refused (407)" FAIL \
    confined_curl --proxy "http://127.0.0.1:$bport" "https://upstream.shield.test:$uport/"
expect "non-allowlisted name refused (403)" FAIL via "$bport" "$cred" "https://evil.shield.test:$uport/"
expect "IPv4 literal refused (403)" FAIL via "$bport" "$cred" "https://127.0.0.1:$uport/"
expect "IPv6 literal refused (403)" FAIL via "$bport" "$cred" "https://[::1]:$uport/"
expect "non-allowed port refused (403)" FAIL via "$bport" "$cred" "https://upstream.shield.test:9/"
expect "domain fronting (SNI != CONNECT host) refused" FAIL via "$bport" "$cred" \
    --connect-to "other.shield.test:$uport:upstream.shield.test:$uport" "https://other.shield.test:$uport/"
expect "plaintext inside tunnel refused (TLS required)" FAIL via "$bport" "$cred" --proxytunnel \
    "http://upstream.shield.test:$uport/"
expect "direct dial to upstream (no broker) blocked by sandbox" FAIL confined_curl "https://127.0.0.1:$uport/"
expect "direct dial to public IPv4 blocked by sandbox" FAIL confined_curl "https://1.1.1.1/"
expect "DNS resolution blocked by sandbox" FAIL confined_curl "https://example.com/"
expect "real YouTube CONNECT refused: no approved resolver (502)" FAIL \
    via "$nport" "$cred" "https://www.youtube.com/"
sleep 3
expect "expired broker refuses new tunnels" FAIL via "$eport" "$cred" "https://upstream.shield.test:$uport/"

grep -q '"reason":"serverNameMismatch"' "$run/broker.log" && echo "PASS  broker logged serverNameMismatch" | tee -a "$results" ||
    { echo "FAIL  broker did not log serverNameMismatch" | tee -a "$results"; failures=$((failures + 1)); }
grep -q '"reason":"notTLS"' "$run/broker.log" && echo "PASS  broker logged notTLS" | tee -a "$results" ||
    { echo "FAIL  broker did not log notTLS" | tee -a "$results"; failures=$((failures + 1)); }
grep -q '"reason":"resolverNotApproved"' "$run/broker-noresolver.log" &&
    echo "PASS  broker logged resolverNotApproved for www.youtube.com" | tee -a "$results" ||
    { echo "FAIL  no resolverNotApproved log" | tee -a "$results"; failures=$((failures + 1)); }
hosts=$(python3 -I -c 'import socket; print(sorted({a[4][0] for a in socket.getaddrinfo("www.youtube.com", 443)}))')
echo "INFO  system resolver www.youtube.com -> $hosts (Shield hosts block unchanged)" | tee -a "$results"
echo "Evidence: $run"
if [ "$failures" != 0 ]; then echo "FAILED: $failures case(s)"; exit 1; fi
echo "PASS: all adversarial broker cases"

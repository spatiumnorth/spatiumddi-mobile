#!/usr/bin/env bash
#
# Stub SpatiumDDI control plane for local development.
#
# Serves /health/platform over TLS with a self-signed certificate, which is the
# situation every real self-hosted install puts the app in. Two instances: one
# healthy, one permanently in a change window.
#
#   ./scripts/dev-control-plane.sh start   # bring both up
#   ./scripts/dev-control-plane.sh stop
#   ./scripts/dev-control-plane.sh test    # start, run the test suite, stop
#
# There is also a proxy mode, for driving the app against a real control plane
# that only speaks HTTP. The app is HTTPS-only by design, so this terminates TLS
# locally with the same dev certificate and forwards everything through:
#
#   ./scripts/dev-control-plane.sh proxy http://ddi.lab.internal:8077
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/.dev-control-plane"
HEALTHY_PORT=8443
MAINTENANCE_PORT=8444

ensure_certificate() {
  mkdir -p "$WORK"
  if [[ -f "$WORK/cert.pem" && -f "$WORK/key.pem" ]]; then return; fi
  echo "Generating a self-signed certificate for the stub..."
  openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 30 -nodes -subj "/CN=ddi.lab.test" \
    -addext "subjectAltName=DNS:ddi.lab.test,DNS:localhost,IP:127.0.0.1" 2>/dev/null
}

fingerprint() {
  openssl x509 -in "$WORK/cert.pem" -noout -fingerprint -sha256 | sed 's/.*=//'
}

write_server() {
  cat > "$WORK/server.py" <<'PY'
import http.server, json, socket, ssl, sys

PORT = int(sys.argv[1])
MODE = sys.argv[2] if len(sys.argv) > 2 else "healthy"

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_GET(self):
        if self.path.startswith("/redirect/"):
            # An off-origin redirect — the next port up — for the test proving
            # the app never follows one with a bearer token attached.
            self.send_response(307)
            self.send_header("Location", "https://localhost:%d%s" % (PORT + 1, self.path[len("/redirect"):]))
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path != "/health/platform":
            self.send_error(404); return
        if MODE == "maintenance":
            # The platform's own change-window refusal, marker and all. An
            # unmarked 503 is a different thing — see ControlPlaneProbe.
            body = json.dumps({
                "detail": "Core switch upgrade until 02:00.",
                "maintenance": True,
                "message": "Core switch upgrade until 02:00.",
            }).encode()
            self.send_response(503)
            self.send_header("Retry-After", "1800")
        else:
            body = json.dumps({"demo_mode": False, "maintenance_mode": False}).encode()
            self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, fmt, *args):
        sys.stderr.write("REQ %s\n" % (fmt % args)); sys.stderr.flush()


class DualStackServer(http.server.ThreadingHTTPServer):
    """Accept both 127.0.0.1 and ::1.

    `localhost` resolves to ::1 first on macOS. An IPv4-only listener therefore
    depends on the client falling back, which a Mac does quickly and a CI
    runner's simulator does not — there the connection simply hangs until the
    request times out.
    """

    address_family = socket.AF_INET6

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain("cert.pem", "key.pem")
srv = DualStackServer(("::", PORT), Handler)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
sys.stderr.write("listening on %d mode=%s\n" % (PORT, MODE)); sys.stderr.flush()
srv.serve_forever()
PY
}

proxy() {
  local upstream="${1:-}"
  if [[ -z "$upstream" ]]; then
    echo "usage: $0 proxy <upstream-url>" >&2
    exit 2
  fi
  ensure_certificate
  stop >/dev/null 2>&1 || true
  ( cd "$WORK" && { nohup "$ROOT/scripts/dev-tls-proxy.py" "$HEALTHY_PORT" cert.pem key.pem "$upstream" \
      > proxy.log 2>&1 & echo $! > healthy.pid; } )
  wait_for_stub "$HEALTHY_PORT" proxy
  echo "proxy       https://localhost:$HEALTHY_PORT -> $upstream"
  echo "fingerprint $(fingerprint)"
}

# Block until the stub actually answers, or say so and stop.
#
# A fixed `sleep` was what this used to do, and it is the reason six trust
# tests failed twice on `main` against a tree whose own pull request was green:
# a cold runner can take longer than the sleep to get Python listening, every
# test then times out at the client's 20-second limit, and the start-up banner
# has already printed as though all were well. The banner is not evidence — it
# prints whether or not anything bound the port.
#
# Polls over `localhost` deliberately, which is what the app connects to, so a
# dual-stack bind that silently came up IPv4-only fails here rather than 20
# minutes later inside the suite.
wait_for_stub() {
  local port="$1" name="$2" attempt=0
  while (( attempt < 60 )); do
    # No `-f`: the maintenance stub answers 503 by design, and that is a
    # perfectly good sign of life.
    if curl -sk --max-time 2 "https://localhost:$port/health/platform" >/dev/null 2>&1; then
      return 0
    fi
    attempt=$(( attempt + 1 ))
    sleep 0.5
  done
  echo "stub '$name' never answered on port $port after 30s" >&2
  echo "--- $name.log ---" >&2
  tail -20 "$WORK/$name.log" >&2 2>/dev/null || true
  return 1
}

start() {
  ensure_certificate
  write_server
  stop >/dev/null 2>&1 || true
  # The braces matter: without them the `cd` applies only to the backgrounded
  # job and the pid file lands in the repo root instead of the work directory.
  ( cd "$WORK" && { nohup python3 server.py "$HEALTHY_PORT" healthy > healthy.log 2>&1 & echo $! > healthy.pid; } )
  ( cd "$WORK" && { nohup python3 server.py "$MAINTENANCE_PORT" maintenance > maintenance.log 2>&1 & echo $! > maintenance.pid; } )
  wait_for_stub "$HEALTHY_PORT" healthy
  wait_for_stub "$MAINTENANCE_PORT" maintenance
  echo "healthy      https://localhost:$HEALTHY_PORT/health/platform"
  echo "maintenance  https://localhost:$MAINTENANCE_PORT/health/platform"
  echo "fingerprint  $(fingerprint)"
}

stop() {
  for name in healthy maintenance; do
    if [[ -f "$WORK/$name.pid" ]]; then
      kill "$(cat "$WORK/$name.pid")" 2>/dev/null || true
      rm -f "$WORK/$name.pid"
    fi
  done
  # A pid file only tracks what this script started. An earlier run that was
  # interrupted leaves the port held, and the next start fails to bind while
  # still looking like it worked.
  # Matched against the command line as launched — `cd "$WORK" && python3
  # server.py <port> <mode>` — not against an absolute path that never appears
  # in it. The port keeps this from reaching an unrelated server.py.
  pkill -f "python3 server.py $HEALTHY_PORT" 2>/dev/null || true
  pkill -f "python3 server.py $MAINTENANCE_PORT" 2>/dev/null || true
  pkill -f "dev-tls-proxy.py" 2>/dev/null || true
  sleep 1
  echo "stub stopped"
}

run_tests() {
  start
  local status=0
  # CI picks a destination that exists on the runner; locally this default is fine.
  local destination="${SPATIUM_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}"
  TEST_RUNNER_SPATIUM_STUB_RUNNING=1 \
  TEST_RUNNER_SPATIUM_EXPECTED_FINGERPRINT="$(fingerprint)" \
  xcodebuild -project "$ROOT/SpatiumDDI/SpatiumDDI.xcodeproj" -scheme SpatiumDDI \
    -destination "$destination" \
    -skipPackagePluginValidation \
    ${SPATIUM_TEST_EXTRA_ARGS:-} test || status=$?
  stop
  return $status
}

case "${1:-start}" in
  start) start ;;
  stop)  stop ;;
  test)  run_tests ;;
  proxy) shift; proxy "$@" ;;
  *) echo "usage: $0 {start|stop|test|proxy <upstream-url>}" >&2; exit 2 ;;
esac

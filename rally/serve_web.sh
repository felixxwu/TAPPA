#!/usr/bin/env bash
# Serve the web build over the local network so other devices (e.g. your phone)
# can play it. The Web export is single-threaded (thread_support=false), so it
# needs no SharedArrayBuffer — which means a plain static HTTP server is enough:
# no cross-origin-isolation headers, no HTTPS / secure context, no self-signed
# cert warning on your phone.
#
#   ./serve_web.sh            # build if needed, then serve on http://0.0.0.0:8080
#   ./serve_web.sh 9000       # use a custom port
#   ./serve_web.sh --no-build # skip the export, serve existing build/web
#
# Plain http://<LAN-IP>:<port> works directly on a phone on the same Wi-Fi.
# (If a future change re-enables thread_support, SharedArrayBuffer comes back and
# this server must again send COOP/COEP over HTTPS — see git history for that
# variant.)
set -euo pipefail

cd "$(dirname "$0")"

PORT=8080
BUILD=1
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    [0-9]*) PORT="$arg" ;;
    *) echo "error: unknown arg $arg (known: <port>, --no-build)" >&2; exit 2 ;;
  esac
done

OUT_DIR="build/web"

if [[ $BUILD -eq 1 ]]; then
  ./build_web.sh >/dev/null
fi
if [[ ! -f "$OUT_DIR/index.html" ]]; then
  echo "error: $OUT_DIR/index.html not found — run ./build_web.sh first" >&2
  exit 1
fi

# Best-effort LAN IP (macOS): try common interfaces.
LAN_IP=""
for iface in en0 en1 en2; do
  LAN_IP="$(ipconfig getifaddr "$iface" 2>/dev/null || true)"
  [[ -n "$LAN_IP" ]] && break
done
[[ -z "$LAN_IP" ]] && LAN_IP="<your-LAN-IP>"

echo "Serving $OUT_DIR over plain HTTP (single-threaded build, no SAB needed)."
echo "  This machine : http://localhost:$PORT"
echo "  On your phone: http://$LAN_IP:$PORT   (same Wi-Fi network)"
echo "Press Ctrl+C to stop."

exec python3 - "$OUT_DIR" "$PORT" <<'PY'
import http.server, sys, socketserver

directory, port = sys.argv[1], int(sys.argv[2])

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=directory, **kw)

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

with Server(("0.0.0.0", port), Handler) as httpd:
    httpd.serve_forever()
PY

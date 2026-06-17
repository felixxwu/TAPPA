#!/usr/bin/env bash
# Serve the web build over the local network so other devices (e.g. your phone)
# can play it. Sends the COOP/COEP cross-origin-isolation headers that the
# threaded Web export requires for SharedArrayBuffer — a plain static server
# (python -m http.server) will NOT work because the game won't start.
#
#   ./serve_web.sh            # build if needed, then serve on https://0.0.0.0:8080
#   ./serve_web.sh 9000       # use a custom port
#   ./serve_web.sh --no-build # skip the export, serve existing build/web
#
# Serves over HTTPS using a self-signed cert in build/certs/ (auto-generated on
# first run). HTTPS is required because the threaded export needs a "secure
# context" for SharedArrayBuffer, which browsers only grant on localhost or
# HTTPS — plain http://<LAN-IP> does NOT qualify. Your phone will show a
# "not private / not trusted" warning the first time; accept it to proceed.
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

# Self-signed cert for HTTPS (secure context required by SharedArrayBuffer).
# Regenerate when missing OR when the current LAN IP isn't in the cert — so it
# stays valid after switching networks (e.g. onto a phone hotspot).
CERT="build/certs/cert.pem"
KEY="build/certs/key.pem"
need_cert=0
if [[ ! -f "$CERT" || ! -f "$KEY" ]]; then
  need_cert=1
elif ! openssl x509 -in "$CERT" -noout -text 2>/dev/null | grep -q "IP Address:$LAN_IP"; then
  need_cert=1
fi
if [[ $need_cert -eq 1 ]]; then
  echo "=== generating self-signed cert for $LAN_IP (build/certs/) ==="
  mkdir -p build/certs
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$KEY" -out "$CERT" -days 365 -subj "/CN=$LAN_IP" \
    -addext "subjectAltName=IP:$LAN_IP,DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1
fi

echo "Serving $OUT_DIR over HTTPS with cross-origin isolation headers."
echo "  This machine : https://localhost:$PORT"
echo "  On your phone: https://$LAN_IP:$PORT   (same Wi-Fi network)"
echo "  (accept the self-signed cert warning on first visit)"
echo "Press Ctrl+C to stop."

exec python3 - "$OUT_DIR" "$PORT" "$CERT" "$KEY" <<'PY'
import http.server, ssl, sys, socketserver

directory, port, cert, key = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=directory, **kw)

    def end_headers(self):
        # Required for SharedArrayBuffer (threaded Godot web export).
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "cross-origin")
        super().end_headers()

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(certfile=cert, keyfile=key)

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    # Wrap each accepted connection (NOT the listening socket — doing the
    # latter breaks the TLS handshake and every request hangs).
    def get_request(self):
        sock, addr = super().get_request()
        return ctx.wrap_socket(sock, server_side=True), addr

with Server(("0.0.0.0", port), Handler) as httpd:
    httpd.serve_forever()
PY

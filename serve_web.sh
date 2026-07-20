#!/usr/bin/env bash
# Serve the web build over the local network so other devices (e.g. your phone)
# can play it. The Web export is single-threaded (thread_support=false), so it
# needs no SharedArrayBuffer and no cross-origin-isolation (COOP/COEP) headers.
#
# BUT: Godot 4.6 web exports refuse to boot outside a "secure context". Plain
# http:// is a secure context only for localhost / 127.0.0.1 — NOT for a LAN IP,
# which is what the phone sees. So to reach a phone we serve over HTTPS with a
# self-signed cert (auto-generated into build/dev-cert.pem); accept the one-time
# "not private" warning on the phone. This is separate from the SharedArrayBuffer
# question — single-threaded removed COOP/COEP, but secure context is still
# required. (No openssl? falls back to plain HTTP, which then only boots via
# localhost or `adb reverse tcp:8080 tcp:8080` + http://localhost:8080.)
#
#   ./serve_web.sh            # build if needed, then serve on https://0.0.0.0:8080
#   ./serve_web.sh 9000       # use a custom port
#   ./serve_web.sh --no-build # skip the export, serve existing build/web
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

RESULTS_DIR="build/bench-results"

# Godot 4.6 web exports refuse to boot outside a "secure context". `localhost` /
# `127.0.0.1` count as secure over plain HTTP, but a LAN IP (the phone's view)
# does NOT — so serving to a phone needs HTTPS. (This is separate from the
# SharedArrayBuffer requirement, which the single-threaded build already avoids.)
# We generate a long-lived self-signed cert once; the phone shows a one-time
# "not private" warning you accept ("Advanced -> proceed"), then the build boots.
CERT="build/dev-cert.pem"
SCHEME="https"
if command -v openssl >/dev/null 2>&1; then
  if [[ ! -f "$CERT" ]]; then
    echo "Generating self-signed dev cert ($CERT) ..."
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -keyout build/dev-key.pem -out build/dev-crt.pem \
      -subj "/CN=rally-dev" \
      -addext "subjectAltName=IP:$LAN_IP,DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1
    cat build/dev-crt.pem build/dev-key.pem > "$CERT"
    rm -f build/dev-crt.pem build/dev-key.pem
  fi
else
  echo "warning: openssl not found — serving plain HTTP. Only localhost / adb-reverse"
  echo "         will boot on Godot 4.6 (a LAN IP over http:// is not a secure context)."
  CERT=""
  SCHEME="http"
fi

echo "Serving $OUT_DIR over $(echo "$SCHEME" | tr '[:lower:]' '[:upper:]') (single-threaded build, no SAB needed)."
echo "  This machine : $SCHEME://localhost:$PORT"
echo "  On your phone: $SCHEME://$LAN_IP:$PORT   (same Wi-Fi; accept the cert warning once)"
echo "Benchmark reports (Settings -> Benchmark on the phone) POST to /bench and"
echo "land in $RESULTS_DIR/ for analysis (features/benchmark.md -> feedback loop)."
echo "Press Ctrl+C to stop."

# The collector serves the build AND accepts POST /bench (the profiling feedback
# loop). Same origin as the page, so the web build's report POST is zero-config.
exec python3 "$(dirname "$0")/tools/bench_collector.py" "$OUT_DIR" "$PORT" "$RESULTS_DIR" "$CERT"

#!/usr/bin/env bash
# Serve the web build over the local network so other devices (e.g. your phone)
# can play it. The Web export is threaded (thread_support=true), so the server
# (tools/bench_collector.py) sends the cross-origin-isolation (COOP/COEP) headers.
#
# BUT: Godot 4.6 web exports refuse to boot outside a "secure context". Plain
# http:// is a secure context only for localhost / 127.0.0.1 — NOT for a LAN IP,
# which is what the phone sees. So to reach a phone we serve over HTTPS with a
# self-signed cert (auto-generated into build/dev-cert.pem); accept the one-time
# "not private" warning on the phone. This is separate from the SharedArrayBuffer
# question: threads need COOP/COEP and a secure context. (No openssl? falls back to plain HTTP, which then only boots via
# localhost or `adb reverse tcp:8080 tcp:8080` + http://localhost:8080.)
#
#   ./start_web.sh            # build if needed, then serve on https://0.0.0.0:8080
#   ./start_web.sh 9000       # use a custom port
#   ./start_web.sh --no-build # skip the export, serve existing build/web
#   ./start_web.sh --no-watch # don't rebuild when source files change
#
# While serving, a change to the game's source (scripts, shaders, scenes, models, levels, project settings) rebuilds
# build/web in the background. The open page is NOT reloaded: the reload token only changes when the server restarts
# (or on POST /reload), so refresh it yourself to load the new build.
#
# WARNING: LOAD-TIME MEASUREMENTS TAKEN THROUGH THIS SCRIPT ARE NOT REPRESENTATIVE.
# tools/bench_collector.py serves everything UNCOMPRESSED (no Content-Encoding,
# no pre-compressed .gz), so index.wasm goes over the wire at its full ~37.7 MB
# and index.pck at its full ~17.3 MB. Production (itch.io, behind Cloudflare)
# gzips both — verified 2026-07-28: index.wasm 9.93 MB and index.pck 9.28 MB
# on the wire with `Content-Encoding: gzip`. So a download/boot timing measured
# here OVERSTATES the real transfer cost by roughly 3-4x. Compare frame times
# and CPU-side work here; do NOT quote local download timings as real-world
# numbers — re-measure against the deployed itch build for those.
set -euo pipefail

cd "$(dirname "$0")"

PORT=8080
BUILD=1
WATCH=1
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    --no-watch) WATCH=0 ;;
    [0-9]*) PORT="$arg" ;;
    *) echo "error: unknown arg $arg (known: <port>, --no-build, --no-watch)" >&2; exit 2 ;;
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

# --- dev-only live reload ---------------------------------------------------
# The collector serves /reload-token (a token that changes when the build does).
# This poller USED TO live in the Web export preset's html/head_include, which
# meant it shipped to itch.io and to every player's phone: one fetch per second
# for the whole session (battery + radio wake on mobile), a 404/second against
# the host, and a real reload hazard if a host ever returns a varying body for
# an unknown path (CDN error pages, ad interstitials, SPA catch-alls). It is now
# injected HERE instead — into the local build output only, never into the
# preset — so production ships no background timer. (The landscape-lock script
# stays in the preset; that one is legitimate.) See
# todo/mobile-web-performance.md 1.4.
#
# Injection is idempotent: guarded by a marker so re-running (or --no-build over
# an already-patched index.html) does not stack multiple pollers.
RELOAD_MARKER="__rally_dev_reload"
inject_poller() {
if ! grep -q "$RELOAD_MARKER" "$OUT_DIR/index.html"; then
  python3 - "$OUT_DIR/index.html" "$RELOAD_MARKER" <<'PY'
import sys
path, marker = sys.argv[1], sys.argv[2]
script = (
    "<script>/*" + marker + " — local dev only, injected by start_web.sh*/"
    "(function(){var cur=null,build=null,NEW='\\u27f3 New build, refresh | ';function p(){"
    "fetch('/reload-token',{cache:'no-store'})"
    ".then(function(r){return r.ok?r.text():null;})"
    ".then(function(t){if(t===null){return;}"
    "if(cur===null){cur=t;}else if(t!==cur){location.reload();}})"
    ".catch(function(){});"
    "fetch('/build-id',{cache:'no-store'})"
    ".then(function(r){return r.ok?r.text():null;})"
    ".then(function(b){if(b===null){return;}"
    "if(build===null){build=b;}else if(b!==build&&document.title.indexOf(NEW)!==0){document.title=NEW+document.title;}})"
    ".catch(function(){});}setInterval(p,1000);})();</script>"
)
html = open(path, encoding="utf-8").read()
if "</head>" in html:
    html = html.replace("</head>", script + "</head>", 1)
else:
    html += script
open(path, "w", encoding="utf-8").write(html)
PY
  echo "Injected dev live-reload poller into $OUT_DIR/index.html (local dev only)."
fi
}
inject_poller

# Best-effort LAN IP (macOS): try common interfaces.
LAN_IP=""
for iface in en0 en1 en2; do
  LAN_IP="$(ipconfig getifaddr "$iface" 2>/dev/null || true)"
  [[ -n "$LAN_IP" ]] && break
done
# No LAN address: the placeholder can't go in the certificate, or openssl refuses it.
SAN_LAN="IP:$LAN_IP,"
if [[ -z "$LAN_IP" ]]; then
  LAN_IP="<your-LAN-IP>"
  SAN_LAN=""
fi

RESULTS_DIR="build/bench-results"

# Godot 4.6 web exports refuse to boot outside a "secure context". `localhost` /
# `127.0.0.1` count as secure over plain HTTP, but a LAN IP (the phone's view)
# does NOT — so serving to a phone needs HTTPS. (This is separate from the
# COOP/COEP headers threads need, which the collector always sends.)
# We generate a long-lived self-signed cert once; the phone shows a one-time
# "not private" warning you accept ("Advanced -> proceed"), then the build boots.
CERT="build/dev-cert.pem"
SCHEME="https"
if command -v openssl >/dev/null 2>&1; then
  # Remade when this Mac's LAN address changes: the phone refuses a cert issued for another IP.
  if [[ ! -f "$CERT" ]] || ! openssl x509 -in "$CERT" -noout -text | grep -qF "IP Address:$LAN_IP,"; then
    echo "Generating self-signed dev cert ($CERT) ..."
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -keyout build/dev-key.pem -out build/dev-crt.pem \
      -subj "/CN=rally-dev" \
      -addext "subjectAltName=${SAN_LAN}DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1
    cat build/dev-crt.pem build/dev-key.pem > "$CERT"
    rm -f build/dev-crt.pem build/dev-key.pem
  fi
else
  echo "warning: openssl not found — serving plain HTTP. Only localhost / adb-reverse"
  echo "         will boot on Godot 4.6 (a LAN IP over http:// is not a secure context)."
  CERT=""
  SCHEME="http"
fi

echo "Serving $OUT_DIR over $(echo "$SCHEME" | tr '[:lower:]' '[:upper:]') (threaded build, cross-origin isolated)."
echo "  This machine : $SCHEME://localhost:$PORT"
echo "  On your phone: $SCHEME://$LAN_IP:$PORT   (same Wi-Fi; accept the cert warning once)"
echo "Benchmark reports (Settings -> Benchmark on the phone) POST to /bench and"
echo "land in $RESULTS_DIR/ for analysis (features/benchmark.md -> feedback loop)."
echo "Press Ctrl+C to stop."

# The collector serves the build AND accepts POST /bench (the profiling feedback
# loop). Same origin as the page, so the web build's report POST is zero-config.
# A fingerprint of every source file's modification time; a different one means something changed.
source_stamp() {
  find scripts shaders benchmark models icons fonts tools/levels addons *.tscn project.godot export_presets.cfg \
    -type f -not -name '*.uid' -not -path '*/node_modules/*' -exec stat -f '%m %N' {} + 2>/dev/null | md5
}

watch_and_rebuild() {
  local last
  last="$(source_stamp)"
  while true; do
    sleep 2
    [[ "$(source_stamp)" == "$last" ]] && continue
    sleep 1  # let a burst of saves finish
    echo "[watch] source changed, rebuilding build/web…"
    if ./build_web.sh >/dev/null 2>&1; then
      inject_poller >/dev/null
      echo "[watch] rebuilt — refresh the page to load it."
    else
      echo "[watch] rebuild FAILED (run ./build_web.sh to see why)."
    fi
    last="$(source_stamp)"  # the build itself touches project.godot
  done
}

WATCH_PID=""
if [[ $WATCH -eq 1 ]]; then
  watch_and_rebuild &
  WATCH_PID=$!
  trap '[[ -n "$WATCH_PID" ]] && kill "$WATCH_PID" 2>/dev/null' EXIT
  echo "Watching source files: a change rebuilds build/web (refresh the page yourself)."
fi

python3 "$(dirname "$0")/tools/bench_collector.py" "$OUT_DIR" "$PORT" "$RESULTS_DIR" "$CERT"

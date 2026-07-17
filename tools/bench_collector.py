#!/usr/bin/env python3
"""Static file server for the web build + a POST sink for benchmark reports.

Used by serve_web.sh so the LAN profiling loop is zero-config: the game is served
from here, and a benchmark run POSTs its results JSON back to the SAME origin at
`/bench` (features/benchmark.md -> "Feedback loop"). Each report is written to
the results directory as `<utc-timestamp>-<label>.json` and its headline printed
to the terminal, so Claude can read build/bench-results/*.json and iterate.

    python3 tools/bench_collector.py <web_dir> <port> <results_dir> [cert.pem]

If a cert file (containing both the certificate and its private key) is given,
the server runs over HTTPS. Godot 4.6 web exports refuse to boot outside a
"secure context", which a plain-HTTP LAN IP is not — so serving the build to a
phone over the LAN requires HTTPS (see serve_web.sh).
"""
import http.server
import json
import socketserver
import ssl
import sys
from datetime import datetime, timezone
from pathlib import Path

WEB_DIR, PORT, RESULTS_DIR = sys.argv[1], int(sys.argv[2]), Path(sys.argv[3])
CERT = sys.argv[4] if len(sys.argv) > 4 else ""


def _safe(name: str) -> str:
    return "".join(c if (c.isalnum() or c in "-_.") else "-" for c in name)[:120]


def _headline(report: dict) -> str:
    stats = report.get("stats", {}) or {}
    scripts = report.get("scripts", {}) or {}
    top = ""
    if scripts:
        k = max(scripts, key=lambda x: scripts[x])
        top = f"  top-script {k}={scripts[k]:.2f}ms"
    dev = report.get("device", {}) or {}
    return (
        f"[bench] {report.get('label', '?')}  "
        f"fps {stats.get('fps_avg', 0):.0f} (1% low {stats.get('fps_1pct_low', 0):.0f})  "
        f"frame p99 {stats.get('frame_p99_ms', 0):.1f}ms  "
        f"render cpu {stats.get('render_cpu_ms_avg', 0):.1f} gpu {stats.get('render_gpu_ms_avg', 0):.1f}  "
        f"phys {stats.get('physics_ms_avg', 0):.1f}ms  "
        f"[{dev.get('os', '?')}/{dev.get('model', '?')}]" + top
    )


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=WEB_DIR, **kw)

    def do_POST(self):
        if self.path.rstrip("/") != "/bench":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            report = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as e:
            self.send_error(400, f"bad JSON: {e}")
            return
        RESULTS_DIR.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        label = _safe(str(report.get("label", "run")))
        path = RESULTS_DIR / f"{stamp}-{label}.json"
        path.write_text(json.dumps(report, indent=2))
        print(_headline(report), flush=True)
        print(f"        -> {path}", flush=True)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true}')

    def end_headers(self):
        # Discourage the browser from caching a stale build during rapid iteration.
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


with Server(("0.0.0.0", PORT), Handler) as httpd:
    if CERT:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(CERT)
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    httpd.serve_forever()

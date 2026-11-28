#!/usr/bin/env python3
"""Prints the Hafren replay's per-device-class numbers as the markdown "Device targets" table.

Reads the reports the web collector stores (build/bench-results/*.json) and the native replay's
report (LevelReplay.REPORT_PATH), keeps the newest report per device class and `-off-<nodes>` variant,
and prints busy_ms p95/p99 and draw_phase_ms for each (features/benchmark.md -> "Device targets").

    python3 tools/device_targets.py [report.json | dir ...]
    python3 tools/device_targets.py --self-test
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NATIVE_REPORT = Path.home() / "Library/Application Support/Godot/app_userdata/TAPPA/level_replay_report.json"
if sys.platform.startswith("linux"):
    NATIVE_REPORT = Path.home() / ".local/share/godot/app_userdata/TAPPA/level_replay_report.json"
DEFAULT_SOURCES = [ROOT / "build/bench-results", NATIVE_REPORT]


def device_class(report: dict) -> str:
    dev = report.get("device", {}) or {}
    name = f"{dev.get('os', '?')}/{dev.get('model', '?')}"
    return name + " (web)" if dev.get("web") else name


def variant(report: dict) -> str:
    label = str(report.get("label", ""))
    return label[label.index("-off-") + 1:] if "-off-" in label else "full"


def ms(stats: dict, key: str) -> str:
    return f"{stats[key]:.1f}" if isinstance(stats.get(key), (int, float)) else "-"


def table(reports: list) -> str:
    newest = {}
    for r in sorted(reports, key=lambda r: str(r.get("timestamp", ""))):
        newest[(device_class(r), variant(r))] = r
    lines = [
        "| Device class | Variant | busy p95 ms | busy p99 ms | draw_phase p95 ms | draw_phase p99 ms | Report |",
        "|---|---|---|---|---|---|---|",
    ]
    for (cls, var), r in sorted(newest.items()):
        s = r.get("stats", {}) or {}
        lines.append(f"| {cls} | {var} | {ms(s, 'busy_p95_ms')} | {ms(s, 'busy_p99_ms')} | "
                     f"{ms(s, 'draw_phase_p95_ms')} | {ms(s, 'draw_phase_p99_ms')} | {r.get('timestamp', '?')} |")
    return "\n".join(lines)


def load(sources: list) -> list:
    files = []
    for src in map(Path, sources):
        files += sorted(src.glob("*.json")) if src.is_dir() else [src] if src.is_file() else []
    reports = []
    for f in files:
        try:
            r = json.loads(f.read_text())
        except (ValueError, OSError) as e:
            print(f"skipping {f}: {e}", file=sys.stderr)
            continue
        if isinstance(r, dict) and str(r.get("schema", "")).startswith("rally-bench/"):
            reports.append(r)
    return reports


def self_test() -> None:
    def rep(ts, label, web, busy99):
        return {"schema": "rally-bench/1", "timestamp": ts, "label": label,
                "device": {"os": "iOS" if web else "macOS", "model": "X", "web": web},
                "stats": {"busy_p95_ms": 10.0, "busy_p99_ms": busy99, "draw_phase_p95_ms": 4.0}}
    out = table([
        rep("2026-01-01", "level-replay-hafren", True, 20.0),
        rep("2026-01-02", "level-replay-hafren", True, 30.0),
        rep("2026-01-01", "level-replay-hafren-off-GroundCover", True, 15.0),
        rep("2026-01-01", "level-replay-hafren", False, 9.0),
    ]).splitlines()
    assert len(out) == 5, out
    assert "| iOS/X (web) | full | 10.0 | 30.0 | 4.0 | - |" in out[2], out
    assert "| iOS/X (web) | off-GroundCover |" in out[3], out
    assert out[4].startswith("| macOS/X | full |"), out
    print("self-test ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    else:
        reports = load(sys.argv[1:] or DEFAULT_SOURCES)
        if not reports:
            sys.exit("no benchmark reports found")
        print(table(reports))

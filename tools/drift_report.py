#!/usr/bin/env python3
"""Car drift report (migration spec 1.3): compares a candidate car trace against the golden one.

Both inputs are the per-tick car traces the free-running level replay writes (`--car-trace`, WP9):
JSON lines, optionally gzipped, a header line then one `{tick, input, snap, world}` row per tick, where
`snap` is `Car.snapshot()`. The runs are matched by tick and cut into SEGMENT_S-second segments. Per
segment it prints how far the candidate's path strays from the golden's against a tolerance that widens
with time, the time each run takes to cover the golden's segment distance, top speeds and end positions,
and it writes an SVG with the two paths overlaid and the deviation curve. A report, not a gate: it exits 0
whatever the drift, and only fails on unreadable input.

    python3 tools/drift_report.py goldens/car_step.jsonl.gz candidate.jsonl.gz [--svg out.svg]
    python3 tools/drift_report.py --self-test
"""
import argparse
import gzip
import json
import math
import os
import sys
import tempfile

TICK_HZ = 60
SEGMENT_S = 10.0
TOL_BASE_M = 0.01
TOL_GROWTH_M_PER_S = 0.25


def load(path):
    """Returns [(tick, (x, y, z), speed)] from a car trace, skipping the header and any row without a snap."""
    with open(path, "rb") as f:
        gz = f.read(2) == b"\x1f\x8b"
    opener = gzip.open if gz else open
    rows = []
    with opener(path, "rt", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            snap = row.get("snap")
            if not isinstance(snap, dict):
                continue
            pos = tuple(float(v) for v in snap["origin"])
            speed = math.sqrt(sum(float(v) ** 2 for v in snap["linear_velocity"]))
            rows.append((int(row["tick"]), pos, speed))
    rows.sort(key=lambda r: r[0])
    return rows


def tolerance(t):
    return TOL_BASE_M + TOL_GROWTH_M_PER_S * t


def _cumulative(points):
    out = [0.0]
    for a, b in zip(points, points[1:]):
        out.append(out[-1] + math.dist(a, b))
    return out


def _time_to_reach(cum, start_i, distance, hz):
    """Seconds from index start_i until the run's travelled distance reaches `distance`; None if it never does."""
    for i in range(start_i, len(cum)):
        if cum[i] >= distance:
            if i == start_i:
                return 0.0
            prev = cum[i - 1]
            frac = (distance - prev) / (cum[i] - prev) if cum[i] > prev else 0.0
            return (i - 1 - start_i + frac) / hz
    return None


def compare(golden, candidate, hz=TICK_HZ, segment_s=SEGMENT_S):
    """Matches the two runs on their shared ticks and returns one dict of figures per segment."""
    cand = {t: (p, s) for t, p, s in candidate}
    pairs = [(t, p, s, cand[t][0], cand[t][1]) for t, p, s in golden if t in cand]
    if not pairs:
        raise ValueError("the two traces share no ticks")
    g_cum = _cumulative([p[1] for p in pairs])
    c_cum = _cumulative([p[3] for p in pairs])
    seg_ticks = max(1, round(segment_s * hz))
    segments = []
    for start in range(0, len(pairs), seg_ticks):
        end = min(start + seg_ticks, len(pairs))
        curve = []
        worst_ratio, first_over = 0.0, None
        for i in range(start, end):
            t = (i - start) / hz
            dev = math.dist(pairs[i][1], pairs[i][3])
            tol = tolerance(t)
            curve.append((t, dev, tol))
            worst_ratio = max(worst_ratio, dev / tol)
            if first_over is None and dev > tol:
                first_over = pairs[i][0]
        g_dist = g_cum[end - 1] - g_cum[start]
        segments.append({
            "first_tick": pairs[start][0], "last_tick": pairs[end - 1][0],
            "curve": curve, "max_dev": max(c[1] for c in curve), "end_dev": curve[-1][1],
            "worst_ratio": worst_ratio, "first_over_tick": first_over,
            "golden_time": _time_to_reach(g_cum, start, g_cum[start] + g_dist, hz),
            "cand_time": _time_to_reach(c_cum, start, c_cum[start] + g_dist, hz),
            "golden_top": max(p[2] for p in pairs[start:end]),
            "cand_top": max(p[4] for p in pairs[start:end]),
            "golden_end": pairs[end - 1][1], "cand_end": pairs[end - 1][3],
        })
    return pairs, segments


def _fmt_time(t):
    return "  never" if t is None else f"{t:7.3f}"


def print_report(segments, out=sys.stdout):
    print(f"tolerance: {TOL_BASE_M} m + {TOL_GROWTH_M_PER_S} m/s since segment start", file=out)
    print(f"{'ticks':>13} {'max dev m':>10} {'end dev m':>10} {'dev/tol':>8} {'over@':>7} "
          f"{'time g':>7} {'time c':>7} {'top g':>7} {'top c':>7}  end golden -> candidate", file=out)
    for s in segments:
        over = "-" if s["first_over_tick"] is None else str(s["first_over_tick"])
        ge = ", ".join(f"{v:.2f}" for v in s["golden_end"])
        ce = ", ".join(f"{v:.2f}" for v in s["cand_end"])
        print(f"{s['first_tick']:>6}-{s['last_tick']:<6} {s['max_dev']:10.4f} {s['end_dev']:10.4f} "
              f"{s['worst_ratio']:8.2f} {over:>7} {_fmt_time(s['golden_time'])} {_fmt_time(s['cand_time'])} "
              f"{s['golden_top']:7.2f} {s['cand_top']:7.2f}  ({ge}) -> ({ce})", file=out)


def write_svg(pairs, segments, path, hz=TICK_HZ):
    """Two panels: the paths seen from above (x, z), and deviation over each segment with its tolerance."""
    w, h, pad = 900, 420, 30
    pts_g = [(p[1][0], p[1][2]) for p in pairs]
    pts_c = [(p[3][0], p[3][2]) for p in pairs]
    xs = [p[0] for p in pts_g + pts_c]
    zs = [p[1] for p in pts_g + pts_c]
    span = max(max(xs) - min(xs), max(zs) - min(zs), 1e-6)
    box = h - 2 * pad
    scale = box / span

    def to_map(p):
        return pad + (p[0] - min(xs)) * scale, pad + (p[1] - min(zs)) * scale

    def poly(points, colour, width):
        d = " ".join(f"{x:.2f},{y:.2f}" for x, y in points)
        return f'<polyline points="{d}" fill="none" stroke="{colour}" stroke-width="{width}"/>'

    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" font-family="sans-serif" '
             f'font-size="12"><rect width="{w}" height="{h}" fill="white"/>',
             f'<text x="{pad}" y="18">path from above: golden (blue), candidate (orange)</text>',
             poly([to_map(p) for p in pts_g], "#2a6fdb", 3), poly([to_map(p) for p in pts_c], "#e8772e", 1.5)]
    for s in segments:
        i = next(k for k, p in enumerate(pairs) if p[0] == s["first_tick"])
        x, y = to_map(pts_g[i])
        parts.append(f'<circle cx="{x:.2f}" cy="{y:.2f}" r="3" fill="#333"/>')

    left, right, top, bottom = box + 2 * pad + 40, w - pad, pad, h - pad
    total = len(pairs)
    y_max = max([s["max_dev"] for s in segments] + [s["curve"][-1][2] * 0.25 for s in segments]) * 1.1

    def to_chart(i, v):
        return left + (right - left) * i / max(total - 1, 1), bottom - (bottom - top) * min(v, y_max) / y_max

    parts.append(f'<text x="{left}" y="18">deviation m (orange) vs tolerance (grey), max {y_max:.3f}</text>')
    parts.append(f'<rect x="{left}" y="{top}" width="{right - left}" height="{bottom - top}" fill="none" stroke="#ccc"/>')
    i = 0
    for s in segments:
        dev = [to_chart(i + k, c[1]) for k, c in enumerate(s["curve"])]
        tol = [to_chart(i + k, c[2]) for k, c in enumerate(s["curve"])]
        parts += [poly(tol, "#999", 1), poly(dev, "#e8772e", 1.5)]
        i += len(s["curve"])
    parts.append(f'<text x="{left}" y="{h - 8}">tick {pairs[0][0]}</text>')
    parts.append(f'<text x="{right}" y="{h - 8}" text-anchor="end">tick {pairs[-1][0]} '
                 f'({total / hz:.1f} s)</text></svg>')
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(parts) + "\n")


def _synthetic(path, ticks, speed_scale, gz):
    """A car driving a wide circle at a speed that ramps up, in the car-trace format."""
    opener = gzip.open if gz else open
    with opener(path, "wt", encoding="utf-8") as f:
        f.write(json.dumps({"format": "car_trace", "car": "synthetic"}) + "\n")
        dist = 0.0
        for t in range(ticks):
            speed = min(30.0, 2.0 + t * 0.2) * speed_scale
            dist += speed / TICK_HZ
            a = dist / 200.0
            pos = [200.0 * math.cos(a), 1.0, 200.0 * math.sin(a)]
            vel = [-speed * math.sin(a), 0.0, speed * math.cos(a)]
            f.write(json.dumps({"tick": t, "input": {}, "world": {},
                                "snap": {"origin": pos, "linear_velocity": vel}}, sort_keys=True) + "\n")


def self_test():
    with tempfile.TemporaryDirectory() as d:
        golden = os.path.join(d, "golden.jsonl.gz")
        slow = os.path.join(d, "slow.jsonl")
        _synthetic(golden, 1500, 1.0, True)
        _synthetic(slow, 1500, 0.99, False)
        g = load(golden)
        assert len(g) == 1500 and g[0][0] == 0, "header skipped, every tick read, gzip sniffed"

        _, same = compare(g, g)
        assert len(same) == 3, "1500 ticks at 60 Hz is three 10 s segments"
        assert all(s["max_dev"] == 0.0 and s["first_over_tick"] is None for s in same), "self-compare is zero drift"
        assert all(s["golden_time"] == s["cand_time"] for s in same)

        pairs, slow_segs = compare(g, load(slow))
        curve = slow_segs[0]["curve"]
        assert curve[0][1] < curve[len(curve) // 2][1] < curve[-1][1], "drift grows over the segment"
        assert slow_segs[-1]["max_dev"] > slow_segs[0]["max_dev"]
        assert slow_segs[-1]["first_over_tick"] is not None, "1% slower falls outside tolerance by the end"
        assert slow_segs[1]["cand_time"] > slow_segs[1]["golden_time"], "slower run takes longer to cover the distance"
        assert slow_segs[1]["cand_top"] < slow_segs[1]["golden_top"]

        late = [r for r in load(slow) if r[0] >= 700]
        _, from_restore = compare(g, late)
        assert from_restore[0]["first_tick"] == 700, "a run restored mid-way is compared from its first tick"

        svg = os.path.join(d, "out.svg")
        write_svg(pairs, slow_segs, svg)
        with open(svg, encoding="utf-8") as f:
            text = f.read()
        assert text.startswith("<svg") and text.count("<polyline") == 2 + 2 * len(slow_segs)
    print("drift_report self-test passed")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("golden", nargs="?")
    ap.add_argument("candidate", nargs="?")
    ap.add_argument("--svg", default="drift_report.svg", help="where to write the plot")
    ap.add_argument("--segment", type=float, default=SEGMENT_S, help="segment length in seconds")
    ap.add_argument("--hz", type=int, default=TICK_HZ, help="physics ticks per second of the traces")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        self_test()
        return
    if not args.golden or not args.candidate:
        ap.error("needs a golden and a candidate trace (or --self-test)")
    pairs, segments = compare(load(args.golden), load(args.candidate), args.hz, args.segment)
    print_report(segments)
    write_svg(pairs, segments, args.svg, args.hz)
    print(f"plot: {args.svg}")


if __name__ == "__main__":
    main()

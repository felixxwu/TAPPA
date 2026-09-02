extends Node
# C1 — benchmark fidelity. Does the CarPerformance benchmark lap RANK cars the same
# way real generated stages do?
#
# For a roster spanning the performance range (every catalogue car, stock AND at max
# potential, so the sample covers the whole power band) this computes:
#   (a) the benchmark time  — BenchmarkTrack + LapTimeModel, frozen conditions
#   (b) the mean optimum_ms across a sample of REAL GENERATED stages
# and reports the SPEARMAN RANK CORRELATION between them. Absolute agreement is
# irrelevant — the benchmark lap is ~40 s where a stage is minutes; what matters is
# that a car faster on the benchmark is faster on real stages.
#
# A single correlation number is not actionable, so it also names the worst
# OVER-RATED and UNDER-RATED cars (largest rank discrepancies in each direction) —
# the outliers are what name the missing term.
#
# The stage sample deliberately spans ARCHETYPES (see ARCHETYPES below): straightness,
# turn_count, forestiness and surface_mix are varied together, and per-archetype
# correlations are reported alongside the pooled one. Calibrating on one kind of stage
# would tune the benchmark to that archetype and mis-rank the others.
#
# Stages are generated LIVE via TrackGenerator (never the authored rally list or its
# baked track_cache) — these are synthetic seeds precisely so no cache can hide a
# generator change.
#
# Knob sweep: --straight / --sweeper take comma-separated values and are swept as a
# cartesian product via BenchmarkTrack.build_from, so the live config is never written.
# The best-correlating setting is flagged at the end.
#
# Run:  ./calibrate_benchmark.sh [-- --stages=8 --straight=350,500,750 --sweeper=70,90]
# Args (all optional, after a bare `--`):
#   --stages=N     stages to generate (default 6). Generation is the whole cost.
#   --seed=N       base seed for stage generation (default 90001)
#   --straight=... benchmark_straight_m values to sweep (default: the live config's)
#   --sweeper=...  benchmark_sweeper_radius_m values to sweep (default: live config's)
#   --stock-only   roster is stock cars only (default also includes max-potential builds)
#
# Design: docs/superpowers/specs/2026-08-15-car-performance-rating-design.md > Calibration.

# Stage archetypes, cycled over --stages. Shape fields only (never rally `difficulty`,
# which conflates generation shape with rival pace — see the spec's Calibration note).
const ARCHETYPES: Array[Dictionary] = [
	{"label": "open-gravel", "straightness": 0.95, "turn_count": 10, "forestiness": 0.25, "surface_mix": 0.0},
	{"label": "open-tarmac", "straightness": 0.90, "turn_count": 12, "forestiness": 0.30, "surface_mix": 1.0},
	{"label": "mixed-gravel", "straightness": 0.65, "turn_count": 16, "forestiness": 0.55, "surface_mix": 0.2},
	{"label": "mixed-tarmac", "straightness": 0.60, "turn_count": 16, "forestiness": 0.55, "surface_mix": 0.8},
	{"label": "twisty-gravel", "straightness": 0.25, "turn_count": 22, "forestiness": 0.80, "surface_mix": 0.0},
	{"label": "twisty-tarmac", "straightness": 0.25, "turn_count": 22, "forestiness": 0.80, "surface_mix": 1.0},
	{"label": "hairpins", "straightness": 0.05, "turn_count": 26, "forestiness": 0.70, "surface_mix": 0.4},
	{"label": "flowing-mixed", "straightness": 0.80, "turn_count": 14, "forestiness": 0.40, "surface_mix": 0.5},
]

const OUTLIER_COUNT := 3


func _ready() -> void:
	var args := _args()
	var cfg: GameConfig = Config.data
	var stage_count := int(args.get("stages", 6))
	var base_seed := int(args.get("seed", 90001))
	var straights := _floats(String(args.get("straight", "")), cfg.benchmark_straight_m)
	var sweepers := _floats(String(args.get("sweeper", "")), cfg.benchmark_sweeper_radius_m)
	var include_tuned := not args.has("stock-only")

	var roster := _roster(include_tuned)
	print("=== C1 benchmark fidelity ===")
	print("roster: %d builds   stages: %d   base seed: %d" % [roster.size(), stage_count, base_seed])
	print("frozen benchmark conditions: mu = %.2f x tire_compound   hairpin r=%.1fm  sweepers=%d" % [
		CarPerformance.BENCHMARK_SURFACE_GRIP, cfg.benchmark_hairpin_radius_m, cfg.benchmark_sweeper_count])
	print("")

	# --- Real stages ---------------------------------------------------------
	var stages := await _generate_stages(stage_count, base_seed)
	if stages.is_empty():
		push_error("calibrate_benchmark: no stage generated")
		get_tree().quit(1)
		return

	# real_ms[build_index] = Array of per-stage optimum ms
	var real_ms: Array = []
	for build in roster:
		var per_stage: Array = []
		for stage in stages:
			per_stage.append(LapTimeModel.optimum_ms(stage["track"], build["meta"], stage["event"]))
		real_ms.append(per_stage)

	var mean_real: Array = []
	for per_stage in real_ms:
		var total := 0.0
		for ms in per_stage:
			total += float(ms)
		mean_real.append(total / maxf(float(per_stage.size()), 1.0))
	var real_rank := _ranks(mean_real)

	# --- Knob sweep ----------------------------------------------------------
	var best := {"rho": -2.0}
	var sweep_rows: Array = []
	for straight in straights:
		for sweeper in sweepers:
			var bench := _benchmark_times(roster, straight, sweeper, cfg)
			var rho := _spearman(bench, mean_real)
			sweep_rows.append({"straight": straight, "sweeper": sweeper, "rho": rho, "bench": bench})
			if rho > float(best["rho"]):
				best = {"rho": rho, "straight": straight, "sweeper": sweeper, "bench": bench}

	# --- Per-build detail at the best setting --------------------------------
	var bench_best: Array = best["bench"]
	var bench_rank := _ranks(bench_best)
	print("--- per-build, at the best-correlating setting (straight=%.0fm sweeper_r=%.0fm) ---"
		% [best["straight"], best["sweeper"]])
	print("%-28s %10s %12s %6s %6s %7s" % ["build", "bench s", "mean real s", "rB", "rR", "delta"])
	var rows: Array = []
	for i in roster.size():
		var delta: float = float(bench_rank[i]) - float(real_rank[i])
		rows.append({"i": i, "delta": delta})
		print("%-28s %10.2f %12.2f %6.1f %6.1f %+7.1f" % [
			roster[i]["label"], float(bench_best[i]) / 1000.0, float(mean_real[i]) / 1000.0,
			bench_rank[i], real_rank[i], delta])
	print("")

	# --- Outliers ------------------------------------------------------------
	# delta = rank(benchmark) - rank(real stages). Ranks are over TIME, so rank 1 is the
	# fastest. A NEGATIVE delta means the benchmark places the car higher up the order
	# than real stages do — the benchmark flatters it: OVER-RATED.
	rows.sort_custom(func(a, b): return float(a["delta"]) < float(b["delta"]))
	print("--- worst OVER-RATED (benchmark flatters them vs real stages) ---")
	for k in mini(OUTLIER_COUNT, rows.size()):
		var r: Dictionary = rows[k]
		if float(r["delta"]) >= 0.0:
			break
		_print_outlier(roster, bench_rank, real_rank, r)
	print("--- worst UNDER-RATED (real stages like them more than the benchmark does) ---")
	for k in mini(OUTLIER_COUNT, rows.size()):
		var r: Dictionary = rows[rows.size() - 1 - k]
		if float(r["delta"]) <= 0.0:
			break
		_print_outlier(roster, bench_rank, real_rank, r)
	print("")

	# --- Per-archetype correlation ------------------------------------------
	# A pooled rho can hide a benchmark that ranks open stages perfectly and twisty ones
	# backwards, so each archetype is scored on its own.
	print("--- per-archetype Spearman (best setting) ---")
	for si in stages.size():
		var col: Array = []
		for i in roster.size():
			col.append(real_ms[i][si])
		print("  %-16s seed %-7d rho = %+.4f  (length %.0f m)" % [
			stages[si]["label"], int(stages[si]["seed"]), _spearman(bench_best, col),
			stages[si]["length_m"]])
	print("")

	# --- Sweep table ---------------------------------------------------------
	print("--- knob sweep (Spearman vs mean real-stage time) ---")
	print("%12s %12s %10s" % ["straight_m", "sweeper_r_m", "rho"])
	for row in sweep_rows:
		var mark := "  <-- best" if is_equal_approx(float(row["rho"]), float(best["rho"])) else ""
		print("%12.0f %12.0f %10.4f%s" % [row["straight"], row["sweeper"], row["rho"], mark])
	print("")
	print("best: benchmark_straight_m = %.0f, benchmark_sweeper_radius_m = %.0f, rho = %.4f"
		% [best["straight"], best["sweeper"], best["rho"]])
	print("(these are GameConfig knobs — set them in config/game_config.tres, not in code)")
	get_tree().quit(0)


func _print_outlier(roster: Array, bench_rank: Array, real_rank: Array, row: Dictionary) -> void:
	var i: int = int(row["i"])
	print("  %-28s bench rank %.1f vs real rank %.1f  (delta %+.1f)" % [
		roster[i]["label"], bench_rank[i], real_rank[i], float(row["delta"])])


# Every catalogue car as a solver meta, stock and (unless --stock-only) at max
# potential. The tuned builds are here to WIDEN the performance range the correlation
# is measured over, not to represent a real save.
func _roster(include_tuned: bool) -> Array:
	var out: Array = []
	# CarLibrary.CARS, not all(): in a bare tool run the Registry seam behind all() is
	# not initialised yet (the same reason report_eligibility.gd reads CARS directly),
	# and a calibration run always wants the shipped roster anyway.
	for car in CarLibrary.CARS:
		var cid := String(car.get("id", "?"))
		out.append({"label": "%s (stock)" % cid, "meta": car})
		if include_tuned:
			out.append({"label": "%s (maxed)" % cid, "meta": UpgradeLibrary.max_potential_meta(car, car)})
	return out


# Benchmark time per build for one knob setting. Mirrors CarPerformance._simulate
# exactly (same frozen mu, same solver call) but through BenchmarkTrack.build_from, so
# a sweep never writes to the live config.
func _benchmark_times(roster: Array, straight_m: float, sweeper_r: float, cfg: GameConfig) -> Array:
	var track := BenchmarkTrack.build_from(straight_m, cfg.benchmark_hairpin_radius_m,
		sweeper_r, cfg.benchmark_sweeper_count)
	var out: Array = []
	for build in roster:
		var meta: Dictionary = build["meta"]
		var mu := CarPerformance.BENCHMARK_SURFACE_GRIP * float(meta.get("tire_compound", 1.0))
		out.append(LapTimeModel.optimum_ms(track, meta, {}, 1.0, 1.0, mu))
	return out


# Synthetic stages, one per archetype, cycling with a fresh seed each lap of the table.
func _generate_stages(count: int, base_seed: int) -> Array:
	var out: Array = []
	for i in count:
		var arch: Dictionary = ARCHETYPES[i % ARCHETYPES.size()]
		var seed_value := base_seed + i * 137
		var event := {
			"seed": seed_value,
			"turn_count": int(arch["turn_count"]),
			"straightness": float(arch["straightness"]),
			"forestiness": float(arch["forestiness"]),
			"surface_mix": float(arch["surface_mix"]),
			"water_enabled": false,
			"region": "",
		}
		var cfg := StageConfig.canonical_event_config(event)
		var params := TrackGenParams.for_event(event, cfg)
		var result := await TrackGenerator.generate(params)
		var centerline := result.get("centerline") as Curve2D
		if centerline == null or not bool(result.get("complete", false)):
			push_warning("calibrate_benchmark: stage %s seed %d incomplete — skipped" % [arch["label"], seed_value])
			continue
		print("generated %-16s seed %-7d %5.0f m  %d turns" % [
			arch["label"], seed_value, centerline.get_baked_length(), int(arch["turn_count"])])
		out.append({
			"label": String(arch["label"]), "seed": seed_value, "event": event,
			"track": result, "length_m": centerline.get_baked_length(),
		})
	print("")
	return out


# --- Statistics --------------------------------------------------------------

# Fractional (tie-averaged) ranks, 1 = smallest value.
func _ranks(values: Array) -> Array:
	var order: Array = []
	for i in values.size():
		order.append(i)
	order.sort_custom(func(a, b): return float(values[a]) < float(values[b]))
	var out: Array = []
	out.resize(values.size())
	var k := 0
	while k < order.size():
		var j := k
		while j + 1 < order.size() and is_equal_approx(float(values[order[j + 1]]), float(values[order[k]])):
			j += 1
		var mean_rank := float(k + j) * 0.5 + 1.0
		for m in range(k, j + 1):
			out[order[m]] = mean_rank
		k = j + 1
	return out


# Spearman rank correlation: Pearson over the tie-averaged ranks (the 1 - 6*d^2/n(n^2-1)
# shortcut is only valid without ties, and equal times DO occur across identical builds).
func _spearman(a: Array, b: Array) -> float:
	var n := mini(a.size(), b.size())
	if n < 2:
		return 0.0
	var ra := _ranks(a)
	var rb := _ranks(b)
	var mean := float(n + 1) * 0.5
	var num := 0.0
	var da := 0.0
	var db := 0.0
	for i in n:
		var x := float(ra[i]) - mean
		var y := float(rb[i]) - mean
		num += x * y
		da += x * x
		db += y * y
	if da <= 0.0 or db <= 0.0:
		return 0.0
	return num / sqrt(da * db)


# --- Argument handling -------------------------------------------------------

# `--key=value` / `--flag` pairs from the user args (everything after a bare `--`),
# matching the house style of the other tool runners.
func _args() -> Dictionary:
	var out: Dictionary = {}
	for raw in OS.get_cmdline_user_args():
		var arg := String(raw)
		if not arg.begins_with("--"):
			continue
		arg = arg.substr(2)
		var eq := arg.find("=")
		if eq < 0:
			out[arg] = true
		else:
			out[arg.substr(0, eq)] = arg.substr(eq + 1)
	return out


func _floats(csv: String, fallback: float) -> Array:
	var out: Array = []
	for part in csv.split(",", false):
		var s := String(part).strip_edges()
		if s.is_valid_float():
			out.append(s.to_float())
	if out.is_empty():
		out.append(fallback)
	return out

extends Node
# Single-event track-generation probe — the "why did rally X seed N not complete?"
# debugging tool for the message tools/generate_track_cache.gd emits
# ("track cache: rally %s seed %d did not complete").
#
# Generates ONE rally event (or an ad-hoc seed) exactly the way the cache baker
# does — same TrackGenParams factory, same TrackGenerator.generate — and prints the
# resolved params, the waterline picture around the start, and how many corners the
# DFS actually placed. It writes NOTHING: data/track_cache.json is never touched, so
# this is safe to run while the committed lockfile is in a known-good state.
#
# It is a SCENE run (not --script): Config and the other autoloads only exist in
# a scene run, and TrackGenerator._search calls Platform.is_headless(), which
# needs them. Same reason generate_track_cache.gd is a scene.
#
# Usage from the repo root (see ./probe_track.sh for a wrapper):
#   $GODOT --headless --path . res://tools/probe_track_event.tscn -- \
#       --rally=gc_island_gp                    # every event of one rally
#   ... -- --rally=gc_island_gp --seed=54103    # a single event
#   ... -- --seed=54103 --turns=31 --straightness=0.2 --water=-4.0   # ad-hoc
# Exit code 1 if any probed event failed to complete, else 0.

const TrackGenParams = preload("res://scripts/track_gen_params.gd")

# Waterline survey: a PROBE_SPAN × PROBE_SPAN m grid centred on the start. A high
# wet fraction next to a `relocated=true` origin is the signature of a start marooned
# on a small dry patch — the DFS then can't fit even the first corner (see
# TrackGenerator._collide_and_cells' WATER_MAX_WET_FRACTION rejection).
const PROBE_SPAN_M := 400.0
const PROBE_STEP_M := 5.0


func _ready() -> void:
	var args := _parse_args()
	var events := _events_for(args)
	if events.is_empty():
		print("probe: no events matched — pass --rally=<id> and/or --seed=<n>")
		get_tree().quit(2)
		return
	var failures := 0
	for ev in events:
		if not await _probe(ev):
			failures += 1
	get_tree().quit(1 if failures > 0 else 0)


func _parse_args() -> Dictionary:
	var out: Dictionary = {}
	for a in OS.get_cmdline_user_args():
		var s := String(a)
		if not s.begins_with("--"):
			continue
		var kv := s.substr(2).split("=", true, 1)
		out[kv[0]] = kv[1] if kv.size() > 1 else "true"
	return out


# Either the authored events of a rally (optionally narrowed to one seed), or a
# synthetic event built from the flags.
func _events_for(args: Dictionary) -> Array:
	var want_seed: int = int(args["seed"]) if args.has("seed") else -1
	if args.has("rally"):
		var out: Array = []
		for rally in RallyLibrary.all():
			if String(rally.get("id", "")) != String(args["rally"]):
				continue
			for ev in rally.get("events", []):
				if want_seed < 0 or int(ev.get("seed", -1)) == want_seed:
					var copy: Dictionary = ev.duplicate(true)
					copy["_rally"] = rally.get("id", "?")
					out.append(copy)
		return out
	if want_seed < 0:
		return []
	var synthetic: Dictionary = {"seed": want_seed, "_rally": "(ad-hoc)"}
	if args.has("turns"):
		synthetic["turn_count"] = int(args["turns"])
	if args.has("straightness"):
		synthetic["straightness"] = float(args["straightness"])
	if args.has("water"):
		synthetic["water_level"] = float(args["water"])
	if args.has("region"):
		synthetic["region"] = String(args["region"])
	return [synthetic]


func _probe(event: Dictionary) -> bool:
	# StageConfig.canonical_event_config + for_event is exactly the pair generate_track_cache.gd
	# uses, so a probe here is the same generation the baker performs.
	var cfg := StageConfig.canonical_event_config(event)
	var p := TrackGenParams.for_event(event, cfg)
	print("--- rally %s seed %d ---" % [event.get("_rally", "?"), p.seed])
	print("  turns=%d width=%.1f clearance=%.1f straightness=%.2f runoff=%.1f reserve_behind=%.1f"
		% [p.turn_count, p.width, p.clearance, p.straightness, p.runoff_m, p.reserve_behind])
	print("  water_enabled=%s water_level=%.2f (authored %.2f) shore_clearance=%.2f"
		% [str(p.water_enabled), p.water_level, p.key_water_level, p.shore_clearance])
	print("  origin=%s base_origin=%s relocated=%s"
		% [str(p.origin), str(p.base_origin), str(p.origin != p.base_origin)])
	if p.water_sampler.is_valid():
		print("  terrain height at origin=%.2f, waterline ceiling=%.2f, wet fraction within %dm=%.3f"
			% [float(p.water_sampler.call(p.origin.x, p.origin.y)),
				p.water_level + p.shore_clearance, int(PROBE_SPAN_M), _wet_fraction(p)])
	var t0 := Time.get_ticks_msec()
	var result: Dictionary = await TrackGenerator.generate(p)
	var ok: bool = result["complete"]
	print("  => complete=%s placed=%d/%d corners in %d ms"
		% [str(ok), result["pieces"].size(), p.turn_count, Time.get_ticks_msec() - t0])
	return ok


# Fraction of a grid around the start that sits below the waterline + shore clearance.
func _wet_fraction(p: TrackGenParams) -> float:
	if not p.water_enabled:
		return 0.0
	var ceiling := p.water_level + p.shore_clearance
	var n := int(PROBE_SPAN_M / PROBE_STEP_M) + 1
	var wet := 0
	var total := 0
	for i in n:
		for j in n:
			var x := p.origin.x + (float(i) - float(n - 1) * 0.5) * PROBE_STEP_M
			var y := p.origin.y + (float(j) - float(n - 1) * 0.5) * PROBE_STEP_M
			total += 1
			if float(p.water_sampler.call(x, y)) < ceiling:
				wet += 1
	return float(wet) / float(total)

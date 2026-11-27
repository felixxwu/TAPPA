class_name LevelKnobs
extends RefCounted
# Docs: features/adaptive-graphics.md — update in the same change as this file.
## The level view's adaptive graphics settings: each one's levels, what it changes live, and how
## much its steps matter to the look. Every setting's top level is the authored GameConfig value.

const COVER_NEAR := ["ground_cover_reach", "ground_cover_fade_start", "ground_cover_fade_end"]
const COVER_FAR := ["ground_cover_far_reach", "ground_cover_far_fade_start", "ground_cover_far_fade_end"]
const MIN_FAR_RADIUS := 3
const MIN_MID_RADIUS := 1.0


static func build(view: LevelView) -> Array[AdaptiveKnob]:
	var cfg: GameConfig = Config.data
	var out: Array[AdaptiveKnob] = []
	var trees := _distance(&"trees", "Trees", view, func(f: float) -> float: return authored("level_tree_draw_m") * f)
	trees.apply = func(l: int) -> void:
		cfg.level_tree_draw_m = authored("level_tree_draw_m") * share(l)
		if is_instance_valid(view._trees):
			view._trees.refresh_draw()
	out.append(trees)
	var near := _distance(&"cover_near", "Grass near", view, func(f: float) -> float: return authored("ground_cover_reach") * f)
	var far := _distance(&"cover_far", "Grass far", view, func(f: float) -> float: return authored("ground_cover_far_reach") * f)
	var refresh_cover := func() -> void:
		var cap := cfg.ground_cover_far_reach / maxf(authored("ground_cover_reach"), 0.001)
		var f := minf(share(near.level), cap)
		for field in COVER_NEAR:
			cfg.set(field, authored(field) * f)
		if view._streamer != null and view._streamer.cover != null:
			view._streamer.cover.refresh_reach()
	near.apply = func(_l: int) -> void: refresh_cover.call()
	far.apply = func(l: int) -> void:
		for field in COVER_FAR:
			cfg.set(field, authored(field) * share(l))
		refresh_cover.call()
	out.append(near)
	out.append(far)
	var rings := LevelStreamer.level_settings()
	var terrain := _knob(&"terrain", "Terrain detail", maxi(rings.far_radius - MIN_FAR_RADIUS, 0) + 1)
	terrain.miss_target = true
	terrain.apply = func(l: int) -> void:
		if view._streamer != null:
			var f := float(l) / maxf(terrain.top(), 1.0)
			view._streamer.apply_rings(lerpf(minf(MIN_MID_RADIUS, rings.mid_radius), rings.mid_radius, f), MIN_FAR_RADIUS + l if terrain.top() > 0 else rings.far_radius)
	out.append(terrain)
	var fx := _knob(&"surface_fx", "Dust & tyre marks", 5)
	fx.apply = func(l: int) -> void:
		var f := l / 4.0
		for n in ["DustPuffs", "WheelParticles"]:
			var pool := view.effect(n) as CpuParticlePool
			if pool != null:
				pool.set_quality(f)
		cfg.tire_marks_enabled = bool(authored("tire_marks_enabled")) and l > 0
		var marks := view.effect("TireMarks") as TireMarks
		if marks != null:
			marks.set_shown(l > 0)
	out.append(fx)
	var smoke := _knob(&"smoke", "Engine smoke", 3)
	smoke.apply = func(l: int) -> void:
		var pool := view.effect("EngineSmoke") as CpuParticlePool
		if pool != null:
			pool.set_quality(l / 2.0)
	out.append(smoke)
	var flames := _knob(&"flames", "Exhaust flames", 2)
	flames.apply = func(l: int) -> void: cfg.exhaust_flames_enabled = bool(authored("exhaust_flames_enabled")) and l > 0
	out.append(flames)
	var crowd := _knob(&"spectators", "Spectators", 2)
	crowd.apply = func(l: int) -> void: cfg.spectators_enabled = bool(authored("spectators_enabled")) and l > 0
	out.append(crowd)
	var weather := _knob(&"weather", "Rain & snow", 3)
	weather.apply = func(l: int) -> void: view.set_weather_ratio(l / 2.0)
	out.append(weather)
	var res := _knob(&"resolution", "Resolution", 4)
	res.last_resort = true
	res.level = res.top()
	res.apply = func(l: int) -> void: view.set_render_scale(lerpf(cfg.adaptive_resolution_floor, 1.0, l / 3.0))
	out.append(res)
	return out


static func authored(field: String) -> Variant:
	return Config.authored_value(field, Config.data.get(field))


## Share of the authored distance a distance setting draws at `level`.
static func share(level: int) -> float:
	var cfg: GameConfig = Config.data
	return lerpf(cfg.adaptive_distance_floor, 1.0, float(level) / maxf(cfg.adaptive_distance_levels - 1, 1))


static func _knob(id: StringName, label: String, levels: int) -> AdaptiveKnob:
	var cfg: GameConfig = Config.data
	var k := AdaptiveKnob.new()
	k.id = id
	k.name = label
	k.levels = levels
	k.level = ceili(k.top() / 2.0)
	var w := float(cfg.adaptive_weights.get(String(id), 1.0))
	k.weight = func(_at: int) -> float: return w
	k.prior_ms = float(cfg.adaptive_priors_ms.get(String(id), 0.3))
	k.cost_ms = k.prior_ms
	return k


# A distance setting: a step that only adds what lies beyond the fog is worth nothing to the look.
static func _distance(id: StringName, label: String, view: LevelView, metres_at: Callable) -> AdaptiveKnob:
	var k := _knob(id, label, Config.data.adaptive_distance_levels)
	var w := float(Config.data.adaptive_weights.get(String(id), 1.0))
	k.weight = func(at: int) -> float:
		var fog := view.fog_end_m()
		return 0.0 if fog > 0.0 and float(metres_at.call(share(at - 1))) >= fog else w
	return k

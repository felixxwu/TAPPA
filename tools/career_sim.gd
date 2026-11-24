extends Node
# Plays whole careers on a level with random choices, to tune delivery routes, payouts and shop stock. Logs each step:
# which deliveries were on offer, where the player drove next, and what they could and couldn't afford at the shops.
# Uses the level's bake for road distances and LevelView's own pay and cargo rules.
# Run: godot --headless --path . res://tools/career_sim.tscn -- [seed=N] [runs=N] [player=random|goal] [buy=0.5]
#      [timeline=1] [matrix=1] [usage=res://out.png] [level=res://tools/levels/x.json]
# runs > 1 prints one summary per career and the averages. player=goal also detours to the nearest shop selling
# something it can afford; random only shops when a drop-off is beside one. matrix=1 prints the road km between every
# teleport point instead. Every run also counts how often each road sample is driven (the sat nav's shortest route) and
# prints that as a grid over the map: passes per career over each cell's roads, "." for none; usage= also paints a PNG,
# and gaps=N lists the N longest stretches never driven (default 8), where a new teleport point would bring traffic.

const SHOP_NEAR_M := 500.0
const GRID := 10

var opts := {"seed": str(Time.get_unix_time_from_system()), "runs": "1", "player": "random", "buy": "0.5"}
var rng := RandomNumberGenerator.new()
var level: Dictionary
var roads: LevelData
var km_cache := {}
var ids_cache := {}
var usage := PackedInt32Array()  # passes over each road sample, summed over every run
var money := 0
var cars: Array[String] = []
var parts: Array[String] = []
var done := {}
var at := Vector2.ZERO
var step := 0
var verbose := true
var delivered := 0
var earned := 0
var driven_km := 0.0
var unpaid_km := 0.0
var buys: Array[int] = []  # how many deliveries were done when each purchase was made
var timeline: Array[String] = []
var broke := 0
var broke_streak := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	var save := String(opts.get("level", Config.data.level_path))
	var bake := LevelBake.load_fresh(save)
	if bake == null:
		push_error("career_sim: no fresh bake for %s; run tools/bake_level.sh first" % save)
		get_tree().quit(1)
		return
	level = JSON.parse_string(FileAccess.get_file_as_string(save))
	roads = bake._roads()
	if opts.has("matrix"):
		print_matrix()
		get_tree().quit()
		return
	var runs := int(opts["runs"])
	verbose = runs == 1
	usage.resize(roads.sx.size())
	var totals := {}
	for r in runs:
		var stats := career(int(opts["seed"]) + r)
		print("seed %d: %s" % [int(opts["seed"]) + r, stats])
		if opts.has("timeline"):
			print("  " + " ".join(timeline))
		for k: String in stats:
			if stats[k] is int or stats[k] is float:
				totals[k] = totals.get(k, 0.0) + float(stats[k]) / runs
	if runs > 1:
		for k: String in totals:
			totals[k] = snappedf(totals[k], 0.1)
		print("average: %s" % totals)
	report_usage(runs)
	get_tree().quit()


func career(seed: int) -> Dictionary:
	rng.seed = seed
	money = Config.data.level_start_money
	for a: Array in [cars, parts, buys, timeline]:
		a.clear()
	done.clear()
	delivered = 0
	earned = 0
	driven_km = 0.0
	unpaid_km = 0.0
	broke = 0
	broke_streak = 0
	step = 0
	log_line("seed %d, %s player, start money $%d" % [seed, opts["player"], money])
	run()
	var gaps: Array[int] = []
	for i in range(1, buys.size()):
		gaps.append(buys[i] - buys[i - 1])
	var quarters := [0, 0, 0, 0]
	for b in buys:
		quarters[mini(3, b * 4 / maxi(delivered, 1))] += 1
	return {"deliveries": delivered, "earned": earned, "bought": buys.size(), "unbought": stock_ids().keys().filter(func(id: String) -> bool: return not (id in cars or id in parts)),
		"cars": cars.size(), "money_left": money, "longest_gap": gaps.max() if not gaps.is_empty() else 0,
		"broke_streak": broke_streak, "after_last_buy": delivered - (buys[-1] if not buys.is_empty() else 0),
		"first_upgrade_at": buys[1] if buys.size() > 1 else -1, "buys_by_quarter": "/".join(quarters.map(str)),
		"km_paid": snappedf(driven_km, 0.1), "km_unpaid": snappedf(unpaid_km, 0.1)}


func run() -> void:
	var start := shop_named(Config.data.level_start_shop)
	at = pos(start)
	visit_shop(start)
	while true:
		var t := next_point()
		if t.is_empty():
			break
		var offered := open_at(t)
		var m: Dictionary = offered[rng.randi() % offered.size()]
		var info := LevelView.delivery_info_on(level, roads, t, m)
		var to := point_named(String(m["to"]))
		done[LevelView.delivery_key(t, m)] = true
		money += int(info["pay"])
		earned += int(info["pay"])
		delivered += 1
		driven_km += float(info["km"])
		drive(pos(t), pos(to))
		at = pos(to)
		log_line("deliver %s (%.0f kg) %s -> %s, %.1f km, +$%d -> $%d" % [info["cargo"], info["kg"], t["name"], to["name"], info["km"], info["pay"], money])
		var shopped := false
		for s: Dictionary in level.get("shops", []):
			if at.distance_to(pos(s)) <= SHOP_NEAR_M:
				visit_shop(s)
				shopped = true
		if not shopped and opts["player"] == "goal":
			detour_to_shop()
		var cheapest := cheapest_unowned()
		broke = broke + 1 if cheapest > money else 0
		broke_streak = maxi(broke_streak, broke)
	var left := 0
	for t: Dictionary in level.get("teleports", []):
		left += open_at(t).size()
	log_line("career over: $%d, cars %s, parts %s, %d deliveries done, %d left unreachable" % [money, cars, parts, done.size(), left])


# A goal-driven player with money for something drives to the nearest shop selling it and buys it.
func detour_to_shop() -> void:
	var best := {}
	var best_km := INF
	for s: Dictionary in level.get("shops", []):
		if affordable(s).is_empty():
			continue
		var km := road_km(at, pos(s))
		if km >= 0.0 and km < best_km:
			best_km = km
			best = s
	if best.is_empty():
		return
	log_line("detour %.1f km to %s" % [best_km, best["name"]])
	unpaid_km += best_km
	drive(at, pos(best))
	at = pos(best)
	visit_shop(best, true)


# Where to pick up next: the point the player is standing on if it still has work, else the nearest by road that does.
func next_point() -> Dictionary:
	var best := {}
	var best_km := INF
	var unreachable := 0
	for t: Dictionary in level.get("teleports", []):
		if open_at(t).is_empty():
			continue
		var km := road_km(at, pos(t))
		if km < 0.0:
			unreachable += 1
		elif km < best_km:
			best_km = km
			best = t
	var nearby := 0
	for t: Dictionary in level.get("teleports", []):
		if at.distance_to(pos(t)) <= SHOP_NEAR_M:
			nearby += open_at(t).size()
	if best.is_empty():
		log_line("no reachable point has deliveries left (%d unreachable)" % unreachable)
		return best
	var here := open_at(best).size()
	if best_km < 0.05:
		log_line("at %s: %d deliveries here, %d within %d m" % [best["name"], here, nearby, SHOP_NEAR_M])
	else:
		log_line("none here (%d within %d m); drive %.1f km to %s, %d deliveries there" % [nearby, SHOP_NEAR_M, best_km, best["name"], here])
		drive(at, pos(best))
		at = pos(best)
		unpaid_km += best_km
	return best


func visit_shop(s: Dictionary, must_buy := false) -> void:
	log_line("shop %s ($%d)" % [s["name"], money])
	while true:
		var can := affordable(s)
		var owned := 0
		for item: Dictionary in s.get("stock", []):
			owned += int(is_owned(item))
		log_line("  %d affordable, %d too dear, %d owned" % [can.size(), s.get("stock", []).size() - can.size() - owned, owned])
		if can.is_empty() or (not cars.is_empty() and not must_buy and rng.randf() >= float(opts["buy"])):
			break
		must_buy = false
		var pick: Dictionary = can[rng.randi() % can.size()]
		var id := String(pick.get("car", pick.get("part")))
		money -= int(pick["price"])
		buys.append(delivered)
		timeline.append("%d:%s" % [delivered, id])
		(cars if pick.has("car") else parts).append(id)
		log_line("  bought %s for $%d -> $%d" % [id, pick["price"], money])
	if cars.is_empty():
		log_line("  stuck: no car and none affordable")


func affordable(s: Dictionary) -> Array:
	return s.get("stock", []).filter(func(i: Dictionary) -> bool:
		return not is_owned(i) and int(i["price"]) <= money and (i.has("car") or not cars.is_empty()))


func is_owned(item: Dictionary) -> bool:
	return String(item.get("car", "")) in cars or String(item.get("part", "")) in parts


func cheapest_unowned() -> int:
	var low := 1 << 30
	for s: Dictionary in level.get("shops", []):
		for item: Dictionary in s.get("stock", []):
			if not is_owned(item):
				low = mini(low, int(item["price"]))
	return low


func stock_ids() -> Dictionary:
	var ids := {}
	for s: Dictionary in level.get("shops", []):
		for item: Dictionary in s.get("stock", []):
			ids[item.get("car", item.get("part"))] = true
	return ids


func print_matrix() -> void:
	var ts: Array = level.get("teleports", [])
	for t: Dictionary in ts:
		print("PT|%s|%.1f|%.1f" % [t["name"], t["x"], t["z"]])
	for a: Dictionary in ts:
		print("KM|%s|%s" % [a["name"], ",".join(ts.map(func(b: Dictionary) -> String:
			var km := road_km(pos(a), pos(b))
			return "%.1f" % km if km >= 0.0 else "X"))])


func drive(a: Vector2, b: Vector2) -> void:
	var key := Vector4(a.x, a.y, b.x, b.y)
	if not ids_cache.has(key):
		ids_cache[key] = roads.route_ids(a, b)
	for id: int in ids_cache[key]:
		usage[id] += 1


# How evenly the careers used the roads: a grid of average passes per career over each cell's road samples.
func report_usage(runs: int) -> void:
	var size := float(level.get("size", 5000))
	var sum := PackedFloat32Array()
	var count := PackedInt32Array()
	sum.resize(GRID * GRID)
	count.resize(GRID * GRID)
	var unused := 0
	for i in usage.size():
		var c := cell_of(Vector2(roads.sx[i], roads.sz[i]), size)
		sum[c] += float(usage[i]) / runs
		count[c] += 1
		unused += int(usage[i] == 0)
	print("road usage, passes per career (north up, %d m cells, . = no road):" % roundi(size / GRID))
	for gz in GRID:
		var row := ""
		for gx in GRID:
			var c := gz * GRID + gx
			row += "    ." if count[c] == 0 else "%5.1f" % (sum[c] / count[c])
		print(row)
	var driven := Array(usage).filter(func(u: int) -> bool: return u > 0)
	var mean := float(driven.reduce(func(acc: int, u: int) -> int: return acc + u, 0)) / maxi(driven.size(), 1)
	print("never driven: %d%% of the road; the busiest road carries %.1fx the average driven road" % [
		roundi(100.0 * unused / maxi(usage.size(), 1)), float(Array(usage).max()) / maxf(mean, 1.0)])
	print_gaps()
	if opts.has("usage"):
		paint_usage(String(opts["usage"]), size)


# The longest stretches no career drove, each with its spot farthest from any teleport point (GAP|m|x|z|heading|clearance).
func print_gaps() -> void:
	var gaps: Array = []
	var i := 0
	while i < usage.size():
		if usage[i] != 0:
			i += 1
			continue
		var j := i
		var m := 0.0
		while j + 1 < usage.size() and usage[j + 1] == 0 and roads.sc[j + 1] == roads.sc[i]:
			m += Vector2(roads.sx[j + 1] - roads.sx[j], roads.sz[j + 1] - roads.sz[j]).length()
			j += 1
		var far := i
		var far_d := -1.0
		for k in range(i, j + 1):
			var d := INF
			for t: Dictionary in level.get("teleports", []):
				d = minf(d, Vector2(roads.sx[k], roads.sz[k]).distance_to(pos(t)))
			if d > far_d:
				far_d = d
				far = k
		gaps.append([m, far, far_d])
		i = j + 1
	gaps.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	for g: Array in gaps.slice(0, int(opts.get("gaps", 8))):
		var k: int = g[1]
		var n := k + 1 if k + 1 < usage.size() and roads.sc[k + 1] == roads.sc[k] else k - 1
		var dir := Vector2(roads.sx[n] - roads.sx[k], roads.sz[n] - roads.sz[k]) * (1.0 if n > k else -1.0)
		print("GAP|%.0f m|%.1f|%.1f|%d|%.0f m from a point" % [g[0], roads.sx[k], roads.sz[k], roundi(rad_to_deg(atan2(dir.x, -dir.y))), g[2]])


func cell_of(p: Vector2, size: float) -> int:
	var gx := clampi(floori((p.x / size + 0.5) * GRID), 0, GRID - 1)
	var gz := clampi(floori((p.y / size + 0.5) * GRID), 0, GRID - 1)
	return gz * GRID + gx


# Each road sample as a dot, grey when never driven, else from blue (rarely) to red (the busiest road).
func paint_usage(path: String, size: float) -> void:
	var px := 1000
	var img := Image.create(px, px, false, Image.FORMAT_RGB8)
	img.fill(Color(0.08, 0.08, 0.08))
	var top := maxf(1.0, float(Array(usage).max()))
	for i in usage.size():
		var x := clampi(roundi((roads.sx[i] / size + 0.5) * px), 1, px - 2)
		var z := clampi(roundi((roads.sz[i] / size + 0.5) * px), 1, px - 2)
		var col := Color(0.35, 0.35, 0.35) if usage[i] == 0 else Color.BLUE.lerp(Color.RED, sqrt(usage[i] / top))
		img.fill_rect(Rect2i(x - 1, z - 1, 3, 3), col)
	for t: Dictionary in level.get("teleports", []):
		img.fill_rect(Rect2i(roundi((float(t["x"]) / size + 0.5) * px) - 4, roundi((float(t["z"]) / size + 0.5) * px) - 4, 9, 9), Color.YELLOW)
	for s: Dictionary in level.get("shops", []):
		img.fill_rect(Rect2i(roundi((float(s["x"]) / size + 0.5) * px) - 4, roundi((float(s["z"]) / size + 0.5) * px) - 4, 9, 9), Color.MAGENTA)
	img.save_png(path)
	print("usage map: %s" % ProjectSettings.globalize_path(path))


func open_at(t: Dictionary) -> Array:
	return t.get("deliveries", []).filter(func(m: Dictionary) -> bool: return not done.has(LevelView.delivery_key(t, m)))


func road_km(a: Vector2, b: Vector2) -> float:
	if a.distance_to(b) < 1.0:
		return 0.0
	var key := Vector4(a.x, a.y, b.x, b.y)
	if not km_cache.has(key):
		var line := roads.route(a, b)
		var m := 0.0
		for i in range(1, line.size()):
			m += line[i - 1].distance_to(line[i])
		km_cache[key] = m / 1000.0 if not line.is_empty() else -1.0
	return km_cache[key]


func point_named(n: String) -> Dictionary:
	for t: Dictionary in level.get("teleports", []):
		if t["name"] == n:
			return t
	return {}


func shop_named(n: String) -> Dictionary:
	var shops: Array = level.get("shops", [])
	for s: Dictionary in shops:
		if s["name"] == n:
			return s
	return shops[0] if not shops.is_empty() else {"name": "nowhere", "x": 0, "z": 0}


func pos(d: Dictionary) -> Vector2:
	return Vector2(float(d["x"]), float(d["z"]))


func log_line(s: String) -> void:
	step += 1
	if verbose:
		print("[%03d] %s" % [step, s])

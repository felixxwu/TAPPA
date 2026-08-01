extends Node
# Eligibility report: for every rally x car, reports whether the car can enter
# stock (as bought) and whether it could enter fully tuned (max potential),
# using the REAL predicates (RallyLibrary.is_eligible / ineligibility_reason)
# so this report can never drift from the game's actual rule. Flags rallies
# with < 2 or > 4 eligible-stock cars, and cars that can enter almost nothing,
# as authoring signals — not a pass/fail gate. See
# todo/one-map-four-corners.md > "New task: an eligibility-report tool".
#
# Run via ./report_eligibility.sh (wraps
# `$GODOT --headless --path . res://tools/report_eligibility.tscn`).


func _ready() -> void:
	var rallies: Array = RallyLibrary.RALLIES
	var cars: Array = CarLibrary.CARS

	var per_car_stock: Dictionary = {}
	var per_car_tuned: Dictionary = {}
	for car in cars:
		per_car_stock[String(car.get("id", ""))] = 0
		per_car_tuned[String(car.get("id", ""))] = 0

	var zero_even_tuned: Array = []

	print("=== Eligibility report (%d rallies x %d cars) ===" % [rallies.size(), cars.size()])
	print("")

	for rally in rallies:
		var rid := String(rally.get("id", ""))
		var rname := String(rally.get("name", rid))
		var stock_eligible: Array = []
		var tuned_eligible: Array = []
		var near_misses: Array = []

		for car in cars:
			var cid := String(car.get("id", ""))
			var floor_meta: Dictionary = UpgradeLibrary.max_potential_meta(car, car)

			var stock_ok := RallyLibrary.is_eligible(rally, car)
			var tuned_ok := RallyLibrary.is_eligible(rally, car, floor_meta)

			if stock_ok:
				stock_eligible.append(cid)
				per_car_stock[cid] = int(per_car_stock[cid]) + 1
			if tuned_ok:
				tuned_eligible.append(cid)
				per_car_tuned[cid] = int(per_car_tuned[cid]) + 1

			if not stock_ok:
				var reason := RallyLibrary.ineligibility_reason(rally, car)
				if tuned_ok:
					reason = "(eligible if fully tuned) " + reason
				near_misses.append("    %-14s %s" % [cid, reason])

		var flag := ""
		if stock_eligible.size() < 2:
			flag = "  <-- OUT OF BAND (too few, stock)"
		elif stock_eligible.size() > 4:
			flag = "  <-- OUT OF BAND (too many, stock)"

		print("--- %s (%s) ---%s" % [rname, rid, flag])
		print("  stock eligible (%d): %s" % [stock_eligible.size(), ", ".join(stock_eligible)])
		print("  tuned eligible (%d): %s" % [tuned_eligible.size(), ", ".join(tuned_eligible)])
		if not near_misses.is_empty():
			print("  ineligible / near-misses:")
			for line in near_misses:
				print(line)
		print("")

		if tuned_eligible.is_empty():
			zero_even_tuned.append(rid)

	print("=== Per-car summary (rallies enterable) ===")
	for car in cars:
		var cid := String(car.get("id", ""))
		var stock_count: int = per_car_stock[cid]
		var tuned_count: int = per_car_tuned[cid]
		var flag := ""
		if stock_count == 0:
			flag = "  <-- enters NOTHING stock"
		elif stock_count <= 1:
			flag = "  <-- enters almost nothing stock"
		print("  %-14s stock: %d / %d   tuned: %d / %d%s" % [
			cid, stock_count, rallies.size(), tuned_count, rallies.size(), flag])

	print("")
	if not zero_even_tuned.is_empty():
		push_error("report_eligibility: rally/rallies with ZERO eligible cars even at max potential (unenterable): %s"
			% ", ".join(zero_even_tuned))
		get_tree().quit(1)
		return

	print("=== OK: every rally has at least one eligible car at max potential ===")
	get_tree().quit(0)

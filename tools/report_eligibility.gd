extends Node
# Eligibility report: for every rally x car, reports whether the car can enter,
# using the REAL predicates (RallyLibrary.is_eligible / ineligibility_reason)
# so this report can never drift from the game's actual rule. Flags rallies
# with < 2 or > 4 eligible cars, and cars that can enter almost nothing,
# as authoring signals — not a pass/fail gate.
#
# There is no longer a "tuned" column: rally entry is purely CATEGORICAL
# (car_type / country / doors / cylinders / displacement / drive_mode), so no amount
# of upgrading or detuning changes who is admitted. See
# todo/one-map-four-corners.md > "New task: an eligibility-report tool".
#
# Run via ./report_eligibility.sh (wraps
# `$GODOT --headless --path . res://tools/report_eligibility.tscn`).


func _ready() -> void:
	var rallies: Array = RallyLibrary.RALLIES
	var cars: Array = CarLibrary.CARS

	var per_car: Dictionary = {}
	for car in cars:
		per_car[String(car.get("id", ""))] = 0

	var unenterable: Array = []

	print("=== Eligibility report (%d rallies x %d cars) ===" % [rallies.size(), cars.size()])
	print("")

	for rally in rallies:
		var rid := String(rally.get("id", ""))
		var rname := String(rally.get("name", rid))
		var eligible: Array = []
		var rejected: Array = []

		for car in cars:
			var cid := String(car.get("id", ""))
			var reason := RallyLibrary.ineligibility_reason(rally, car)
			if reason == "":
				eligible.append(cid)
				per_car[cid] = int(per_car[cid]) + 1
			else:
				rejected.append("    %-14s %s" % [cid, reason])

		var flag := ""
		if eligible.size() < 2:
			flag = "  <-- OUT OF BAND (too few)"
		elif eligible.size() > 4:
			flag = "  <-- OUT OF BAND (too many)"

		print("--- %s (%s) ---%s" % [rname, rid, flag])
		print("  eligible (%d): %s" % [eligible.size(), ", ".join(eligible)])
		if not rejected.is_empty():
			print("  ineligible:")
			for line in rejected:
				print(line)
		print("")

		if eligible.is_empty():
			unenterable.append(rid)

	print("=== Per-car summary (rallies enterable) ===")
	for car in cars:
		var cid := String(car.get("id", ""))
		var count: int = per_car[cid]
		var flag := ""
		if count == 0:
			flag = "  <-- enters NOTHING"
		elif count <= 1:
			flag = "  <-- enters almost nothing"
		print("  %-14s enters: %d / %d%s" % [cid, count, rallies.size(), flag])

	print("")
	if not unenterable.is_empty():
		push_error("report_eligibility: rally/rallies with ZERO eligible cars (unenterable): %s"
			% ", ".join(unenterable))
		get_tree().quit(1)
		return

	print("=== OK: every rally has at least one eligible car ===")
	get_tree().quit(0)

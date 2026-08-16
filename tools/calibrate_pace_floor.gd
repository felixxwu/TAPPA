extends Node
# C2 — pace floor. What fraction of the LapTimeModel QSS optimum does a real driver
# actually achieve? That fraction is what RallyLibrary.PACE_MIN_FLOOR (currently 1.10)
# should be set from: it is the hard clamp that stops a rival being given a time no
# human could match, and phase 5 of the rating design (matched machinery) is only safe
# if a player can get within it. See
# docs/superpowers/specs/2026-08-15-car-performance-rating-design.md > Calibration (C2).
#
# HONEST POSTURE, READ THIS BEFORE QUOTING ANY NUMBER FROM THIS TOOL:
# there is no recorded human-time corpus in this repository. This script therefore does
# NOT output a human-performance figure. What it does is inventory the time-like data
# that actually exists, say exactly what each source can and cannot support, and compute
# the one weak indicative band the data does allow — clearly labelled as not sufficient
# to set the floor. If you want a real number, the "WHAT WOULD BE NEEDED" section at the
# bottom says what to collect.
#
# Run:  ./calibrate_pace_floor.sh [-- --profile=user://profile.json]
#   --profile=PATH   profile to inventory (default Save.DEFAULT_PROFILE_PATH)
#   --no-solve       inventory only; skip the (track-generating) indicative band

const OPT_BAND_HEADER := "%-22s %10s %12s %12s %10s %10s"


func _ready() -> void:
	var args := _args()
	var profile_path := String(args.get("profile", Save.DEFAULT_PROFILE_PATH))
	print("=== C2 pace floor — data availability report ===")
	print("current RallyLibrary.PACE_MIN_FLOOR = %.3f (rivals never go below this x optimum)"
		% RallyLibrary.PACE_MIN_FLOOR)
	print("")

	var profile := _load_profile(profile_path)
	var records := _human_records(profile, profile_path)
	_report_other_sources()

	if records.is_empty() or args.has("no-solve"):
		_report_verdict(records, [])
		get_tree().quit(0)
		return

	# --- The one indicative computation the data allows -----------------------
	# A recorded best_combined_ms says nothing about WHICH car set it, so the optimum it
	# should be divided by is unknown. The best that can be done is a BAND: solve every
	# eligible stock car over the rally's stages and bracket the ratio between the
	# fastest car's optimum (ratio ceiling) and the slowest's (ratio floor).
	print("--- indicative human/optimum band (NOT sufficient to set the floor) ---")
	print(OPT_BAND_HEADER % ["rally", "human s", "fastest opt s", "slowest opt s", "ratio lo", "ratio hi"])
	var bands: Array = []
	for rec in records:
		var rally: Dictionary = rec["rally"]
		var tracks: Array = await RallySession._generate_event_tracks(rally)
		var events: Array = rally.get("events", [])
		var sums := _eligible_optimum_sums(rally, tracks, events)
		if sums.is_empty():
			print("%-22s %10.2f  (no eligible stock car — cannot bracket)"
				% [rally.get("id", "?"), float(rec["human_ms"]) / 1000.0])
			continue
		sums.sort()
		var fastest: float = float(sums[0])
		var slowest: float = float(sums[sums.size() - 1])
		var human := float(rec["human_ms"])
		var ratio_hi := human / maxf(fastest, 1.0)   # vs the quickest car it could have been
		var ratio_lo := human / maxf(slowest, 1.0)   # vs the slowest car it could have been
		# Two tells that a stored time was never DRIVEN, and so is not evidence of
		# anything: the dev cheat writes a flat placeholder combined time, and a ratio
		# under 1.0 means "beat the physics optimum in every eligible car", which no
		# driver does. Flagged and excluded rather than silently averaged in.
		var note := ""
		if int(rec["human_ms"]) == Save.DEV_WIN_TIME_MS:
			note = "  <-- DEV CHEAT placeholder (Save.DEV_WIN_TIME_MS), not driven"
		elif ratio_hi < 1.0:
			note = "  <-- IMPOSSIBLE (< optimum in every eligible car), not driven"
		else:
			bands.append({"lo": ratio_lo, "hi": ratio_hi})
		print(OPT_BAND_HEADER % [
			String(rally.get("id", "?")), "%.2f" % (human / 1000.0),
			"%.2f" % (fastest / 1000.0), "%.2f" % (slowest / 1000.0),
			"%.3fx" % ratio_lo, "%.3fx" % ratio_hi] + note)
	print("")
	_report_verdict(records, bands)
	get_tree().quit(0)


# --- Source 1: the local save profile ----------------------------------------

func _human_records(profile: Dictionary, path: String) -> Array:
	print("--- source 1: save profile (%s) ---" % path)
	if profile.is_empty():
		print("  NOT PRESENT / unreadable. No recorded times on this machine.")
		print("")
		return []
	var out: Array = []
	var rallies: Dictionary = profile.get(Save.KEY_RALLIES, {})
	for rid in rallies:
		var rec: Dictionary = rallies[rid]
		var ms := int(rec.get("best_combined_ms", 0))
		if ms <= 0:
			continue
		var rally := RallyLibrary.by_id(String(rid))
		if rally.is_empty():
			print("  %s: best_combined_ms=%d but no such rally in RALLIES (stale save entry)" % [rid, ms])
			continue
		out.append({"rally": rally, "human_ms": ms})
	print("  rallies with a recorded best_combined_ms: %d" % out.size())
	print("  CAVEATS, all of them fatal to using this as a pace corpus:")
	print("    * the time is RALLY-COMBINED, not per stage — a single bad stage is invisible")
	print("    * the CAR that set it is not recorded, so there is no optimum to divide by")
	print("    * neither is the car's tune, its damage state, or the weather rolled")
	print("    * it is one player on one machine — n=%d is not a distribution" % out.size())
	print("")
	return out


# --- Source 2..n: everything else that looks like a time ----------------------

func _report_other_sources() -> void:
	print("--- source 2: rival / ghost times (tools/audit_ghost_pace.gd) ---")
	print("  UNUSABLE AS EVIDENCE, and not because it is missing: rival times are DERIVED")
	print("  from LapTimeModel.optimum_ms by multiplying it by the pace factors, then clamped")
	print("  at PACE_MIN_FLOOR itself (RallyLibrary.generate_opponent_field). Measuring them")
	print("  against the optimum measures the constants that produced them — it is circular.")
	print("  tools/audit_ghost_pace.gd is likewise a solver-vs-solver audit: it reports whether")
	print("  the ghost's grip/power solve can HIT a target pace, never whether a human can.")
	print("")
	print("--- source 3: challenge results (profile challenge_results / challenge_run) ---")
	print("  Per-stage times DO exist here (challenge_run.stage_times_ms), which is the shape")
	print("  a corpus needs — but only for an IN-PROGRESS run, and finished periods keep only")
	print("  a cumulative_ms. Same missing-car problem as source 1.")
	print("")
	print("--- source 4: global stage leaderboards ---")
	print("  Posted times leave the game and are not mirrored into this repository, so nothing")
	print("  here can read them. This is the one existing pipeline that ALREADY carries")
	print("  per-stage human times, and is the cheapest place to get a real corpus from.")
	print("")


func _report_verdict(records: Array, bands: Array) -> void:
	print("=== VERDICT ===")
	print("MEASURED: nothing that can set PACE_MIN_FLOOR. There is no human-time corpus in")
	print("this repository — no per-stage time paired with the car that set it.")
	if bands.is_empty():
		print("NOT MEASURED: the human/optimum ratio. %s"
			% ("No recorded rally best times were found at all." if records.is_empty()
				else "Recorded times exist but could not be bracketed."))
	else:
		var lo := INF
		var hi := -INF
		for b in bands:
			lo = minf(lo, float(b["lo"]))
			hi = maxf(hi, float(b["hi"]))
		print("INDICATIVE ONLY: across %d PLAUSIBLY-DRIVEN rally best times (dev-cheat" % bands.size())
		print("  placeholders and sub-optimum times excluded above) the human/optimum ratio")
		print("  falls somewhere in [%.2fx .. %.2fx], the width being the unknown car, not" % [lo, hi])
		print("  driver spread. One player, no per-stage resolution: do NOT set the floor from this.")
	print("")
	print("=== WHAT WOULD BE NEEDED TO SET PACE_MIN_FLOOR HONESTLY ===")
	print("  1. Record, at every stage finish: stage time, the rally+event ids, the car")
	print("     instance and its merged meta (or its CarPerformance rating), and the")
	print("     LapTimeModel optimum solved for THAT car on THAT track. The ratio must be")
	print("     computed at finish time, when every input is still known.")
	print("  2. Persist it as an append-only list, separate from best_combined_ms (a BEST")
	print("     time is a max-of-attempts and biases the distribution optimistically).")
	print("  3. Collect across several players and a spread of cars — a floor derived from")
	print("     one driver in one car is a floor for that driver in that car.")
	print("  4. Then set PACE_MIN_FLOOR at (or just under) the FASTEST observed ratio, not")
	print("     the mean: it is a clamp against impossible rival times, so it has to sit")
	print("     below what the best observed human actually did.")
	print("  Until then PACE_MIN_FLOOR = %.2f remains an unvalidated authored guess, and the"
		% RallyLibrary.PACE_MIN_FLOOR)
	print("  design's phase-5 gate (matched machinery makes P1 unreachable) is UNANSWERED.")


# --- Helpers ------------------------------------------------------------------

# Combined optimum over a rally's stages, for every stock car eligible to enter it.
func _eligible_optimum_sums(rally: Dictionary, tracks: Array, events: Array) -> Array:
	var out: Array = []
	for car in CarLibrary.CARS:
		if not RallyLibrary.is_eligible(rally, car):
			continue
		var total := 0.0
		for i in events.size():
			if i >= tracks.size():
				continue
			var event: Dictionary = (events[i] as Dictionary).duplicate()
			event["region"] = rally.get("region", "")
			total += float(LapTimeModel.optimum_ms(tracks[i], car, event))
		if total > 0.0:
			out.append(total)
	return out


func _load_profile(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


# `--key=value` / `--flag` pairs from the user args (everything after a bare `--`).
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

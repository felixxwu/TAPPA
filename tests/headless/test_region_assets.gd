extends GutTest
# Catalogue-CONTRACT tests for the shipped RegionLibrary.REGIONS — the one class of
# region test that is allowed to read the real catalogue rather than a synthetic one
# (test_region_library.gd covers the LOGIC against synthetic regions).
#
# Deliberately nothing here pins an authored value. No test asserts which regions exist,
# which texture a region picked, how tall its trees are, or how a mix is weighted — all
# of that is content a designer retunes, and a test that fails when they do is a test
# that stops them. What IS asserted is the contract every reasonable authoring must
# satisfy: the paths resolve, the profiles are ones Foliage knows, and the numbers are
# usable. Those hold no matter what anyone authors, and they are exactly the mistakes
# that ship as an invisible or missing tree rather than as an error.


# NOTE on what is deliberately NOT here: "every authored tree texture resolves". That
# looks like the obvious first test for a new region, and it is already covered — and
# covered more strongly — by test_snow_region.gd::
# test_every_region_tree_texture_traces_to_a_solid_silhouette, which loads every
# species' texture across every region AND traces it, catching both a missing file and
# the far nastier failure of a file that loads but silhouettes to nothing.


# `profile` selects which GameConfig sizing block Foliage.spawn_trees uses, and it does
# so by comparing against "region" — so ANY other string silently means the home
# profile. A typo'd profile is therefore not an error, just a tree that is quietly the
# wrong size, which is worth failing loudly instead.
func test_every_species_names_a_known_sizing_profile() -> void:
	for region in RegionLibrary.all():
		var look := RegionLibrary.look_of(String(region.get("id", "")))
		for species in RegionLibrary.tree_mix(look):
			var profile := String((species as Dictionary).get("profile", ""))
			assert_true(profile == "home" or profile == "region",
				"region %s names an unknown sizing profile: '%s'"
					% [region.get("id", "?"), profile])


# Sanity guards on the mix numbers — these rule out values that are broken outright
# (a zero-area billboard, a species that can never be drawn), not values that are merely
# a different design choice. A designer doubling a tree's height or reweighting a mix
# passes all of this.
func test_species_weights_and_scales_are_usable() -> void:
	for region in RegionLibrary.all():
		var rid := String(region.get("id", ""))
		var mix := RegionLibrary.tree_mix(RegionLibrary.look_of(rid))
		assert_gt(mix.size(), 0, "region %s resolves to an empty tree mix" % rid)
		var total := 0.0
		for species in mix:
			var s := species as Dictionary
			var weight := float(s.get("weight", 0.0))
			assert_gt(weight, 0.0,
				"region %s has a species that can never be drawn" % rid)
			total += weight
			# Omitted entirely is the common case and means Vector2.ONE — only an
			# authored one is checked.
			if s.has("size_scale"):
				var scale: Vector2 = s["size_scale"]
				assert_true(is_finite(scale.x) and is_finite(scale.y),
					"region %s has a non-finite size_scale" % rid)
				assert_gt(scale.x, 0.0, "region %s has a zero-width species" % rid)
				assert_gt(scale.y, 0.0, "region %s has a zero-height species" % rid)
		assert_gt(total, 0.0, "region %s has no drawable weight at all" % rid)


# `look_from` is resolved by look_of walking to the named parent. A dangling name is not
# an error there — the parent resolves to {} and the child silently inherits nothing,
# which reads as "the region ignored half its own look". One hop only is intentional
# (look_of does not recurse), so a parent that itself has a look_from would also quietly
# lose a generation; assert both.
func test_every_look_from_names_a_real_region_that_is_not_itself_derived() -> void:
	for region in RegionLibrary.all():
		var parent := String(region.get("look_from", ""))
		if parent == "":
			continue
		var rid := String(region.get("id", ""))
		assert_ne(parent, rid, "region %s inherits its look from itself" % rid)
		assert_ne(RegionLibrary.index_of(parent), -1,
			"region %s inherits from an unknown region '%s'" % [rid, parent])
		assert_eq(String(RegionLibrary.by_id(parent).get("look_from", "")), "",
			"region %s inherits from %s, which is itself derived — look_of resolves"
				% [rid, parent] + " one hop only, so a generation would be dropped")


# Every RegionStageLibrary key must name a region that exists in RegionLibrary — a
# stage tagged with a region that resolves to {} drives with no look overrides at all
# rather than failing.
func test_every_region_stage_library_key_resolves_to_a_look() -> void:
	for rid in RegionStageLibrary.region_ids():
		assert_ne(RegionLibrary.index_of(rid), -1,
			"RegionStageLibrary region '%s' is not in the RegionLibrary catalogue" % rid)


# The REVERSE direction: every authored region must actually have stages, or
# RegionStagePool.draw silently returns nothing for it and the region is unplayable
# despite existing. Unlike the old rally-tag model, RegionStageLibrary keys ARE the
# reachability — this just confirms the two authored tables (REGIONS, STAGES) agree.
func test_every_region_has_authored_stages() -> void:
	var staged := {}
	for rid in RegionStageLibrary.region_ids():
		staged[rid] = true
	for region in RegionLibrary.all():
		var rid := String(region.get("id", ""))
		assert_true(staged.has(rid),
			("region '%s' is in REGIONS but has no entry in RegionStageLibrary.STAGES, " +
				"so RegionStagePool.draw returns nothing for it — add an 8-slot x 3-candidate " +
				"entry keyed '%s' to scripts/region_stage_library.gd.") % [rid, rid])


# Every `res://` path authored ANYWHERE in a REGIONS entry must point at a real file.
# Tree textures are traced more strongly by test_snow_region.gd, but a region's
# sky_panorama / grass_texture / gravel_texture (and any path field added later — this
# walks the whole dict) had NO guard at all: a dangling path here loads as null at
# runtime and ships as an untextured world, with every test green. (Found by the
# small-model-readiness loop, round 003: a probe invented three plausible-looking
# texture filenames by analogy with the -greece/-snow naming convention — none existed.
# Never invent an asset filename: list textures/ and use what is actually there.)
#
# This pins no authored value: it does not care which file a region picked, only that
# the file it names exists. Retuning any look passes.
func test_every_authored_region_resource_path_resolves() -> void:
	var checked := 0
	for region in RegionLibrary.all():
		checked += _assert_paths_resolve(region, String(region.get("id", "?")))
	assert_gt(checked, 0, "the path walk found no res:// strings at all — walker broken?")


func _assert_paths_resolve(value: Variant, where: String) -> int:
	var checked := 0
	match typeof(value):
		TYPE_STRING:
			var s := String(value)
			if s.begins_with("res://"):
				checked += 1
				assert_true(ResourceLoader.exists(s) or FileAccess.file_exists(s),
					"region '%s' names '%s', which does not exist — never invent an " % [where, s] +
					"asset filename; list textures/ and use a real file")
		TYPE_DICTIONARY:
			for k in value:
				checked += _assert_paths_resolve(value[k], where)
		TYPE_ARRAY:
			for item in value:
				checked += _assert_paths_resolve(item, where)
	return checked

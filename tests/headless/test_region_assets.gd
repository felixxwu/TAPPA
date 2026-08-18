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


# Every rally's region tag must name a region that exists. RallyLibrary's own suite
# asserts this too; it is repeated here against the LOOK path specifically, because a
# rally tagged with a region that resolves to {} drives a stage with no look overrides
# at all rather than failing.
func test_every_rally_region_resolves_to_a_look() -> void:
	for rally in RallyLibrary.all():
		var rid := String(rally.get("region", ""))
		assert_ne(RegionLibrary.index_of(rid), -1,
			"rally %s names region '%s', which is not in the catalogue"
				% [rally.get("id", "?"), rid])


# The REVERSE direction of the test above, and the one that actually bites when someone
# ADDS a region. A region is only ever reached through a rally's `region` tag — nothing
# else selects one — so an entry added to REGIONS that no rally names is dead data: it
# never renders, it never appears on the map, and every region test above still passes
# because they all iterate REGIONS rather than what the game can reach. That is a silent
# half-finished feature, which is why it is asserted here rather than left to review.
# (Found by the small-model-readiness loop, round 002: a probe added a complete, valid
# region and stopped, because nothing told it the rally tag was the other half.)
#
# This pins no authored value: it does not care WHICH regions exist, how many, or which
# rallies claim them — only that the two authored tables agree. Retuning either passes.
func test_every_region_is_reachable_from_at_least_one_rally() -> void:
	var claimed := {}
	for rally in RallyLibrary.all():
		claimed[String(rally.get("region", ""))] = true
	for region in RegionLibrary.all():
		var rid := String(region.get("id", ""))
		assert_true(claimed.has(rid),
			("region '%s' is in REGIONS but no rally in RallyLibrary.RALLIES tags it, " +
			"so nothing can ever reach it — give a rally \"region\": \"%s\"") % [rid, rid])


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

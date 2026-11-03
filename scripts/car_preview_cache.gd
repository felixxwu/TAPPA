extends Node
# Docs: features/card-carousel.md — update in the same change as this file.
# Tests: tests/headless/test_car_preview_cache.gd — extend in the same change.
#
# Autoload "CarPreviewCache": a SESSION-lifetime cache of CarCardPreview instances, one
# per car (owned or unowned catalogue), keyed by key_for(car_ref). CarProp.spawn (a full
# car.tscn instantiation, every embedded car glb body before pruning) is the genuinely
# per-car-expensive half of a CarCardPreview — the SubViewport/camera/light are cheap by
# comparison — so caching by CAR rather than by screen slot or by page instance is what
# actually removes the lag of a car card list (the title's starter choice, the rest stop's
# Garage) showing a car nobody had looked at yet this session.
#
# An AUTOLOAD, not a Dictionary a page owns itself: pages are torn down and rebuilt on every
# visit and scene change, so a cache scoped to one would lose everything at exactly the point
# a persistent one is supposed to help. A page PARKS its previews before it frees its cards
# (CardUI.park_previews) so the next visit reuses them.

var _cache: Dictionary = {}
var _graveyard: Control


func _ready() -> void:
	_graveyard = Control.new()
	_graveyard.visible = false
	add_child(_graveyard)
	# A replaced world (a new world, a cloud download, a wipe, the benchmark ending) brings other
	# owned cars, whose instance ids can repeat the old ones — so the old previews must go.
	WorldSession.world_changed.connect(drop_owned)


# A stable cache key for a car ref — an owned-car Dictionary or a CarLibrary catalogue
# index, the same two shapes CarCardPreview accepts. Prefixed so an owned car's
# instance_id and a catalogue index can never collide.
static func key_for(car_ref) -> String:
	if car_ref is Dictionary:
		# A fitted wing changes the model, so it needs its own preview.
		return "owned:%d:%d" % [int(car_ref.get("instance_id", -1)), int(UpgradeLibrary.aero_fitted(car_ref))]
	return "catalog:%d" % int(car_ref)


# The cached preview for `car_ref`, building one if this is the first time it's been
# asked for. Always returned UNPARENTED (pulled out of the graveyard if it was resting
# there) — the caller owns deciding where it actually shows.
#
# A cache hit whose node is no longer VALID is treated as a miss, not an error. A preview
# actively shown on a card (i.e. NOT parked in the graveyard) at the moment its whole page
# is torn down without parking it first is
# freed right along with that card as a normal side effect of Node.free() cascading to
# children; this cache has no hook into every place that can happen, so rather than try to
# park every live preview before every possible teardown, a stale dictionary entry is
# simply rebuilt the next time it's asked for.
func get_or_build(car_ref) -> CarCardPreview:
	var key := key_for(car_ref)
	# Fetched UNTYPED on purpose: a Dictionary can hold a stale Object reference (see the
	# comment below), and assigning THAT straight into a CarCardPreview-typed variable is
	# what actually threw "Trying to assign invalid previously freed instance" — the
	# typed assignment itself validates the object, before any is_instance_valid guard of
	# ours gets a chance to run.
	var cached = _cache.get(key)
	# is_instance_valid alone misses a node that's been queue_free()'d but not yet
	# actually deleted (its whole PAGE torn down a moment ago, say) — still "valid" by
	# that check, but reparenting it now crashes the same way.
	# is_instance_valid FIRST: a freed object can compare unequal to null, so a
	# `cached != null and ...` guard let a freed preview through to the typed assignment.
	if not is_instance_valid(cached) or (cached as Node).is_queued_for_deletion():
		cached = null
	var preview: CarCardPreview = cached
	if preview == null:
		preview = CarCardPreview.new(car_ref)
		_cache[key] = preview
		return preview
	# Hand it back unparented wherever it was resting: the graveyard, or a page that was
	# queue_free()d without parking its previews (the page is still its parent until the
	# deferred free runs, so a plain add_child by the caller would fail).
	var parent := preview.get_parent()
	if parent != null:
		parent.remove_child(preview)
	return preview


# Free every owned-car preview (keys "owned:*"). Catalogue previews stay — those cars exist
# in every world. Connected to WorldSession.world_changed in _ready.
func drop_owned() -> void:
	for key in _cache.keys():
		if not String(key).begins_with("owned:"):
			continue
		var preview = _cache[key]
		_cache.erase(key)
		if is_instance_valid(preview):
			var node := preview as Node
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()


# Park a preview the caller is done showing FOR NOW, without freeing it — a later
# get_or_build for the same car reuses it instead of spawning again.
func park(preview: CarCardPreview) -> void:
	var parent := preview.get_parent()
	if parent != null:
		parent.remove_child(preview)
	_graveyard.add_child(preview)

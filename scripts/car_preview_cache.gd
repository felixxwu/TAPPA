extends Node
# Docs: features/card-carousel.md — update in the same change as this file.
# Tests: tests/headless/test_car_preview_cache.gd — extend in the same change.
#
# Autoload "CarPreviewCache": a SESSION-lifetime cache of CarCardPreview instances, one
# per car (owned or unowned catalogue), keyed by key_for(car_ref). CarProp.spawn (a full
# car.tscn instantiation, every embedded car glb body before pruning) is the genuinely
# per-car-expensive half of a CarCardPreview — the SubViewport/camera/light are cheap by
# comparison — so caching by CAR rather than by screen slot or by page instance is what
# actually removes the lag reported on the CAR page when the selection moved to a car
# nobody had looked at yet this session.
#
# An AUTOLOAD, not a Dictionary HubShell owns itself: HubShell is torn down and rebuilt
# from scratch every time a run ends and the player returns to the hub
# (Scenes.change_to), so a cache scoped to it would lose everything at exactly the point
# a persistent one is supposed to help. warm_all() is meant to be kicked off once, early
# (HubShell._ready()), and is cheap to call again on every later hub visit — cars already
# cached are skipped instantly, so only genuinely NEW cars (just bought, say) cost anything.

var _cache: Dictionary = {}
var _graveyard: Control
var _warming := false

# How many NEW previews warm_all builds before yielding a frame. Spreading the cost out
# is the whole point — building every car SYNCHRONOUSLY in one call is exactly the
# original "the game freezes" bug this cache exists to avoid, just moved to a different
# trigger (hub startup) instead of removed.
const _WARM_PER_FRAME := 1


func _ready() -> void:
	_graveyard = Control.new()
	_graveyard.visible = false
	add_child(_graveyard)


# A stable cache key for a car ref — an owned-car Dictionary or a CarLibrary catalogue
# index, the same two shapes CarCardPreview accepts. Prefixed so an owned car's
# instance_id and a catalogue index can never collide.
static func key_for(car_ref) -> String:
	if car_ref is Dictionary:
		return "owned:%d" % int(car_ref.get("instance_id", -1))
	return "catalog:%d" % int(car_ref)


# The cached preview for `car_ref`, building one if this is the first time it's been
# asked for. Always returned UNPARENTED (pulled out of the graveyard if it was resting
# there) — the caller owns deciding where it actually shows.
#
# A cache hit whose node is no longer VALID is treated as a miss, not an error. A preview
# actively shown on a card (i.e. NOT parked in the graveyard) at the moment its whole page
# is torn down — leaving the CAR page, a run starting, HubShell itself being freed — is
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
	if cached != null and (not is_instance_valid(cached) or (cached as Node).is_queued_for_deletion()):
		cached = null
	var preview: CarCardPreview = cached
	if preview == null:
		preview = CarCardPreview.new(car_ref)
		_cache[key] = preview
		return preview
	if preview.get_parent() == _graveyard:
		_graveyard.remove_child(preview)
	return preview


# Park a preview the caller is done showing FOR NOW, without freeing it — a later
# get_or_build for the same car reuses it instead of spawning again. Also what actually
# seats a freshly built preview into the tree in the first place (see warm_all): a
# CarCardPreview does nothing until it enters the SceneTree (_ready is what triggers the
# CarProp spawn), so a warmed car that's never shown still needs parking somewhere.
func park(preview: CarCardPreview) -> void:
	var parent := preview.get_parent()
	if parent != null:
		parent.remove_child(preview)
	_graveyard.add_child(preview)


# Build (and park) every current owned + unowned-catalogue car's preview, a few at a time
# across separate frames. Idempotent and safe to call from every HubShell._ready() — a
# car already cached is skipped in the same frame, so a second/third call (every later
# hub visit) is cheap regardless of how many cars exist. Awaiting the call means waiting
# for the WHOLE cache: a call that arrives while a pass is already running WAITS for that
# pass (and then runs its own, instant one) rather than returning "done" with cars still
# building — which is what lets HubShell._ready hold its loading screen until warming has
# genuinely finished.
func warm_all() -> void:
	while _warming:
		await get_tree().process_frame
	_warming = true
	var refs: Array = []
	for car in Save.profile.get(Save.KEY_CARS, []):
		var entry: Dictionary = car
		if int(entry.get("instance_id", -1)) >= 0:
			refs.append(entry)
	var catalogue := CarLibrary.all()
	for index in catalogue.size():
		var model_id := String(catalogue[index].get("id", ""))
		if model_id != "" and not Save.owns_model(model_id):
			refs.append(index)

	var since_yield := 0
	for car_ref in refs:
		if not is_instance_valid(self):
			return
		if not _cache.has(key_for(car_ref)):
			park(get_or_build(car_ref))
			since_yield += 1
			if since_yield >= _WARM_PER_FRAME:
				since_yield = 0
				await get_tree().process_frame
	_warming = false

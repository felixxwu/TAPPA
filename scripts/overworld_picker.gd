class_name OverworldPicker
extends Node3D
# THE DIEGETIC CAR PICKER — choosing a car without leaving the hub.
#
# The player drives to a rally, the detail card opens, and pressing Enter used to LOAD hq.tscn
# and walk them round the car park. Now the camera swings to a three-quarter view in front of
# the very car they parked, a menu opens over it, and the car in front of them is REPLACED as
# they browse. The car never moves: it stays exactly where they stopped.
#
# Design decision D3 is unchanged in intent — the car you drove here is not necessarily the car
# you want to race, so there is still a pick. Only its VENUE moved (features/overworld.md).
#
# TWO MODES, ONE PICKER, because the diegetic look must not drift between them:
#
#   RALLY    the owned cars that can enter this rally. Confirm starts the rally.
#   STARTER  the starter pool, on a profile that owns nothing at all. Confirm GRANTS the car.
#            There is no cancel — a player cannot decline to own a car and drive off — so this
#            mode installs no back action at all (which also leaves Esc free for the pause menu).
#
# WHAT IT DOES NOT DO: reshape the live player car while browsing. That is deliberate and it is
# the crux of the implementation —
#
#   * `car.gd::respawn`'s own comment says swapping cars by repeatedly reshaping ONE body is what
#     left cars "spinning in place with no traction": a VehicleBody3D accumulates stale
#     wheel/suspension state when its wheels are relocated again and again. `apply_owned` is that
#     pipeline (it relocates wheels and resets the pose), which is why the tuning lift uses
#     `_rederive_live_config` instead for a mere upgrade change.
#   * `Car.respawn` (a fresh instance) is the sanctioned alternative, but in this hub a dozen
#     things hold the car — CameraManager's two cameras (one is a CHILD of it), the zone manager,
#     the map, the garage, the surface/exhaust effects, SpeedLines, TireMarks, and 21 `$Car`
#     lookups — so re-instantiating per browse step is a re-pointing exercise, not a swap.
#
# So BROWSING shows a frozen `CarProp` standing exactly where the real car is, with the real car
# hidden behind it. The prop is the established recipe (the same one the zone ghost cars,
# the HQ lineup and the podium use), cached per candidate, and it touches no physics.
#
# The REAL car is reshaped exactly ONCE, and only in STARTER mode, when the grant happens — a
# one-time event, following the tuning lift's own recipe (freeze -> apply_owned -> re-seat ->
# clear the droop -> hand back). The RALLY mode never reshapes it at all: confirming leaves for
# the stage scene, which fields the chosen car itself.

signal closed()                                  # cancelled; the host puts the card back up
signal started(rally_id: String, instance_id: int)   # confirmed a rally start
signal granted(instance_id: int)                 # confirmed a starter grant

enum Mode { RALLY, STARTER }

# How far AHEAD of the car's nose the camera always stands, whatever the authored offset says.
# Not a look tunable — it is what makes a colinear `look_at` unreachable (see `showroom_pose`).
const MIN_STANDOFF_M := 0.75
# Below this |forward x up| the two are parallel enough for `Basis.looking_at` to warn.
const COLINEAR_EPSILON := 0.001
# A width floor for the bar's name box, px. Without it the bar's whole width changes with every car
# name, so the chevrons walk left and right as you cycle — the same "one panel you keep opening
# rather than a new one each time" reasoning `RallyDetail.BODY_WIDTH` exists for. A layout constant,
# not a look dial.
const BAR_NAME_WIDTH_PX := 320.0 * UITheme.UI_SCALE

# The prop stands where the real car is; nothing here moves the car (the user was explicit).
# These are the CAMERA's numbers and they are authored — see GameConfig.overworld_picker_*.

var mode := Mode.RALLY

var _car: Variant = null              # the live player car, held dynamically (see the garage)
var _car_scene: PackedScene = null
# The STARTER POOL's model ids, INJECTED. Defaults to the catalogue's own
# `CarLibrary.STARTER_MODEL_IDS`, which is what production wants; a caller passes its own so the
# starter flow can be exercised against a synthetic roster without this file — or a test — ever
# naming a shipped car. (That const is catalogue CONTENT: its own comment warns that the set is
# load-bearing for playability and gets revisited, so nothing outside the catalogue should hardcode
# it and no test should depend on which ids are in it.)
var _starter_ids: Array = []
# `Callable(hidden: bool)` — hide/restore the world's ZONE VISUALS while the showroom shot is up.
# Injected, so this file never reaches into the hub's tree or knows what a zone is; the host owns
# what "zone visuals" means (`Overworld._set_zone_visuals_hidden`).
var _hide_zones := Callable()
var _visuals := true
var _rally: Dictionary = {}
# The candidate list, in display order: owned cars (RALLY) or catalogue previews (STARTER).
var _cars: Array[Dictionary] = []
var _index := 0
var _open := false

# The showroom camera. Its own Camera3D, made `current` — the protocol the start-line reveal's
# orbit camera established. CameraManager writes no transforms of its own, so it does not fight
# this; it hands control back through `activate_current()`.
var _cam: Camera3D = null
# THE FLY-OUT. On close the showroom camera does not cut back to the driving view — it flies to
# wherever the player's chosen camera is sitting and hands over on arrival, so leaving the picker
# reads as one continuous move rather than a jump. Same shape as start_line.gd's reveal fly
# (capture the pose, smoothstep across, snap exactly on the last frame).
#
# Driven from THIS node's own _process, not the host's `update()`: the host stops calling that the
# moment the picker closes, and the whole point is that the move outlives the close. Processing is
# switched on only while a fly is in flight, so a closed picker costs nothing.
# Ground height under a world point, injected by the host. The contact plane the prop stands on is
# read from THIS rather than derived from the real car's pose: during the starter pick the picker
# opens on boot, before the car has fallen its `spawn_clearance`, so the car's own origin is metres
# above where it will end up and every prop inherited that error exactly.
var _ground_at := Callable()

var _flying := false
var _fly_t := 0.0
var _fly_from := Transform3D.IDENTITY
var _fly_from_fov := 70.0
var _cam_was_fov := 0.0

# The frozen prop currently standing in for the car, and the per-candidate cache.
var _prop: Node3D = null
var _props: Dictionary = {}           # candidate key -> prop node
var _prop_parking: Node3D = null      # holds the props nobody is showing

# The real car's collision layer while we have it hidden, or -1 when we have not taken it. Restored
# on hand-back like the freeze and the visibility — take only your own, put back only your own.
var _car_layer_was := -1
# Did WE freeze the real car / hide it? Restored on close, and only if we changed it.
var _car_was_frozen := false
var _car_hidden := false
# Did WE hide the zone layer? Tracked so restoring is idempotent and so a double-open cannot leave
# the world's zones hidden for the rest of the session — the same take-only-your-own discipline the
# car's freeze and the control lock use.
var _zones_hidden := false

# --- UI ---------------------------------------------------------------------------------
var _layer: CanvasLayer = null
var _ui_root: Control = null
var _page: VBoxContainer = null
var _name_label: Label = null
var _stats_label: Label = null
var _reason_label: Label = null
var _prev_button: Button = null
var _next_button: Button = null
var _confirm: Button = null
var _back: Button = null


# `opts`:
#   car        the live player car        REQUIRED for the camera pose and the prop's seat.
#   car_scene  PackedScene of car.tscn    optional; without it no prop is built.
#   visuals    bool                       false = no camera, no prop (the Control tree is still
#                                          built — a Control needs no renderer, so the whole
#                                          menu and its navigation stay testable headless).
func setup(opts: Dictionary) -> void:
	_car = opts.get("car", null)
	_car_scene = opts.get("car_scene", null)
	_visuals = bool(opts.get("visuals", true))
	_ground_at = opts.get("ground_at", Callable())
	_starter_ids = opts.get("starter_ids", CarLibrary.STARTER_MODEL_IDS)
	_hide_zones = opts.get("hide_zones", Callable())
	_prop_parking = Node3D.new()
	_prop_parking.name = "PropCache"
	_prop_parking.visible = false
	add_child(_prop_parking)
	_build_ui()


# --- Opening and closing ----------------------------------------------------------------


## Open on the owned cars that can enter `rally`. False (and nothing opens) when the player owns
## nothing that could ever enter it — the host keeps the card up and says so, rather than
## presenting an empty showroom.
func open_for_rally(rally: Dictionary) -> bool:
	_rally = rally
	return _open_with(Mode.RALLY, eligible_cars(rally))


## Open on the starter pool. False if the pool is empty (a synthetic roster).
func open_for_starter() -> bool:
	_rally = {}
	var pool := starter_cars(_starter_ids)
	if pool.is_empty():
		# NOTHING TO OFFER. Loud, because on a carless profile this is the difference between a
		# player choosing their first car and a player driving a loaner they can never race — but
		# still a refusal rather than an empty showroom, so the hub stays playable.
		push_error("OverworldPicker: the starter pool is empty — no starter pick can be offered.")
		return false
	return _open_with(Mode.STARTER, pool)


func _open_with(p_mode: int, cars: Array[Dictionary]) -> bool:
	if cars.is_empty():
		return false
	mode = p_mode as Mode
	_cars = cars
	_index = _initial_index()
	_open = true
	_take_over_car()
	# CLEAR THE VIEW. The player is by definition parked ON a rally zone when this opens — that is
	# how it opened — so the zone's light tube is a translucent column standing around the very car
	# they are trying to look at, its marker and star row float directly above it, and a car-unlock
	# zone parks a full-size ghost car beside it. All of it is between the camera and the subject.
	# Handled through an injected hook rather than by reaching into the hub (see `_hide_zones`), and
	# restored in `close()` — the one funnel every non-confirming exit passes through.
	_set_zones_hidden(true)
	_build_camera()
	# SHOW THE MENU BEFORE FILLING IT, exactly as the garage's `enter()` documents: `UITheme.
	# is_focusable` (which every focus decision goes through, including MenuNav's own fallback)
	# requires `is_visible_in_tree()`, so a page filled while its CanvasLayer is hidden resolves
	# nothing focusable and comes up with a dead cursor no key press can revive.
	if _layer != null:
		_layer.visible = true
	# The bar's SHAPE never changes with the candidate set (that was the row list's problem — two
	# rallies admitting the same number of cars left the previous one's names on screen), so opening
	# is just a re-dress.
	_refresh()
	return true


## Cancel. RALLY mode only — STARTER installs no back action, so nothing calls this there.
func close() -> void:
	if not _open:
		return
	_open = false
	if _layer != null:
		_layer.visible = false
	_park_prop()
	_release_camera()
	_hand_car_back()
	_set_zones_hidden(false)
	closed.emit()


func is_open() -> bool:
	return _open


## Whether the zone visuals are currently hidden on this picker's account. The test seam, and the
## reason it is tracked rather than inferred: the hook is a one-way call into the host, so this is
## the only place that can answer "did we hide them and have we put them back".
func zones_hidden() -> bool:
	return _zones_hidden


func _set_zones_hidden(hidden: bool) -> void:
	if _zones_hidden == hidden or not _hide_zones.is_valid():
		return
	_zones_hidden = hidden
	_hide_zones.call(hidden)


# --- The candidate sets -----------------------------------------------------------------


## The owned cars worth showing for `rally`: eligible as built, OR ineligible on drive mode
## alone and therefore convertible. EXACTLY the car park's `_can_ever_enter` filter, through the
## shared `RallyDetail` decisions — the one eligibility rule, never re-derived. A car that can
## never enter (wrong body, country, doors) is HIDDEN rather than greyed, as the car park hides
## it; a convertible one is SHOWN with the rally's own reason and a dead Confirm, because
## converting it is a garage decision with a star price on screen.
static func eligible_cars(rally: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for car in Save.profile.get(Save.KEY_CARS, []):
		var owned: Dictionary = car
		var entry := CarLibrary.for_owned(owned)
		if entry.is_empty():
			continue     # a model the catalogue no longer has
		if bool(RallyDetail.entry_plan(rally, owned)["eligible"]) \
				or RallyDetail.convertible_for(rally, owned, entry):
			out.append(owned)
	return out


## The starter pool as pick-able entries. Not owned cars — the profile owns nothing yet — so each
## carries the CarLibrary index and id the grant needs, in the given order.
##
## An id the catalogue cannot resolve is SKIPPED AND REPORTED rather than carried as a hole: an
## unresolvable entry would reach `CarProp.spawn` and `Save.grant_car` as a car that does not exist.
## This is reachable in production, not only under a synthetic roster — `STARTER_MODEL_IDS` is a
## hand-maintained list of ids in a catalogue that gets renamed and retuned, which is exactly what
## its own comment warns about — so it is loud (this repo prefers loud holes to silent ones) and it
## degrades: a pool that resolves to NOTHING returns empty, and every caller below treats empty as
## "do not open", rather than anyone indexing into it.
static func starter_cars(model_ids: Array = CarLibrary.STARTER_MODEL_IDS) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var missing := PackedStringArray()
	for model_id in model_ids:
		var idx := CarLibrary.index_of(String(model_id))
		if idx < 0:
			missing.append(String(model_id))
			continue
		out.append({"model_id": String(model_id), "index": idx, "instance_id": -1})
	if not missing.is_empty():
		push_error(("OverworldPicker: %d starter car id(s) do not resolve in the catalogue: %s."
			+ " A fresh profile can only be granted one of the ids that DO resolve"
			+ " (%d left).") % [missing.size(), ", ".join(missing), out.size()])
	return out


func candidates() -> Array[Dictionary]:
	return _cars


func focused_index() -> int:
	return _index


func focused_car() -> Dictionary:
	return _cars[_index] if _index >= 0 and _index < _cars.size() else {}


## Why the focused car cannot enter, or "" when it can. The rally's OWN sentence
## (`RallyLibrary.ineligibility_reason`), never a re-worded copy. Always "" in STARTER mode:
## nothing gates a first car.
func reason() -> String:
	if mode == Mode.STARTER or _rally.is_empty():
		return ""
	var owned := focused_car()
	if owned.is_empty():
		return ""
	var entry := CarLibrary.for_owned(owned)
	if entry.is_empty():
		return ""
	return RallyLibrary.ineligibility_reason(_rally,
		UpgradeLibrary.effective_meta(owned, entry))


## Can the focused car be confirmed? The car park leaves this to a disabled button alone; here it
## is a predicate, so the press path can re-check it rather than trusting the button's state.
func can_confirm() -> bool:
	return _open and not focused_car().is_empty() and reason() == ""


# --- Browsing ---------------------------------------------------------------------------


## Cycle the selection by `step`, WRAPPING — the house behaviour for a selector
## (`hq.gd::_cycle_lift_car` uses `wrapi`, and the car park's chevrons cycle too). A carousel that
## stops dead at the last car reads as broken, especially in a two-car garage where the player
## cannot tell "the end of the list" from "the button is not working".
##
## A no-op with fewer than two candidates, exactly as `_cycle_lift_car` returns early on `< 2`.
func select_step(step: int) -> void:
	if not _open or _cars.size() < 2 or step == 0:
		return
	_index = wrapi(_index + step, 0, _cars.size())
	_refresh()


## Jump straight to a candidate (the pointer path, and how a test seats the selection).
func select_index(i: int) -> void:
	if not _open or _cars.is_empty():
		return
	var next := clampi(i, 0, _cars.size() - 1)
	if next == _index:
		return
	_index = next
	_refresh()


# Which car the picker opens on: the one the player is ALREADY driving, when it is in the list.
# Anything else means arriving at a rally in an eligible car and being shown someone else's.
func _initial_index() -> int:
	if mode == Mode.STARTER:
		return 0
	var selected := Save.selected_instance_id()
	for i in _cars.size():
		if int(_cars[i].get("instance_id", -2)) == selected:
			return i
	return 0


# --- Confirm ----------------------------------------------------------------------------


## Confirm the focused car. RALLY: hands the host the rally + instance id to start. STARTER:
## hands it the granted instance id. Returns false if the focused car cannot be confirmed — the
## re-check the car park never had.
func confirm() -> bool:
	if not can_confirm():
		return false
	var owned := focused_car()
	if mode == Mode.STARTER:
		var id := _grant(owned)
		if id < 0:
			return false
		granted.emit(id)
		return true
	var instance_id := int(owned.get("instance_id", -1))
	if instance_id < 0 or _rally.is_empty():
		return false
	started.emit(String(_rally.get("id", "")), instance_id)
	return true


# Grant the chosen starter, through the SHARED save seam — `Save.grant_car` builds the whole
# OwnedCar (instance id, HP from the model's `max_hp`, empty upgrades / tuning / toe, drivetrain
# override cleared, reward history) and persists it. A second grant path of our own that drifted
# from the HQ's is exactly the class of bug this project keeps hitting, so the only things added
# here are the two profile flags and the selection, which is what `hq.gd::_confirm_starter` does
# around the same seam.
#
# `starter_model_id` is NOT optional bookkeeping: `RallyLibrary.lit_sources` lights the OPENING
# rally's circle from it, so a profile granted a car without it would come up with a completely
# dark map and nowhere to go.
#
# Returns the new instance id, or -1.
func _grant(entry: Dictionary) -> int:
	var model_id := String(entry.get("model_id", ""))
	if model_id == "" or CarLibrary.index_of(model_id) < 0:
		# Belt and braces over `starter_cars`' filter: granting a car the catalogue cannot resolve
		# would write an OwnedCar that nothing can ever field.
		push_error("OverworldPicker: refusing to grant unresolvable starter '%s'." % model_id)
		return -1
	var car := Save.grant_car(model_id)
	var instance_id := int(car.get("instance_id", -1))
	if instance_id < 0:
		return -1
	Save.profile["starter_picked"] = true
	Save.profile["starter_model_id"] = model_id
	Save.set_selected_car(instance_id)   # persists; also promotes the car to the front
	return instance_id


# --- The real car: hidden, not reshaped -------------------------------------------------


# Take the car over for the duration: FREEZE it so a car left rolling cannot drift out of its own
# showroom shot, and HIDE it so the prop can stand in the same place without z-fighting it.
#
# Both are recorded so `_hand_car_back` only undoes what it actually did — the same
# take-only-your-own discipline `Overworld._lock_for_detail` uses for `controls_locked`, which
# this deliberately does NOT touch: in RALLY mode the detail card already holds that lock, and
# two owners clearing one flag is how a hub ends up handing a locked car back to nobody.
func _take_over_car() -> void:
	if _car == null or not is_instance_valid(_car):
		return
	_car_was_frozen = bool(_car.get("freeze"))
	if not _car_was_frozen:
		_car.set("freeze", true)
	var node := _car as Node3D
	if node != null and node.visible:
		node.visible = false
		_car_hidden = true
	# AND ITS COLLIDER GOES WITH IT. Hiding a body does not stop it colliding, and the prop now
	# spawns LIVE and is dropped onto the ground at exactly the spot the real car occupies — so
	# without this the prop lands on the invisible car instead of the road, or is shoved sideways
	# out of frame. Zeroing the LAYER (not the mask) is the established way to make a body
	# undetectable while leaving what IT collides with intact, so the real car still rests on the
	# terrain: see ghost_car.gd and overworld_zones.gd, which neutralise their props the same way.
	var body := _car as CollisionObject3D
	if body != null:
		_car_layer_was = body.collision_layer
		body.collision_layer = 0


func _hand_car_back() -> void:
	if _car == null or not is_instance_valid(_car):
		return
	if _car_hidden:
		_car_hidden = false
		(_car as Node3D).visible = true
	var body := _car as CollisionObject3D
	if body != null and _car_layer_was >= 0:
		body.collision_layer = _car_layer_was
		_car_layer_was = -1
	if not _car_was_frozen:
		_car.set("freeze", false)


## Re-field the LIVE car as `owned` and re-seat it where it stands. The ONE in-place reshape in
## this file, and the host calls it only after a starter grant.
##
## It follows the tuning lift's recipe exactly (`overworld_garage._on_upgrade_changed`), because
## `apply_owned` ends in a reset and relocates the wheels:
##
##   1. unfreeze first — a frozen body's reset is what leaves it stuck;
##   2. apply_owned (the model, its upgrades, its tuning, its saved HP);
##   3. RE-SEAT at the pose it was standing in, at the NEW model's own rest height. A different
##      car has a different `wheel_radius` / axle travel, so re-using the old body origin sinks
##      or floats it — this project has sunk props into the ground four times for exactly that. The
##      contact plane is what is preserved, computed from each model's `settled_ride_height`.
##
##      THE ORDER OF THOSE TWO READS IS LOAD-BEARING: `settled_ride_height()` answers for whichever
##      car is currently fielded, so the plane must be measured BEFORE `apply_owned` (with the
##      outgoing car's height) and restored AFTER it (with the incoming car's). Read it at one
##      moment for both and the re-seat is a no-op that leaves the body exactly where it was —
##      wrong by the difference between the two cars' rest heights, which looks like a sunk car and
##      is what `test_refielding_preserves_the_contact_plane_at_the_new_ride_height` pins;
##   4. `reset_to`, never a bare transform write (the physics server discards those outside the
##      step, and it wakes a sleeping body);
##   5. clear the wheel-visual droop, in case anything settled it while frozen — a settled car
##      handed back to physics renders its wheels below where the solver has them;
##   6. re-disable damage: `apply_owned` calls `damage.field(...)`, which re-binds the model to
##      the saved HP, and the hub deliberately runs with damage OFF (`Overworld._field_car`), so
##      the disable has to be re-applied AFTER every fielding or a hub drive starts costing HP.
func refield_live_car(owned: Dictionary) -> void:
	if _car == null or not is_instance_valid(_car) or owned.is_empty():
		return
	var node := _car as Node3D
	var pose := node.global_transform
	var plane := _contact_plane_of(_car, pose)
	_car.set("freeze", false)
	_car.call("apply_owned", owned)
	var seated := pose
	seated.origin = plane + pose.basis.y.normalized() * _ride_height_of(_car)
	_car.call("reset_to", seated)
	if _car.has_method("clear_wheel_visual_droop"):
		_car.call("clear_wheel_visual_droop")
	var model = _car.get("damage")
	if model != null:
		model.enabled = false


# The ground point under a car's wheels, derived from its own analytic rest height — the ONE
# quantity that is comparable between two different models standing in the same spot.
## The ground the prop should stand on, under `pose`.
##
## PREFERS THE TERRAIN. Deriving it from the standing car (`_contact_plane_of`) assumes that car is
## already at rest, and during the STARTER pick it is not: the picker opens on boot and the car has
## just been seated at `height_at + spawn_clearance` (2.5 m), so its origin is metres above the
## ground it will settle onto. Every prop was then seated relative to that and appeared in the air
## by exactly the clearance — which is why correcting the height arithmetic three times never
## helped. The plane is a property of the GROUND, not of whatever happens to be standing on it.
##
## Falls back to the pose-derived plane when no ground source was injected (headless tests, and any
## host that does not supply one), so there is still an answer when there is nothing better.
func _plane_under(pose: Transform3D) -> Vector3:
	if _ground_at.is_valid():
		var y: float = _ground_at.call(pose.origin)
		if is_finite(y):
			return Vector3(pose.origin.x, y, pose.origin.z)
	return _contact_plane_of(_car, pose)



static func _contact_plane_of(car: Variant, pose: Transform3D) -> Vector3:
	return pose.origin - pose.basis.y.normalized() * _ride_height_of(car)


static func _ride_height_of(car: Variant) -> float:
	if car != null and is_instance_valid(car) and car.has_method("settled_ride_height"):
		return float(car.call("settled_ride_height"))
	return 0.0


# --- The stand-in prop -----------------------------------------------------------------


# Show the focused candidate as a frozen prop standing exactly where the real car stands.
func _show_prop() -> void:
	if not _visuals or _car_scene == null or _car == null or not is_instance_valid(_car):
		return
	var key := _prop_key(focused_car())
	if key == "":
		return
	_park_prop()
	var prop := _prop_for(key, focused_car())
	if prop == null:
		return
	if prop.get_parent() != null:
		prop.get_parent().remove_child(prop)
	add_child(prop)
	_prop = prop
	_seat_prop(prop)


# Seat a prop where the real car is: the SAME CONTACT PLANE, at this model's own rest height, and
# the car's own basis — so a car parked on a slope is replaced by one leaning the same way rather
# than by one standing bolt upright in the hillside.
func _seat_prop(prop: Node3D) -> void:
	var pose := (_car as Node3D).global_transform
	var plane := _plane_under(pose)
	var seated := pose
	# SEATED AT ITS ESTIMATED REST HEIGHT, then left live to hold itself there.
	#
	# `settled_ride_height()` is the project's own estimate of how far a body origin rests above
	# the ground for THIS model's wheels and suspension, so placing the prop there means it starts
	# where it belongs rather than falling into place. Physics stays enabled — the suspension holds
	# it, absorbs any small error in the estimate, and copes with a cambered pad — but there is no
	# drop, so cycling through cars does not read as a series of cars falling from the sky.
	seated.origin = plane + pose.basis.y.normalized() * _ride_height_of(prop)
	# `reset_to`, NOT a bare `global_transform` write. This prop is LIVE, and the physics server
	# DISCARDS a transform written outside the physics step — which is why the car kept appearing in
	# the air however carefully the seat was computed: the pose above was thrown away and the prop
	# stayed wherever it was spawned. `Car.reset_to` queues the teleport for `_integrate_forces`,
	# wakes a sleeping body (a sleeping one never runs that callback, so the pose would never land)
	# and still sets the node transform now for same-frame non-physics readers like the camera.
	# It is the only safe teleport in this project; every other caller already uses it.
	if prop.has_method("reset_to"):
		prop.call("reset_to", seated)
	else:
		prop.global_transform = seated
	# A live body must be woken and cleared: it was frozen while parked (see _park_prop), and it
	# keeps whatever velocity it had when it was put away.
	prop.set("freeze", false)
	prop.set("linear_velocity", Vector3.ZERO)
	prop.set("angular_velocity", Vector3.ZERO)
	prop.set("handbrake_locked", true)
	# WHEEL VISUALS BACK TO ZERO, every time it is shown.
	#
	# The wheel mesh hangs off a `Visual` child whose `position.y` carries a droop offset, and
	# `drivetrain._update_visuals` only SPINS and STEERS that node — it never moves it vertically
	# (its own docstring says the offset persists). So:
	#   * a FROZEN prop needs the offset, because its body cannot sink onto its suspension and the
	#     wheels would otherwise sit up in the arches — that is what `settle_wheel_visuals` is for;
	#   * a LIVE one needs y = 0, because the body itself settles and the wheel node stays at its
	#     mount. Any leftover offset is then counted TWICE and the wheels sit too low.
	# Nothing guarantees zero on its own: these props are cached and reused, and a single pass
	# through any settle path (a previous frozen life, `settle_wheels_to_ground`) leaves the offset
	# behind for good. Clearing on every show makes it independent of whatever the prop did before,
	# which is what "the wheels are not always in the right place when cycling" looks like.
	if prop.has_method("clear_wheel_visual_droop"):
		prop.call("clear_wheel_visual_droop")


func _park_prop() -> void:
	if _prop == null or not is_instance_valid(_prop):
		_prop = null
		return
	# FROZEN ON THE WAY OUT. These props are cached and reused, and the holder they are parked in
	# is invisible but still in the tree — a live body left there keeps running physics and falls
	# out of the world, so the next look at that car would find it somewhere under the terrain.
	_prop.set("freeze", true)
	remove_child(_prop)
	_prop_parking.add_child(_prop)
	_prop = null


# One prop per candidate, cached: `CarProp.spawn` instantiates car.tscn (nine embedded bodies) and
# duplicates every surviving mesh, which is why every other prop holder in this project caches
# them. Browsing back and forth therefore costs nothing after the first look.
func _prop_for(key: String, entry: Dictionary) -> Node3D:
	if _props.has(key):
		var cached: Node3D = _props[key]
		if is_instance_valid(cached):
			return cached
		_props.erase(key)
	# SPAWNED LIVE, not frozen. A frozen prop had to be placed analytically — contact plane plus
	# this model's computed rest height — and any error in that sum reads as a car hovering over
	# the ground, which is what it did. A live body just falls onto its own suspension and is
	# right by construction, whatever the model or the slope.
	#
	# This is the podium's own recipe (`CarProp.spawn` with `freeze`/`disable_process` off — its
	# header calls it "podium's LIVE settle"), so it is a supported mode rather than a frozen prop
	# being abused. Two consequences follow and both are handled:
	#   * `prune_bodies` must be OFF — CarProp documents it as frozen-props-only.
	#   * no `settle_wheel_visuals`. That call exists because a FROZEN prop's wheel solver never
	#     runs, so its wheels stay tucked in the arches (the ghost-car lesson). A live prop's
	#     solver does run, and calling it would translate the visuals a second time on top.
	var opts := {
		"freeze": false,
		"disable_process": false,
		"prune_bodies": false,
		# HANDBRAKE HELD, for the whole time it is on show: `Car.is_held()` is
		# `controls_locked or handbrake_locked`, and that is what feeds the handbrake in the
		# drivetrain each tick. Without it a car dropped onto a cambered road or a pad edge
		# rolls quietly out of frame while the player is reading its stats.
		"configure": func(c: Variant) -> void:
			c.set("handbrake_locked", true),
	}
	if int(entry.get("instance_id", -1)) >= 0:
		opts["owned"] = entry     # the player's actual car: its upgrades, tune and wheel style
	else:
		opts["index"] = int(entry.get("index", 0))
	var prop := CarProp.spawn(_prop_parking, _car_scene, opts)
	if prop == null:
		return null
	_props[key] = prop
	return prop


# Cache key: the OWNED INSTANCE (two instances of one model can differ in upgrades, tune and
# wheels), or the model id for a starter preview.
static func _prop_key(entry: Dictionary) -> String:
	if entry.is_empty():
		return ""
	var id := int(entry.get("instance_id", -1))
	return "owned:%d" % id if id >= 0 else "model:%s" % String(entry.get("model_id", ""))


## The prop currently standing in for the car, or null. Test seam.
func shown_prop() -> Node3D:
	return _prop


# --- The showroom camera ---------------------------------------------------------------


# A THREE-QUARTER VIEW IN FRONT OF THE CAR, and the car does not move to suit it — the user was
# explicit that it stays where they stopped, so the camera comes to the car.
#
# Its own Camera3D made `current`, which is the protocol `start_line.gd`'s reveal orbit
# established: `CameraManager` never writes a transform (it only flips `current` on the chase and
# bonnet cameras when the player cycles), so an override camera does not fight it, and
# `activate_current()` is the documented hand-back.
func _build_camera() -> void:
	if not _visuals or _car == null or not is_instance_valid(_car):
		return
	if _cam == null:
		_cam = Camera3D.new()
		_cam.name = "ShowroomCamera"
		add_child(_cam)
	_cam.fov = maxf(Config.data.overworld_picker_camera_fov, 1.0)
	_cam.global_transform = showroom_pose((_car as Node3D).global_transform,
		Config.data.overworld_picker_camera_offset, _ride_height_of(_car),
		Config.data.overworld_picker_camera_aim_drop_m)
	_cam.current = true


## The camera pose for a car standing at `car_pose`. STATIC and pure, so the framing is testable
## with no camera, no car and no viewport.
##
## `offset` is in the CAR's own space (x = to its right, y = up from the ground it stands on,
## z = ahead of its nose — car.tscn faces -Z, so a positive z becomes -Z locally). The camera
## then looks back at the car's middle, which is what makes it read as a showroom shot of THAT
## car rather than a fixed angle the car happens to be in.
##
## A COLINEAR `look_at` IS MADE IMPOSSIBLE HERE, not tolerated downstream. `Basis.looking_at`
## warns (and produces a garbage basis) when the view direction is parallel to `up`, which is
## what a camera directly above or below the car asks for. Two guards, in order:
##
##   1. MIN_STANDOFF_M: the camera is always at least that far AHEAD of the nose, so the view
##      direction always carries a component along the car's own Z and therefore can never be
##      parallel to its Y. This is what actually removes the degeneracy — including for a
##      zero offset, which a caller can reach by clearing the GameConfig field. It survives
##      `aim_drop` unchanged: dropping the aim only moves the target along the car's Y, and the
##      standoff component along its Z is what the guarantee rests on.
##   2. A colinearity fallback anyway, so the guarantee survives someone later relaxing (1):
##      tilt `up` onto the car's forward axis, which is always perpendicular to it.
static func showroom_pose(car_pose: Transform3D, offset: Vector3, ride_height: float,
		aim_drop := 0.0) -> Transform3D:
	var up := car_pose.basis.y.normalized()
	var plane := car_pose.origin - up * ride_height
	var local := Vector3(offset.x, offset.y, -maxf(absf(offset.z), MIN_STANDOFF_M))
	var eye := plane + car_pose.basis * local
	# Aim at the body's middle rather than the ground: framing the contact plane puts the car in
	# the top half of the shot with a lot of tarmac under it.
	#
	# ...then AIM `aim_drop` METRES LOWER, which PITCHES THE CAMERA DOWN and pushes the car UP the
	# frame — off the bottom strip the menu bar occupies, so the car clears its own menu. Done by
	# moving the aim point rather than by raising the camera: raising the eye would frame more
	# tarmac and shrink the car, while dropping the aim keeps the same distance and the same size
	# and just re-centres what is on screen. The bar is bottom-anchored, so up the frame is exactly
	# where the room is.
	var target := plane + up * (maxf(ride_height, 0.1) * 2.0 - maxf(aim_drop, 0.0))
	var forward := target - eye
	if forward.length_squared() < 1e-6:
		return Transform3D(car_pose.basis, eye)
	if forward.normalized().cross(up).length() < COLINEAR_EPSILON:
		up = -car_pose.basis.z.normalized()
	return Transform3D(Basis.looking_at(forward, up), eye)


func _release_camera() -> void:
	# Fly if there is something to fly BETWEEN; otherwise hand over immediately. The immediate path
	# is what headless tests and a visuals-off picker take, so the hand-back contract is unchanged
	# for them — only the visible case gained a transition.
	var target := _player_camera()
	if _cam != null and _cam.current and target != null and Config.data.overworld_picker_fly_seconds > 0.0:
		_fly_from = _cam.global_transform
		_fly_from_fov = _cam.fov
		_fly_t = 0.0
		_flying = true
		set_process(true)
		return
	_hand_camera_over()


# Snap the viewport back to the mode the PLAYER chose, rather than assuming it was the chase camera
# — the same call the start-line reveal makes.
func _hand_camera_over() -> void:
	_flying = false
	set_process(false)
	if _cam != null:
		_cam.current = false
	var mgr := _camera_manager()
	if mgr != null:
		mgr.activate_current()


## The camera the player would be looking through if the picker were not up — chase or bonnet,
## whichever they last chose. Read from CameraManager rather than assumed, for the same reason
## `activate_current()` exists: forcing chase would silently change a bonnet player's view.
func _player_camera() -> Camera3D:
	var mgr := _camera_manager()
	if mgr == null:
		return null
	var chase := mgr.chase_camera
	var bonnet := mgr.bonnet_camera
	if mgr.active_index() == CameraManager.ORDER.find(CameraManager.Mode.BONNET):
		return bonnet if bonnet != null else chase
	return chase if chase != null else bonnet


func _ready() -> void:
	# Defining _process makes a node process by DEFAULT, and only the fly-out wants it. Off until
	# a fly actually starts, so a closed or headless picker costs nothing per frame.
	set_process(false)


func _process(delta: float) -> void:
	if not _flying:
		set_process(false)
		return
	var target := _player_camera()
	if target == null or _cam == null:
		_hand_camera_over()
		return
	var secs := maxf(Config.data.overworld_picker_fly_seconds, 0.0001)
	_fly_t += delta
	var k := smoothstep(0.0, 1.0, clampf(_fly_t / secs, 0.0, 1.0))
	# The target is re-read every frame rather than captured once: the driving camera follows the
	# car, so a captured pose would be stale by arrival if anything moved.
	var to := target.global_transform
	_cam.global_transform = Transform3D(_fly_from.basis.slerp(to.basis, k),
		_fly_from.origin.lerp(to.origin, k))
	_cam.fov = lerpf(_fly_from_fov, target.fov, k)
	if _fly_t >= secs:
		# Land exactly on the target before handing over, so the switch of `current` is invisible.
		_cam.global_transform = to
		_cam.fov = target.fov
		_hand_camera_over()


func _camera_manager() -> CameraManager:
	var host := get_parent()
	if host == null:
		return null
	return host.get_node_or_null("CameraManager") as CameraManager


## The showroom camera, or null with visuals off. Test seam.
func camera() -> Camera3D:
	return _cam


# Per-frame, from the host. Two jobs, both cheap: keep the shot framed on the car (which can only
# move if something else teleports it), and RE-ASSERT the override.
#
# The re-assert is not paranoia: `CameraManager` still polls `cycle_camera` every frame and has no
# concept of an override, so pressing C while the picker is open would hand the viewport to the
# chase camera and leave the player looking at a hidden car. Taking it straight back is a
# two-line fix here versus a gate in a shared file.
func update(_delta: float) -> void:
	if not _open or _cam == null or _car == null or not is_instance_valid(_car):
		return
	_cam.global_transform = showroom_pose((_car as Node3D).global_transform,
		Config.data.overworld_picker_camera_offset, _ride_height_of(_car),
		Config.data.overworld_picker_camera_aim_drop_m)
	if not _cam.current:
		_cam.current = true


# --- The menu: a CAROUSEL BAR ALONG THE BOTTOM ------------------------------------------
#
# One car at a time, chosen with LEFT / RIGHT — the shape the old menus use, mirrored from the car
# park's chevron nav row (`hq.gd::_build_carpark_nav_row`) and the garage lift's selector: a `<`, a
# centred name, a `>`, with the stats line under it and the actions below that. It replaced a
# side list of rows, which fought the whole point of a diegetic picker: the car is the content, and a
# list down the side of it is a menu wearing a showroom's clothes.
#
# BOTTOM-ANCHORED so the car itself is unobstructed — which is also why the stats line lives in this
# bar rather than beside each of several rows. In STARTER mode it reads the same way, and better: a
# fresh player has nothing to compare against, so one car at a time with its numbers under it is
# exactly the right amount of information.
#
# BUILT EVEN HEADLESS (`visuals: false` skips the camera and the prop, not this): a Control tree
# needs no renderer, which is what keeps the navigation testable.
#
# NAVIGATION IS THE DIEGETIC PATTERN, NOT MenuNav — a deliberate choice, and the second of the two
# frameworks CLAUDE.md blesses (`MenuNav.attach` for a flat widget list, the
# `hq.gd._unhandled_input` shape for a diegetic station). See `_unhandled_input` for why a carousel
# cannot use the first one.


func _build_ui() -> void:
	_layer = CanvasLayer.new()
	_layer.name = "PickerUI"
	_layer.layer = 40
	_layer.visible = false
	add_child(_layer)
	_ui_root = Control.new()
	_ui_root.name = "PickerMenu"
	_ui_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(_ui_root)
	# The page CLAIMS THE SCREEN while it is up, so the map's cursor, the pause menu's nav and
	# anything else that reads input go deaf rather than acting under a menu the player is reading.
	_ui_root.add_to_group(MenuNav.SCREEN_CLAIMER_GROUP)

	var margins := MarginContainer.new()
	margins.set_anchors_preset(Control.PRESET_FULL_RECT)
	margins.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "top", "right", "bottom"]:
		margins.add_theme_constant_override("margin_" + side, UITheme.MARGIN)
	_ui_root.add_child(margins)
	# A spacer that eats all the vertical room pushes the bar to the BOTTOM edge. Same trick the
	# card's footer uses, and it leaves the whole upper frame to the car.
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", UITheme.GAP)
	margins.add_child(column)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(spacer)
	var panel := UITheme.panel()
	panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	column.add_child(panel)
	_page = VBoxContainer.new()
	_page.name = "Picker"
	_page.add_theme_constant_override("separation", UITheme.GAP_TIGHT)
	panel.add_child(_page)
	_build_bar()


# The bar's widgets, built ONCE and re-dressed per selection — nothing here is rebuilt when the car
# changes, because the bar's SHAPE never changes (unlike a row list, whose length did).
func _build_bar() -> void:
	# NO TITLE ROW. It said "SELECT A CAR" (or "CHOOSE YOUR FIRST CAR") over a bar whose whole
	# content is a car name, its stats and a Start button — a caption for something already obvious,
	# costing a row of the frame that the CAR wants. The two modes are still distinguishable at a
	# glance, and by the only words that carry information: the confirm button reads "Start Rally >"
	# or "Take This Car >".

	# The chevron row: < NAME >, the car park's own shape.
	var selector := HBoxContainer.new()
	selector.add_theme_constant_override("separation", UITheme.GAP)
	_page.add_child(selector)
	_prev_button = _arrow_button("<", -1)
	selector.add_child(_prev_button)
	_name_label = UITheme.label("")
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Wraps rather than clipping: a car name plus its position ("... (1 OF 3)") is the longest line
	# in the bar, and the car park lost its tail off the edge of a panel for want of this.
	_name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_name_label.custom_minimum_size = Vector2(BAR_NAME_WIDTH_PX, 0.0)
	selector.add_child(_name_label)
	_next_button = _arrow_button(">", 1)
	selector.add_child(_next_button)

	_stats_label = UITheme.label("", "dim")
	_stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_page.add_child(_stats_label)
	_reason_label = UITheme.label("", "red")
	_reason_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_reason_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_page.add_child(_reason_label)

	_page.add_child(HSeparator.new())
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", UITheme.GAP)
	_page.add_child(actions)
	# BACK ON THE LEFT, CONFIRM ON THE RIGHT — the order every other screen in the game uses (the
	# rally card's footer is "< Map" then "Enter Rally", the garage's pages the same), so "back" is
	# always the leftmost thing and "forward" always the rightmost. It was the other way round here.
	#
	# NOTE THE ASYMMETRY THIS HAS TO SURVIVE: starter mode has no Back at all (a player cannot
	# decline to own a car and drive off), so the button is built either way and HIDDEN there —
	# which leaves the confirm button alone in a centred row, exactly as it looked before, rather
	# than sitting off to one side with a gap where Back would be.
	_back = UITheme.row_button("< Back", close)
	actions.add_child(_back)
	_confirm = UITheme.row_button("", _on_confirm_pressed)
	actions.add_child(_confirm)


# A chevron. `UITheme.row_button` (the SHARED widget) rather than a hand-rolled Button, so it carries
# the house styling — and left as `FOCUS_NONE` on purpose: these are POINTER AFFORDANCES for an
# action the keyboard and pad reach with left/right, exactly as the lift's chevrons document. Marked
# `menu_nav_skip` as well, so if a MenuNav ever attaches above this bar it cannot turn them into
# focus stops and re-create the "press right, the highlight hops to an arrow, the car does not
# change" problem this layout exists to avoid.
func _arrow_button(text: String, step: int) -> Button:
	var b := UITheme.row_button(text, select_step.bind(step))
	b.set_meta("menu_nav_skip", true)
	return b


# Re-dress the bar for the focused car: the readouts, the arrows, the Confirm button's state, and the
# car standing in front of the camera.
func _refresh() -> void:
	if _page == null:
		return
	var owned := focused_car()
	var spec := CarLibrary.for_owned(owned) if int(owned.get("instance_id", -1)) >= 0 \
		else CarLibrary.by_id(String(owned.get("model_id", "")))
	# The position readout is what tells the player there is more than one car to see at all — the
	# car park carries the same "(1 OF 2)" for the same reason.
	var label_text := String(spec.get("name", ""))
	if _cars.size() > 1:
		label_text += "   (%d OF %d)" % [_index + 1, _cars.size()]
	_name_label.text = label_text
	# The SHARED helper, not a local copy — hq.gd's own `_car_stats_text` now delegates to this
	# same static, so the bar and the car park can never disagree about how a car reads.
	_stats_label.text = RallyDetail.car_stats_text(owned, spec)
	# THE REASON SURVIVES THE STATS LINE. They are two separate labels and the stats line never
	# carries the reason: a car that cannot enter needs both the numbers AND the sentence saying why
	# it is out, and that sentence is the one thing a blocked player actually acts on.
	var why := reason()
	_reason_label.text = why
	_reason_label.visible = why != ""
	_confirm.text = _confirm_text()
	_confirm.disabled = not can_confirm()
	# NOTHING TO CYCLE: hide the chevrons and disable them, the pair `hq.gd` uses
	# (`_set_carpark_arrows_visible`, and the lift's "hidden so the row reads as a plain nameplate,
	# disabled so neither cursor nor click can reach a button that isn't on screen"). The centre
	# label stays, so the bar still names the car.
	var cyclable := _cars.size() > 1
	for arrow in [_prev_button, _next_button]:
		arrow.visible = cyclable
		arrow.disabled = not cyclable
	_back.visible = mode == Mode.RALLY
	_back.disabled = mode != Mode.RALLY
	_show_prop()
	# The house rules (row heights, uppercasing) on the bar. Run while the layer is VISIBLE, because
	# some of what `enforce` resolves depends on `is_visible_in_tree()`.
	UITheme.enforce(_ui_root)


func _confirm_text() -> String:
	return "Start Rally >" if mode == Mode.RALLY else "Take This Car >"


# THE INPUT MODEL, and the decision the layout turns on.
#
# LEFT / RIGHT CHANGE THE CAR. They do not move a highlight between the two chevrons, which is what
# `MenuNav` (and the lift, whose arrows ARE focus stops) would do — and for a carousel that is the
# wrong answer twice over: a pad player presses right and the cursor hops to an arrow instead of the
# car changing, and the player is left with two competing selection models on one screen, which is
# exactly the trap the map's cursor fell into.
#
# So this bar has NO MenuNav and NO focus cursor: every button in it is `FOCUS_NONE`, which means the
# GUI focus phase consumes nothing and these presses arrive here intact. Enter/A confirms, Esc/B
# cancels (rally mode only — the starter pick has nowhere to go back to, and leaving the press
# unclaimed is what keeps Esc reaching the pause menu so a player who wants out can still quit).
# Both the `ui_*` and the game's own `menu_*` actions are accepted, so keyboard, D-pad and stick all
# work: `ui_left/right` carry the arrows, the D-pad and the stick, `menu_left/right` carry WASD.
#
# This node is the LAST child of the hub (built after the map and the card), and `_unhandled_input`
# is delivered from the last child up — so the picker sees Esc before the authored PauseMenu, whose
# `pause` action is bound to the same key.
func _unhandled_input(event: InputEvent) -> void:
	if not _open:
		return
	if event.is_action_pressed("ui_left") or event.is_action_pressed("menu_left"):
		select_step(-1)
	elif event.is_action_pressed("ui_right") or event.is_action_pressed("menu_right"):
		select_step(1)
	elif event.is_action_pressed("ui_accept") or event.is_action_pressed("menu_select"):
		confirm()
	elif mode == Mode.RALLY \
			and (event.is_action_pressed("ui_cancel") or event.is_action_pressed("menu_back")):
		close()
	else:
		return
	get_viewport().set_input_as_handled()


func _on_confirm_pressed() -> void:
	confirm()


## The menu root, so the host (and a test) can reach the bar. Test seam, as the garage's
## `ui_root()` is.
func ui_root() -> Control:
	return _ui_root


## Are the cycling chevrons on screen? False when there is only one candidate.
func arrows_visible() -> bool:
	return _prev_button != null and _prev_button.visible and _next_button.visible


func confirm_button() -> Button:
	return _confirm


func back_button() -> Button:
	return _back


## The bar's readout text, for the tests that assert the stats line comes from the shared helper.
func stats_text() -> String:
	return _stats_label.text if _stats_label != null else ""


func name_text() -> String:
	return _name_label.text if _name_label != null else ""


func reason_text() -> String:
	return _reason_label.text if _reason_label != null and _reason_label.visible else ""

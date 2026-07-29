class_name WheelStyle
extends RefCounted
# Pure COSMETIC wheel-swap logic: which wheel style an owned car is wearing, and the
# texture that style resolves to. No scene / save coupling — Save owns the mutation
# (Save.set_wheels) and car.gd applies the result. See features/wheel-customization.md.
#
# A wheel style is just a DONOR CAR's stable CarLibrary id: every car in the roster
# donates its wheels to every other car, always, for free. The swap carries the wheel
# TEXTURE and nothing else — wheel_radius / wheel_width_front / wheel_width_rear (and
# therefore ride height, load sensitivity and grip) always come from the car's OWN
# CarLibrary entry, so a wheel change can never move a single stat.
#
# Deliberately NOT part of EngineSwap: wheels are a separate, free, ungated system with
# no token economy and no eligibility rules.


# The wheel-style id an owned car is wearing: its chosen donor if set, else the car's
# own model id (stock). Mirrors EngineSwap.current_engine_id's shape.
static func current_wheel_id(owned: Dictionary, stock_model_id: String) -> String:
	var chosen := String(owned.get("wheels", ""))
	return chosen if not chosen.is_empty() else stock_model_id


# True when this car is wearing someone else's wheels.
static func is_swapped(owned: Dictionary, stock_model_id: String) -> bool:
	return current_wheel_id(owned, stock_model_id) != stock_model_id


# The wheel texture path an owned car should render. Resolves the chosen style through
# CarLibrary; falls back to the car's OWN wheel texture when the style id is unknown
# (a donor renamed or dropped from the roster must degrade to stock, never to a blank
# disc), and to "" when even the stock entry has none (car.gd draws a blank dark disc).
static func texture_for(owned: Dictionary, stock_model_id: String) -> String:
	var stock_tex := _texture_of(stock_model_id)
	var id := current_wheel_id(owned, stock_model_id)
	if id == stock_model_id:
		return stock_tex
	var tex := _texture_of(id)
	return tex if not tex.is_empty() else stock_tex


static func _texture_of(model_id: String) -> String:
	var entry := CarLibrary.by_id(model_id)
	if entry.is_empty():
		return ""
	return String(entry.get("wheel_texture", ""))


# The wheel styles on offer for a car, in roster order with the car's OWN wheels first
# (the "Stock" option). Every entry is { "id", "name", "texture", "stock" } where `id`
# is a real CarLibrary id and `name` is the donor car's name. Cars with no authored
# wheel_texture donate nothing (a blank disc isn't a style).
static func options_for(stock_model_id: String) -> Array:
	var out: Array = []
	var stock_first: Array = []
	# A car that authors NO wheel_texture donates nothing, so it wouldn't appear in its own
	# option list — leaving the player on a donor style with no way back to their own
	# wheels (and option_index would silently seat on index 0, someone else's wheels).
	# Synthesize the stock option for such a car: an empty texture is exactly what
	# car.gd renders as the blank dark disc, i.e. its real stock look.
	if CarLibrary.by_id(stock_model_id).get("wheel_texture", "") == "":
		var entry := CarLibrary.by_id(stock_model_id)
		if not entry.is_empty():
			stock_first.append({
				"id": stock_model_id,
				"name": "%s (Stock)" % String(entry.get("name", "")),
				"texture": "",
				"stock": true,
			})
	for entry in CarLibrary.wheel_catalogue():
		var is_stock: bool = String(entry.get("id", "")) == stock_model_id
		var option := {
			"id": String(entry.get("id", "")),
			"name": ("%s (Stock)" % String(entry.get("name", ""))) if is_stock else String(entry.get("name", "")),
			"texture": String(entry.get("texture", "")),
			"stock": is_stock,
		}
		if is_stock:
			stock_first.append(option)
		else:
			out.append(option)
	return stock_first + out


# Index into options_for() of the style this car is currently wearing; 0 (the stock
# option) when the chosen style isn't on offer.
static func option_index(options: Array, owned: Dictionary, stock_model_id: String) -> int:
	var current := current_wheel_id(owned, stock_model_id)
	for i in options.size():
		if String((options[i] as Dictionary).get("id", "")) == current:
			return i
	return 0

extends GutTest
# Hafren shops that sell tires, drivetrain kits and engine swaps, and the Parts menu that switches them. Synthetic level and stock only.

const PATH := "user://test_level_shop_specialties.json"
var _car: String
var _other: String


func before_each() -> void:
	_car = Config.data.level_car_id
	_other = String(CarLibrary.all().filter(func(c: Dictionary) -> bool: return c["id"] != _car)[0]["id"])


func after_each() -> void:
	Config.data.level_car_id = _car
	LevelView._next_pose = null
	Scenes.last_blocked_path = ""
	LevelView.forget_progress()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))


func _tire() -> String:
	return "tire:%s" % String(LootRules.TIRES.keys()[0])


func _kit() -> String:
	return "drivetrain:%d" % int(LootRules.KITS.keys()[0])


func _view(stock: Array, parts := {}, car := "") -> LevelView:
	var hm: Array = []
	hm.resize(201 * 201)
	hm.fill(0.0)
	var lv := {"road": [{"x": -100.0, "z": 0.0, "w": 3.0, "m": null, "tension": 1.0}, {"x": 100.0, "z": 0.0, "w": 3.0, "m": null, "tension": 1.0}],
		"trees": [], "heightmap": hm, "shops": [{"x": 35.0, "z": 3.0, "name": "Shop", "stock": stock}]}
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(lv))
	f.close()
	LevelView.forget_progress()
	Save.set_setting(LevelView.CARS_KEY, [_car, _other])
	Save.set_setting(LevelView.MONEY_KEY, 1000000)
	Save.set_setting(LevelView.PARTS_KEY, parts)
	if not car.is_empty():
		Config.data.level_car_id = car
	var world: Node = (load(Scenes.WORLD) as PackedScene).instantiate()
	world.get_node("Level").level_path = PATH
	add_child_autofree(world)
	var view: LevelView = world.get_node("Level")
	await wait_for_signal(view.loaded, 30.0)
	return view


func _titles(view: LevelView) -> Array:
	return CardUI.titles(view.store.find_children("*", "CardCarousel", true, false)[0])


func _part_ids(view: LevelView) -> Array:
	return view.owned["parts"].map(func(p: Dictionary) -> String: return String(p["id"]))


func test_a_bought_tire_and_kit_go_on_this_car_only() -> void:
	var view := await _view([{"part": _tire(), "price": 10}, {"part": _kit(), "price": 10}])
	assert_false(_tire() in _part_ids(view), "a tire not bought isn't on the car")
	assert_false(_kit() in _part_ids(view), "nor a kit")
	view.open_store(0)
	var cards: CardCarousel = view.store.find_children("*", "CardCarousel", true, false)[0]
	CardUI.pick(cards, LootRules.card_text({"kind": "part", "id": _tire()})[0])
	(ConfirmPopup.any_open(get_tree()) as ConfirmPopup)._on_action(1)
	assert_true(_tire() in LevelView.bought_parts(), "the tire is bought for the driven car")
	assert_eq(LevelView.bought_parts(_other), [], "and no other car")
	var fitted: Array = view.owned["parts"].filter(func(p: Dictionary) -> bool: return p["id"] == _tire())
	assert_true(fitted.size() == 1 and LootRules.is_on(fitted[0]), "fitted and switched on at once")
	assert_eq(_titles(view).size(), 2, "the card stays, reading Owned")
	CardUI.pick(view.store.find_children("*", "CardCarousel", true, false)[0], LootRules.card_text({"kind": "part", "id": _tire()})[0])
	assert_null(ConfirmPopup.any_open(get_tree()), "an owned tire can't be bought twice")


func test_a_car_driven_again_has_only_its_last_bought_tire_on() -> void:
	var tires: Array = LootRules.TIRES.keys().slice(0, 2).map(func(k: String) -> String: return "tire:" + k)
	var view := await _view([], {_other: tires}, _other)
	var on: Array = view.owned["parts"].filter(func(p: Dictionary) -> bool: return LootRules.is_tire(p) and LootRules.is_on(p))
	assert_eq(on.map(func(p: Dictionary) -> String: return String(p["id"])), [tires[1]], "one set of tires on: the last bought")


func test_engine_swap_card_shows_only_where_stocked_and_not_from_the_map() -> void:
	var view := await _view([{"engine_swap": true, "price": 0}])
	view.open_store(0)
	assert_true("Engine swap" in _titles(view), "a shop stocking swaps offers it")
	view.close_store()
	view.open_store(0, true)
	assert_false("Engine swap" in _titles(view), "not when picked on the map, where the car isn't")
	view._free_store()
	view._store_remote = false
	view.level["shops"][0]["stock"] = [{"part": _tire(), "price": 10}]
	view.open_store(0)
	assert_false("Engine swap" in _titles(view), "a shop without it has no card")


func test_engine_swap_page_opens_from_the_shop_and_back_returns_to_it() -> void:
	var view := await _view([{"engine_swap": true, "price": 0}])
	view.open_store(0)
	CardUI.pick(view.store.find_children("*", "CardCarousel", true, false)[0], "Engine swap")
	assert_null(view.store, "the shop gives way to the engines page")
	assert_not_null(view.shop)
	assert_eq(view.shop.view, RestStopPage.View.ENGINES)
	MenuNav.of(view.shop._page)._unhandled_input(_back_event())
	assert_not_null(view.store, "Back is the shop again")


func test_parts_menu_lists_owned_parts_without_engine_swaps_and_backs_out() -> void:
	var view := await _view([{"part": _tire(), "price": 10}])
	view.open_parts()
	var titles: Array = CardUI.titles(view.shop._cards)
	assert_true("Tires" in titles and "Drivetrain" in titles and "Upgrades" in titles, "the three part pages")
	assert_false("Engine swaps" in titles, "no engine swaps there")
	CardUI.pick(view.shop._cards, "Tires")
	assert_eq(view.shop.view, RestStopPage.View.TIRES)
	assert_false(LootRules.card_text({"kind": "part", "id": _tire()})[0] in CardUI.titles(view.shop._cards), "an unbought tire isn't listed")
	MenuNav.of(view.shop._page)._unhandled_input(_back_event())
	assert_eq(view.shop.view, RestStopPage.View.SHOP, "Back steps to the parts menu")


func _back_event() -> InputEventAction:
	var e := InputEventAction.new()
	e.action = "ui_cancel"
	e.pressed = true
	return e

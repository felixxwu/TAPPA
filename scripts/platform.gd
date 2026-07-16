class_name Platform
extends RefCounted

## Small platform/runtime capability queries shared across the project.


# True when running under Godot's headless display server (the test runner and
# CI use `--headless`). Callers gate visual-only work — spectator crowds, camera
# effects, target-FPS caps — on this. Centralised so the brittle magic string
# lives in exactly one place rather than being re-typed at every call site.
static func is_headless() -> bool:
	return DisplayServer.get_name() == "headless"


# True on the platforms that need the aggressive thermal frame cap: mobile
# (phones/tablets that throttle under sustained load) and web (often running on
# those same devices, single-threaded). Desktop keeps the higher cap. Centralised
# so the export-feature strings live in one place (mirrors is_headless()).
static func is_mobile_or_web() -> bool:
	return OS.has_feature("mobile") or OS.has_feature("web")


# The world's downward gravity magnitude (m/s^2), read from the project's physics
# settings. Centralised so the hardcoded 9.8 default isn't re-typed at each site;
# the fallback matches Godot's own default for physics/3d/default_gravity, so the
# returned value is identical to the literals it replaces when no override is set.
static func gravity() -> float:
	return ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)

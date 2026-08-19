class_name AudioBuses
extends RefCounted
# Docs: features/sfx.md, features/music.md — update in the same change as this file.
# Tests: tests/headless/test_audio.gd — extend in the same change.
#
# THE single definition of every mix bus name this project creates. Audio buses used to be
# raw string literals scattered across audio.gd, music_director.gd and settings_menu.gd — a
# dozen-odd copies of "Master"/"Music"/"Engine" that a rename would realistically miss one of,
# and the failure mode is silent: AudioServer.get_bus_index() returns -1 and the sound just
# stops routing, with no error anywhere. Route every bus lookup through these consts instead.
#
# MASTER is bus 0, always present (Godot creates it for every project) — it is never created
# by this codebase, only looked up/muted/volumed. MUSIC, ENGINE and SFX are created on demand
# at boot (see music_director.gd._ensure_music_bus/_ensure_engine_bus and
# audio.gd._ensure_bus) — there is no default_bus_layout .tres in this project, so these three
# only exist once the relevant autoload has run _ready().
const MASTER := &"Master"
const MUSIC := &"Music"
const ENGINE := &"Engine"
const SFX := &"SFX"

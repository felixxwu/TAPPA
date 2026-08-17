class_name TiltInput
extends RefCounted
# Device tilt for the TILT control scheme (mobile_controls.gd, SCHEME_TILT_GAS_BRAKE).
#
# Returns the gravity vector in SCREEN space (x = the screen's horizontal axis, so
# rolling the phone's right-hand edge DOWN gives a positive x), in m/s^2, pointing
# DOWN — the same convention Input.get_gravity() uses on Android/iOS. That's all
# MobileControls.tilt_steer needs.
#
# Two things have to be true for tilt to work at all, and neither is free:
#
#   1. NATIVE (Android/iOS). Godot's sensors are OFF by default — the project
#      settings `input_devices/sensors/enable_gravity` / `enable_accelerometer`
#      default to FALSE (verified against 4.6.3), and with them unset
#      Input.get_gravity() returns Vector3.ZERO forever. project.godot turns them
#      on; do not remove those lines or tilt steering silently dies again.
#   2. WEB. Godot has NO sensor support on the web export at all — get_gravity()
#      is hardcoded to zero there (godot-proposals#2526 is still open). So on the
#      web we read the browser's own `deviceorientation` events through
#      JavaScriptBridge and rotate them into screen space ourselves.
#
# The web feed follows the same PUSH + PULL plumbing as the touch watchdog in
# mobile_controls.gd (a JS -> GDScript callback plus a per-frame read of a window
# property, deduped by a sequence number), for the reasons documented there: neither
# path is worth betting the controls on alone, and both readers must fail by doing
# nothing rather than raising, since an error here would abort the caller's frame.

const G := 9.80665

# Web only, deliberately UNTYPED — JavaScriptObject property access is dynamic.
var _js_window = null
var _sync_cb = null
var _installed := false
# Newest snapshot adopted (-1 = none; JS starts its counter at 0 and only bumps it
# when the reading actually changes), so push and pull can't apply one twice.
var _seq := -1
# Latest browser-sourced gravity, already rotated into screen space. `null` means
# "no feed" — off the web build, in tests, and on a browser/iframe that delivers no
# orientation events — and then we fall back to the engine's own sensors.
var _web_gravity = null
var _logged := false


# Install the browser listener. Idempotent, and a no-op off the web build (where
# Input.get_gravity() is the real source). Called lazily, only once the tilt scheme
# is actually selected, so players on the other five schemes never pay for a
# 60 Hz sensor stream.
func install() -> void:
	if _installed or not OS.has_feature("web"):
		return
	_installed = true
	_js_window = JavaScriptBridge.get_interface("window")
	if _js_window == null:
		return
	_sync_cb = JavaScriptBridge.create_callback(_on_tilt_sync)
	_js_window.godotTiltSync = _sync_cb
	JavaScriptBridge.eval(_TILT_JS, true)


# PUSH path: JS calls window.godotTiltSync(seq, "x:y:z"). Type-checked rather than
# blind-converted — see the header note about failing by doing nothing.
func _on_tilt_sync(args: Array) -> void:
	if args.size() < 2 or not _is_number(args[0]) or typeof(args[1]) != TYPE_STRING:
		return
	adopt(int(args[0]), args[1])


# PULL path, once a frame: one int read while the phone is still, and the payload is
# only fetched and parsed when the reading has actually moved.
func poll() -> void:
	if _js_window == null:
		return
	var raw_seq = _js_window.__rallyTiltSeq
	if not _is_number(raw_seq):
		return
	var seq := int(raw_seq)
	# seq 0 is JS's "no orientation event has fired yet" value: leave the feed null
	# rather than reporting a level phone we never measured.
	if seq <= 0 or seq <= _seq:
		return
	var raw = _js_window.__rallyTiltData
	if typeof(raw) != TYPE_STRING:
		return
	adopt(seq, raw)


# Store a newer reading. Payload is "x:y:z" in m/s^2, screen space. Public so the
# push path, the pull path and the tests all go through one door.
func adopt(seq: int, data: String) -> void:
	if seq <= _seq:
		return
	var f := data.split(":")
	if f.size() != 3:
		return
	_seq = seq
	_web_gravity = Vector3(float(f[0]), float(f[1]), float(f[2]))
	if not _logged and _js_window != null:
		_logged = true
		print("[rally] tilt sensor feeding: seq=", seq, " gravity=", _web_gravity)


# Screen-space gravity (m/s^2, pointing down). The browser feed wins where it
# exists; otherwise the engine's own sensors, which Godot already rotates to the
# current display orientation on Android. get_accelerometer() is a fallback for
# devices with no composite gravity sensor — at rest it reads the same vector, just
# noisier under hand movement.
func gravity() -> Vector3:
	if _web_gravity != null:
		return _web_gravity
	var g := Input.get_gravity()
	if g == Vector3.ZERO:
		g = Input.get_accelerometer()
	return g


# Where the current reading comes from, for the on-device debug readout.
func source() -> String:
	if _web_gravity != null:
		return "browser"
	if gravity() == Vector3.ZERO:
		return "none"
	return "sensor"


func _is_number(v) -> bool:
	return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT


# Publishes the phone's gravity direction, rotated into SCREEN space, to
# window.__rallyTiltData (+ a change counter) and straight through the bridge.
#
# `deviceorientation` is used rather than `devicemotion`: its beta/gamma are angles
# with a spec'd sign, whereas accelerationIncludingGravity is famously negated on
# iOS relative to everyone else. beta/gamma are reported in the device's NATURAL
# (portrait) frame regardless of how the screen is rotated, so we rotate by
# screen.orientation.angle ourselves — the game is played in landscape, where the
# steering axis is the natural Y axis, not X.
#
# Requires a secure context (https), which both hosts are. In a CROSS-ORIGIN IFRAME
# (itch.io embeds the game in one) the browser's default permissions policy blocks
# the sensor unless the embedder sets allow="accelerometer; gyroscope" on the iframe
# — nothing we can do from in here, and the reason the readout below distinguishes
# "no feed" from "level".
const _TILT_JS := """
(function () {
	if (window.__rallyTiltWatch) { return; }
	window.__rallyTiltWatch = true;
	window.__rallyTiltData = '';
	window.__rallyTiltSeq = 0;
	var G = 9.80665;

	function publish(x, y, z) {
		var s = x.toFixed(3) + ':' + y.toFixed(3) + ':' + z.toFixed(3);
		if (s === window.__rallyTiltData) { return; }
		window.__rallyTiltData = s;
		window.__rallyTiltSeq++;
		try {
			if (window.godotTiltSync) { window.godotTiltSync(window.__rallyTiltSeq, s); }
		} catch (err) {}
	}

	// Degrees the DEVICE is rotated clockwise from its natural orientation. The
	// legacy window.orientation uses the opposite sign to screen.orientation.angle
	// (90 there is 270 here), hence the negation on that fallback.
	function screenAngle() {
		if (window.screen && screen.orientation
				&& typeof screen.orientation.angle === 'number') {
			return screen.orientation.angle;
		}
		return (typeof window.orientation === 'number') ? -window.orientation : 0;
	}

	window.addEventListener('deviceorientation', function (e) {
		if (e.beta === null || e.gamma === null) { return; }
		var b = e.beta * Math.PI / 180.0;
		var g = e.gamma * Math.PI / 180.0;
		// Gravity (pointing DOWN) in device axes, from the Z-X'-Y'' Tait-Bryan
		// angles the spec defines: flat and face-up (beta = gamma = 0) gives
		// (0, 0, -1), i.e. straight into the back of the phone.
		var dx = Math.cos(b) * Math.sin(g);
		var dy = -Math.sin(b);
		var dz = -Math.cos(b) * Math.cos(g);
		// Rotate device -> screen. The device is turned clockwise by `a`, so the
		// screen's axes are the device's turned counter-clockwise by the same
		// amount: at a = 90 the screen's +x IS the device's +y.
		var a = screenAngle() * Math.PI / 180.0;
		var ca = Math.cos(a);
		var sa = Math.sin(a);
		publish((dx * ca + dy * sa) * G, (-dx * sa + dy * ca) * G, dz * G);
	}, true);

	// iOS 13+ hands out orientation events only after an explicit grant, and only
	// asks when the request is made from inside a user gesture — so we ask on the
	// first touch and then get out of the way.
	function askPermission() {
		window.removeEventListener('pointerdown', askPermission, true);
		window.removeEventListener('touchend', askPermission, true);
		try {
			if (typeof DeviceOrientationEvent !== 'undefined'
					&& typeof DeviceOrientationEvent.requestPermission === 'function') {
				DeviceOrientationEvent.requestPermission().catch(function () {});
			}
		} catch (err) {}
	}
	window.addEventListener('pointerdown', askPermission, true);
	window.addEventListener('touchend', askPermission, true);
	console.log('[rally] tilt sensor installed');
})();
"""

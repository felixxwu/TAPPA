class_name UsernamePopup
extends CanvasLayer
# The leaderboard display-name capture (docs/superpowers/specs/
# 2026-07-31-global-leaderboards-design.md §3). A one-field modal built on the
# project's TextField, shaped like ConfirmPopup (dim backdrop + centred house
# panel + MenuNav-wired action row) so it reads as the same furniture.
#
# Named UsernamePopup, NOT Popup — Godot has a native Popup class.
#
# The name is NOT unique: two players may both be KANGAROO. There is no
# reservation document and therefore no "name taken" state to render.
#
# IT IS DISMISSABLE — Cancel, Esc and gamepad B all close it having written
# nothing. It is raised automatically just after a sign-in (AccountMenu.
# _maybe_prompt_username), and a player who signed in for cloud SAVE and does not
# care about leaderboards must not be held hostage by a text field to finish doing
# that. Nothing is lost by declining: the global standings page still offers
# "Choose a name to post" after every stage, and Settings -> Account has a row for
# it, so there are two standing ways back. A hard-modal here would buy a name from
# players who did not want one and would be the first un-escapable dialog in the
# game.
#
# It also owns the two statics for reading and writing profile["username"], so
# every caller (this popup, the global standings page, the account menu) goes
# through one sanitiser rather than each inventing its own.

signal finished(username: String)  # "" when cancelled

const MAX_LEN := 16
const PROFILE_KEY := "username"

var _field: TextField = null
var _done := false


# --- Profile access -----------------------------------------------------------

# The player's stored leaderboard name, "" when they have not chosen one. The key
# is backfilled by Save._migrate with no SCHEMA_VERSION bump, so an older profile
# simply reads "" here rather than erroring.
static func current() -> String:
	return sanitize(String(Save.profile.get(PROFILE_KEY, "")))


# Persist a chosen name. Returns the stored (sanitised) value, or "" if the input
# sanitised away to nothing — in which case nothing is written.
static func store(raw: String) -> String:
	var clean := sanitize(raw)
	if clean == "":
		return ""
	Save.profile[PROFILE_KEY] = clean
	Save.save()
	return clean


# The house rules from §3: uppercased (the UITheme.caps style the whole UI uses),
# filtered to A–Z / 0–9 / space, trimmed, capped at MAX_LEN characters. Interior
# runs of spaces are collapsed so "A      B" can't be used to fake a blank name.
# Pure + static so it is testable without building the popup.
static func sanitize(raw: String) -> String:
	var out := ""
	for c in UITheme.caps(raw):
		if (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c == " ":
			out += c
	while out.contains("  "):
		out = out.replace("  ", " ")
	out = out.strip_edges()
	if out.length() > MAX_LEN:
		out = out.substr(0, MAX_LEN).strip_edges()
	return out


# --- Building -----------------------------------------------------------------

# host: parent to attach under (its process mode is inherited, as ConfirmPopup's
# is). Returns the live popup so the caller can await/connect `finished` — or NULL
# when another modal is already on screen.
#
# SAME EXCLUSIVITY RULE AS ConfirmPopup, deliberately sharing its group rather than
# owning a second one: this popup is on the same layer 101, so "a modal is up" has
# to mean the same thing to both or they stack. Up to three AccountMenu instances
# can be alive at once and each used to keep its own `_username_prompt_open` bool
# (two of the three call sites checked nothing at all) — the exact topology that
# produced the double conflict prompt.
static func open(host: Node) -> UsernamePopup:
	if not is_instance_valid(host) or not host.is_inside_tree():
		return null
	var live := ConfirmPopup.any_open(host.get_tree())
	if live != null:
		push_warning("UsernamePopup refused: '%s' is already on screen." % [
			live.get_meta("modal_title", "another modal")])
		return null
	var popup := UsernamePopup.new()
	host.add_child(popup)
	popup._build()
	return popup


func _build() -> void:
	layer = 101  # above overlays, same as ConfirmPopup
	add_to_group(ConfirmPopup.MODAL_GROUP)  # one modal at a time — see ConfirmPopup
	set_meta("modal_title", "Choose a name")

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = UITheme.MODAL_DIM
	dim.mouse_filter = Control.MOUSE_FILTER_STOP  # swallow taps so nothing falls through
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := UITheme.panel(1.0, 20)
	center.add_child(panel)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", UITheme.GAP)
	vbox.custom_minimum_size = Vector2(420, 0)
	panel.add_child(vbox)

	vbox.add_child(UITheme.title("Choose a name"))
	var body := Label.new()
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.text = "This is the name other players see next to your time. " \
		+ "Letters, numbers and spaces, up to %d characters." % MAX_LEN
	vbox.add_child(body)

	_field = TextField.new("Name", "KANGAROO")
	_field.line.max_length = MAX_LEN
	_field.set_text(current())
	vbox.add_child(_field)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.GAP)
	vbox.add_child(row)
	var save_btn := _button("Save")
	save_btn.pressed.connect(_on_save)
	row.add_child(save_btn)
	var cancel := _button("Cancel")
	cancel.pressed.connect(_on_cancel)
	row.add_child(cancel)

	# Enter in the field submits — the ordinary expectation, and the only way to
	# submit on a phone where the on-screen keyboard covers the button.
	_field.submitted.connect(_on_save)
	TextField.wire_column([_field, save_btn])

	UITheme.enforce(self)
	# Keyboard + gamepad: the cursor lands in the field, up/down walk field ->
	# Save -> Cancel, and Back (Esc / gamepad B) cancels. MenuNav.is_text_editing
	# means the first Back press only releases the field, which is what a player
	# mid-typing expects.
	MenuNav.attach(center, {"first": _field.line, "on_back": _on_cancel})


func _button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = Vector2(0, UITheme.MENU_ROW_H)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return b


# --- Actions ------------------------------------------------------------------

func _on_save() -> void:
	if _done:
		return
	var stored := store(_field.text())
	if stored == "":
		# Nothing usable typed: stay open rather than closing on a silent no-op.
		_field.clear()
		UITheme.focus_grab(_field.line)
		return
	_close(stored)


func _on_cancel() -> void:
	_close("")


func _close(result: String) -> void:
	if _done:
		return
	_done = true
	finished.emit(result)
	queue_free()

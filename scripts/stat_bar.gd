class_name StatBar
extends HBoxContainer
# A segmented stat bar — a name, a row of blocks, and the figure itself.
#
# The point of the segments (rather than a smooth ProgressBar) is that they are COUNTABLE:
# "six blocks of twelve" is read at a glance and compared between cars without reading any
# number at all, which is the whole reason the simple upgrades page exists. The number
# still rides on the end for anyone who wants it.
#
# Every bar is scaled against the ROSTER, not against the car (CarStatBounds), so a full
# bar means "as good as this game gets" and a starter car genuinely looks like a starter
# car. See todo/simplified-upgrade-menu.md §3a.
#
# Blocks, in order:
#   green — the car AS IT SHIPS
#   gold  — what the player's UPGRADES added on top of stock
#   empty — the rest of the roster's range
# and, when the host set a power-to-weight cap, every filled block PAST the cap is painted
# red instead, so "over the line" is visible without reading the figure.
#
# Gold is the star colour on purpose: those blocks are literally what the stars bought, so
# the page shows a return on the spend without a word of explanation.
#
# The gold tier is NOT the same idea as the dimmed "headroom" tier that was tried here
# first and cut. Headroom coloured a stat the car does NOT yet have, which invites the
# reading "the pale part is also mine"; gold colours performance the car HAS, split by
# where it came from. One is a promise, the other is a fact — only the fact belongs on a
# bar being read at a glance. Where a car can still GET to remains the Auto-Upgrade
# button's job, stated in words ("210 to 260 hp/t").

# Long enough to read a real difference between two cars at a glance. Twelve blocks was
# too coarse: the roster's mid-field cars landed on the same count and the bars stopped
# discriminating exactly where most of the garage sits.
const SEGMENTS := 20
# Blocks carry a real MINIMUM WIDTH, not just an expand flag. The pages that host these
# bars shrink-wrap to their content, so a block whose minimum width is 0 contributes
# nothing to the row's minimum — the panel sizes itself around the name and figure labels
# alone and the whole bar collapses to invisible. The expand flag still lets the blocks
# take any extra width a wider panel offers.
const SEGMENT_W := 8.0
const SEGMENT_H := 12.0
const SEGMENT_GAP := 2
# The name and figure columns are kept narrow on purpose — every unit they give back goes
# to the blocks, which are the part the player actually reads.
const LABEL_MIN_W := 84.0
const VALUE_MIN_W := 78.0
const WRENCH_MIN_W := 34.0
# Every row is the same height whether or not it carries a wrench. UITheme.enforce pins
# single-line buttons to MENU_ROW_H, so a wrenched row is that tall while a wrenchless one
# is only as tall as its text — leaving the bars unevenly spaced down the page for a reason
# the player can't see. Pinning the ROW rather than padding the spacer keeps the two cases
# identical even if the button metrics change.
const ROW_H := UITheme.MENU_ROW_H

const _EMPTY_ALPHA := 0.18


# `value` is a 0..1 fraction of the roster range (CarStatBounds.fraction). `stock` is the
# same fraction for the car with NO upgrades fitted — blocks above it are painted gold as
# the player's own gains; pass < 0 for a row where "stock" means nothing (Condition).
# `limit` (0..1, or < 0 for none) marks a ceiling the car must stay under. `on_wrench`,
# when valid, adds a wrench button at the end of the row — the way into the upgrades that
# move THIS stat, so the bar is not just a readout but the handle for changing it.
static func build(name: String, value: float, text: String, stock := -1.0,
		limit := -1.0, on_wrench := Callable()) -> StatBar:
	var bar := StatBar.new()
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.custom_minimum_size = Vector2(0.0, ROW_H)
	bar.add_theme_constant_override("separation", 8)

	var key := UITheme.label(name)
	key.custom_minimum_size = Vector2(LABEL_MIN_W, 0.0)
	bar.add_child(key)

	var blocks := HBoxContainer.new()
	blocks.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	blocks.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	blocks.add_theme_constant_override("separation", SEGMENT_GAP)
	bar.add_child(blocks)
	# Round UP so any non-zero stat lights at least one block: a car that shows an
	# entirely empty bar reads as broken rather than as slow.
	var lit := 0 if value <= 0.0 else maxi(1, ceili(clampf(value, 0.0, 1.0) * SEGMENTS))
	var cap := -1 if limit < 0.0 else ceili(clampf(limit, 0.0, 1.0) * SEGMENTS)
	# A stock reading ABOVE the current one means the player has given performance away
	# (a detune, or ballast they left on), not gained it — so there is no gold to draw and
	# the whole filled run stays green.
	var base := lit if stock < 0.0 else mini(lit, maxi(1, ceili(clampf(stock, 0.0, 1.0) * SEGMENTS)))
	for i in SEGMENTS:
		blocks.add_child(_segment(i, lit, base, cap))

	var value_label := UITheme.label(text)
	value_label.custom_minimum_size = Vector2(VALUE_MIN_W, 0.0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	bar.add_child(value_label)
	if on_wrench.is_valid():
		bar.add_child(_wrench(name, on_wrench))
	else:
		# A row with no wrench still reserves its column, so the figures stay in one
		# vertical line. Letting the value label slide right to fill the space would make
		# the wrenchless rows the odd ones out — the eye reads a ragged column of numbers
		# as a mistake long before it works out which rows have a button.
		var gap := Control.new()
		gap.custom_minimum_size = Vector2(WRENCH_MIN_W, ROW_H)
		gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bar.add_child(gap)
	return bar


# The row's wrench. Built by hand rather than through UITheme.button, which pins a width
# floor meant for stacked columns and sets FOCUS_NONE — this has to hug its icon and it has
# to be reachable without a pointer (features/menus.md → Menu navigation). The stat name
# rides on the tooltip and the focus key, so keyboard focus survives the page rebuild a
# press triggers and the wrenches are told apart in a nav test.
static func _wrench(name: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.icon = WrenchIcon.texture()
	b.tooltip_text = "Change %s" % name
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = Vector2(WRENCH_MIN_W, 0.0)
	b.set_meta("upgrade_focus_key", "wrench:%s" % name.to_lower())
	b.pressed.connect(on_press)
	return b


static func _segment(index: int, lit: int, base: int, cap: int) -> Control:
	var block := ColorRect.new()
	block.custom_minimum_size = Vector2(SEGMENT_W, SEGMENT_H)
	block.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if index >= lit:
		block.color = Color(UITheme.INK.r, UITheme.INK.g, UITheme.INK.b, _EMPTY_ALPHA)
		return block
	# Over a cap the filled blocks past it go red — the one thing a player under a class
	# restriction needs to see, and it needs no reading. It OUTRANKS the stock/upgrade
	# split: which side of the line the car sits on matters more than where the power
	# came from.
	if cap >= 0 and index >= cap:
		block.color = UITheme.RED
	elif index >= base:
		block.color = UITheme.GOLD   # bought with stars
	else:
		block.color = UITheme.GREEN  # stock
	return block

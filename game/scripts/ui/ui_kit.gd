class_name UiKit
extends RefCounted

## Small factory helpers shared by every sub-panel.
##
## Everything here creates plain Control nodes and leans on `FlightLabTheme`
## type variations for their look — no `theme_override_*` calls, so restyling
## the whole panel means editing one file.

const T := preload("res://scripts/ui/flight_lab_theme.gd")


# --------------------------------------------------------------- structure ---

## A titled card. Returns the VBox the caller fills; the PanelContainer is
## already parented.
static func card(parent: Node, title: String = "") -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.theme_type_variation = "CardPanel"
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)
	if not title.is_empty():
		box.add_child(section_label(title))
	return box


static func section_label(text: String) -> Label:
	var l := Label.new()
	l.theme_type_variation = "SectionLabel"
	l.text = text.to_upper()
	return l


static func title_label(text: String) -> Label:
	var l := Label.new()
	l.theme_type_variation = "TitleLabel"
	l.text = text
	return l


## Wrapped explanatory copy.
static func body(parent: Node, text: String, variation: String = "BodyLabel") -> Label:
	var l := Label.new()
	l.theme_type_variation = variation
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.custom_minimum_size.x = 40
	parent.add_child(l)
	return l


static func hsep(parent: Node) -> HSeparator:
	var s := HSeparator.new()
	parent.add_child(s)
	return s


static func spacer(parent: Node, height: int = 4) -> Control:
	var c := Control.new()
	c.custom_minimum_size.y = height
	parent.add_child(c)
	return c


static func hspace(parent: Node) -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(c)
	return c


# ---------------------------------------------------------------- readouts ---

## key: value row. Returns the value Label so callers can update it cheaply.
static func kv(parent: Node, key: String, value: String = "—",
		value_variation: String = "ValueLabel", tooltip: String = "") -> Label:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(row)
	var k := Label.new()
	k.theme_type_variation = "SmallLabel"
	k.text = key
	k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(k)
	var v := Label.new()
	v.theme_type_variation = value_variation
	v.text = value
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(v)
	if not tooltip.is_empty():
		row.tooltip_text = tooltip
		k.tooltip_text = tooltip
		v.tooltip_text = tooltip
	return v


## A boxed instrument readout: small caption over a large value.
## Returns the value Label.
static func gauge(parent: Node, caption: String, value: String = "—",
		min_width: int = 74, variation: String = "BigValueLabel") -> Label:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	col.custom_minimum_size.x = min_width
	parent.add_child(col)
	var cap := Label.new()
	cap.theme_type_variation = "TinyLabel"
	cap.text = caption.to_upper()
	col.add_child(cap)
	var v := Label.new()
	v.theme_type_variation = variation
	v.text = value
	col.add_child(v)
	return v


# ------------------------------------------------------------------ chips ---

const CHIP_COLORS := {
	"speed": T.CHIP_SPEED,
	"glide": T.CHIP_GLIDE,
	"turn": T.CHIP_TURN,
	"fade": T.CHIP_FADE,
}

const CHIP_TOOLTIPS := {
	"speed": "Speed — how fast the disc must be thrown to fly as designed. Tracks rim width almost perfectly (R^2 = 0.96 over 43 moulds).",
	"glide": "Glide — how much lift the disc holds at low speed. Manufacturer-rated; the least well determined of the four from measured data.",
	"turn": "Turn — high-speed rightward deviation for a RHBH throw. Negative = turns more. In this model it comes from CM at low angle of attack.",
	"fade": "Fade — low-speed leftward finish for a RHBH throw. Higher = harder finish. Comes from CM at high angle of attack.",
}

static var _chip_styles: Dictionary = {}


static func _chip_style(c: Color) -> StyleBoxFlat:
	var key := c.to_html(false)
	if _chip_styles.has(key):
		return _chip_styles[key]
	var s := T.sb(c, 4, 0, c, 5, 1)
	_chip_styles[key] = s
	return s


## One flight-number cell, retail style: a coloured box with the number in it.
static func chip(kind: String, value: float) -> Control:
	var col: Color = CHIP_COLORS.get(kind, T.TEXT_DIM)
	var p := PanelContainer.new()
	p.theme_type_variation = "PlainPanel"
	p.add_theme_stylebox_override("panel", _chip_style(col))
	p.tooltip_text = CHIP_TOOLTIPS.get(kind, kind)
	var l := Label.new()
	l.text = _fmt_flight(value)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color", Color("06101c"))
	l.add_theme_font_size_override("font_size", T.FS_SMALL)
	l.custom_minimum_size.x = 20
	p.add_child(l)
	return p


static func _fmt_flight(v: float) -> String:
	if is_equal_approx(v, roundf(v)):
		return str(int(roundf(v)))
	return "%.1f" % v


## The four flight numbers in the conventional speed / glide / turn / fade order.
static func flight_chips(parent: Node, numbers: Dictionary, with_caption: bool = false) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 3)
	parent.add_child(row)
	for kind in ["speed", "glide", "turn", "fade"]:
		var cell := VBoxContainer.new()
		cell.add_theme_constant_override("separation", 1)
		row.add_child(cell)
		cell.add_child(chip(kind, float(numbers.get(kind, 0.0))))
		if with_caption:
			var cap := Label.new()
			cap.theme_type_variation = "TinyLabel"
			cap.text = kind.substr(0, 1).to_upper()
			cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			cell.add_child(cap)
	return row


# ----------------------------------------------------------------- badges ---

static func badge(text: String, variation: String, tooltip: String = "") -> PanelContainer:
	var p := PanelContainer.new()
	p.theme_type_variation = variation
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var l := Label.new()
	l.theme_type_variation = "TinyLabel"
	l.text = text
	match variation:
		"BadgeMeasured":
			l.add_theme_color_override("font_color", T.OK_TEXT)
		"BadgeDerived":
			l.add_theme_color_override("font_color", T.TEXT_DIM)
	p.add_child(l)
	if not tooltip.is_empty():
		p.tooltip_text = tooltip
		l.tooltip_text = tooltip
	return p


# ---------------------------------------------------------------- buttons ---

static func button(parent: Node, text: String, variation: String = "GhostButton",
		tooltip: String = "") -> Button:
	var b := Button.new()
	b.text = text
	b.theme_type_variation = variation
	b.tooltip_text = tooltip
	b.focus_mode = Control.FOCUS_NONE
	parent.add_child(b)
	return b


static func check(parent: Node, text: String, pressed: bool, tooltip: String = "") -> CheckButton:
	var c := CheckButton.new()
	c.text = text
	c.button_pressed = pressed
	c.tooltip_text = tooltip
	c.focus_mode = Control.FOCUS_NONE
	parent.add_child(c)
	return c


static func option(parent: Node, items: Array, selected: int = 0, tooltip: String = "") -> OptionButton:
	var o := OptionButton.new()
	for it in items:
		o.add_item(str(it))
	if selected >= 0 and selected < o.item_count:
		o.select(selected)
	o.tooltip_text = tooltip
	o.fit_to_longest_item = false
	o.clip_text = true
	o.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(o)
	return o


static func labeled(parent: Node, text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(row)
	var l := Label.new()
	l.theme_type_variation = "SmallLabel"
	l.text = text
	l.custom_minimum_size.x = 62
	row.add_child(l)
	return row


# ------------------------------------------------------------- formatting ---

static func fmt(value: float, decimals: int = 1, unit: String = "") -> String:
	var s := String.num(value, decimals)
	if unit.is_empty():
		return s
	return "%s %s" % [s, unit]


## Signed lateral distance, spoken the way a disc golfer would.
static func fmt_lateral(metres: float) -> String:
	if absf(metres) < 0.05:
		return "0.0 m"
	var side := "R" if metres > 0.0 else "L"
	return "%.1f m %s" % [absf(metres), side]


static func category_label(category: String) -> String:
	return category.replace("_", " ").capitalize()

class_name SliderField
extends VBoxContainer

## A labelled slider with a numeric entry box, a live secondary readout and an
## optional validity flag.
##
## Units: the field works entirely in *display* units (degrees, millimetres,
## grams, rev/s). `unit_scale` records the factor that converts a display value
## to the SI value the physics wants, and `si_value()` applies it. Conversion
## therefore happens exactly once, at the UI boundary, per CONTRACT §1.

signal value_changed(display_value: float)

enum Flag { NONE, OK, WARN, BAD }

var slider: HSlider
var spin: SpinBox
var name_label: Label
var hint_label: Label

## Multiply a display value by this to get SI (e.g. 0.001 for millimetres).
var unit_scale: float = 1.0

var _syncing: bool = false


func _init(
		label: String,
		min_value: float,
		max_value: float,
		step: float,
		initial: float,
		unit: String = "",
		tooltip: String = "",
		scale_to_si: float = 1.0) -> void:
	unit_scale = scale_to_si
	add_theme_constant_override("separation", 1)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if not tooltip.is_empty():
		tooltip_text = tooltip

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	add_child(head)

	name_label = Label.new()
	name_label.theme_type_variation = "SmallLabel"
	name_label.text = label
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.clip_text = true
	head.add_child(name_label)

	hint_label = Label.new()
	hint_label.theme_type_variation = "TinyLabel"
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hint_label.visible = false
	head.add_child(hint_label)

	spin = SpinBox.new()
	spin.min_value = min_value
	spin.max_value = max_value
	spin.step = step
	spin.value = initial
	spin.suffix = unit
	spin.allow_greater = false
	spin.allow_lesser = false
	spin.select_all_on_focus = true
	# Wide enough for the longest value+unit this panel produces ("212.0 mm",
	# "21.0 rev/s", "9.81 m/s²") plus the stepper arrows. A LineEdit clips its
	# left when right-aligned text overflows, which silently turns 212 into 12.
	spin.custom_minimum_size.x = 116
	spin.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	head.add_child(spin)

	slider = HSlider.new()
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = step
	slider.value = initial
	slider.custom_minimum_size.y = 14
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.focus_mode = Control.FOCUS_CLICK
	add_child(slider)

	slider.value_changed.connect(_on_slider)
	spin.value_changed.connect(_on_spin)


func _on_slider(v: float) -> void:
	if _syncing:
		return
	_syncing = true
	spin.value = v
	_syncing = false
	value_changed.emit(v)


func _on_spin(v: float) -> void:
	if _syncing:
		return
	_syncing = true
	slider.value = v
	_syncing = false
	value_changed.emit(v)


# -------------------------------------------------------------------- api ---

func get_value() -> float:
	return slider.value


## The value in SI units, ready to hand to the physics core.
func si_value() -> float:
	return slider.value * unit_scale


func set_value_silent(v: float) -> void:
	_syncing = true
	slider.value = v
	spin.value = slider.value
	_syncing = false


## Change the usable range (used when the disc category changes). The current
## value is clamped into the new range rather than left illegal.
func set_range(min_value: float, max_value: float, step: float = -1.0) -> void:
	_syncing = true
	if step > 0.0:
		slider.step = step
		spin.step = step
	slider.min_value = min_value
	slider.max_value = max_value
	spin.min_value = min_value
	spin.max_value = max_value
	var v: float = clampf(slider.value, min_value, max_value)
	slider.value = v
	spin.value = v
	_syncing = false


## Secondary readout to the right of the label — a converted unit, a ratio, a
## rule of thumb. Empty string hides it.
func set_hint(text: String) -> void:
	hint_label.text = text
	hint_label.visible = not text.is_empty()


## Colour the label to flag a value that is legal-but-odd or outright illegal.
func set_flag(flag: int, reason: String = "") -> void:
	match flag:
		Flag.OK:
			name_label.add_theme_color_override("font_color", FlightLabTheme.OK_TEXT)
		Flag.WARN:
			name_label.add_theme_color_override("font_color", FlightLabTheme.WARN_TEXT)
		Flag.BAD:
			name_label.add_theme_color_override("font_color", FlightLabTheme.BAD_TEXT)
		_:
			name_label.remove_theme_color_override("font_color")
	name_label.tooltip_text = reason

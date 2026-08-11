class_name ThrowPanel
extends VBoxContainer

## Release conditions. Everything on screen is in degrees, metres and rev/s;
## `build_params()` is the one place where degrees become radians, per
## CONTRACT §1.

signal params_changed()

const T := preload("res://scripts/ui/flight_lab_theme.gd")

## Per-category ranges and defaults. A putter's speed range is not a driver's,
## and offering a 30 m/s putt as the middle of the slider teaches the wrong
## thing. Values are what a good amateur through a touring pro would produce.
## [speed_min, speed_max, speed_default, spin_default, launch_deg, hyzer_deg]
##
## ---------------------------------------------------------------------------
## These defaults were measured, and the hyzer numbers are a model artefact
## ---------------------------------------------------------------------------
## Every default below was chosen by sweeping launch angle × hyzer angle for the
## discs in that category through the shipped physics and picking a release
## whose flight matches what the category is supposed to do. The earlier set was
## never swept and showed badly: the putter default was 13 m/s, which is a
## *putt* (16 m), not the ~18 m/s drive CONTRACT §5 specifies; and the distance
## driver default of 9° hyzer produced a Destroyer that flew 78.6 m and finished
## 20 m RIGHT — an overstable 12-speed that never fades back, which is the first
## thing a user would see and would read as a broken simulator.
##
## The distance-driver hyzer of 22° is much more than a real thrower uses, and
## that is a **known limitation of the model, not a modelling choice made here**.
## The shipped precession law carries an empirical `PRECESSION_GAIN = 2.0`
## (CONTRACT §4 v3) that doubles the whole precession response — the early turn
## as well as the late fade — so every roster disc with a published turn of −1
## or lower turns over and stays right when released flat, and needs 18–22° of
## hyzer to come back. Discs with turn 0 (Teebird, Firebird, Aviar, Zone, Roc)
## behave correctly from flat. See README.md, "What this model gets wrong".
## The 13°/22° distance-driver release is also exactly the one
## `tools/aero/validation/destroyer_power_drive.json` publishes, so pressing
## THROW on a Destroyer reproduces the documented reference flight (113.5 m).
const CATEGORY_PROFILE := {
	"putter":          [4.0, 22.0, 18.0, 16.0, 8.0, 2.0],
	"approach":        [5.0, 24.0, 19.0, 17.0, 8.0, 3.0],
	"midrange":        [6.0, 28.0, 22.0, 20.0, 8.0, 3.0],
	"fairway_driver":  [8.0, 32.0, 24.0, 22.0, 9.0, 6.0],
	"control_driver":  [9.0, 36.0, 26.0, 24.0, 10.0, 8.0],
	"distance_driver": [10.0, 40.0, 27.0, 25.0, 13.0, 22.0],
}
const DEFAULT_PROFILE := [5.0, 36.0, 22.0, 20.0, 9.0, 6.0]

var speed: SliderField
var spin: SliderField
var nose: SliderField
var hyzer: SliderField
var launch: SliderField
var height: SliderField
var heading: SliderField

var _category: String = ""
var _profile: Array = DEFAULT_PROFILE
var _fields: Array[SliderField] = []


func _init() -> void:
	add_theme_constant_override("separation", 8)

	var card := UiKit.card(self, "Release")

	# Handedness / technique. This is the fastest way to explain the sign of
	# the spin field, which CONTRACT §1 calls the most important sign in the
	# project.
	var hand := HBoxContainer.new()
	hand.add_theme_constant_override("separation", 4)
	card.add_child(hand)
	var lbl := Label.new()
	lbl.theme_type_variation = "SmallLabel"
	lbl.text = "Technique"
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hand.add_child(lbl)
	var bh := UiKit.button(hand, "RHBH / LHFH", "SegButton",
		"Right-hand backhand (or left-hand forehand): positive spin. The disc turns right early and fades left late.")
	var fh := UiKit.button(hand, "RHFH / LHBH", "SegButton",
		"Right-hand forehand (or left-hand backhand): negative spin. Mirror image — turns left early, fades right late.")
	bh.pressed.connect(func() -> void: _set_spin_sign(1.0))
	fh.pressed.connect(func() -> void: _set_spin_sign(-1.0))

	speed = _add(card, SliderField.new("Launch speed", 4.0, 40.0, 0.5, 20.0, " m/s",
		"Speed of the disc's centre of mass at release."))
	spin = _add(card, SliderField.new("Spin", -45.0, 45.0, 0.5, 20.0, " rev/s",
		"Signed: positive is RHBH (the angular velocity vector points down through the disc). Negative flips turn and fade to the other side. More spin means a stabler flight — spin is the gain on the aerodynamic torque, not a source of curve."))
	nose = _add(card, SliderField.new("Nose angle", -20.0, 20.0, 0.5, 0.0, "°",
		"Disc pitch relative to the velocity vector. Nose up costs distance fast; a nose-down release is what long drivers are doing."))
	hyzer = _add(card, SliderField.new("Hyzer / anhyzer", -60.0, 60.0, 0.5, 4.0, "°",
		"Bank angle at release. Positive is hyzer (right edge down for a RHBH throw); negative is anhyzer."))
	launch = _add(card, SliderField.new("Launch angle", -30.0, 45.0, 0.5, 6.0, "°",
		"Elevation of the velocity vector above horizontal."))
	height = _add(card, SliderField.new("Release height", 0.1, 2.5, 0.05, 1.4, " m",
		"Height of the disc above the tee at release."))
	heading = _add(card, SliderField.new("Aim", -45.0, 45.0, 0.5, 0.0, "°",
		"Heading of the throw. 0 is straight downrange; positive aims right."))

	var note := UiKit.card(self, "Sign convention")
	UiKit.body(note, "Positive spin is RHBH — the spin vector points down through the disc while lift acts up along the disc normal. Turn and fade come out of the pitching moment CM(α) precessing that gyroscope, so flipping the sign of spin mirrors the flight and changes nothing else.")

	_update_hints()


func _add(parent: Node, field: SliderField) -> SliderField:
	parent.add_child(field)
	field.value_changed.connect(_on_any_changed)
	_fields.append(field)
	return field


func _on_any_changed(_v: float) -> void:
	_update_hints()
	params_changed.emit()


func _set_spin_sign(sign_value: float) -> void:
	var magnitude: float = absf(spin.get_value())
	if magnitude < 0.5:
		magnitude = float(_profile[3])
	spin.set_value_silent(sign_value * magnitude)
	_on_any_changed(0.0)


func _update_hints() -> void:
	speed.set_hint("%.0f mph" % (speed.get_value() * 2.23694))
	var rpm: float = spin.get_value() * 60.0
	spin.set_hint("%s · %.0f rpm" % ["RHBH" if spin.get_value() >= 0.0 else "RHFH", absf(rpm)])
	var n: float = nose.get_value()
	nose.set_hint("nose up" if n > 0.5 else ("nose down" if n < -0.5 else "flat"))
	var hy: float = hyzer.get_value()
	hyzer.set_hint("hyzer" if hy > 0.5 else ("anhyzer" if hy < -0.5 else "flat"))
	var hd: float = heading.get_value()
	heading.set_hint("right" if hd > 0.5 else ("left" if hd < -0.5 else "downrange"))


# -------------------------------------------------------------------- api ---

## Retune the ranges and defaults when the selected disc's category changes.
## Values already on screen are kept where they still make sense and clamped
## where they do not, so browsing within a category never disturbs a setup.
func apply_category(category: String, force_defaults: bool = false) -> bool:
	var changed := force_defaults or category != _category
	_category = category
	_profile = CATEGORY_PROFILE.get(category, DEFAULT_PROFILE)
	speed.set_range(float(_profile[0]), float(_profile[1]))
	if changed:
		reset_to_defaults()
	_update_hints()
	return changed


func reset_to_defaults() -> void:
	speed.set_value_silent(float(_profile[2]))
	var sign_value: float = 1.0 if spin.get_value() >= 0.0 else -1.0
	spin.set_value_silent(sign_value * float(_profile[3]))
	nose.set_value_silent(0.0)
	hyzer.set_value_silent(float(_profile[5]))
	launch.set_value_silent(float(_profile[4]))
	height.set_value_silent(1.4)
	heading.set_value_silent(0.0)
	_update_hints()
	params_changed.emit()


## THE units boundary: degrees in the widgets, radians in the contract type.
func build_params() -> DiscFlightSim.ThrowParams:
	var p := DiscFlightSim.ThrowParams.new()
	p.speed_mps = speed.get_value()
	p.spin_rps = spin.get_value()
	p.nose_angle_rad = deg_to_rad(nose.get_value())
	p.hyzer_angle_rad = deg_to_rad(hyzer.get_value())
	p.launch_angle_rad = deg_to_rad(launch.get_value())
	p.launch_height_m = height.get_value()
	p.launch_heading_rad = deg_to_rad(heading.get_value())
	return p


## Compact description for the comparison table.
func summary() -> String:
	return "%.0f m/s · %.0f rev/s · %s%.0f°" % [
		speed.get_value(), spin.get_value(),
		"+" if hyzer.get_value() >= 0.0 else "", hyzer.get_value()]

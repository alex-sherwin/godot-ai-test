class_name EnvironmentPanel
extends VBoxContainer

## Air, wind and gravity.
##
## The quantity the physics actually reads is air density, and nothing on this
## panel sets it directly — it falls out of altitude and temperature through the
## ISA barometric formula. Showing the derived number next to the two sliders
## that move it is the whole point: it is why a drive in Denver goes further and
## fades later than the same drive at sea level.

signal env_changed()

const T := preload("res://scripts/ui/flight_lab_theme.gd")
const SEA_LEVEL_DENSITY := 1.225

const ALTITUDE_PRESETS := [
	["Sea level", 0.0],
	["Charlotte, NC — 230 m", 230.0],
	["Denver, CO — 1609 m", 1609.0],
	["Mexico City — 2240 m", 2240.0],
	["Leadville, CO — 3094 m", 3094.0],
]

const GRAVITY_PRESETS := [
	["Earth 9.81", 9.81],
	["Moon 1.62", 1.62],
	["Mars 3.72", 3.72],
	["Jupiter 24.79", 24.79],
]

var wind_speed: SliderField
var altitude: SliderField
var temperature: SliderField
var gravity: SliderField
var dial: CompassDial

var _density_label: Label
var _density_delta: Label
var _headwind_label: Label
var _crosswind_label: Label
var _vector_label: Label
var _range_note: Label


func _init() -> void:
	add_theme_constant_override("separation", 8)

	# ---- wind --------------------------------------------------------
	var wind := UiKit.card(self, "Wind")

	dial = CompassDial.new()
	wind.add_child(dial)
	dial.direction_changed.connect(func(_d: float) -> void: _refresh())

	var wcol := VBoxContainer.new()
	wcol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wcol.add_theme_constant_override("separation", 4)
	wind.add_child(wcol)

	wind_speed = SliderField.new("Wind speed", 0.0, 20.0, 0.1, 0.0, " m/s",
		"Steady wind. Aerodynamic forces use the disc's airspeed — velocity minus wind — while gravity stays in the world frame.")
	wcol.add_child(wind_speed)
	wind_speed.value_changed.connect(func(v: float) -> void:
		dial.speed_mps = v
		_refresh())

	_headwind_label = UiKit.kv(wcol, "Headwind", "0.0 m/s", "ValueLabel",
		"Component opposing the throw. A headwind raises the angle of attack, which is why discs turn over less and fade harder into the wind.")
	_crosswind_label = UiKit.kv(wcol, "Crosswind", "0.0 m/s", "ValueLabel",
		"Component across the throw. Positive pushes the disc to the thrower's right.")
	_vector_label = UiKit.kv(wcol, "World vector", "(0, 0, 0)", "SmallLabel",
		"The wind as the physics core sees it: Y-up, −Z downrange, +X to the thrower's right.")

	# ---- air ---------------------------------------------------------
	var air := UiKit.card(self, "Air")
	var preset_row := UiKit.labeled(air, "Preset")
	var alt_preset := UiKit.option(preset_row, ALTITUDE_PRESETS.map(func(p: Array) -> String: return p[0]), 0)
	alt_preset.item_selected.connect(func(i: int) -> void:
		altitude.set_value_silent(float(ALTITUDE_PRESETS[i][1]))
		_refresh())

	# 1 m steps rather than 10: the presets are real elevations (Denver is
	# 1609 m, not 1610) and a typed value should survive the round trip.
	altitude = SliderField.new("Altitude", 0.0, 3500.0, 1.0, 0.0, " m",
		"Elevation above sea level. Thinner air means less lift and less drag: more distance, a later and weaker fade.")
	air.add_child(altitude)
	altitude.value_changed.connect(func(_v: float) -> void: _refresh())

	temperature = SliderField.new("Temperature", -20.0, 45.0, 0.5, 15.0, " °C",
		"Local air temperature. Warm air is thinner air.")
	air.add_child(temperature)
	temperature.value_changed.connect(func(_v: float) -> void: _refresh())

	var dbox := PanelContainer.new()
	dbox.theme_type_variation = "InsetPanel"
	air.add_child(dbox)
	var dcol := VBoxContainer.new()
	dcol.add_theme_constant_override("separation", 0)
	dbox.add_child(dcol)
	var cap := Label.new()
	cap.theme_type_variation = "TinyLabel"
	cap.text = "AIR DENSITY — THE NUMBER THE PHYSICS READS"
	dcol.add_child(cap)
	var drow := HBoxContainer.new()
	drow.add_theme_constant_override("separation", 8)
	dcol.add_child(drow)
	_density_label = Label.new()
	_density_label.theme_type_variation = "HugeValueLabel"
	_density_label.text = "1.225"
	drow.add_child(_density_label)
	var unit := Label.new()
	unit.theme_type_variation = "SmallLabel"
	unit.text = "kg/m³"
	unit.size_flags_vertical = Control.SIZE_SHRINK_END
	drow.add_child(unit)
	UiKit.hspace(drow)
	_density_delta = Label.new()
	_density_delta.theme_type_variation = "SmallLabel"
	_density_delta.size_flags_vertical = Control.SIZE_SHRINK_END
	drow.add_child(_density_delta)

	_range_note = Label.new()
	_range_note.theme_type_variation = "TinyLabel"
	_range_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_range_note.custom_minimum_size.x = 40
	air.add_child(_range_note)

	# ---- gravity -----------------------------------------------------
	var grav := UiKit.card(self, "Gravity")
	gravity = SliderField.new("Gravity", 0.5, 25.0, 0.01, 9.81, " m/s²",
		"Left in because a 175 g disc thrown on the Moon is a genuinely interesting flight: the same lift now supports six times the hang time.")
	grav.add_child(gravity)
	gravity.value_changed.connect(func(_v: float) -> void: _refresh())
	var grow := HBoxContainer.new()
	grow.add_theme_constant_override("separation", 4)
	grav.add_child(grow)
	for preset: Array in GRAVITY_PRESETS:
		var b := UiKit.button(grow, preset[0], "SegButton")
		var value: float = preset[1]
		b.pressed.connect(func() -> void:
			gravity.set_value_silent(value)
			_refresh())

	_refresh()


func _refresh() -> void:
	var rho := air_density()
	_density_label.text = "%.3f" % rho
	var pct: float = (rho / SEA_LEVEL_DENSITY - 1.0) * 100.0
	_density_delta.text = "%+.1f%% vs sea level, 15 °C" % pct
	_density_delta.add_theme_color_override("font_color",
		T.TEXT_DIM if absf(pct) < 1.0 else (T.CHIP_TURN if pct < 0.0 else T.ACCENT_BRIGHT))

	var w: float = wind_speed.get_value()
	var b: float = dial.bearing_deg
	_headwind_label.text = "%+.1f m/s" % CompassDial.headwind(b, w)
	_crosswind_label.text = "%+.1f m/s" % CompassDial.crosswind(b, w)
	var v := CompassDial.wind_vector(b, w)
	_vector_label.text = "(%.1f, %.1f, %.1f)" % [v.x, v.y, v.z]

	if absf(pct) < 0.5:
		_range_note.text = "Standard conditions. Every aerodynamic force scales with this number, so it moves lift and drag together."
	else:
		var sign_word := "less" if pct < 0.0 else "more"
		_range_note.text = "%.1f%% %s air than standard. Lift and drag both scale with density, so thin air flies further and fades later — the disc keeps more speed but generates less of the moment that turns it." % [absf(pct), sign_word]

	env_changed.emit()


# -------------------------------------------------------------------- api ---

func air_density() -> float:
	return Atmosphere.air_density(altitude.get_value(), temperature.get_value())


func build_environment() -> DiscFlightSim.FlightEnvironment:
	# NOTE: CONTRACT §4 calls this type `Environment`; Godot reserves that
	# identifier for a native class, so Track B named it `FlightEnvironment`.
	var env := DiscFlightSim.FlightEnvironment.new()
	env.air_density = air_density()
	env.wind = CompassDial.wind_vector(dial.bearing_deg, wind_speed.get_value())
	env.gravity = gravity.get_value()
	return env


func reset_to_defaults() -> void:
	wind_speed.set_value_silent(0.0)
	dial.speed_mps = 0.0
	dial.bearing_deg = 0.0
	altitude.set_value_silent(0.0)
	temperature.set_value_silent(15.0)
	gravity.set_value_silent(9.81)
	_refresh()


func summary() -> String:
	var w: float = wind_speed.get_value()
	if w < 0.05:
		return "%.0f m · %.0f °C · calm" % [altitude.get_value(), temperature.get_value()]
	return "%.0f m · %.0f °C · %.1f m/s %s" % [
		altitude.get_value(), temperature.get_value(), w,
		CompassDial._quadrant(dial.bearing_deg)]

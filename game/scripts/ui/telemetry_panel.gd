class_name TelemetryPanel
extends VBoxContainer

## Live instrument readouts during the flight, the landing summary afterwards,
## and a comparison table of recent throws.
##
## `push_live()` runs every rendered frame, so it does no allocation, no layout
## and no node creation — it writes strings into labels that already exist, at
## 20 Hz, and skips the work entirely when the panel is not on screen.

signal cleared()

const T := preload("res://scripts/ui/flight_lab_theme.gd")
const MAX_ROWS := 8
const UPDATE_HZ := 20.0

var _live: Dictionary = {}
var _hud: Dictionary = {}
var _result: Dictionary = {}
var _table: GridContainer
var _table_hint: Label
var _status_dot: Panel
var _phase_label: Label

var _origin := Vector3.ZERO
var _origin_valid := false
var _accum := 0.0
var _rows := 0
var _best_distance := 0.0
var _flying := false


func _init() -> void:
	add_theme_constant_override("separation", 8)

	# ---- live --------------------------------------------------------
	var live := UiKit.card(self, "In flight")
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	live.add_child(head)
	_status_dot = Panel.new()
	_status_dot.custom_minimum_size = Vector2(8, 8)
	_status_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_status_dot.add_theme_stylebox_override("panel", T.sb(T.TEXT_FAINT, 999, 0, T.BORDER, 0, 0))
	head.add_child(_status_dot)
	_phase_label = Label.new()
	_phase_label.theme_type_variation = "SmallLabel"
	_phase_label.text = "Ready"
	head.add_child(_phase_label)

	var grid := GridContainer.new()
	grid.columns = 3
	live.add_child(grid)
	_live["speed"] = UiKit.gauge(grid, "Speed m/s", "—", 78)
	_live["spin"] = UiKit.gauge(grid, "Spin rev/s", "—", 78)
	_live["alpha"] = UiKit.gauge(grid, "AoA °", "—", 78,)
	_live["altitude"] = UiKit.gauge(grid, "Height m", "—", 78)
	_live["distance"] = UiKit.gauge(grid, "Distance m", "—", 78)
	_live["time"] = UiKit.gauge(grid, "Time s", "—", 78)
	grid.get_child(2).tooltip_text = "Angle of attack: the angle between the disc's plane and the air flowing over it. It is what selects the pitching moment, and therefore whether the disc is turning or fading right now."

	# ---- result ------------------------------------------------------
	var res := UiKit.card(self, "Last throw")
	var rgrid := GridContainer.new()
	rgrid.columns = 2
	rgrid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	res.add_child(rgrid)
	_result["distance"] = UiKit.kv(rgrid, "Distance", "—", "ValueLabel", "Straight-line distance from release to landing.")
	_result["lateral"] = UiKit.kv(rgrid, "Lateral", "—", "ValueLabel", "Signed offset from the aim line at landing. R is right of the line, L is left.")
	_result["peak"] = UiKit.kv(rgrid, "Max height", "—", "ValueLabel")
	_result["time"] = UiKit.kv(rgrid, "Flight time", "—", "ValueLabel")
	_result["spin"] = UiKit.kv(rgrid, "Spin retained", "—", "ValueLabel", "Fraction of the release spin still left at landing. A real flight loses 10–20%; spin acts as the gain on the aerodynamic torque, so a disc that keeps its spin resists both turn and fade.")
	_result["glide"] = UiKit.kv(rgrid, "Avg speed", "—", "ValueLabel")

	# ---- comparison --------------------------------------------------
	var comp := UiKit.card(self, "Recent throws")
	var chead := HBoxContainer.new()
	comp.add_child(chead)
	_table_hint = Label.new()
	_table_hint.theme_type_variation = "TinyLabel"
	_table_hint.text = "Throw a few discs to compare them."
	_table_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chead.add_child(_table_hint)
	var clear := UiKit.button(chead, "Clear", "GhostButton", "Empty the comparison table.")
	clear.pressed.connect(func() -> void:
		clear_history()
		cleared.emit())

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.custom_minimum_size.y = 120
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	comp.add_child(scroll)

	_table = GridContainer.new()
	_table.columns = 5
	_table.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_table)
	_add_header()


func _add_header() -> void:
	for h in ["Disc", "Dist", "Lat", "Peak", "Time"]:
		var l := Label.new()
		l.theme_type_variation = "TinyLabel"
		l.text = h.to_upper()
		if h != "Disc":
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		else:
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_table.add_child(l)


# ------------------------------------------------------------------- live ---

func begin_flight() -> void:
	_origin_valid = false
	_flying = true
	_accum = 999.0
	_phase_label.text = "In flight"
	_status_dot.add_theme_stylebox_override("panel", T.sb(T.ACCENT_BRIGHT, 999, 0, T.BORDER, 0, 0))


func end_flight() -> void:
	_flying = false
	_phase_label.text = "Landed"
	_status_dot.add_theme_stylebox_override("panel", T.sb(T.OK_TEXT, 999, 0, T.BORDER, 0, 0))


func reset_live() -> void:
	_flying = false
	_origin_valid = false
	_phase_label.text = "Ready"
	_status_dot.add_theme_stylebox_override("panel", T.sb(T.TEXT_FAINT, 999, 0, T.BORDER, 0, 0))
	for key: String in _live:
		_live[key].text = "—"
	for key: String in _hud:
		_hud[key].text = "—"


## The always-visible HUD strip is owned by ControlPanel; it hands its labels
## over so both readouts are filled from one throttled update.
func attach_hud(labels: Dictionary) -> void:
	_hud = labels


## Called every rendered frame. Cheap on purpose: it formats six numbers at
## 20 Hz and writes them into labels that already exist. No allocation of
## nodes, no layout, no work at all in between ticks.
func push_live(state: DiscFlightSim.DiscState, alpha_deg: float, delta: float) -> void:
	if not _origin_valid:
		_origin = state.position
		_origin_valid = true
	_accum += delta
	if _accum < 1.0 / UPDATE_HZ:
		return
	_accum = 0.0
	var flat := Vector2(state.position.x - _origin.x, state.position.z - _origin.z)
	var values := {
		"speed": "%.1f" % state.velocity.length(),
		"spin": "%.1f" % (state.spin / TAU),
		"alpha": "%.1f" % alpha_deg,
		"altitude": "%.1f" % state.position.y,
		"distance": "%.1f" % flat.length(),
		"time": "%.2f" % state.time,
	}
	for key: String in _hud:
		_hud[key].text = values[key]
	if not is_visible_in_tree():
		return
	for key: String in _live:
		_live[key].text = values[key]


# ----------------------------------------------------------------- result ---

func show_result(result: DiscFlightSim.FlightResult, disc_name: String, provenance: String,
		release: String) -> void:
	end_flight()
	_result["distance"].text = "%.1f m" % result.distance_m
	_result["lateral"].text = UiKit.fmt_lateral(result.lateral_m)
	_result["peak"].text = "%.1f m" % result.max_height_m
	_result["time"].text = "%.2f s" % result.flight_time_s
	# `spin_retained` is an additive extra on Track B's FlightResult rather than
	# a CONTRACT §4 field, so it is read defensively.
	if "spin_retained" in result:
		set_spin_retained(float(result.spin_retained))
	else:
		_result["spin"].text = "—"
	if result.flight_time_s > 0.01:
		_result["glide"].text = "%.1f m/s" % (result.distance_m / result.flight_time_s)
	else:
		_result["glide"].text = "—"
	_add_row(disc_name, provenance, release, result)


func set_spin_retained(fraction: float) -> void:
	_result["spin"].text = "%.0f%%" % (fraction * 100.0)


func _add_row(disc_name: String, provenance: String, release: String,
		result: DiscFlightSim.FlightResult) -> void:
	_table_hint.text = "Most recent first · %d shown" % mini(_rows + 1, MAX_ROWS)

	# Newest first: insert directly after the header row.
	var cells: Array[Control] = []

	var name_box := HBoxContainer.new()
	name_box.add_theme_constant_override("separation", 4)
	name_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var dot := Panel.new()
	dot.custom_minimum_size = Vector2(6, 6)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.add_theme_stylebox_override("panel",
		T.sb(Provenance.dot_color(provenance), 999, 0, T.BORDER, 0, 0))
	dot.tooltip_text = Provenance.one_liner(provenance)
	name_box.add_child(dot)
	var n := Label.new()
	n.theme_type_variation = "SmallLabel"
	n.text = disc_name
	n.clip_text = true
	n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	n.tooltip_text = "%s — %s" % [disc_name, release]
	name_box.add_child(n)
	cells.append(name_box)

	var best: bool = result.distance_m > _best_distance + 0.05
	if best:
		_best_distance = result.distance_m
	cells.append(_cell("%.1f" % result.distance_m, best))
	cells.append(_cell(UiKit.fmt_lateral(result.lateral_m).replace(" m", ""), false))
	cells.append(_cell("%.1f" % result.max_height_m, false))
	cells.append(_cell("%.2f" % result.flight_time_s, false))

	for i in range(cells.size()):
		_table.add_child(cells[i])
		_table.move_child(cells[i], _table.columns + i)
	_rows += 1

	while _rows > MAX_ROWS:
		for i in range(_table.columns):
			var idx: int = _table.get_child_count() - 1
			_table.get_child(idx).free()
		_rows -= 1


func _cell(text: String, highlight: bool) -> Label:
	var l := Label.new()
	l.theme_type_variation = "ValueLabel" if highlight else "SmallLabel"
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	return l


func clear_history() -> void:
	for c in _table.get_children():
		c.free()
	_rows = 0
	_best_distance = 0.0
	_add_header()
	_table_hint.text = "Throw a few discs to compare them."

class_name ControlPanel
extends Control

## The whole user interface for Disc Golf Flight Lab, as one node Track C drops
## into the main scene.
##
## Layout, deliberately: the 3D view is the product and the panel serves it, so
## the panel never covers the fairway. A slide-out drawer on the right holds
## everything that is a *setting*; a strip at the top left holds the live
## instrument readout; a bar along the bottom holds the *actions*. The drawer
## collapses to a single button, and every action it holds also has a keyboard
## shortcut, so the range can always be made the whole screen.
##
## The C ↔ D interface is the signals and the five `set_*` methods below, and
## nothing else. Sub-panels never reach outside themselves.
##
## Units: everything on screen is degrees, millimetres, grams and rev/s;
## everything crossing a signal is SI radians, metres and kilograms
## (CONTRACT §1).

# --- signals Track C listens to ---------------------------------------------
signal throw_requested(params: DiscFlightSim.ThrowParams)
signal disc_selected(disc_id: String)
signal geometry_changed(geometry: Dictionary)
## CONTRACT §4 names this type `Environment`; Godot reserves that identifier for
## a native class, so Track B's is `DiscFlightSim.FlightEnvironment`.
signal environment_changed(env: DiscFlightSim.FlightEnvironment)
signal camera_view_changed(view: String)
signal clear_trails_requested()
signal vectors_toggled(enabled: bool)

const T := preload("res://scripts/ui/flight_lab_theme.gd")
const DISCS_JSON := "res://data/discs.json"
const VIEWS := ["follow", "tee", "top", "side", "free"]
const VIEW_LABELS := ["Follow", "Tee", "Top", "Side", "Free"]
const TAB_NAMES := ["Throw", "Discs", "Design", "Env", "Flight"]

var throw_panel: ThrowPanel
var roster_panel: RosterPanel
var designer_panel: DesignerPanel
var environment_panel: EnvironmentPanel
var telemetry_panel: TelemetryPanel

var _drawer: PanelContainer
var _drawer_open := true
var _handle: Button
var _tabs: TabContainer
var _hud: PanelContainer
var _action_bar: PanelContainer
var _info_overlay: PanelContainer
var _status_label: Label
var _active_name: Label
var _active_badge_slot: HBoxContainer
var _view_buttons: Array[Button] = []
var _vectors_check: CheckButton
var _data_note: Label
var _shortcut_hint: Label

var _roster: Array = []
var _roster_by_id: Dictionary = {}
var _active_id: String = ""
var _active_name_text: String = "—"
var _active_provenance: String = Provenance.FALLBACK
var _designing := false
var _roster_pushed := false


# ============================================================== life cycle ===

func _ready() -> void:
	theme = FlightLabTheme.build()
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_PASS

	_build_hud()
	_build_drawer()
	_build_action_bar()
	_build_info_overlay()

	resized.connect(_layout)
	_layout()

	# If Track C has not pushed a roster by the end of this frame, load one
	# ourselves so the panel is useful standalone.
	call_deferred("_ensure_roster")


func _ensure_roster() -> void:
	if _roster_pushed:
		return
	var loaded := _load_roster_json()
	if loaded.is_empty():
		set_disc_roster(SampleRoster.entries())
		_data_note.text = "No disc data loaded — showing a built-in placeholder roster with no aerodynamic tables."
		_data_note.visible = true
		set_status("Placeholder roster · no coefficient data")
	else:
		set_disc_roster(loaded)


func _load_roster_json() -> Array:
	if not FileAccess.file_exists(DISCS_JSON):
		return []
	var text := FileAccess.get_file_as_string(DISCS_JSON)
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary and (parsed as Dictionary).has("discs"):
		parsed = (parsed as Dictionary)["discs"]
	if parsed is Array:
		return parsed
	push_warning("ControlPanel: %s did not parse to an array" % DISCS_JSON)
	return []


var _extras_cache: Dictionary = {}
var _extras_loaded := false


## Provenance fields from `discs.json` that a caller-supplied roster may lack.
func _provenance_extras() -> Dictionary:
	if _extras_loaded:
		return _extras_cache
	_extras_loaded = true
	for entry in _load_roster_json():
		if not (entry is Dictionary) or not (entry as Dictionary).has("id"):
			continue
		var e: Dictionary = entry
		var keep := {}
		for key: String in ["aero_source", "geometry_provenance", "manufacturer"]:
			if e.has(key):
				keep[key] = e[key]
		if not keep.is_empty():
			_extras_cache[str(e["id"])] = keep
	return _extras_cache


# =================================================================== build ===

func _build_hud() -> void:
	_hud = PanelContainer.new()
	_hud.theme_type_variation = "HudPanel"
	_hud.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_hud)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	_hud.add_child(col)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	col.add_child(head)
	var title := Label.new()
	title.theme_type_variation = "SectionLabel"
	title.text = "FLIGHT LAB"
	head.add_child(title)
	UiKit.hspace(head)
	_active_badge_slot = HBoxContainer.new()
	_active_badge_slot.add_theme_constant_override("separation", 5)
	head.add_child(_active_badge_slot)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	col.add_child(row)
	var hud_labels := {
		"speed": UiKit.gauge(row, "Speed m/s", "—", 62),
		"spin": UiKit.gauge(row, "Spin rev/s", "—", 62),
		"alpha": UiKit.gauge(row, "AoA °", "—", 52),
		"altitude": UiKit.gauge(row, "Height m", "—", 58),
		"distance": UiKit.gauge(row, "Distance m", "—", 70),
	}
	_hud.set_meta("labels", hud_labels)


func _build_drawer() -> void:
	_drawer = PanelContainer.new()
	_drawer.theme_type_variation = "DrawerPanel"
	_drawer.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_drawer)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	_drawer.add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	margin.add_child(col)

	# --- header -------------------------------------------------------
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	col.add_child(head)
	var t := Label.new()
	t.theme_type_variation = "TitleLabel"
	t.text = "Disc Golf Flight Lab"
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.clip_text = true
	head.add_child(t)
	var info := UiKit.button(head, "?", "IconButton",
		"How the aerodynamic data was obtained, and how far to trust it.")
	info.pressed.connect(_show_info)
	var collapse := UiKit.button(head, "▶", "IconButton", "Hide the panel   (H)")
	collapse.pressed.connect(func() -> void: set_drawer_open(false))

	var sub := HBoxContainer.new()
	sub.add_theme_constant_override("separation", 6)
	col.add_child(sub)
	_active_name = Label.new()
	_active_name.theme_type_variation = "DimLabel"
	_active_name.text = "—"
	_active_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_active_name.clip_text = true
	sub.add_child(_active_name)

	_data_note = Label.new()
	_data_note.theme_type_variation = "WarnLabel"
	_data_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_data_note.custom_minimum_size.x = 40
	_data_note.visible = false
	col.add_child(_data_note)

	# --- tabs ---------------------------------------------------------
	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.tabs_position = TabContainer.POSITION_TOP
	_tabs.clip_tabs = false
	col.add_child(_tabs)

	throw_panel = ThrowPanel.new()
	roster_panel = RosterPanel.new()
	designer_panel = DesignerPanel.new()
	environment_panel = EnvironmentPanel.new()
	telemetry_panel = TelemetryPanel.new()

	_add_tab(throw_panel, TAB_NAMES[0], false)
	_add_tab(roster_panel, TAB_NAMES[1], true)
	_add_tab(designer_panel, TAB_NAMES[2], false)
	_add_tab(environment_panel, TAB_NAMES[3], false)
	_add_tab(telemetry_panel, TAB_NAMES[4], true)

	telemetry_panel.attach_hud(_hud.get_meta("labels"))

	roster_panel.disc_chosen.connect(_on_disc_chosen)
	roster_panel.info_requested.connect(_show_info)
	designer_panel.geometry_changed.connect(_on_geometry_changed)
	designer_panel.info_requested.connect(_show_info)
	environment_panel.env_changed.connect(_on_env_changed)
	telemetry_panel.cleared.connect(func() -> void: clear_trails_requested.emit())


## `fills_height` distinguishes a tab whose content scrolls as a list (roster,
## telemetry) from one that is a stack of cards.
func _add_tab(panel: Control, title: String, fills_height: bool) -> void:
	var scroll := ScrollContainer.new()
	scroll.name = title
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	_tabs.add_child(scroll)

	var inner := MarginContainer.new()
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if fills_height:
		inner.size_flags_vertical = Control.SIZE_EXPAND_FILL
	inner.add_theme_constant_override("margin_top", 8)
	inner.add_theme_constant_override("margin_right", 4)
	scroll.add_child(inner)

	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_child(panel)


func _build_action_bar() -> void:
	_action_bar = PanelContainer.new()
	_action_bar.theme_type_variation = "BarPanel"
	_action_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_action_bar)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	_action_bar.add_child(col)

	var flow := HFlowContainer.new()
	col.add_child(flow)

	var throw_btn := UiKit.button(flow, "THROW", "PrimaryButton", "Launch the disc   (Space)")
	throw_btn.pressed.connect(do_throw)

	var reset_btn := UiKit.button(flow, "Reset", "GhostButton",
		"Clear the flight and restore the release defaults for this disc   (R)")
	reset_btn.pressed.connect(do_reset)

	var vsep := VSeparator.new()
	flow.add_child(vsep)

	var group := ButtonGroup.new()
	for i in range(VIEWS.size()):
		var b := UiKit.button(flow, VIEW_LABELS[i], "SegButton",
			"Camera: %s   (C cycles)" % VIEW_LABELS[i])
		b.toggle_mode = true
		b.button_group = group
		if VIEWS[i] == "follow":
			b.button_pressed = true
		var view: String = VIEWS[i]
		b.pressed.connect(func() -> void: camera_view_changed.emit(view))
		_view_buttons.append(b)

	var vsep2 := VSeparator.new()
	flow.add_child(vsep2)

	_vectors_check = UiKit.check(flow, "Vectors", false,
		"Draw the aerodynamic force vectors on the disc in flight   (V)")
	_vectors_check.toggled.connect(func(pressed: bool) -> void: vectors_toggled.emit(pressed))

	var trails := UiKit.button(flow, "Clear trails", "GhostButton",
		"Remove the ghost trails of previous throws   (T)")
	trails.pressed.connect(func() -> void: clear_trails_requested.emit())

	var status_row := HBoxContainer.new()
	status_row.add_theme_constant_override("separation", 6)
	col.add_child(status_row)
	_status_label = Label.new()
	_status_label.theme_type_variation = "SmallLabel"
	_status_label.text = "Ready."
	_status_label.clip_text = true
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_row.add_child(_status_label)
	_shortcut_hint = Label.new()
	_shortcut_hint.theme_type_variation = "TinyLabel"
	_shortcut_hint.text = "SPACE throw · R reset · C camera · V vectors · T trails · H panel"
	_shortcut_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	status_row.add_child(_shortcut_hint)

	_handle = Button.new()
	_handle.text = "◀  CONTROLS"
	_handle.theme_type_variation = "GhostButton"
	_handle.focus_mode = Control.FOCUS_NONE
	_handle.tooltip_text = "Show the control panel   (H)"
	_handle.visible = false
	_handle.pressed.connect(func() -> void: set_drawer_open(true))
	add_child(_handle)


func _build_info_overlay() -> void:
	_info_overlay = PanelContainer.new()
	_info_overlay.theme_type_variation = "OverlayPanel"
	_info_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_info_overlay.visible = false
	add_child(_info_overlay)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	_info_overlay.add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	margin.add_child(col)

	var head := HBoxContainer.new()
	col.add_child(head)
	var t := Label.new()
	t.theme_type_variation = "TitleLabel"
	t.text = "Measured vs derived"
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(t)
	var close := UiKit.button(head, "✕", "IconButton", "Close   (Esc)")
	close.pressed.connect(func() -> void: _info_overlay.visible = false)

	var legend := HBoxContainer.new()
	legend.add_theme_constant_override("separation", 6)
	col.add_child(legend)
	legend.add_child(Provenance.badge(Provenance.MEASURED))
	legend.add_child(Provenance.badge(Provenance.DERIVED))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 7)
	scroll.add_child(body)

	for entry: Array in Provenance.explanation():
		match entry[0]:
			"h":
				UiKit.body(body, entry[1], "DimLabel")
			"h2":
				body.add_child(UiKit.section_label(entry[1]))
			"code":
				var box := PanelContainer.new()
				box.theme_type_variation = "InsetPanel"
				body.add_child(box)
				var l := Label.new()
				l.theme_type_variation = "SmallLabel"
				l.text = entry[1]
				box.add_child(l)
			_:
				UiKit.body(body, entry[1])

	UiKit.body(body, Provenance.CITATION + ". Data via the shotshaper library (GPL-3.0).", "TinyLabel")


func _show_info() -> void:
	_info_overlay.visible = true
	set_drawer_open(true)


# ================================================================== layout ===

## Everything is positioned with anchors and grow directions rather than with
## explicit sizes: the action bar's height changes whenever its flow container
## rewraps, and only the layout engine knows when that happened.
func _layout() -> void:
	var vp := size
	if vp.x <= 0.0:
		return
	var margin := 12.0 if vp.x >= 900.0 else 8.0
	var drawer_w: float = clampf(vp.x * 0.31, 330.0, 440.0)
	if vp.x < 700.0:
		drawer_w = maxf(vp.x - 2.0 * margin - 34.0, 220.0)

	for panel in [_drawer, _info_overlay]:
		panel.anchor_left = 1.0
		panel.anchor_right = 1.0
		panel.anchor_top = 0.0
		panel.anchor_bottom = 1.0
		panel.offset_left = -(drawer_w + margin)
		panel.offset_right = -margin
		panel.offset_top = margin
		panel.offset_bottom = -margin
	_drawer.visible = _drawer_open
	if not _drawer_open:
		_info_overlay.visible = false

	var right_edge: float = (vp.x - drawer_w - margin - 4.0) if _drawer_open else (vp.x - margin)

	# Top-left HUD: pinned corner, sizes itself to its contents. On the web the
	# export shell injects a "Back to overview" link over the top-left corner of
	# the canvas (see export_presets.cfg html/head_include), so the HUD starts
	# below it rather than underneath it.
	var top_inset: float = 34.0 if OS.has_feature("web") else 0.0
	_hud.anchor_left = 0.0
	_hud.anchor_top = 0.0
	_hud.anchor_right = 0.0
	_hud.anchor_bottom = 0.0
	_hud.grow_horizontal = Control.GROW_DIRECTION_END
	_hud.grow_vertical = Control.GROW_DIRECTION_END
	_hud.offset_left = margin
	_hud.offset_top = margin + top_inset
	_hud.offset_right = margin
	_hud.offset_bottom = margin + top_inset
	_hud.visible = vp.y > 300.0

	# Bottom action bar: pinned to the bottom, grows upward as it rewraps.
	_action_bar.anchor_left = 0.0
	_action_bar.anchor_right = 0.0
	_action_bar.anchor_top = 1.0
	_action_bar.anchor_bottom = 1.0
	_action_bar.grow_horizontal = Control.GROW_DIRECTION_END
	_action_bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_action_bar.offset_left = margin
	_action_bar.offset_right = maxf(right_edge, margin + 220.0)
	_action_bar.offset_top = -margin
	_action_bar.offset_bottom = -margin
	_shortcut_hint.visible = right_edge - margin > 620.0

	_handle.visible = not _drawer_open
	_handle.anchor_left = 1.0
	_handle.anchor_right = 1.0
	_handle.anchor_top = 0.0
	_handle.anchor_bottom = 0.0
	_handle.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_handle.grow_vertical = Control.GROW_DIRECTION_END
	_handle.offset_left = -margin
	_handle.offset_right = -margin
	_handle.offset_top = margin
	_handle.offset_bottom = margin


func set_drawer_open(open: bool) -> void:
	if _drawer_open == open:
		return
	_drawer_open = open
	_layout()


# =============================================================== shortcuts ===

func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	match key.keycode:
		KEY_SPACE, KEY_ENTER, KEY_KP_ENTER:
			do_throw()
		KEY_R:
			do_reset()
		KEY_C:
			cycle_camera()
		KEY_V:
			_vectors_check.button_pressed = not _vectors_check.button_pressed
		KEY_T:
			clear_trails_requested.emit()
		KEY_H:
			set_drawer_open(not _drawer_open)
		KEY_ESCAPE:
			if _info_overlay.visible:
				_info_overlay.visible = false
			else:
				return
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5:
			var index: int = key.keycode - KEY_1
			set_drawer_open(true)
			_tabs.current_tab = index
		_:
			return
	get_viewport().set_input_as_handled()


func cycle_camera() -> void:
	var current := 0
	for i in range(_view_buttons.size()):
		if _view_buttons[i].button_pressed:
			current = i
			break
	var next: int = (current + 1) % _view_buttons.size()
	_view_buttons[next].button_pressed = true
	camera_view_changed.emit(VIEWS[next])


# ================================================================= actions ===

func do_throw() -> void:
	var params := throw_panel.build_params()
	telemetry_panel.begin_flight()
	set_status("Thrown: %s · %s" % [_active_name_text, throw_panel.summary()])
	throw_requested.emit(params)


func do_reset() -> void:
	throw_panel.reset_to_defaults()
	telemetry_panel.reset_live()
	set_status("Release parameters reset.")


# ================================================== interface for Track C ====

func set_disc_roster(discs: Array) -> void:
	_roster_pushed = true
	_roster.clear()
	_roster_by_id.clear()
	# Track C builds its roster entries from DiscDefinition, which drops the
	# per-parameter provenance block Track A ships. Merge it back in from the
	# data file so "which of these numbers is a measurement?" stays answerable
	# however the roster arrived.
	var extras := _provenance_extras()
	for d in discs:
		var entry := _normalize_disc(d)
		if entry.is_empty():
			continue
		var extra: Variant = extras.get(entry["id"], null)
		if extra is Dictionary:
			for key: String in (extra as Dictionary):
				if not entry.has(key):
					entry[key] = (extra as Dictionary)[key]
		_roster.append(entry)
		_roster_by_id[entry["id"]] = entry

	roster_panel.set_roster(_roster)
	designer_panel.set_roster(_roster)

	var measured := 0
	var fallback := 0
	for d: Dictionary in _roster:
		match Provenance.normalize(d.get("aero_provenance", "")):
			Provenance.MEASURED: measured += 1
			Provenance.FALLBACK: fallback += 1
	if fallback == 0:
		_data_note.visible = false
	_status_label.tooltip_text = "%d discs · %d with measured coefficients" % [_roster.size(), measured]

	if _active_id.is_empty() and not _roster.is_empty():
		var first: Dictionary = _roster[0]
		for d: Dictionary in _roster:
			if Provenance.normalize(d.get("aero_provenance", "")) == Provenance.MEASURED:
				first = d
				break
		set_active_disc(first)
		disc_selected.emit(str(first["id"]))


func set_active_disc(disc: Dictionary) -> void:
	var entry := _normalize_disc(disc)
	if entry.is_empty():
		return
	var id: String = entry["id"]
	_active_name_text = str(entry.get("name", id))
	_active_provenance = Provenance.normalize(entry.get("aero_provenance", ""))

	var known: bool = _roster_by_id.has(id)
	if known:
		_active_id = id
		roster_panel.set_selected(id)
		_designing = false
		designer_panel.clear_model_flight_numbers()
		var geometry: Dictionary = entry.get("geometry", {})
		if not geometry.is_empty():
			designer_panel.set_geometry(geometry, id, _active_name_text)
		throw_panel.apply_category(str(entry.get("category", "")))
	else:
		# A shape that is not in the roster: the design being edited, handed
		# back with whatever the aero model made of it. CONTRACT §7 — a shape
		# nobody has scanned cannot be measured, whatever the entry claims.
		_designing = true
		_active_provenance = Provenance.CUSTOM
		var fn: Dictionary = entry.get("flight_numbers", {})
		if not fn.is_empty():
			designer_panel.set_model_flight_numbers(fn, _active_provenance)

	_active_name.text = "%s · %s" % [_active_name_text,
		UiKit.category_label(str(entry.get("category", "custom")))]
	for c in _active_badge_slot.get_children():
		c.queue_free()
	_active_badge_slot.add_child(Provenance.badge(_active_provenance))


func set_live_state(state: DiscFlightSim.DiscState, alpha_deg: float) -> void:
	telemetry_panel.push_live(state, alpha_deg, get_process_delta_time())


func set_flight_result(result: DiscFlightSim.FlightResult) -> void:
	telemetry_panel.show_result(result, _active_name_text, _active_provenance,
		throw_panel.summary())
	set_status("Landed %.1f m out, %s of the line, %.2f s in the air." % [
		result.distance_m, UiKit.fmt_lateral(result.lateral_m), result.flight_time_s])


func set_status(text: String) -> void:
	_status_label.text = text


# ================================================================ internal ===

func _on_disc_chosen(disc_id: String) -> void:
	if not _roster_by_id.has(disc_id):
		return
	set_active_disc(_roster_by_id[disc_id])
	disc_selected.emit(disc_id)


func _on_geometry_changed(g: Dictionary) -> void:
	_designing = true
	designer_panel.clear_model_flight_numbers()
	_active_provenance = Provenance.CUSTOM
	for c in _active_badge_slot.get_children():
		c.queue_free()
	_active_badge_slot.add_child(Provenance.badge(Provenance.CUSTOM))
	geometry_changed.emit(g)


func _on_env_changed() -> void:
	environment_changed.emit(environment_panel.build_environment())


## Accepts either a CONTRACT §3 dictionary or a `DiscDefinition`, because Track
## C may hold either shape depending on how it loaded the roster.
func _normalize_disc(d: Variant) -> Dictionary:
	if d is Dictionary:
		var dict: Dictionary = (d as Dictionary).duplicate(true)
		if not dict.has("id"):
			return {}
		dict["id"] = str(dict["id"])
		if not dict.has("flight_numbers"):
			dict["flight_numbers"] = {}
		if not dict.has("geometry"):
			dict["geometry"] = {}
		return dict
	if d is Object:
		var o: Object = d
		if not ("id" in o):
			return {}
		var geometry := {}
		for key: String in DiscGeometryCalc.KEYS:
			if key in o:
				geometry[key] = o.get(key)
		return {
			"id": str(o.get("id")),
			"name": str(o.get("name")) if "name" in o else str(o.get("id")),
			"category": str(o.get("category")) if "category" in o else "unknown",
			"flight_numbers": {
				"speed": float(o.get("speed")) if "speed" in o else 0.0,
				"glide": float(o.get("glide")) if "glide" in o else 0.0,
				"turn": float(o.get("turn")) if "turn" in o else 0.0,
				"fade": float(o.get("fade")) if "fade" in o else 0.0,
			},
			"geometry": geometry,
			"aero_provenance": str(o.get("aero_provenance")) if "aero_provenance" in o else "derived",
		}
	return {}

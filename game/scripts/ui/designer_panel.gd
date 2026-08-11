class_name DesignerPanel
extends VBoxContainer

## Custom disc designer: the eight CONTRACT §2 parameters, the cross-section
## they describe, the quantities that follow from them exactly, and an honest
## account of the ones that do not.
##
## Lengths are edited in millimetres and mass in grams because that is how disc
## specifications are written and read; `geometry()` converts to SI once, on the
## way out.

signal geometry_changed(geometry: Dictionary)
signal info_requested()

const T := preload("res://scripts/ui/flight_lab_theme.gd")
const EMIT_INTERVAL := 0.05

## key -> [label, min, max, step, unit, scale_to_si, tooltip]
const PARAMS := {
	"diameter_m": ["Diameter", 200.0, 220.0, 0.1, " mm", 0.001,
		"Outer diameter. PDGA approval requires 21.0–21.3 cm."],
	"mass_kg": ["Mass", 120.0, 200.0, 1.0, " g", 0.001,
		"Throwing weight. The PDGA cap is 8.3 g per cm of diameter, and never more than 200 g."],
	"rim_width_m": ["Rim width", 6.0, 30.0, 0.1, " mm", 0.001,
		"Radial width of the rim — the single strongest predictor of the speed rating (R² = 0.96 over 43 moulds). PDGA maximum 26 mm."],
	"rim_depth_m": ["Rim depth", 8.0, 30.0, 0.1, " mm", 0.001,
		"Depth of the rim cavity: how far the underside of the flight plate sits above the resting plane."],
	"rim_thickness_m": ["Nose thickness", 1.0, 20.0, 0.1, " mm", 0.001,
		"Axial thickness of the rim wing at the outer edge — how blunt the nose is. Published by nobody; inferred for every disc in the roster."],
	"parting_line_m": ["Parting line", 0.5, 30.0, 0.1, " mm", 0.001,
		"Height of the widest point of the rim above the resting plane. Its ratio to rim depth dominates both turn and fade."],
	"dome_height_m": ["Dome height", 0.0, 20.0, 0.1, " mm", 0.001,
		"Apex of the flight plate above its rim edge. Dome is what disc golfers mean by glide, though the link to the coefficient set is the weakest one in this model."],
	"inner_rim_edge_m": ["Inner rim edge", 50.0, 110.0, 0.1, " mm", 0.001,
		"Radius where the rim meets the flight plate. It is not independent: it must equal radius − rim width."],
}

const ORDER := ["diameter_m", "mass_kg", "rim_width_m", "rim_depth_m",
	"rim_thickness_m", "parting_line_m", "dome_height_m", "inner_rim_edge_m"]

var _fields: Dictionary = {}
var _profile_view: DiscProfileView
var _source_opt: OptionButton
var _link_check: CheckButton
var _issue_box: VBoxContainer
var _metrics: Dictionary = {}
var _flight_row: HBoxContainer
var _flight_note: Label
var _source_name: Label

var _discs: Array = []
var _source_id: String = ""
var _model_numbers: Dictionary = {}
var _model_provenance: String = Provenance.CUSTOM
var _dirty := false
var _pristine := true
var _since_emit := 0.0
var _mesh_profile_source: Callable = Callable()
var _overlay_opt: OptionButton
var _mesh_script: Script = null
var _provenance_note: Label


func _init() -> void:
	add_theme_constant_override("separation", 8)
	set_process(false)

	# ---- source ------------------------------------------------------
	var src := UiKit.card(self, "Start from")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	src.add_child(row)
	_source_opt = UiKit.option(row, ["—"], 0, "Load an existing mould's geometry, then tweak it.")
	_source_opt.item_selected.connect(_on_source_selected)
	var revert := UiKit.button(row, "Revert", "GhostButton", "Restore the source disc's geometry.")
	revert.pressed.connect(func() -> void: _on_source_selected(_source_opt.selected))
	_source_name = Label.new()
	_source_name.theme_type_variation = "TinyLabel"
	_source_name.text = "Edits apply to the disc in flight; the catalogue entry is untouched."
	_source_name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_source_name.custom_minimum_size.x = 40
	src.add_child(_source_name)
	_provenance_note = Label.new()
	_provenance_note.theme_type_variation = "WarnLabel"
	_provenance_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_provenance_note.custom_minimum_size.x = 40
	_provenance_note.visible = false
	src.add_child(_provenance_note)

	# ---- cross-section ----------------------------------------------
	var shape := UiKit.card(self, "Cross-section")
	_profile_view = DiscProfileView.new()
	shape.add_child(_profile_view)
	var ctl := HBoxContainer.new()
	shape.add_child(ctl)
	var exag := UiKit.check(ctl, "Exaggerate vertical", true,
		"A disc is 211 mm across and 20 mm tall. At true scale the profile is a hairline, so the diagram stretches it 3× by default and says so on the drawing.")
	exag.toggled.connect(func(pressed: bool) -> void:
		_profile_view.exaggeration = 3.0 if pressed else 1.0)
	UiKit.hspace(ctl)
	var ghost_label := Label.new()
	ghost_label.theme_type_variation = "TinyLabel"
	ghost_label.text = "Overlay"
	ctl.add_child(ghost_label)
	_overlay_opt = UiKit.option(ctl, ["Source mould", "As rendered", "None"], 0,
		"Source mould: the shape this design started from.\nAs rendered: the profile the mesh builder actually lathes, which is not always the same curve the aero model reads.")
	_overlay_opt.size_flags_horizontal = Control.SIZE_SHRINK_END
	_overlay_opt.custom_minimum_size.x = 128
	_overlay_opt.item_selected.connect(func(_i: int) -> void: _update_overlay())
	_mesh_script = _load_mesh_builder()

	# ---- parameters --------------------------------------------------
	var params := UiKit.card(self, "Geometry")
	for key: String in ORDER:
		var spec: Array = PARAMS[key]
		var f := SliderField.new(spec[0], spec[1], spec[2], spec[3], spec[1], spec[4], spec[6], spec[5])
		params.add_child(f)
		_fields[key] = f
		f.value_changed.connect(_on_param_changed.bind(key))
	_link_check = UiKit.check(params, "Keep inner rim edge = radius − rim width", true,
		"The three are geometrically dependent. Unlink to see what an inconsistent parameter set does — the checker will flag it.")
	_link_check.toggled.connect(func(pressed: bool) -> void:
		if pressed:
			_relink()
		_refresh())

	_issue_box = VBoxContainer.new()
	_issue_box.add_theme_constant_override("separation", 4)
	params.add_child(_issue_box)

	# ---- derived -----------------------------------------------------
	var derived := UiKit.card(self, "Follows exactly from the geometry")
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	derived.add_child(grid)
	_metrics["area"] = UiKit.kv(grid, "Area", "—", "ValueLabel",
		"Reference area for every aerodynamic coefficient: π r². ~0.0350 m² for a 211 mm disc — not the 0.0568 m² Ultimate figure, which would inflate every force by 62%.")
	_metrics["height"] = UiKit.kv(grid, "Height", "—", "ValueLabel", "Overall height, comparable with the PDGA published figure.")
	_metrics["parting_ratio"] = UiKit.kv(grid, "Parting ratio", "—", "ValueLabel",
		"parting_line / rim_depth. The shape number that dominates both turn and fade.")
	_metrics["nose_ratio"] = UiKit.kv(grid, "Nose ratio", "—", "ValueLabel", "rim_thickness / rim_depth — how blunt the leading edge is.")
	_metrics["i_zz"] = UiKit.kv(grid, "I_zz", "—", "ValueLabel",
		"Spin-axis moment of inertia, integrated over the solid of revolution. It sets how much the disc resists the aerodynamic torque: precession rate goes as 1/(I_zz·ω).")
	_metrics["i_xy"] = UiKit.kv(grid, "I_xy", "—", "ValueLabel", "Transverse moment of inertia.")
	_metrics["density"] = UiKit.kv(grid, "Implied plastic", "—", "ValueLabel",
		"mass ÷ swept volume. Real disc plastics run 800–1400 kg/m³; outside that, the shape and the mass are not describing the same object.")
	_metrics["volume"] = UiKit.kv(grid, "Volume", "—", "ValueLabel", "Volume of the solid of revolution.")

	# ---- flight numbers ---------------------------------------------
	var flight := UiKit.card(self, "Flight numbers")
	_flight_row = HBoxContainer.new()
	_flight_row.add_theme_constant_override("separation", 8)
	flight.add_child(_flight_row)
	_flight_note = Label.new()
	_flight_note.theme_type_variation = "TinyLabel"
	_flight_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_flight_note.custom_minimum_size.x = 40
	flight.add_child(_flight_note)
	var why := UiKit.button(flight, "Why isn't this measured?", "GhostButton")
	why.pressed.connect(func() -> void: info_requested.emit())

	set_geometry(SampleRoster.entries()[5]["geometry"], "teebird", "Innova Teebird")


func _process(delta: float) -> void:
	_since_emit += delta
	if _dirty and _since_emit >= EMIT_INTERVAL:
		_dirty = false
		_since_emit = 0.0
		set_process(false)
		geometry_changed.emit(geometry())


# ------------------------------------------------------------------ edits ---

func _published_numbers() -> Dictionary:
	for d: Dictionary in _discs:
		if str(d.get("id", "")) == _source_id:
			var fn: Variant = d.get("flight_numbers", null)
			return (fn as Dictionary) if fn is Dictionary else {}
	return {}


func _on_param_changed(_value: float, key: String) -> void:
	_pristine = false
	if _link_check.button_pressed and key in ["diameter_m", "rim_width_m"]:
		_relink()
	elif _link_check.button_pressed and key == "inner_rim_edge_m":
		# The user grabbed the dependent slider; move rim width to match rather
		# than silently snapping their edit back.
		var radius_mm: float = _field("diameter_m").get_value() * 0.5
		_field("rim_width_m").set_value_silent(
			clampf(radius_mm - _field("inner_rim_edge_m").get_value(), 6.0, 30.0))
	_refresh()
	_dirty = true
	set_process(true)


func _relink() -> void:
	var radius_mm: float = _field("diameter_m").get_value() * 0.5
	var inner: float = radius_mm - _field("rim_width_m").get_value()
	_field("inner_rim_edge_m").set_value_silent(clampf(inner, 50.0, 110.0))


func _field(key: String) -> SliderField:
	return _fields[key]


func _refresh() -> void:
	var g := geometry()
	var d := DiscGeometryCalc.derived(g)

	_metrics["area"].text = "%.4f m²" % d["area_m2"]
	_metrics["height"].text = "%.1f mm" % (float(d["height_m"]) * 1000.0)
	_metrics["parting_ratio"].text = "%.2f" % d["parting_ratio"]
	_metrics["nose_ratio"].text = "%.2f" % d["nose_ratio"]
	_metrics["i_zz"].text = "%.5f kg·m²" % d["i_zz"]
	_metrics["i_xy"].text = "%.5f kg·m²" % d["i_xy"]
	_metrics["density"].text = "%.0f kg/m³" % d["density_kg_m3"]
	_metrics["volume"].text = "%.1f cm³" % (float(d["volume_m3"]) * 1e6)

	_field("rim_width_m").set_hint("speed ≈ %.1f" % DiscGeometryCalc.speed_from_rim(float(g["rim_width_m"])))
	_field("parting_line_m").set_hint("ratio %.2f" % d["parting_ratio"])
	_field("mass_kg").set_hint("%.0f kg/m³" % d["density_kg_m3"])

	_profile_view.set_profile(DiscGeometryCalc.outline(g), g, "%.0f mm × %.1f mm" % [
		float(g["diameter_m"]) * 1000.0, float(d["height_m"]) * 1000.0])
	_update_overlay()

	_update_issues(g)
	_update_flight_numbers(g)


## The mesh builder belongs to Track C; it is loaded by path at runtime so this
## panel still parses and runs on its own if that file is absent or renamed.
func _load_mesh_builder() -> Script:
	const PATH := "res://scripts/mesh/disc_mesh_builder.gd"
	if not ResourceLoader.exists(PATH):
		return null
	var s: Resource = load(PATH)
	return s as Script


## The profile the renderer actually lathes. Not necessarily the curve the aero
## model reads: the two tracks interpret `rim_thickness_m` differently, and the
## overlay is here so that disagreement is visible rather than assumed away.
func _rendered_outline(g: Dictionary) -> PackedVector2Array:
	if _mesh_profile_source.is_valid():
		var pts: Variant = _mesh_profile_source.call(g)
		if pts is PackedVector2Array and (pts as PackedVector2Array).size() >= 3:
			return pts
	if _mesh_script != null and _mesh_script.has_method("cross_section_polyline"):
		var poly: Variant = _mesh_script.cross_section_polyline(g, 96)
		if poly is PackedVector2Array and (poly as PackedVector2Array).size() >= 3:
			return poly
	return PackedVector2Array()


func _update_overlay() -> void:
	match _overlay_opt.selected:
		0:
			_profile_view.set_reference(_source_outline())
		1:
			_profile_view.set_reference(_rendered_outline(geometry()))
		_:
			_profile_view.set_reference(PackedVector2Array())


func _source_outline() -> PackedVector2Array:
	for d: Dictionary in _discs:
		if str(d.get("id", "")) == _source_id:
			return DiscGeometryCalc.outline(d.get("geometry", {}))
	return PackedVector2Array()


func _update_issues(g: Dictionary) -> void:
	for c in _issue_box.get_children():
		c.queue_free()
	for f: SliderField in _fields.values():
		f.set_flag(SliderField.Flag.NONE)

	var issues := DiscGeometryCalc.check(g)
	if issues.is_empty():
		var ok := PanelContainer.new()
		ok.theme_type_variation = "OkPanel"
		_issue_box.add_child(ok)
		var l := Label.new()
		l.theme_type_variation = "OkLabel"
		l.text = "PDGA-legal, and manufacturable as described."
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		ok.add_child(l)
		return

	for issue: Dictionary in issues:
		var bad: bool = int(issue["level"]) == DiscGeometryCalc.Level.BAD
		var panel := PanelContainer.new()
		panel.theme_type_variation = "BadPanel" if bad else "WarnPanel"
		_issue_box.add_child(panel)
		var l := Label.new()
		l.theme_type_variation = "BadLabel" if bad else "WarnLabel"
		l.text = str(issue["text"])
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = 40
		panel.add_child(l)
		var key: String = str(issue.get("key", ""))
		if _fields.has(key):
			_fields[key].set_flag(
				SliderField.Flag.BAD if bad else SliderField.Flag.WARN, str(issue["text"]))


func _update_flight_numbers(g: Dictionary) -> void:
	for c in _flight_row.get_children():
		c.queue_free()

	# Three possible sources, in order of authority for the shape on screen:
	# what the aero model made of this exact design; the manufacturer's
	# published rating while the design is still an untouched copy of a mould;
	# or, once edited, only the one number geometry actually determines.
	var published: Dictionary = _published_numbers() if _pristine else {}
	var numbers := {
		"speed": DiscGeometryCalc.speed_from_rim(float(g["rim_width_m"])),
		"glide": NAN, "turn": NAN, "fade": NAN,
	}
	var badge: PanelContainer
	if not _model_numbers.is_empty():
		for k: String in ["speed", "glide", "turn", "fade"]:
			if _model_numbers.has(k):
				numbers[k] = float(_model_numbers[k])
		badge = Provenance.badge(_model_provenance)
	elif not published.is_empty():
		for k: String in ["speed", "glide", "turn", "fade"]:
			if published.has(k):
				numbers[k] = float(published[k])
		badge = UiKit.badge("PUBLISHED RATING", "BadgeDerived",
			"The manufacturer's own rating for this mould. A marketing number: neither measured aerodynamics nor model output.")
	else:
		badge = Provenance.badge(Provenance.CUSTOM)

	for kind in ["speed", "glide", "turn", "fade"]:
		var cell := VBoxContainer.new()
		cell.add_theme_constant_override("separation", 1)
		_flight_row.add_child(cell)
		var v: float = float(numbers[kind])
		if is_nan(v):
			var box := PanelContainer.new()
			box.theme_type_variation = "InsetPanel"
			cell.add_child(box)
			var q := Label.new()
			q.theme_type_variation = "FaintLabel"
			q.text = "  —  "
			box.add_child(q)
		else:
			cell.add_child(UiKit.chip(kind, v))
		var cap := Label.new()
		cap.theme_type_variation = "TinyLabel"
		cap.text = kind.substr(0, 1).to_upper()
		cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cell.add_child(cap)

	UiKit.hspace(_flight_row)
	_flight_row.add_child(badge)

	if not _model_numbers.is_empty():
		_flight_note.text = "Turn and fade here are model output, not measurement: the shape → CM(α) mapping behind them is fitted to four discs (R² = 0.89 and 0.91, n = 4). Treat a one-point difference as noise."
	elif not published.is_empty():
		_flight_note.text = "The mould's published rating, shown while this is still an unedited copy of it. Change any parameter and only speed survives — it follows from rim width alone (R² = 0.95 over the roster). Turn and fade come from CM(α), which the aero model has to re-derive."
	else:
		_flight_note.text = "Speed is computed from rim width alone (least squares over the shipped roster, R² = 0.95, ±1 rating). Glide, turn and fade cannot be read off the geometry: they come from CM(α), and the shape → CM mapping is a regression anchored on four measured discs. They fill in once the aero model rebuilds this design."


# -------------------------------------------------------------------- api ---

func set_roster(discs: Array) -> void:
	_discs = discs
	_source_opt.clear()
	for d: Dictionary in discs:
		_source_opt.add_item(str(d.get("name", d.get("id", "?"))))
		_source_opt.set_item_metadata(_source_opt.item_count - 1, str(d.get("id", "")))
	for i in range(_source_opt.item_count):
		if str(_source_opt.get_item_metadata(i)) == _source_id:
			_source_opt.select(i)
			break


func _on_source_selected(index: int) -> void:
	if index < 0 or index >= _source_opt.item_count:
		return
	var id := str(_source_opt.get_item_metadata(index))
	for d: Dictionary in _discs:
		if str(d.get("id", "")) == id:
			set_geometry(d.get("geometry", {}), id, str(d.get("name", id)))
			_dirty = true
			set_process(true)
			return


## Load a parameter set into the sliders without emitting.
func set_geometry(g: Dictionary, source_id: String = "", source_name: String = "") -> void:
	var geo := DiscGeometryCalc.sanitize(g)
	for key: String in ORDER:
		var spec: Array = PARAMS[key]
		_fields[key].set_value_silent(float(geo[key]) / float(spec[5]))
	if not source_id.is_empty():
		_source_id = source_id
		_source_name.text = "Started from %s. Edits apply to the disc in flight; the catalogue entry is untouched." % source_name
		_update_provenance_note(source_id)
		for i in range(_source_opt.item_count):
			if str(_source_opt.get_item_metadata(i)) == source_id:
				_source_opt.select(i)
				break
	_pristine = true
	_refresh()


## Which of the eight numbers for the source mould are published measurements
## and which are model output wearing the shape of one.
func _update_provenance_note(source_id: String) -> void:
	_provenance_note.visible = false
	for d: Dictionary in _discs:
		if str(d.get("id", "")) != source_id:
			continue
		var gp: Variant = d.get("geometry_provenance", null)
		if not (gp is Dictionary):
			return
		var inferred: Array = []
		var published := 0
		for key: String in DiscGeometryCalc.KEYS:
			var origin := str((gp as Dictionary).get(key, ""))
			if origin.begins_with("pdga"):
				published += 1
			elif origin.begins_with("inferred"):
				inferred.append(str(PARAMS[key][0]).to_lower())
		if inferred.is_empty():
			return
		var names := " and ".join(PackedStringArray(inferred))
		_provenance_note.text = "%d of these eight numbers come from the PDGA certification record. %s%s %s inferred from this disc's flight numbers — model output, not a measurement of the mould." % [
			published, names.substr(0, 1).to_upper(), names.substr(1),
			"are" if inferred.size() > 1 else "is"]
		_provenance_note.visible = true
		return


## The eight parameters in SI, ready for the mesh builder and the aero model.
func geometry() -> Dictionary:
	var out := {}
	for key: String in ORDER:
		out[key] = _fields[key].si_value()
	return out


## Flight numbers the aero model produced for the current design, if any.
func set_model_flight_numbers(numbers: Dictionary, provenance: String) -> void:
	_model_numbers = numbers.duplicate()
	_model_provenance = provenance
	_update_flight_numbers(geometry())


func clear_model_flight_numbers() -> void:
	_model_numbers = {}
	_model_provenance = Provenance.CUSTOM
	_update_flight_numbers(geometry())


## Let Track C supply the profile the mesh is actually lathed from.
func set_mesh_profile_source(fn: Callable) -> void:
	_mesh_profile_source = fn
	_refresh()

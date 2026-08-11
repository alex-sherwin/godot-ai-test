class_name RosterPanel
extends VBoxContainer

## The disc roster browser: name, category, the four flight numbers in the
## retail speed / glide / turn / fade treatment, and — mandatory, per
## CONTRACT §7 — a provenance badge on every single row.

signal disc_chosen(disc_id: String)
signal info_requested()

const T := preload("res://scripts/ui/flight_lab_theme.gd")

const SORT_KEYS := ["name", "speed", "glide", "turn", "fade", "stability"]

var _discs: Array = []
var _rows: Dictionary = {}
var _selected_id: String = ""

var _search: LineEdit
var _category_opt: OptionButton
var _stability_opt: OptionButton
var _sort_opt: OptionButton
var _dir_btn: Button
var _measured_only: CheckButton
var _speed_min: SpinBox
var _speed_max: SpinBox
var _count_label: Label
var _scroll: ScrollContainer
var _list: VBoxContainer
var _ascending := true


func _init() -> void:
	add_theme_constant_override("separation", 8)
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	var filters := UiKit.card(self, "Filter")

	_search = LineEdit.new()
	_search.placeholder_text = "Search by name…"
	_search.clear_button_enabled = true
	_search.text_changed.connect(func(_t: String) -> void: _rebuild())
	filters.add_child(_search)

	var r1 := HBoxContainer.new()
	r1.add_theme_constant_override("separation", 6)
	filters.add_child(r1)
	_category_opt = UiKit.option(r1, ["All categories"], 0, "Filter by disc category.")
	_category_opt.item_selected.connect(func(_i: int) -> void: _rebuild())
	_stability_opt = UiKit.option(r1, ["Any stability", "Understable", "Neutral", "Overstable"], 0,
		"Bucketed on turn + fade: understable below 1, neutral 1–2, overstable above 2.")
	_stability_opt.item_selected.connect(func(_i: int) -> void: _rebuild())

	var r2 := HBoxContainer.new()
	r2.add_theme_constant_override("separation", 6)
	filters.add_child(r2)
	var speed_label := Label.new()
	speed_label.theme_type_variation = "SmallLabel"
	speed_label.text = "Speed"
	r2.add_child(speed_label)
	_speed_min = _make_spin(r2, 1.0, 15.0, 1.0)
	var dash := Label.new()
	dash.theme_type_variation = "SmallLabel"
	dash.text = "–"
	r2.add_child(dash)
	_speed_max = _make_spin(r2, 1.0, 15.0, 15.0)
	_sort_opt = UiKit.option(r2, ["Name", "Speed", "Glide", "Turn", "Fade", "Stability"], 0,
		"Sort order.")
	_sort_opt.item_selected.connect(func(_i: int) -> void: _rebuild())
	_dir_btn = UiKit.button(r2, "↑", "SegButton", "Toggle ascending / descending")
	_dir_btn.custom_minimum_size.x = 28
	_dir_btn.pressed.connect(func() -> void:
		_ascending = not _ascending
		_dir_btn.text = "↑" if _ascending else "↓"
		_rebuild())

	var r3 := HBoxContainer.new()
	r3.add_theme_constant_override("separation", 6)
	filters.add_child(r3)
	_measured_only = UiKit.check(r3, "Measured only", false,
		"Show only the discs whose aerodynamic tables come from the published CFD dataset.")
	_measured_only.toggled.connect(func(_p: bool) -> void: _rebuild())
	_count_label = Label.new()
	_count_label.theme_type_variation = "TinyLabel"
	_count_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	r3.add_child(_count_label)
	var info := UiKit.button(r3, "What is derived?", "GhostButton",
		"Read how measured and derived coefficients differ, and how far to trust each.")
	info.pressed.connect(func() -> void: info_requested.emit())

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.custom_minimum_size.y = 150
	add_child(_scroll)
	var scroll := _scroll

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 4)
	scroll.add_child(_list)


func _make_spin(parent: Node, lo: float, hi: float, value: float) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = 1.0
	s.value = value
	s.custom_minimum_size.x = 58
	parent.add_child(s)
	s.value_changed.connect(func(_v: float) -> void: _rebuild())
	return s


# -------------------------------------------------------------------- api ---

func set_roster(discs: Array) -> void:
	_discs = discs
	var cats: Array = []
	for d: Dictionary in _discs:
		var c: String = str(d.get("category", "unknown"))
		if not cats.has(c):
			cats.append(c)
	cats.sort()
	var previous: String = _category_opt.get_item_text(_category_opt.selected) if _category_opt.selected >= 0 else ""
	_category_opt.clear()
	_category_opt.add_item("All categories")
	for c: String in cats:
		_category_opt.add_item(UiKit.category_label(c))
		_category_opt.set_item_metadata(_category_opt.item_count - 1, c)
	for i in range(_category_opt.item_count):
		if _category_opt.get_item_text(i) == previous:
			_category_opt.select(i)
			break
	_rebuild()


func set_selected(disc_id: String) -> void:
	if _selected_id == disc_id:
		return
	_selected_id = disc_id
	for id: String in _rows:
		_paint_row(_rows[id], id == _selected_id)
	if _rows.has(disc_id) and is_inside_tree():
		# Deferred: the row may have been created this frame and have no rect
		# yet, in which case scrolling to it is a no-op.
		_scroll.call_deferred("ensure_control_visible", _rows[disc_id])


# ------------------------------------------------------------------- list ---

func _rebuild() -> void:
	for child in _list.get_children():
		child.queue_free()
	_rows.clear()

	var filtered := _filtered()
	_sort(filtered)

	for d: Dictionary in filtered:
		_list.add_child(_make_row(d))

	_count_label.text = "%d of %d discs" % [filtered.size(), _discs.size()]
	if filtered.is_empty() and not _discs.is_empty():
		var empty := Label.new()
		empty.theme_type_variation = "FaintLabel"
		empty.text = "No disc matches these filters."
		_list.add_child(empty)


func _filtered() -> Array:
	var needle: String = _search.text.strip_edges().to_lower()
	var cat: String = ""
	if _category_opt.selected > 0:
		cat = str(_category_opt.get_item_metadata(_category_opt.selected))
	var stability: int = _stability_opt.selected
	var s_lo: float = _speed_min.value
	var s_hi: float = _speed_max.value
	var measured_only: bool = _measured_only.button_pressed

	var out: Array = []
	for d: Dictionary in _discs:
		var fn: Dictionary = d.get("flight_numbers", {})
		var speed: float = float(fn.get("speed", 0.0))
		if speed < s_lo - 0.001 or speed > s_hi + 0.001:
			continue
		if not cat.is_empty() and str(d.get("category", "")) != cat:
			continue
		if not needle.is_empty() and not str(d.get("name", "")).to_lower().contains(needle):
			continue
		if measured_only and Provenance.normalize(d.get("aero_provenance", "")) != Provenance.MEASURED:
			continue
		if stability > 0:
			var stab: float = float(fn.get("turn", 0.0)) + float(fn.get("fade", 0.0))
			if stability == 1 and stab >= 1.0:
				continue
			if stability == 2 and (stab < 1.0 or stab > 2.0):
				continue
			if stability == 3 and stab <= 2.0:
				continue
		out.append(d)
	return out


func _sort(list: Array) -> void:
	var key: String = SORT_KEYS[_sort_opt.selected]
	var asc := _ascending
	list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var av: Variant = _sort_value(a, key)
		var bv: Variant = _sort_value(b, key)
		if av == bv:
			return str(a.get("name", "")) < str(b.get("name", ""))
		return (av < bv) if asc else (av > bv))


func _sort_value(d: Dictionary, key: String) -> Variant:
	if key == "name":
		return str(d.get("name", ""))
	var fn: Dictionary = d.get("flight_numbers", {})
	if key == "stability":
		return float(fn.get("turn", 0.0)) + float(fn.get("fade", 0.0))
	return float(fn.get(key, 0.0))


func _make_row(d: Dictionary) -> PanelContainer:
	var id: String = str(d.get("id", ""))
	var row := PanelContainer.new()
	row.theme_type_variation = "RowPanel"
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_rows[id] = row

	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	row.add_child(h)

	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 1)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(left)

	var name_label := Label.new()
	name_label.text = str(d.get("name", id))
	name_label.clip_text = true
	left.add_child(name_label)

	var meta := HBoxContainer.new()
	meta.add_theme_constant_override("separation", 5)
	left.add_child(meta)
	var cat := Label.new()
	cat.theme_type_variation = "TinyLabel"
	cat.text = UiKit.category_label(str(d.get("category", "unknown")))
	meta.add_child(cat)
	var kind := Provenance.normalize(d.get("aero_provenance", ""))
	meta.add_child(Provenance.badge(kind))

	UiKit.flight_chips(h, d.get("flight_numbers", {}))

	row.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
				set_selected(id)
				disc_chosen.emit(id))
	row.mouse_entered.connect(func() -> void:
		if id != _selected_id:
			row.theme_type_variation = "RowPanelHover")
	row.mouse_exited.connect(func() -> void:
		if id != _selected_id:
			row.theme_type_variation = "RowPanel")

	_paint_row(row, id == _selected_id)
	return row


func _paint_row(row: PanelContainer, selected: bool) -> void:
	row.theme_type_variation = "RowPanelSelected" if selected else "RowPanel"

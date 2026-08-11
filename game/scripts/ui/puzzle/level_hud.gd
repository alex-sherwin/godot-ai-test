class_name PuzzleLevelHud
extends Control

## The in-level readout: what you are trying to do, what you have left to do it
## with, what the air is like in each room, and what the medals cost.
##
## Three pinned pieces, none of which crosses the middle of the screen:
##   top left    objective, progress, hint
##   top right   per-room conditions, medal thresholds, portal legend
##   top centre  the dive-portal warning, when the level has one
##
## ---------------------------------------------------------------------------
## Why every room's conditions, not just the current one
## ---------------------------------------------------------------------------
## The whole design rests on rooms having their own weather: the tee chamber is
## standard in every level and whatever is strange is *through the portal*
## (LEVEL_DESIGN §1). A player standing on the tee therefore needs to read the
## far room's air **before** throwing, not after arriving in it. So the panel
## lists every room, marks the one the disc is in, and flags each value that
## differs from sea-level standard — because "4.00 m/s²" and "9.81 m/s²" in the
## same colour read the same at a glance, and one of them is the entire puzzle.

const PT := preload("res://scripts/ui/puzzle/puzzle_theme.gd")
const Facts := preload("res://scripts/ui/puzzle/level_facts.gd")
const LevelDataT := preload("res://scripts/puzzle/level_data.gd")

## The web export shell injects a "Back to overview" pill over the top-left
## corner of the canvas (`export_presets.cfg`, html/head_include). Start below it
## rather than underneath it — the same inset `ControlPanel._layout()` applies.
const WEB_TOP_INSET := 34.0
const MARGIN := 12.0

var _status: PanelContainer = null
var _info: PanelContainer = null
var _dive: PanelContainer = null

var _order: Label = null
var _title: Label = null
var _medal_slot: HBoxContainer = null
var _objective: Label = null
var _hint_panel: PanelContainer = null
var _hint_label: Label = null
var _hint_button: Button = null
var _discs: Label = null
var _best: Label = null
var _buttons_row: HBoxContainer = null
var _buttons_value: Label = null
var _progress: Label = null

var _rooms_box: VBoxContainer = null
var _extra: VBoxContainer = null
var _medals_box: VBoxContainer = null
var _portals_box: VBoxContainer = null

var _room_rows: Array = []
var _hint_shown: bool = false


func _init() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_status()
	_build_info()
	_build_dive()
	resized.connect(_layout)


# =================================================================== build ===

func _build_status() -> void:
	_status = PanelContainer.new()
	_status.theme_type_variation = "HudPanel"
	_status.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_status)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 5)
	_status.add_child(col)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	col.add_child(head)
	_order = Label.new()
	_order.theme_type_variation = "NumberLabel"
	_order.text = "01"
	head.add_child(_order)
	_title = Label.new()
	_title.theme_type_variation = "TitleLabel"
	_title.text = "—"
	_title.clip_text = true
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title)
	_medal_slot = HBoxContainer.new()
	_medal_slot.add_theme_constant_override("separation", 4)
	head.add_child(_medal_slot)

	_objective = Label.new()
	_objective.theme_type_variation = "BodyLabel"
	_objective.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_objective.custom_minimum_size.x = 40
	col.add_child(_objective)

	var stats := HBoxContainer.new()
	stats.add_theme_constant_override("separation", 18)
	col.add_child(stats)
	_discs = UiKit.gauge(stats, "Discs left", "—", 74)
	_best = UiKit.gauge(stats, "Best to flag", "—", 96)
	_progress = UiKit.gauge(stats, "Status", "Ready", 110, "ValueLabel")

	_buttons_row = HBoxContainer.new()
	_buttons_row.add_theme_constant_override("separation", 8)
	_buttons_row.visible = false
	col.add_child(_buttons_row)
	var buttons_key := Label.new()
	buttons_key.theme_type_variation = "SmallLabel"
	buttons_key.text = "Buttons armed"
	buttons_key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_buttons_row.add_child(buttons_key)
	_buttons_value = Label.new()
	_buttons_value.theme_type_variation = "ValueLabel"
	_buttons_row.add_child(_buttons_value)

	var hint_head := HBoxContainer.new()
	hint_head.add_theme_constant_override("separation", 6)
	col.add_child(hint_head)
	_hint_button = UiKit.button(hint_head, "Show the hint", "GhostButton",
		"One sentence from the level designer.   (K)")
	_hint_button.pressed.connect(func() -> void: set_hint_shown(not _hint_shown))
	UiKit.hspace(hint_head)

	_hint_panel = PanelContainer.new()
	_hint_panel.theme_type_variation = "HintPanel"
	_hint_panel.visible = false
	col.add_child(_hint_panel)
	_hint_label = Label.new()
	_hint_label.theme_type_variation = "HintLabel"
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_label.custom_minimum_size.x = 40
	_hint_panel.add_child(_hint_label)


func _build_info() -> void:
	_info = PanelContainer.new()
	_info.theme_type_variation = "HudPanel"
	_info.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_info)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	_info.add_child(col)

	col.add_child(UiKit.section_label("Room conditions"))
	_rooms_box = VBoxContainer.new()
	_rooms_box.add_theme_constant_override("separation", 4)
	col.add_child(_rooms_box)

	# Medals and portals live in their own sections so they can be folded away
	# together. The right-hand column is 720 px tall at the guaranteed floor and
	# cannot hold both this panel and an open exact-parameters drawer; room
	# conditions are what a player tunes AGAINST, so they are the part that stays.
	_extra = VBoxContainer.new()
	_extra.add_theme_constant_override("separation", 8)
	col.add_child(_extra)

	UiKit.hsep(_extra)
	_extra.add_child(UiKit.section_label("Medals"))
	_medals_box = VBoxContainer.new()
	_medals_box.add_theme_constant_override("separation", 3)
	_extra.add_child(_medals_box)

	UiKit.hsep(_extra)
	_extra.add_child(UiKit.section_label("Portals"))
	_portals_box = VBoxContainer.new()
	_portals_box.add_theme_constant_override("separation", 3)
	_extra.add_child(_portals_box)


func _build_dive() -> void:
	_dive = PanelContainer.new()
	_dive.theme_type_variation = "DiveBanner"
	_dive.mouse_filter = Control.MOUSE_FILTER_STOP
	_dive.visible = false
	add_child(_dive)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	_dive.add_child(col)
	var head := Label.new()
	head.theme_type_variation = "DiveTitle"
	head.text = Facts.DIVE_TITLE
	col.add_child(head)
	var body := Label.new()
	body.theme_type_variation = "DiveLabel"
	body.text = Facts.DIVE_BODY
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size.x = 40
	col.add_child(body)


# ==================================================================== fill ===

func set_level(level: LevelDataT) -> void:
	_order.text = "%02d" % level.order
	_title.text = level.name
	_objective.text = Facts.objective_line(level)
	_hint_label.text = level.hint
	set_hint_shown(false)

	_buttons_row.visible = not level.requires_buttons.is_empty()
	_buttons_value.text = "0 / %d" % level.requires_buttons.size()

	_fill_rooms(level)
	_fill_medals(level)
	_fill_portals(level)

	_dive.visible = Facts.has_dive_portal(level)
	set_medal("")
	set_progress("Ready", false)
	_layout()


func _fill_rooms(level: LevelDataT) -> void:
	for child in _rooms_box.get_children():
		child.queue_free()
	_room_rows.clear()
	for r in level.rooms:
		var room: LevelDataT.RoomData = r
		var conditions := Facts.conditions(room)
		var card := PanelContainer.new()
		card.theme_type_variation = "InsetPanel"
		_rooms_box.add_child(card)
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 1)
		card.add_child(col)

		var head := HBoxContainer.new()
		head.add_theme_constant_override("separation", 6)
		col.add_child(head)
		var name_label := Label.new()
		name_label.theme_type_variation = "SmallLabel"
		name_label.text = room.name
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.clip_text = true
		head.add_child(name_label)
		var here := Label.new()
		here.theme_type_variation = "OkLabel"
		here.text = "YOU ARE HERE"
		here.visible = false
		head.add_child(here)

		# Values that differ from sea-level standard are accented; the ones that
		# match stay dim. Deliberately NOT orange — orange means dive portal and
		# nothing else in this UI.
		_reading(col, "wind", str(conditions["wind_text"]), bool(conditions["wind_odd"]))
		_reading(col, "air", str(conditions["density_text"]), bool(conditions["density_odd"]))
		_reading(col, "gravity", str(conditions["gravity_text"]), bool(conditions["gravity_odd"]))
		var note := str(conditions["note"])
		if not note.is_empty():
			UiKit.body(col, note, "TinyLabel")

		_room_rows.append({"card": card, "here": here})


func _reading(parent: Node, key: String, value: String, odd: bool) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	var k := Label.new()
	k.theme_type_variation = "TinyLabel"
	k.text = key
	k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(k)
	var v := Label.new()
	v.theme_type_variation = "ValueLabel" if odd else "SmallLabel"
	v.text = value + ("  ≠ std" if odd else "")
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(v)


func _fill_medals(level: LevelDataT) -> void:
	for child in _medals_box.get_children():
		child.queue_free()
	for m in level.medals:
		var tier: LevelDataT.MedalTier = m
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		_medals_box.add_child(row)
		var chip := PanelContainer.new()
		chip.theme_type_variation = PT.medal_variation(tier.tier)
		row.add_child(chip)
		var chip_label := Label.new()
		chip_label.theme_type_variation = PT.medal_variation(tier.tier) + "Label"
		chip_label.text = PT.medal_label(tier.tier)
		chip.add_child(chip_label)
		var value := Label.new()
		value.theme_type_variation = "SmallLabel"
		value.text = Facts.medal_line(tier)
		value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(value)


func _fill_portals(level: LevelDataT) -> void:
	for child in _portals_box.get_children():
		child.queue_free()
	for row_data: Dictionary in Facts.portal_rows(level):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		_portals_box.add_child(row)
		var dive := bool(row_data["dive"])
		var chip := PanelContainer.new()
		chip.theme_type_variation = "DiveChip" if dive else "PortalChip"
		row.add_child(chip)
		var chip_label := Label.new()
		chip_label.theme_type_variation = "DiveLabel" if dive else "PortalChipLabel"
		chip_label.text = "DIVE" if dive else "NORMAL"
		chip.add_child(chip_label)
		var name_label := Label.new()
		name_label.theme_type_variation = "SmallLabel"
		name_label.text = str(row_data["id"]) + ("  (you place it)" if bool(row_data["placed"]) else "")
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.clip_text = true
		row.add_child(name_label)
		var size_label := Label.new()
		size_label.theme_type_variation = "TinyLabel"
		size_label.text = "%.0f × %.0f m" % [float(row_data["width"]), float(row_data["height"])]
		row.add_child(size_label)

	if Facts.has_dive_portal(level):
		var warn := PanelContainer.new()
		warn.theme_type_variation = "DivePanel"
		_portals_box.add_child(warn)
		var l := Label.new()
		l.theme_type_variation = "DiveLabel"
		l.text = Facts.DIVE_SHORT
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = 40
		warn.add_child(l)


# =================================================================== state ===

func set_discs(remaining: int, total: int) -> void:
	_discs.text = "%d / %d" % [remaining, total]


func set_best_distance(metres: float) -> void:
	_best.text = "—" if metres >= INF else "%.2f m" % metres


func set_buttons(armed: int, required: int) -> void:
	_buttons_row.visible = required > 0
	_buttons_value.text = "%d / %d" % [armed, required]


func set_progress(text: String, _good: bool) -> void:
	_progress.text = text


func set_medal(medal: String) -> void:
	for child in _medal_slot.get_children():
		child.queue_free()
	if medal.is_empty():
		return
	var chip := PanelContainer.new()
	chip.theme_type_variation = PT.medal_variation(medal)
	_medal_slot.add_child(chip)
	var l := Label.new()
	l.theme_type_variation = PT.medal_variation(medal) + "Label"
	l.text = PT.medal_label(medal)
	chip.add_child(l)


func set_current_room(room_index: int) -> void:
	for i in _room_rows.size():
		var entry: Dictionary = _room_rows[i]
		var card: PanelContainer = entry["card"]
		var here: Label = entry["here"]
		var current := i == room_index
		card.theme_type_variation = "RowPanelSelected" if current else "InsetPanel"
		here.visible = current


func set_hint_shown(shown: bool) -> void:
	_hint_shown = shown and not _hint_label.text.is_empty()
	_hint_panel.visible = _hint_shown
	_hint_button.text = "Hide the hint" if _hint_shown else "Show the hint"
	_hint_button.visible = not _hint_label.text.is_empty()


func hint_shown() -> bool:
	return _hint_shown


## Fold the medals and portal legend away, leaving room conditions. Called when
## the exact-parameters drawer opens, because the two share the right column.
## Nothing is lost: medals are on the level card and the results screen, and the
## dive warning keeps its banner across the top whatever this panel is doing.
func set_compact(compact: bool) -> void:
	_extra.visible = not compact


## Canvas y of the bottom of the conditions panel. `PuzzleUi` starts the
## exact-parameters drawer below it — the two share the right-hand column and the
## drawer is the one that gives way.
##
## Deliberately the panel's MINIMUM size and not its current `size`: this is read
## in the same frame the medals and portal legend are folded away, and `size` is
## a laid-out value that has not caught up yet. Deferring the read to the next
## frame does not fix it either, because the container's own sort pass is also
## deferred. The minimum size recomputes on demand and hidden children
## contribute nothing to it, so it is right immediately.
func info_bottom() -> float:
	var top: float = MARGIN + (WEB_TOP_INSET if OS.has_feature("web") else 0.0)
	return top + _info.get_combined_minimum_size().y


# ================================================================== layout ===

func _layout() -> void:
	var vp := size
	if vp.x <= 0.0:
		return
	var top: float = MARGIN + (WEB_TOP_INSET if OS.has_feature("web") else 0.0)
	var status_w: float = clampf(vp.x * 0.30, 340.0, 430.0)
	var info_w: float = clampf(vp.x * 0.24, 280.0, 350.0)

	_status.anchor_left = 0.0
	_status.anchor_top = 0.0
	_status.anchor_right = 0.0
	_status.anchor_bottom = 0.0
	_status.grow_horizontal = Control.GROW_DIRECTION_END
	_status.grow_vertical = Control.GROW_DIRECTION_END
	_status.offset_left = MARGIN
	_status.offset_top = top
	_status.offset_right = MARGIN + status_w
	_status.offset_bottom = top

	_info.anchor_left = 1.0
	_info.anchor_top = 0.0
	_info.anchor_right = 1.0
	_info.anchor_bottom = 0.0
	_info.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_info.grow_vertical = Control.GROW_DIRECTION_END
	_info.offset_left = -(MARGIN + info_w)
	_info.offset_top = MARGIN
	_info.offset_right = -MARGIN
	_info.offset_bottom = MARGIN

	# The dive banner sits between the two panels, centred on the gap rather than
	# on the screen, so it never slides under either of them.
	var left_edge: float = MARGIN + status_w + 10.0
	var right_edge: float = vp.x - MARGIN - info_w - 10.0
	var width: float = maxf(right_edge - left_edge, 260.0)
	_dive.anchor_left = 0.0
	_dive.anchor_top = 0.0
	_dive.anchor_right = 0.0
	_dive.anchor_bottom = 0.0
	_dive.grow_horizontal = Control.GROW_DIRECTION_END
	_dive.grow_vertical = Control.GROW_DIRECTION_END
	_dive.offset_left = left_edge
	_dive.offset_top = top
	_dive.offset_right = left_edge + width
	_dive.offset_bottom = top

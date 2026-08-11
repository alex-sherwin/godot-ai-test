class_name PuzzleLevelSelect
extends PanelContainer

## The level browser. All ten levels are open from the start — the difficulty
## curve is real (each level's "harder than the last" justification is written
## down and measured) but gating it behind completion would hide nine tenths of
## the design from anyone who gets stuck on Level 4.
##
## Each card carries what a player needs to choose: the concept, the objective,
## the medal thresholds, the hint, and — where it applies — the badge that says
## this level contains a portal that will drop your disc out of the sky.
##
## The backdrop is opaque. A menu that lets a lit 3D scene through is the defect
## that shows up in every screenshot review, and this one covers 100% of the
## canvas on purpose.

signal level_chosen(level_id: String)
signal dismissed()
signal sandbox_requested()

const PT := preload("res://scripts/ui/puzzle/puzzle_theme.gd")
const Facts := preload("res://scripts/ui/puzzle/level_facts.gd")
const LevelDataT := preload("res://scripts/puzzle/level_data.gd")

var _grid: HFlowContainer = null
var _scroll: ScrollContainer = null
var _more: Button = null
var _notice: Label = null
var _cards: Dictionary = {}
var _current_id: String = ""
var _close_button: Button = null


func _init() -> void:
	theme_type_variation = "ScreenPanel"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 26)
	margin.add_theme_constant_override("margin_right", 26)
	# The web export shell injects a "Back to overview" pill over the top-left
	# corner of the canvas (`export_presets.cfg`, html/head_include). Start below
	# it, exactly as `PuzzleLevelHud` and `ControlPanel` do.
	margin.add_theme_constant_override("margin_top",
		20 + (34 if OS.has_feature("web") else 0))
	margin.add_theme_constant_override("margin_bottom", 18)
	add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	margin.add_child(col)

	# --- header --------------------------------------------------------
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	col.add_child(head)

	var titles := VBoxContainer.new()
	titles.add_theme_constant_override("separation", 2)
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(titles)
	var title := Label.new()
	title.theme_type_variation = "ResultTitle"
	title.text = "Portal Puzzles"
	titles.add_child(title)
	var sub := Label.new()
	sub.theme_type_variation = "BodyLabel"
	sub.text = "Ten sealed chambers, each with its own air. The physics is the same model the Flight Lab runs; what changes is the room on the other side of the portal."
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub.custom_minimum_size.x = 320
	titles.add_child(sub)

	var actions := VBoxContainer.new()
	actions.add_theme_constant_override("separation", 6)
	actions.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	head.add_child(actions)
	_close_button = UiKit.button(actions, "Back to the level", "GhostButton",
		"Return to the level you were playing.   (Esc)")
	_close_button.pressed.connect(func() -> void: dismissed.emit())
	var lab := UiKit.button(actions, "Open Flight Lab instead", "GhostButton",
		"The sandbox: one open range, every disc, every parameter.")
	lab.pressed.connect(func() -> void: sandbox_requested.emit())

	# --- legend --------------------------------------------------------
	var legend := PanelContainer.new()
	legend.theme_type_variation = "DivePanel"
	col.add_child(legend)
	var legend_col := VBoxContainer.new()
	legend_col.add_theme_constant_override("separation", 2)
	legend.add_child(legend_col)
	var legend_head := Label.new()
	legend_head.theme_type_variation = "DiveTitle"
	legend_head.text = Facts.DIVE_TITLE
	legend_col.add_child(legend_head)
	var legend_body := Label.new()
	legend_body.theme_type_variation = "DiveLabel"
	legend_body.text = Facts.DIVE_LEGEND
	legend_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	legend_body.custom_minimum_size.x = 40
	legend_col.add_child(legend_body)

	# --- grid ----------------------------------------------------------
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.follow_focus = true
	col.add_child(_scroll)

	_notice = Label.new()
	_notice.theme_type_variation = "BadLabel"
	_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notice.visible = false
	col.add_child(_notice)

	_grid = HFlowContainer.new()
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", 10)
	_grid.add_theme_constant_override("v_separation", 10)
	_scroll.add_child(_grid)

	# --- the scroll cue ------------------------------------------------
	# At 1280x720 three cards fit per row and rows 4 and 5 — levels 9 and 10 —
	# are below the fold, with a 6 px scrollbar as the only sign they exist.
	# Nine tenths of the level set is visible; the tenth that is not is the two
	# hardest levels, and a player who never finds them is the failure this
	# banner exists to prevent. It says how many are hidden, it is clickable,
	# and it disappears once you reach the bottom.
	_more = Button.new()
	_more.theme_type_variation = "GhostButton"
	_more.focus_mode = Control.FOCUS_NONE
	_more.visible = false
	_more.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_more.pressed.connect(_scroll_a_page)
	col.add_child(_more)
	_scroll.get_v_scroll_bar().value_changed.connect(func(_v: float) -> void: _update_more())
	_scroll.resized.connect(_update_more)
	_grid.resized.connect(_update_more)


## How many cards are entirely below the visible area, and the banner that says
## so. Counted from the cards' own rectangles rather than from a row estimate,
## because `HFlowContainer` decides the row count from the canvas width and this
## panel is played at anything from 760 px to 1920 px wide.
func _update_more() -> void:
	if _more == null or _scroll == null:
		return
	var bar := _scroll.get_v_scroll_bar()
	var view_bottom: float = bar.value + _scroll.size.y
	var hidden := 0
	var first_hidden := ""
	for id: String in _cards:
		var card: PanelContainer = _cards[id]
		if card.position.y + card.size.y * 0.5 > view_bottom:
			hidden += 1
			if first_hidden.is_empty() or card.position.y < _cards[first_hidden].position.y:
				first_hidden = id
	if hidden <= 0:
		_more.visible = false
		return
	_more.visible = true
	_more.text = "▼  Scroll for %d more level%s" % [hidden, "" if hidden == 1 else "s"]
	_more.tooltip_text = "There are %d levels in all. Scroll, or click here." % _cards.size()


func _scroll_a_page() -> void:
	if _scroll == null:
		return
	var bar := _scroll.get_v_scroll_bar()
	bar.value = minf(bar.value + _scroll.size.y * 0.8, bar.max_value - _scroll.size.y)
	_update_more()


# ==================================================================== fill ===

func set_levels(levels: Array, medals: Dictionary) -> void:
	for child in _grid.get_children():
		child.queue_free()
	_cards.clear()
	for lv in levels:
		var level: LevelDataT = lv
		_card(level, str(medals.get(level.id, "")))
	_apply_selection()
	# The cards have no size until the container has laid them out, so the
	# overflow count is only meaningful a frame later.
	call_deferred("_update_more")


func set_notice(text: String) -> void:
	_notice.text = text
	_notice.visible = not text.is_empty()


func _card(level: LevelDataT, medal: String) -> void:
	var card := PanelContainer.new()
	card.theme_type_variation = "LevelCard"
	# Three across at 1280 with the margins and separation below, two when the
	# canvas is wider than it is tall by less.
	card.custom_minimum_size = Vector2(376, 0)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	_grid.add_child(card)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 5)
	card.add_child(col)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	col.add_child(head)
	var order := Label.new()
	order.theme_type_variation = "NumberLabel"
	order.text = "%02d" % level.order
	head.add_child(order)
	var name_label := Label.new()
	name_label.theme_type_variation = "TitleLabel"
	name_label.text = level.name
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.clip_text = true
	head.add_child(name_label)
	var chip := PanelContainer.new()
	chip.theme_type_variation = PT.medal_variation(medal)
	head.add_child(chip)
	var chip_label := Label.new()
	chip_label.theme_type_variation = PT.medal_variation(medal) + "Label"
	chip_label.text = PT.medal_label(medal)
	chip.add_child(chip_label)

	UiKit.body(col, level.concept, "DimLabel")

	var badges := HFlowContainer.new()
	badges.add_theme_constant_override("h_separation", 5)
	badges.add_theme_constant_override("v_separation", 4)
	col.add_child(badges)
	if Facts.has_dive_portal(level):
		_badge(badges, "DIVE PORTAL", true)
	if Facts.places_portals(level):
		_badge(badges, "YOU PLACE A PORTAL", false)
	if not level.buttons.is_empty():
		_badge(badges, "BUTTONS", false)
	_badge(badges, "%d ROOMS" % level.rooms.size(), false)
	_badge(badges, "1 DISC MAX" if level.max_discs == 1 else "%d DISCS MAX" % level.max_discs, false)

	var objective := PanelContainer.new()
	objective.theme_type_variation = "InsetPanel"
	col.add_child(objective)
	var objective_col := VBoxContainer.new()
	objective_col.add_theme_constant_override("separation", 3)
	objective.add_child(objective_col)
	UiKit.body(objective_col, Facts.objective_line(level), "SmallLabel")
	var tiers := HBoxContainer.new()
	tiers.add_theme_constant_override("separation", 10)
	objective_col.add_child(tiers)
	for m in level.medals:
		var tier: LevelDataT.MedalTier = m
		var t := Label.new()
		t.theme_type_variation = PT.medal_variation(tier.tier) + "Label"
		t.text = "%s ≤ %.0f m" % [PT.medal_label(tier.tier), tier.max_flag_distance_m]
		tiers.add_child(t)

	var hint_panel := PanelContainer.new()
	hint_panel.theme_type_variation = "HintPanel"
	col.add_child(hint_panel)
	var hint := Label.new()
	hint.theme_type_variation = "HintLabel"
	hint.text = "Hint — " + level.hint
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size.x = 40
	hint_panel.add_child(hint)

	# Hand-rolled hit handling, matching `RosterPanel`'s rows: a Button cannot
	# size itself from child controls, and a card is all child controls.
	var level_id: String = level.id
	card.gui_input.connect(func(event: InputEvent) -> void:
		var mb := event as InputEventMouseButton
		if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			level_chosen.emit(level_id))
	card.mouse_entered.connect(func() -> void:
		if _current_id != level_id:
			card.theme_type_variation = "LevelCardHover")
	card.mouse_exited.connect(func() -> void:
		if _current_id != level_id:
			card.theme_type_variation = "LevelCard")
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	# THE WHOLE CARD has to be clickable. A `PanelContainer` stops mouse input by
	# default, so the objective box and the hint box inside each card were eating
	# the click and doing nothing with it — measured in a browser at a canvas
	# width where four cards fit per row and the click landed on the hint. Labels
	# already default to ignoring input; these do not.
	_make_inert(card)
	_cards[level_id] = card


## Every Control under `root` stops taking mouse input, so `root` gets it all.
static func _make_inert(root: Node) -> void:
	for child in root.get_children():
		var control := child as Control
		if control != null:
			control.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_make_inert(child)


func _badge(parent: Node, text: String, dive: bool) -> void:
	var p := PanelContainer.new()
	p.theme_type_variation = "DiveChip" if dive else "PortalChip"
	parent.add_child(p)
	var l := Label.new()
	l.theme_type_variation = "DiveLabel" if dive else "PortalChipLabel"
	l.text = text
	p.add_child(l)


func set_current(level_id: String) -> void:
	_current_id = level_id
	_apply_selection()


func _apply_selection() -> void:
	for id: String in _cards:
		var card: PanelContainer = _cards[id]
		card.theme_type_variation = "LevelCardCurrent" if id == _current_id else "LevelCard"


func set_can_dismiss(can: bool) -> void:
	_close_button.disabled = not can

class_name PuzzleAdvancedPanel
extends PanelContainer

## The exact-numbers panel: every release parameter the drag sets, plus the two
## it does not, as `SliderField`s — the same widget the sandbox's Throw tab uses,
## so a player who has used Flight Lab already knows this control.
##
## ---------------------------------------------------------------------------
## Why it exists at all when there is a drag
## ---------------------------------------------------------------------------
## Dragging is fast and approximate. Puzzles are not: LEVEL_DESIGN measures gold
## windows of 2-3 degrees on launch angle (Level 9) and about 3 m of miss per
## degree of hyzer (Level 2). A player who has found the shape of the answer by
## dragging needs to be able to say "10.0 degrees" and to say it again tomorrow.
## So the numbers are not a debug view — they are how a throw is reproduced.
##
## Both directions are live and there is exactly one owner of the values:
## `PuzzleAimController`. Dragging writes it and this panel reads it back;
## typing writes it and the reticle moves. Neither path has its own copy.
##
## Collapsed by default: the 3D view is the product, and this is 300 px of
## panel. The header stays, so the panel advertises itself.

const LevelDataT := preload("res://scripts/puzzle/level_data.gd")

signal collapsed_changed(collapsed: bool)

var controller: PuzzleAimController = null

var _body: VBoxContainer = null
var _scroll: ScrollContainer = null
var _header: Button = null
var _speed: SliderField = null
var _spin: SliderField = null
var _nose: SliderField = null
var _hyzer: SliderField = null
var _launch: SliderField = null
var _height: SliderField = null
var _heading: SliderField = null
var _fields: Array[SliderField] = []
var _summary: Label = null
var _solution_row: HBoxContainer = null
var _solution_button: Button = null
var _collapsed: bool = true
var _syncing: bool = false


func _init(aim: PuzzleAimController) -> void:
	controller = aim
	theme_type_variation = "DrawerPanel"
	mouse_filter = Control.MOUSE_FILTER_STOP

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 7)
	margin.add_child(col)

	_header = Button.new()
	_header.theme_type_variation = "DisclosureButton"
	_header.focus_mode = Control.FOCUS_NONE
	_header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_header.tooltip_text = "Every release parameter, exactly.   (A)"
	_header.pressed.connect(func() -> void: set_collapsed(not _collapsed))
	col.add_child(_header)

	_summary = Label.new()
	_summary.theme_type_variation = "SmallLabel"
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary.custom_minimum_size.x = 40
	col.add_child(_summary)

	# The fields scroll. Expanded, the drawer is capped so it cannot reach the
	# room-conditions panel above it (they share the right-hand column), and on a
	# 1280x720 canvas seven slider fields plus the solution row do not fit in what
	# is left. A panel that silently grows under another panel is the defect this
	# replaces.
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.follow_focus = true
	_scroll.visible = false
	# A floor, so a short canvas cannot squeeze the drawer down to a sliver, and
	# bottom padding so the last field never ends flush with the panel edge —
	# content cut exactly at a slider reads as clipped rather than as scrollable.
	_scroll.custom_minimum_size.y = 132
	col.add_child(_scroll)

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 6)
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_body)

	var card := UiKit.card(_body, "Release")
	_speed = _add(card, SliderField.new("Launch speed", 4.0, 40.0, 0.5, 22.0, " m/s",
		"Speed of the disc's centre of mass at release. The aim drag sets this from how far out you put the reticle."))
	_spin = _add(card, SliderField.new("Spin", -45.0, 45.0, 0.5, 20.0, " rev/s",
		"Signed: positive is RHBH. Spin is the gain on the aerodynamic torque — more spin holds the bank you released with, exactly like thicker air does."))
	_nose = _add(card, SliderField.new("Nose angle", -20.0, 20.0, 0.5, 0.0, "°",
		"Disc pitch relative to the velocity vector. Nose up costs distance fast."))
	_hyzer = _add(card, SliderField.new("Hyzer / anhyzer", -60.0, 60.0, 0.5, 4.0, "°",
		"Bank angle at release. Positive is hyzer. Right-drag horizontally, or roll the wheel for one degree a notch."))
	_launch = _add(card, SliderField.new("Launch angle", -30.0, 45.0, 0.5, 8.0, "°",
		"Elevation of the velocity vector above horizontal. Right-drag vertically."))
	_height = _add(card, SliderField.new("Release height", 0.1, 2.5, 0.05, 1.4, " m",
		"Height above the tee at release."))
	_heading = _add(card, SliderField.new("Aim", -45.0, 45.0, 0.5, 0.0, "°",
		"Heading of the throw. 0 is straight downrange; positive aims right. Left-drag on the view sets this."))

	_solution_row = HBoxContainer.new()
	_solution_row.add_theme_constant_override("separation", 6)
	_solution_row.visible = false
	_body.add_child(_solution_row)
	UiKit.body(_solution_row, "A line this level was validated against:", "TinyLabel")
	_solution_button = UiKit.button(_solution_row, "Load it", "GhostButton",
		"Fill in the release the level designer measured. Solving it yourself is the game; this is here so a level is never unwinnable.")

	UiKit.spacer(_body, 14)

	if controller != null:
		controller.changed.connect(_sync_from_controller)
	_update_header()


func _add(parent: Node, field: SliderField) -> SliderField:
	parent.add_child(field)
	field.value_changed.connect(_on_field_changed.bind(field))
	_fields.append(field)
	return field


func _on_field_changed(_v: float, _field: SliderField) -> void:
	if _syncing or controller == null:
		return
	# Push all seven every time rather than mapping field -> setter: each setter
	# clamps and is idempotent, and this cannot drift out of sync with the field
	# list the way a parallel lookup table can.
	controller.set_speed(_speed.get_value())
	controller.set_spin(_spin.get_value())
	controller.set_nose(_nose.get_value())
	controller.set_hyzer(_hyzer.get_value())
	controller.set_launch(_launch.get_value())
	controller.set_height(_height.get_value())
	controller.set_heading(_heading.get_value())


func _sync_from_controller() -> void:
	if controller == null:
		return
	_syncing = true
	_speed.set_range(controller.speed_min, controller.speed_max)
	_speed.set_value_silent(controller.speed_mps)
	_spin.set_value_silent(controller.spin_rps)
	_nose.set_value_silent(controller.nose_deg)
	_hyzer.set_value_silent(controller.hyzer_deg)
	_launch.set_value_silent(controller.launch_deg)
	_height.set_value_silent(controller.height_m)
	_heading.set_value_silent(controller.heading_deg)
	_syncing = false
	_update_hints()
	_summary.text = controller.summary()


func _update_hints() -> void:
	_speed.set_hint("%.0f%% power" % (controller.power() * 100.0))
	_spin.set_hint("RHBH" if controller.spin_rps >= 0.0 else "RHFH")
	_hyzer.set_hint("hyzer" if controller.hyzer_deg > 0.5
		else ("anhyzer" if controller.hyzer_deg < -0.5 else "flat"))
	_heading.set_hint("right" if controller.heading_deg > 0.5
		else ("left" if controller.heading_deg < -0.5 else "downrange"))
	_nose.set_hint("nose up" if controller.nose_deg > 0.5
		else ("nose down" if controller.nose_deg < -0.5 else "flat"))


# -------------------------------------------------------------------- api ---

func set_collapsed(collapsed: bool) -> void:
	if _collapsed == collapsed:
		return
	_collapsed = collapsed
	_scroll.visible = not collapsed
	_update_header()
	collapsed_changed.emit(collapsed)


func is_collapsed() -> bool:
	return _collapsed


func _update_header() -> void:
	# ASCII markers on purpose: the export's bundled font has no geometric
	# triangles and draws them as tofu boxes. Verified in a browser screenshot.
	_header.text = ("+  EXACT PARAMETERS" if _collapsed else "-  EXACT PARAMETERS") + "   (A)"


## Offer the release this level was validated against. Every level ships one
## (LEVEL_DESIGN §5 replayed all ten through the reference integrator), so this
## is a real escape hatch and not a placeholder: solving it is the game, but a
## level should never be unwinnable.
func set_solution(step: LevelDataT.SolutionStep) -> void:
	if step == null or controller == null:
		_solution_row.visible = false
		return
	_solution_row.visible = true
	_solution_button.text = "Load the %s line" % step.disc.capitalize()
	for c in _solution_button.pressed.get_connections():
		_solution_button.pressed.disconnect(c["callable"])
	_solution_button.pressed.connect(func() -> void: controller.apply_solution(step))


func refresh() -> void:
	_sync_from_controller()

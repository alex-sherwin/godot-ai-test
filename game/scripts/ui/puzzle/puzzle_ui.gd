class_name PuzzleUi
extends Control

## The whole Portal Puzzles interface, as one node.
##
## Layout, deliberately, and it is the rule the sandbox already follows: the 3D
## view is the product and the panels serve it. Nothing sits in the middle of the
## screen except the aim overlay, which is drawn *on* the view rather than over
## it.
##
##   top left      objective, progress, hint          `PuzzleLevelHud`
##   top right     per-room conditions, medals, portal legend
##   top centre    the dive-portal warning, when the level has one
##   bottom left   the action bar: throw, retry, disc, camera, levels
##   bottom right  the exact-parameters drawer, collapsed by default
##   everywhere    the aim overlay: ghost, reticle, bank, flag
##
## Level select and the results screen are the two modal states; both are
## dismissible and neither steals the keyboard from the rest.
##
## ---------------------------------------------------------------------------
## Keyboard
## ---------------------------------------------------------------------------
## Every key consumed here is declared in `scripts/key_bindings.gd` under
## `PUZZLE`, and `tests/suites/test_key_bindings.gd` scrapes the `match` arms
## below and fails the build if they and the table disagree. That test exists
## because two handlers once bound the same six keys and tree order silently
## decided which won.

signal throw_requested()
signal retry_requested()
signal level_requested(level_id: String)
signal camera_view_changed(view: String)
## One channel for everything the camera can be asked to do that is not a named
## view: "inspect_toggle", "flag", "portal", "reset", "zoom_in", "zoom_out".
signal camera_command(command: String)
## The landing beat was cut short by a keypress. See `PuzzleModeApp._land`.
signal hold_skipped()
signal ghost_toggled(enabled: bool)
signal disc_changed(disc_id: String)
signal portal_disc_toggled(portal_disc_id: String)
signal sandbox_requested()

const Facts := preload("res://scripts/ui/puzzle/level_facts.gd")
const LevelDataT := preload("res://scripts/puzzle/level_data.gd")

## `inspect` is free look. It is a view rather than a modifier so that it appears
## in the same segmented control as the others, is reachable by the same C cycle,
## and leaves by being replaced — there is no second state to get stuck in.
const VIEWS := ["tee", "top", "level", "follow", "inspect"]
const VIEW_LABELS := ["Tee", "Top", "Level", "Follow", "Inspect"]

var aim: PuzzleAimController = null
var overlay: PuzzleAimOverlay = null
var hud: PuzzleLevelHud = null
var advanced: PuzzleAdvancedPanel = null
var level_select: PuzzleLevelSelect = null
var results: PuzzleResultsScreen = null

var _action_bar: PanelContainer = null
var _status: Label = null
var _shortcuts: Label = null
var _throw_button: Button = null
var _disc_row: HBoxContainer = null
var _portal_check: CheckButton = null
var _view_buttons: Array[Button] = []
var _ghost_check: CheckButton = null
var _gesture_hint: PanelContainer = null
var _inspect_row: HFlowContainer = null
var _portal_focus_button: Button = null

var _disc_buttons: Dictionary = {}
var _disc_ids: PackedStringArray = PackedStringArray()
var _disc_id: String = ""
var _portal_disc_id: String = ""
var _level: LevelDataT = null
var _ghost_enabled: bool = true


func _init(controller: PuzzleAimController) -> void:
	aim = controller


func _ready() -> void:
	theme = PuzzleTheme.build()
	mouse_filter = Control.MOUSE_FILTER_PASS

	overlay = PuzzleAimOverlay.new()
	overlay.controller = aim
	add_child(overlay)

	hud = PuzzleLevelHud.new()
	add_child(hud)

	_build_action_bar()
	_build_gesture_hint()

	advanced = PuzzleAdvancedPanel.new(aim)
	add_child(advanced)
	advanced.collapsed_changed.connect(func(collapsed: bool) -> void:
		hud.set_compact(not collapsed)
		_layout())

	results = PuzzleResultsScreen.new()
	add_child(results)
	results.dismissed.connect(func() -> void: results.visible = false)
	results.retry_requested.connect(func() -> void:
		results.visible = false
		retry_requested.emit())
	results.levels_requested.connect(func() -> void: open_level_select())

	level_select = PuzzleLevelSelect.new()
	level_select.visible = false
	add_child(level_select)
	level_select.dismissed.connect(func() -> void: level_select.visible = false)
	level_select.level_chosen.connect(func(id: String) -> void:
		level_select.visible = false
		results.visible = false
		level_requested.emit(id))
	level_select.sandbox_requested.connect(func() -> void: sandbox_requested.emit())

	resized.connect(_layout)
	_action_bar.resized.connect(_layout)
	# THE trap in this project, already documented in `app/hud_overlay.gd`:
	# setting anchors alone on a Control whose parent is not a Control leaves it
	# at ZERO SIZE. Everything still draws — `_draw` is not clipped and child
	# panels keep their minimum size — so the failure looks like "every panel is
	# stacked in the top-left corner and the full-screen menu is transparent",
	# which reads as a styling bug rather than a sizing one. Offsets have to be
	# set too, and the size re-applied whenever the viewport changes.
	get_viewport().size_changed.connect(_fit_to_viewport)
	_fit_to_viewport()
	advanced.refresh()


## The aim overlay is a live control surface, so it goes quiet whenever a modal
## is up. Driven from a per-frame read of the two `visible` flags rather than
## from every call site that raises or dismisses one: there are six of those and
## the day one of them is missed, the reticle sits on top of the results screen
## describing a throw that has already happened.
func _process(_delta: float) -> void:
	var modal: bool = results.visible or level_select.visible
	overlay.aiming_enabled = not modal
	overlay.show_flag = not level_select.visible


func _fit_to_viewport() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	size = get_viewport().get_visible_rect().size
	_layout()


# =================================================================== build ===

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

	_throw_button = UiKit.button(flow, "THROW", "PrimaryButton", "Release the disc.   (Space)")
	_throw_button.pressed.connect(func() -> void: throw_requested.emit())

	var retry := UiKit.button(flow, "Retry", "GhostButton",
		"Start the level again from the tee: discs, buttons and placed portals all reset.   (R)")
	retry.pressed.connect(func() -> void: retry_requested.emit())

	var levels := UiKit.button(flow, "Levels", "GhostButton", "Browse all ten levels.   (L)")
	levels.pressed.connect(func() -> void: open_level_select())

	flow.add_child(VSeparator.new())

	var disc_label := Label.new()
	disc_label.theme_type_variation = "TinyLabel"
	disc_label.text = "DISC"
	disc_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	flow.add_child(disc_label)
	_disc_row = HBoxContainer.new()
	_disc_row.add_theme_constant_override("separation", 4)
	flow.add_child(_disc_row)

	# Only levels that ship a portal disc show this, and it is a mode switch
	# rather than a separate throw button: the release is set the same way and
	# what changes is what the disc does when it lands.
	_portal_check = UiKit.check(flow, "Portal disc", false,
		"Throw the portal disc instead. It opens a portal wherever it strikes a portalable panel, never scores, and is spent either way.")
	_portal_check.visible = false
	_portal_check.toggled.connect(func(pressed: bool) -> void:
		portal_disc_toggled.emit(_portal_disc_id if pressed else ""))

	flow.add_child(VSeparator.new())

	var group := ButtonGroup.new()
	const VIEW_TIPS := {
		"tee": "Behind the tee, along the aim.",
		"top": "Straight down over the whole level — the view that explains a portal chain.",
		"level": "The whole level from a corner.",
		"follow": "Chase the disc.",
		"inspect": "Free look: drag to orbit, right-drag to pan, wheel or +/- to zoom. Aiming is suspended and your throw is left exactly as it was.   (F)",
	}
	for i in VIEWS.size():
		var b := UiKit.button(flow, VIEW_LABELS[i], "SegButton",
			"%s   (C cycles)" % str(VIEW_TIPS.get(VIEWS[i], "Camera: " + VIEW_LABELS[i])))
		b.toggle_mode = true
		b.button_group = group
		if VIEWS[i] == "tee":
			b.button_pressed = true
		var view: String = VIEWS[i]
		b.pressed.connect(func() -> void: camera_view_changed.emit(view))
		_view_buttons.append(b)

	_ghost_check = UiKit.check(flow, "Ghost", true,
		"Predict this throw inside the launch room. It stops at the first portal and never predicts through one.   (G)")
	_ghost_check.toggled.connect(func(pressed: bool) -> void:
		_ghost_enabled = pressed
		ghost_toggled.emit(pressed))

	_build_inspect_row(col)

	var status_row := HBoxContainer.new()
	status_row.add_theme_constant_override("separation", 8)
	col.add_child(status_row)
	_status = Label.new()
	_status.theme_type_variation = "SmallLabel"
	_status.text = "Ready."
	_status.clip_text = true
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_row.add_child(_status)
	_shortcuts = Label.new()
	_shortcuts.theme_type_variation = "TinyLabel"
	# Generated from the binding table, so the hint cannot advertise a key the
	# handler does not bind.
	_shortcuts.text = KeyBindings.hint(KeyBindings.PUZZLE,
		[KEY_SPACE, KEY_R, KEY_C, KEY_F, KEY_A, KEY_G, KEY_K, KEY_L])
	_shortcuts.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	status_row.add_child(_shortcuts)


## The inspect controls, and their legend. Only on screen while the camera is in
## free look, and inside the action bar rather than floating: a control surface
## that appears in a new place every time is a control surface nobody finds.
##
## The three buttons are the answer to "I have flown the camera somewhere odd":
## two framings worth having on a multi-room level, and one way straight back.
func _build_inspect_row(col: VBoxContainer) -> void:
	_inspect_row = HFlowContainer.new()
	_inspect_row.add_theme_constant_override("h_separation", 6)
	_inspect_row.visible = false
	col.add_child(_inspect_row)

	var tag := Label.new()
	tag.theme_type_variation = "TinyLabel"
	tag.text = "INSPECT"
	tag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_inspect_row.add_child(tag)

	var flag := UiKit.button(_inspect_row, "Flag", "GhostButton",
		"Orbit the flag, seen from the tee's side of it.")
	flag.pressed.connect(func() -> void: camera_command.emit("flag"))
	_portal_focus_button = UiKit.button(_inspect_row, "Portal", "GhostButton",
		"Orbit a portal, square-on from the room it opens into.")
	_portal_focus_button.pressed.connect(func() -> void: camera_command.emit("portal"))
	var home := UiKit.button(_inspect_row, "Back to the tee", "GhostButton",
		"Put the camera back behind the tee, along the aim.   (Home)")
	home.pressed.connect(func() -> void: camera_command.emit("reset"))

	var legend := Label.new()
	legend.theme_type_variation = "TinyLabel"
	legend.text = "drag orbit · right-drag pan · wheel or + / − zoom · Esc back to the tee"
	legend.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_inspect_row.add_child(legend)


func set_portal_focus_available(available: bool) -> void:
	if _portal_focus_button != null:
		_portal_focus_button.visible = available


## The gesture legend. It sits over the view, above the action bar, because the
## drag is the primary control and an undiscoverable primary control is not one.
func _build_gesture_hint() -> void:
	_gesture_hint = PanelContainer.new()
	_gesture_hint.theme_type_variation = "HudPanel"
	_gesture_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_gesture_hint)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 1)
	_gesture_hint.add_child(col)
	col.add_child(UiKit.section_label("Aim by dragging"))
	for row: Array in [
			["Drag", "move the reticle — its bearing is your aim, its distance your power"],
			["Right-drag", "shape the release — across is hyzer, up/down is launch angle"],
			["Wheel", "hyzer, one degree a notch"],
			# The camera is the other half of the mouse and has to be advertised in
			# the same place, or free look is a feature nobody finds. Middle-drag
			# works at any time because the aim never uses that button.
			["Middle-drag", "orbit the camera — starts inspecting, shift to pan"],
			["F", "inspect: free look around the course, aiming suspended"]]:
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 8)
		col.add_child(line)
		var k := Label.new()
		k.theme_type_variation = "ValueLabel"
		k.text = str(row[0])
		k.custom_minimum_size.x = 78
		line.add_child(k)
		var v := Label.new()
		v.theme_type_variation = "TinyLabel"
		v.text = str(row[1])
		line.add_child(v)


# ==================================================================== fill ===

func set_level(level: LevelDataT, library: Object) -> void:
	_level = level
	hud.set_level(level)
	level_select.set_current(level.id)
	_fill_discs(level.allowed_disc_ids(), library)

	var ids := Facts.portal_disc_ids(level)
	_portal_disc_id = ids[0] if not ids.is_empty() else ""
	_portal_check.visible = not _portal_disc_id.is_empty()
	_portal_check.set_pressed_no_signal(false)

	advanced.set_solution(Facts.scoring_solution(level))
	set_status("%s — %s" % [level.name, level.concept])


func _fill_discs(ids: PackedStringArray, library: Object) -> void:
	for child in _disc_row.get_children():
		child.queue_free()
	_disc_buttons.clear()
	_disc_ids = ids
	if _disc_ids.is_empty():
		return
	var group := ButtonGroup.new()
	for id in _disc_ids:
		var label := id.capitalize()
		var tooltip := "Throw the %s." % label
		var disc: Variant = library.call("get_disc", id) if library != null else null
		if disc is Object:
			var o: Object = disc
			label = str(o.get("name"))
			tooltip = "%s — %s, %s/%s/%s/%s" % [label,
				UiKit.category_label(str(o.get("category"))),
				str(o.get("speed")), str(o.get("glide")), str(o.get("turn")), str(o.get("fade"))]
		var b := UiKit.button(_disc_row, label, "DiscButton", tooltip)
		b.toggle_mode = true
		b.button_group = group
		var disc_id: String = id
		b.pressed.connect(func() -> void: select_disc(disc_id))
		_disc_buttons[id] = b
	select_disc(_disc_ids[0])


func select_disc(disc_id: String) -> void:
	if not _disc_buttons.has(disc_id):
		return
	_disc_id = disc_id
	(_disc_buttons[disc_id] as Button).button_pressed = true
	disc_changed.emit(disc_id)


func current_disc_id() -> String:
	return _disc_id


## "" for an ordinary throw, else the portal-disc id the session should spend.
func current_portal_disc_id() -> String:
	return _portal_disc_id if (_portal_check.visible and _portal_check.button_pressed) else ""


func set_portal_disc_available(available: bool) -> void:
	_portal_check.disabled = not available
	if not available and _portal_check.button_pressed:
		_portal_check.set_pressed_no_signal(false)
		portal_disc_toggled.emit("")


func cycle_disc(step: int) -> void:
	if _disc_ids.is_empty():
		return
	var i := 0
	for j in _disc_ids.size():
		if _disc_ids[j] == _disc_id:
			i = j
			break
	select_disc(_disc_ids[posmod(i + step, _disc_ids.size())])


func set_status(text: String) -> void:
	_status.text = text


func set_throw_enabled(enabled: bool) -> void:
	_throw_button.disabled = not enabled


func ghost_enabled() -> bool:
	return _ghost_enabled


func open_level_select() -> void:
	end_landing_hold()
	level_select.visible = true
	results.visible = false


# ============================================================ landing hold ===

## Mark the landing and hold everything else off it. `label` carries the number
## the player threw for; `hint` says how to stop waiting.
func begin_landing_hold(at: Vector3, label: String, hint: String) -> void:
	overlay.landing_position = at
	overlay.landing_label = label
	overlay.landing_hint = hint
	overlay.show_landing = true
	overlay.holding = true


## End the beat but keep the marker: the results panel is a centred modal with a
## "Look at the landing" button, and that button has to lead somewhere.
func end_landing_hold() -> void:
	overlay.holding = false
	overlay.landing_hint = ""


func clear_landing() -> void:
	end_landing_hold()
	overlay.show_landing = false
	overlay.landing_label = ""


func cycle_camera() -> void:
	var current := _current_view_index()
	var next: int = (current + 1) % _view_buttons.size()
	_view_buttons[next].button_pressed = true
	camera_view_changed.emit(VIEWS[next])


func _current_view_index() -> int:
	for i in _view_buttons.size():
		if _view_buttons[i].button_pressed:
			return i
	return 0


func current_view() -> String:
	return VIEWS[_current_view_index()]


## `view` may be a framing with no button of its own — the landing hold is one —
## in which case the selector is left showing the view it will return to.
func set_camera_view(view: String) -> void:
	for i in VIEWS.size():
		if VIEWS[i] == view:
			_view_buttons[i].button_pressed = true
	var inspecting: bool = view == "inspect"
	_inspect_row.visible = inspecting
	# The overlay is the one place that decides whether a drag is an aim or a
	# camera move, so it is told, rather than asking the rig every event.
	overlay.inspecting = inspecting
	_layout()


# =============================================================== shortcuts ===

## Every key here is declared in `KeyBindings.PUZZLE`; the guard is what stops
## this handler from swallowing something it does not own, and the test suite
## fails the build if the arms below and the table disagree.
func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	# ANY key cuts the landing beat short and brings the results, bound or not,
	# and does nothing else with that press. A key that both dismissed the hold
	# and did its own job would mean an impatient R retried the level before the
	# player had seen the score they were retrying.
	if overlay.holding:
		hold_skipped.emit()
		get_viewport().set_input_as_handled()
		return
	if not KeyBindings.PUZZLE.has(key.keycode):
		return
	match key.keycode:
		KEY_SPACE, KEY_ENTER, KEY_KP_ENTER:
			if not level_select.visible and not _throw_button.disabled:
				throw_requested.emit()
		KEY_R:
			results.visible = false
			retry_requested.emit()
		KEY_A:
			advanced.set_collapsed(not advanced.is_collapsed())
		KEY_C:
			cycle_camera()
		KEY_F:
			camera_command.emit("inspect_toggle")
		KEY_HOME:
			camera_command.emit("reset")
		KEY_EQUAL, KEY_PLUS:
			camera_command.emit("zoom_in")
		KEY_MINUS:
			camera_command.emit("zoom_out")
		KEY_G:
			_ghost_check.button_pressed = not _ghost_check.button_pressed
		KEY_K:
			hud.set_hint_shown(not hud.hint_shown())
		KEY_L:
			if level_select.visible:
				level_select.visible = false
			else:
				open_level_select()
		KEY_N:
			# Always "next level", whether or not the results screen is up: the
			# binding table says `next level` and a key that means two things
			# depending on a modal is how a shortcut becomes untrustworthy.
			results.next_level_requested.emit()
		KEY_BRACKETLEFT:
			cycle_disc(-1)
		KEY_BRACKETRIGHT:
			cycle_disc(1)
		KEY_ESCAPE:
			if level_select.visible:
				level_select.visible = false
			elif results.visible:
				results.visible = false
			elif current_view() == "inspect":
				# "Back" out of a camera that has been flown somewhere odd, which
				# is the same gesture as backing out of a modal.
				camera_command.emit("reset")
			elif not advanced.is_collapsed():
				advanced.set_collapsed(true)
			else:
				return
		_:
			return
	get_viewport().set_input_as_handled()


# ================================================================== layout ===

## Anchors and grow directions rather than explicit sizes: the action bar's
## height changes whenever its flow container rewraps, and only the layout engine
## knows when that happened.
##
## `project.godot` pins `canvas_items` / `expand` at a 1280x720 base, so the
## canvas-space viewport is never smaller than 1280x720 in either axis at any
## window size. There are therefore no narrow-viewport branches here — the
## sandbox had some, they could not execute, and they were deleted.
## `tests/check_resources.gd` asserts the three project settings that guarantee
## the floor.
func _layout() -> void:
	var vp := size
	if vp.x <= 0.0:
		return
	var margin := 12.0
	var drawer_w: float = clampf(vp.x * 0.28, 330.0, 400.0)

	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	level_select.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# Bottom-left action bar, growing upward as it rewraps, stopping short of the
	# drawer so the two can never overlap.
	_action_bar.anchor_left = 0.0
	_action_bar.anchor_right = 1.0
	_action_bar.anchor_top = 1.0
	_action_bar.anchor_bottom = 1.0
	_action_bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_action_bar.offset_left = margin
	_action_bar.offset_right = -(margin + drawer_w + 10.0)
	_action_bar.offset_top = -margin
	_action_bar.offset_bottom = -margin

	# Exact-parameters drawer, bottom right. Collapsed it is one header sized by
	# its content; expanded it is pinned into the band between the bottom of the
	# room-conditions panel and the top of the action bar, and scrolls inside
	# that. Letting it size itself when open put 470 px of sliders straight
	# through the conditions panel on a 720-tall canvas.
	advanced.anchor_left = 1.0
	advanced.anchor_right = 1.0
	advanced.anchor_bottom = 1.0
	advanced.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	advanced.grow_vertical = Control.GROW_DIRECTION_BEGIN
	advanced.offset_left = -(margin + drawer_w)
	advanced.offset_right = -margin
	advanced.offset_bottom = -margin
	if advanced.is_collapsed():
		advanced.anchor_top = 1.0
		advanced.offset_top = -margin
	else:
		advanced.anchor_top = 0.0
		advanced.offset_top = clampf(hud.info_bottom() + 10.0, vp.y * 0.26, vp.y * 0.66)

	# The gesture legend rides just above the action bar. `_action_bar.resized`
	# re-runs this, because its height depends on how its flow container wrapped
	# and that is only known after a layout pass.
	var bar_h: float = _action_bar.size.y
	_gesture_hint.anchor_left = 0.0
	_gesture_hint.anchor_right = 0.0
	_gesture_hint.anchor_top = 1.0
	_gesture_hint.anchor_bottom = 1.0
	_gesture_hint.grow_horizontal = Control.GROW_DIRECTION_END
	_gesture_hint.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_gesture_hint.offset_left = margin
	_gesture_hint.offset_right = margin
	_gesture_hint.offset_top = -(margin + bar_h + 8.0)
	_gesture_hint.offset_bottom = -(margin + bar_h + 8.0)

	# Results: centred, wide enough for the four gauges in one row, and never so
	# tall that it hides the landing it is describing.
	var result_w: float = clampf(vp.x * 0.46, 540.0, 720.0)
	results.anchor_left = 0.5
	results.anchor_right = 0.5
	results.anchor_top = 0.5
	results.anchor_bottom = 0.5
	results.grow_horizontal = Control.GROW_DIRECTION_BOTH
	results.grow_vertical = Control.GROW_DIRECTION_BOTH
	results.offset_left = -result_w * 0.5
	results.offset_right = result_w * 0.5
	results.offset_top = 0.0
	results.offset_bottom = 0.0

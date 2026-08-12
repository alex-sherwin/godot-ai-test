class_name PuzzleAimOverlay
extends Control

## Everything drawn *over* the 3D view: the ghost trajectory, the aim reticle,
## the bank and launch indicators, and the marker where the prediction stops.
## Also the surface that owns the aim drag.
##
## ---------------------------------------------------------------------------
## Why this is 2D over the viewport rather than 3D geometry
## ---------------------------------------------------------------------------
## The ghost is an interface element, not part of the world: it must stay legible
## against a bright wall and a dark floor alike, it must never be occluded by the
## geometry it is predicting a path through, and its line weight must not shrink
## with distance or the far end of a 115 m preview disappears. Drawing it in
## canvas space with `Camera3D.unproject_position()` gives all three for free, and
## it costs one `draw_polyline_colors` call. Doing it in 3D would need an
## unshaded, depth-test-disabled material and would still be a 1 px line —
## GL Compatibility ignores line width (PORTAL_CONTRACT §8 territory, and P2's
## renderer is the place for anything that genuinely belongs in the world).
##
## ---------------------------------------------------------------------------
## The truncation is the point
## ---------------------------------------------------------------------------
## The ghost stops at the first portal plane and never predicts through it.
## Drawn naively that reads as a bug — a line that just stops. So it is drawn as
## a *designed boundary*: the trajectory fades to nothing over its last few
## metres, and a labelled marker sits on the plane saying what stopped it. When
## that portal inverts, the marker is orange and says DIVE, because a disc
## through it loses 40-45% of its distance (PORTAL_CONTRACT §6) and nothing about
## the geometry says so.

## ---------------------------------------------------------------------------
## It also owns the CAMERA gestures, and that is deliberate
## ---------------------------------------------------------------------------
## This Control covers the viewport with `MOUSE_FILTER_STOP`, so every click and
## every motion event reaches it before anything else in the tree — a camera
## reading `_unhandled_input` underneath would never see a thing. Rather than
## poke a hole in it, the overlay routes inspection gestures to the camera rig
## itself. One node decides whether a drag is an aim or a camera move, so the two
## cannot fight, and the rule is a single line:
##
##   INSPECT MODE     left-drag orbits, right-drag pans, the wheel zooms.
##                    Aiming is suspended; the aim is NOT touched.
##   AIMING (normal)  left-drag aims, right-drag shapes, the wheel is hyzer —
##                    and MIDDLE-drag orbits (shift+middle pans) so the camera
##                    can be nudged without leaving the aim.

const T := preload("res://scripts/ui/flight_lab_theme.gd")
const PT := preload("res://scripts/ui/puzzle/puzzle_theme.gd")
const RigT := preload("res://scripts/app/camera_rig.gd")

signal aim_dragged()
signal drag_finished()
## A click during the landing hold: the player is done looking, bring the results.
signal hold_skipped()
## A camera gesture arrived while the camera was in a fixed view. Free look is a
## mode, so the mode has to be entered — otherwise middle-drag moves an orbit
## nobody is looking through and reads as a dead control.
signal inspect_requested()

## Behind-the-camera and absurd projections come back as huge coordinates;
## anything further than this outside the canvas is dropped rather than drawn.
const CULL_MARGIN := 4000.0

var camera: Camera3D = null
var controller: PuzzleAimController = null
## The camera rig this overlay routes inspection gestures to. See the note above.
var rig: CameraRig = null

## The prediction, pushed from Track P3's `PuzzleGhost`. Kept as plain fields
## rather than a reference to the predictor so the overlay can be driven by a
## test, and so a stale predictor cannot be drawn.
var ghost_points: PackedVector3Array = PackedVector3Array()
## "floor" | "portal" | "wall" | "barrier" | "truncated" | "failed" | ""
var ghost_end_kind: String = ""
var ghost_end_position: Vector3 = Vector3.ZERO
## True when the portal the prediction stops at is a DIVE portal.
var ghost_end_dive: bool = false
## True when the prediction stops against a PORTALABLE panel rather than stone.
## The marker then reads as an opportunity (violet, the disc-placed portal
## colour) instead of as a failure, because with a portal disc armed that is
## exactly what it is.
var ghost_end_portalable: bool = false
## What the marker says. Set by the mode controller, which is the only thing
## that knows what `end_id` refers to.
var ghost_end_label: String = ""
var flag_position: Vector3 = Vector3.ZERO
var show_flag: bool = true
var aiming_enabled: bool = true
## Set while a disc is in the air: the ghost and the reticle are hidden, because
## a prediction for a throw that is already happening is noise.
var in_flight: bool = false
## Set for the beat after the disc stops, while the camera holds on the landing
## and before any result panel appears. Same reasoning as `in_flight`: the next
## throw's prediction drawn over the landing you are being shown is noise.
var holding: bool = false
## Set while the camera is in free look. The ghost and the reticle stay DRAWN —
## seeing your line from a new angle is the point — but the drag no longer aims.
var inspecting: bool = false

## Where the disc came to rest, and what to say about it. Drawn from the moment
## it lands until the next throw, so "Look at the landing" has something to look
## at.
var landing_position: Vector3 = Vector3.ZERO
var landing_label: String = ""
var show_landing: bool = false
## Second line under the landing tag during the hold, e.g. how to skip it.
var landing_hint: String = ""

var _font: Font = null
var _font_small: int = 11
## Label plates already drawn this frame, so a new one can step around them.
var _tag_rects: Array[Rect2] = []


func _init() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_CROSS
	focus_mode = Control.FOCUS_NONE


func _ready() -> void:
	_font = get_theme_default_font()
	set_process(true)


func _process(_delta: float) -> void:
	# The camera moves every frame in the follow view, so the overlay is redrawn
	# every frame. It is a few dozen draw calls; the alternative is stale lines.
	queue_redraw()


# =================================================================== input ===

## 0 none, 1 orbit, 2 pan. Camera drags are tracked separately from the aim drag
## because they can happen while an aim is not in progress and must never write
## the controller.
var _cam_drag: int = 0


func _gui_input(event: InputEvent) -> void:
	# The landing beat: any click ends it, and nothing else happens. A click that
	# both dismissed the hold AND re-aimed would mean the impatient player silently
	# threw away their aim.
	if holding:
		var press := event as InputEventMouseButton
		if press != null and press.pressed:
			hold_skipped.emit()
			accept_event()
		return

	# Camera gestures come first and do not care whether aiming is enabled:
	# looking around is legal while a result panel is up — that is what its
	# "Look at the landing" button is for — and while the aim is suspended.
	var press := event as InputEventMouseButton
	if press != null and _camera_button(press):
		return
	var move := event as InputEventMouseMotion
	if move != null and _cam_drag != 0:
		if rig != null:
			if _cam_drag == 1:
				rig.orbit(move.relative.x, move.relative.y)
			else:
				rig.pan(move.relative.x, move.relative.y)
		accept_event()
		return

	if controller == null or not aiming_enabled or inspecting:
		return

	var button := event as InputEventMouseButton
	if button != null:
		if button.button_index == MOUSE_BUTTON_WHEEL_UP and button.pressed:
			controller.nudge_hyzer(1.0)
			accept_event()
			return
		if button.button_index == MOUSE_BUTTON_WHEEL_DOWN and button.pressed:
			controller.nudge_hyzer(-1.0)
			accept_event()
			return
		var shape: bool = button.button_index == MOUSE_BUTTON_RIGHT \
			or (button.button_index == MOUSE_BUTTON_LEFT and button.shift_pressed)
		if button.button_index == MOUSE_BUTTON_LEFT or button.button_index == MOUSE_BUTTON_RIGHT:
			if button.pressed:
				if shape:
					controller.begin_shape(button.position)
				else:
					controller.begin_aim(button.position)
					_aim_to(button.position)
				aim_dragged.emit()
			else:
				controller.end_drag()
				drag_finished.emit()
			accept_event()
		return

	var motion := event as InputEventMouseMotion
	if motion == null:
		return
	if controller.drag != PuzzleAimController.Drag.NONE:
		if controller.drag == PuzzleAimController.Drag.SHAPE:
			controller.shape_to(motion.position)
		else:
			_aim_to(motion.position)
		aim_dragged.emit()
		accept_event()


const ROUTE_AIM := "aim"
const ROUTE_ORBIT := "orbit"
const ROUTE_PAN := "pan"
const ROUTE_ZOOM_IN := "zoom_in"
const ROUTE_ZOOM_OUT := "zoom_out"


## WHO OWNS THIS BUTTON. The whole no-fighting rule, as one pure function, so a
## test can assert it exhaustively rather than a comment claiming it.
##
## In inspect mode the whole mouse belongs to the camera. Outside it, only the
## middle button does — the two aim drags keep left and right exactly as they
## were, and the wheel keeps nudging hyzer, because a control that changes
## meaning under the player is worse than one they have to learn. The wheel
## becoming zoom in inspect mode is that rebind made deliberately and in one
## direction only: while you are aiming, the wheel is still hyzer.
static func route(button_index: int, shift: bool, inspecting_now: bool) -> String:
	if button_index == MOUSE_BUTTON_MIDDLE:
		return ROUTE_PAN if shift else ROUTE_ORBIT
	if not inspecting_now:
		return ROUTE_AIM
	match button_index:
		MOUSE_BUTTON_LEFT:
			return ROUTE_PAN if shift else ROUTE_ORBIT
		MOUSE_BUTTON_RIGHT:
			return ROUTE_PAN
		MOUSE_BUTTON_WHEEL_UP:
			return ROUTE_ZOOM_IN
		MOUSE_BUTTON_WHEEL_DOWN:
			return ROUTE_ZOOM_OUT
	return ROUTE_AIM


## Camera half of the button handling. Returns true when the event was a camera
## gesture and the aim must not see it.
func _camera_button(button: InputEventMouseButton) -> bool:
	var owner := route(button.button_index, button.shift_pressed, inspecting)
	if owner == ROUTE_AIM:
		return false
	if not inspecting and button.pressed:
		inspect_requested.emit()
	match owner:
		ROUTE_ORBIT:
			_cam_drag = 1 if button.pressed else 0
		ROUTE_PAN:
			_cam_drag = 2 if button.pressed else 0
		ROUTE_ZOOM_IN:
			if button.pressed and rig != null:
				rig.zoom(RigT.ZOOM_WHEEL_IN)
		ROUTE_ZOOM_OUT:
			if button.pressed and rig != null:
				rig.zoom(RigT.ZOOM_WHEEL_OUT)
		_:
			return false
	accept_event()
	return true


func _aim_to(screen_point: Vector2) -> void:
	var point: Variant = ground_point(screen_point)
	if point is Vector3:
		controller.aim_at_ground(point)


## Where a screen point lands on the tee room's floor, or null when the ray
## points at or above the horizon.
func ground_point(screen_point: Vector2) -> Variant:
	if camera == null or controller == null:
		return null
	var origin := camera.project_ray_origin(screen_point)
	var dir := camera.project_ray_normal(screen_point)
	if absf(dir.y) < 1.0e-5:
		return null
	var t := (controller.tee_position.y - origin.y) / dir.y
	if t <= 0.0:
		return null
	return origin + dir * t


# ==================================================================== draw ===

func _draw() -> void:
	if camera == null or controller == null:
		return
	_tag_rects.clear()
	if aiming_enabled and not in_flight and not holding:
		_draw_aim_line()
		_draw_ghost()
		_draw_reticle()
		_draw_release_indicator()
	# The landing is drawn whatever else is on screen, including under the results
	# modal: dismissing that panel has to leave something to look at.
	if show_landing:
		_draw_landing()
	if show_flag:
		_draw_flag()


func _project(p: Vector3) -> Variant:
	if camera.is_position_behind(p):
		return null
	var s := camera.unproject_position(p)
	if not s.is_finite() or absf(s.x) > CULL_MARGIN or absf(s.y) > CULL_MARGIN:
		return null
	return s


# ---------------------------------------------------------------- the ghost --

func _draw_ghost() -> void:
	var points := ghost_points
	if points.size() < 2:
		return

	var screen: PackedVector2Array = PackedVector2Array()
	var alphas: PackedFloat32Array = PackedFloat32Array()
	var n := points.size()
	for i in n:
		var s: Variant = _project(points[i])
		if s == null:
			break
		screen.append(s)
		# Fade the last fifth to nothing. The prediction genuinely gets less
		# useful as it approaches the boundary — beyond it the far room's air is
		# a different problem — so the line says so instead of stopping dead.
		var u := float(i) / float(maxi(n - 1, 1))
		alphas.append(1.0 if u < 0.8 else clampf((1.0 - u) / 0.2, 0.0, 1.0))
	if screen.size() < 2:
		return

	var base: Color = PT.DIVE if (ghost_end_dive and ghost_end_kind == "portal") else PT.GHOST

	# A wide, dim pass under a narrow, bright one: a 1 px line over a lit 3D
	# scene disappears, and a plain thick line reads as a pipe rather than a
	# prediction.
	var glow: PackedColorArray = PackedColorArray()
	var core: PackedColorArray = PackedColorArray()
	for i in screen.size():
		glow.append(Color(base.r, base.g, base.b, 0.20 * alphas[i]))
		core.append(Color(base.r, base.g, base.b, 0.95 * alphas[i]))
	draw_polyline_colors(screen, glow, 7.0, true)
	draw_polyline_colors(screen, core, 2.0, true)

	_draw_ghost_shadow(points)
	_draw_stop_marker()


## The ghost's ground track, dashed. Height is the hardest thing to read off a
## projected line, and the gap between the trajectory and its shadow is what
## makes a 12 m apex look like 12 m.
func _draw_ghost_shadow(points: PackedVector3Array) -> void:
	var ground: PackedVector2Array = PackedVector2Array()
	var floor_y := controller.tee_position.y
	var step := maxi(1, int(points.size() / 40))
	for i in range(0, points.size(), step):
		var s: Variant = _project(Vector3(points[i].x, floor_y, points[i].z))
		if s == null:
			break
		ground.append(s)
	if ground.size() < 2:
		return
	_draw_dashed(ground, Color(PT.GHOST.r, PT.GHOST.g, PT.GHOST.b, 0.30), 1.0, 7.0, 6.0)


func _draw_stop_marker() -> void:
	if ghost_end_kind.is_empty() or ghost_end_kind == "floor":
		return
	var at: Variant = _project(ghost_end_position)
	if at == null:
		return
	var p: Vector2 = at
	var color: Color = PT.PORTAL
	match ghost_end_kind:
		"portal":
			color = PT.DIVE if ghost_end_dive else PT.PORTAL
		"wall":
			color = PT.PLACED if ghost_end_portalable else T.BAD_TEXT
		"barrier", "failed":
			color = T.BAD_TEXT
		_:
			color = T.TEXT_FAINT

	# A ringed cross rather than a bare stop: the prediction ending has to read
	# as an instrument mark, not as the line having run out of budget.
	draw_arc(p, 13.0, 0.0, TAU, 40, Color(color.r, color.g, color.b, 0.95), 2.0, true)
	draw_arc(p, 20.0, 0.0, TAU, 48, Color(color.r, color.g, color.b, 0.35), 1.0, true)
	for a: float in [0.0, PI * 0.5, PI, PI * 1.5]:
		var d := Vector2(cos(a), sin(a))
		draw_line(p + d * 6.0, p + d * 11.0, color, 1.5, true)

	# BELOW the marker. The reticle's own tag sits above and to the right of a
	# point that is often within a few pixels of this one — the ghost stops at
	# the portal and the reticle is usually just past it — and two plates in the
	# same place made both unreadable.
	if not ghost_end_label.is_empty():
		_draw_tag(p + Vector2(26.0, 30.0), ghost_end_label, color)


# ------------------------------------------------------------ the aim line ---

func _draw_aim_line() -> void:
	var tee := controller.tee_position
	var target := controller.reticle_draw_position()
	var a: Variant = _project(tee)
	var b: Variant = _project(target)
	if a == null or b == null:
		return
	# Subdivided so the ground line follows the perspective instead of cutting a
	# straight chord across it.
	var pts: PackedVector2Array = PackedVector2Array()
	for i in 25:
		var s: Variant = _project(tee.lerp(target, float(i) / 24.0))
		if s == null:
			return
		pts.append(s)
	_draw_dashed(pts, Color(PT.AIM.r, PT.AIM.g, PT.AIM.b, 0.55), 2.0, 10.0, 7.0)


## The reticle is a POWER GAUGE on the launch room's floor, not a landing
## prediction — the disc goes through a portal and lands in another room
## entirely, often 130 m to the side. Bounded to the room (see
## `PuzzleAimController.reticle_draw_position`), it slides to the wall and stops
## there; when it does, the ring goes hollow and the tag says the carry runs
## past the room rather than leaving a solid marker floating in the void.
func _draw_reticle() -> void:
	var target := controller.reticle_draw_position()
	var at: Variant = _project(target)
	if at == null:
		return
	var p: Vector2 = at
	var pulse: float = 1.0 if controller.drag == PuzzleAimController.Drag.AIM else 0.72
	var clamped := controller.reticle_clamped()
	var c := Color(PT.AIM.r, PT.AIM.g, PT.AIM.b, pulse * (0.55 if clamped else 1.0))

	draw_arc(p, 16.0, 0.0, TAU, 40, c, 2.0, true)
	if clamped:
		# An open chevron pointing on down the aim line: the throw continues past
		# this wall, the gauge does not.
		for a: float in [-0.6, 0.6]:
			var d := Vector2(cos(a), sin(a))
			draw_line(p + d * 18.0, p + d * 30.0, c, 2.0, true)
	else:
		draw_arc(p, 5.0, 0.0, TAU, 20, Color(c.r, c.g, c.b, 0.6), 1.5, true)
		for a: float in [0.0, PI * 0.5, PI, PI * 1.5]:
			var d := Vector2(cos(a), sin(a))
			draw_line(p + d * 16.0, p + d * 24.0, c, 2.0, true)

	var tag := "aim %s%.0f°  ·  %.1f m/s" % [
		"+" if controller.heading_deg >= 0.0 else "", controller.heading_deg,
		controller.speed_mps]
	if clamped:
		tag += "  ·  carry %.0f m, past this room" % controller.reticle_distance()
	_draw_tag(p + Vector2(30.0, -14.0), tag, PT.AIM)


## Bank and launch angle, drawn at the tee where the throw actually happens.
## A number in a panel is precise; this is what makes 22° of hyzer *look* like a
## disc tipped a long way over.
func _draw_release_indicator() -> void:
	var tee := controller.tee_position
	var origin: Variant = _project(tee + Vector3(0.0, controller.height_m, 0.0))
	if origin == null:
		return
	var p: Vector2 = origin
	var hyzer := deg_to_rad(controller.hyzer_deg)
	var launch := deg_to_rad(controller.launch_deg)

	# Horizon reference.
	draw_line(p - Vector2(34, 0), p + Vector2(34, 0), Color(1, 1, 1, 0.14), 1.0, true)

	# The disc edge-on, banked. Positive hyzer drops the left edge for a RHBH
	# throw (`disc_flight_sim.launch` — the contract's parenthetical says the
	# opposite and is wrong), so the left end of the bar goes down.
	var d := Vector2(cos(-hyzer), sin(-hyzer))
	var c := PT.AIM
	draw_line(p - d * 30.0, p + d * 30.0, Color(c.r, c.g, c.b, 0.9), 3.0, true)
	draw_circle(p, 3.0, Color(c.r, c.g, c.b, 0.9))

	# Launch elevation, as a wedge pointing where the disc leaves.
	var e := Vector2(cos(-launch), sin(-launch))
	draw_line(p, p + e * 46.0, Color(PT.GHOST.r, PT.GHOST.g, PT.GHOST.b, 0.75), 2.0, true)
	draw_line(p + e * 46.0, p + e * 38.0 + Vector2(-e.y, e.x) * 6.0,
		Color(PT.GHOST.r, PT.GHOST.g, PT.GHOST.b, 0.75), 2.0, true)
	draw_line(p + e * 46.0, p + e * 38.0 - Vector2(-e.y, e.x) * 6.0,
		Color(PT.GHOST.r, PT.GHOST.g, PT.GHOST.b, 0.75), 2.0, true)

	_draw_tag(p + Vector2(-118.0, 34.0), "hyzer %s%.1f°   launch %.1f°" % [
		"+" if controller.hyzer_deg >= 0.0 else "", controller.hyzer_deg,
		controller.launch_deg], T.TEXT_DIM)


## Where the disc stopped, and how far that was from the flag. The 3D marker on
## the floor (`PuzzleLevelPreview.set_landing_marker`) is the thing in the world;
## this is the readout on top of it, in canvas space so it stays legible at any
## distance and never ends up behind a wall.
func _draw_landing() -> void:
	var at: Variant = _project(landing_position)
	if at == null:
		return
	var p: Vector2 = at
	var c := T.ACCENT
	draw_arc(p, 15.0, 0.0, TAU, 40, Color(c.r, c.g, c.b, 0.95), 2.0, true)
	draw_arc(p, 24.0, 0.0, TAU, 48, Color(c.r, c.g, c.b, 0.30), 1.0, true)
	for a: float in [0.25, 0.75, 1.25, 1.75]:
		var d := Vector2(cos(a * PI), sin(a * PI))
		draw_line(p + d * 8.0, p + d * 13.0, Color(c.r, c.g, c.b, 0.9), 1.5, true)
	if not landing_label.is_empty():
		_draw_tag(p + Vector2(30.0, -16.0), landing_label, c)
	if not landing_hint.is_empty():
		_draw_tag(p + Vector2(30.0, 22.0), landing_hint, T.TEXT_DIM)


func _draw_flag() -> void:
	var at: Variant = _project(flag_position)
	if at == null:
		return
	var p: Vector2 = at
	var top: Variant = _project(flag_position + Vector3(0.0, 3.0, 0.0))
	var c := PT.BUTTON_ARMED
	if top != null:
		draw_line(p, top, Color(c.r, c.g, c.b, 0.8), 2.0, true)
		var t: Vector2 = top
		draw_colored_polygon(PackedVector2Array([t, t + Vector2(16, 5), t + Vector2(0, 11)]),
			Color(c.r, c.g, c.b, 0.85))
	draw_arc(p, 9.0, 0.0, TAU, 24, Color(c.r, c.g, c.b, 0.7), 1.5, true)
	_draw_tag(p + Vector2(14.0, 12.0), "FLAG", c)


# -------------------------------------------------------------- primitives ---

func _draw_dashed(points: PackedVector2Array, color: Color, width: float,
		dash: float, gap: float) -> void:
	var carry := 0.0
	var on := true
	for i in range(points.size() - 1):
		var a := points[i]
		var b := points[i + 1]
		var seg := a.distance_to(b)
		if seg < 0.001:
			continue
		var dir := (b - a) / seg
		var travelled := 0.0
		while travelled < seg:
			var span: float = (dash if on else gap) - carry
			var take: float = minf(span, seg - travelled)
			if on:
				draw_line(a + dir * travelled, a + dir * (travelled + take), color, width, true)
			travelled += take
			carry += take
			if carry >= (dash if on else gap) - 0.0001:
				carry = 0.0
				on = not on


## A short label with its own plate, because white text over a lit 3D scene is
## unreadable roughly half the time and an outline is not enough.
##
## Plates step around each other. The aim reticle and the ghost's stop marker are
## routinely within a few pixels — the prediction ends at the portal and the
## reticle is usually just past it — and two plates on the same line made both
## unreadable. Measured at 1858x720, where they landed 8 px apart.
func _draw_tag(at: Vector2, text: String, color: Color) -> void:
	if _font == null:
		return
	var size := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_small)
	var pad := Vector2(6, 3)
	var rect := Rect2(at - Vector2(0, size.y * 0.78) - pad, size + pad * 2.0)
	# Keep the plate on screen: a tag that runs off the right edge is how a
	# perfectly good readout becomes invisible at 1280 wide.
	if rect.position.x + rect.size.x > size_of_canvas().x - 6.0:
		rect.position.x = at.x - rect.size.x - 34.0
	rect.position.x = maxf(rect.position.x, 6.0)
	rect.position.y = clampf(rect.position.y, 6.0, size_of_canvas().y - rect.size.y - 6.0)
	for _attempt in 4:
		var clash := false
		for other: Rect2 in _tag_rects:
			if rect.intersects(other):
				rect.position.y = other.position.y + other.size.y + 4.0
				clash = true
		if not clash:
			break
	rect.position.y = clampf(rect.position.y, 6.0, size_of_canvas().y - rect.size.y - 6.0)
	_tag_rects.append(rect)
	draw_rect(rect, Color(0.031, 0.043, 0.071, 0.86), true)
	draw_rect(rect, Color(color.r, color.g, color.b, 0.45), false, 1.0)
	draw_string(_font, rect.position + pad + Vector2(0, size.y * 0.78), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, _font_small, color)


func size_of_canvas() -> Vector2:
	return size

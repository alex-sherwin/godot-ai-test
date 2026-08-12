class_name CameraRig
extends Node3D

## THE camera. One Camera3D, one smoother, one orbit implementation, shared by
## both modes — the sandbox drives it through its named views, Portal Puzzles
## adopts the same rig for its own framings (see `custom` below) so there is not
## a second camera system to keep in step.
##
## A disc flight is four different stories depending on where you stand:
##
##   tee     fixed behind the tee, panning to track the disc. The thrower's
##           view, and the only one where turn and fade look like turn and fade.
##   follow  chase camera on the disc. Best for speed and the release itself.
##   top     plan view, auto-framed to the whole flight. Lateral shape.
##   side    elevation, auto-framed. Height and glide.
##   free    mouse orbit / pan / zoom around a pivot. "Reading the green".
##   landing frames where the disc came to rest, low in the frame. Held for a
##           beat after every throw so the landing is seen before any result
##           panel covers it.
##   custom  the owner publishes the pose itself with `push_pose()`. Puzzle mode
##           uses this: its levels are rooms laid side by side in one world and
##           only the level knows where a camera may stand, but the easing, the
##           orbit and the input handling are the same problem in both modes.
##
## TRANSITIONS. Every view publishes a target pose each frame and the camera
## eases toward it with a critically-damped exponential, so a view change is
## just a target jump that the smoother absorbs — no tween bookkeeping, no
## special cases, and the camera never snaps even if the view changes mid-blend.
## The up vector is smoothed the same way, which is what makes tee -> top (where
## up rotates from +Y to -Z) roll over instead of flipping.
##
## INPUT. The rig reads the mouse itself only when `owns_input` is true, which is
## the sandbox. In puzzle mode the aim overlay is a full-screen Control that
## takes the mouse before `_unhandled_input` ever runs, so it routes gestures in
## by calling `orbit()` / `pan()` / `zoom()` — one owner of the mouse, and
## therefore no way for the camera to fight drag-to-aim.

const VIEWS := ["tee", "follow", "top", "side", "free", "landing", "custom"]

## Exponential smoothing rates, 1/s. Higher = tighter tracking.
const RATE_NORMAL := 5.0
const RATE_SWITCH := 2.2      ## used for the first `SWITCH_EASE` seconds after a change
const SWITCH_EASE := 1.1
const UP_RATE := 3.2

## Orbit gains. Radians per pixel of drag, and the multiplier one notch of wheel
## (or one press of +/-) applies to the orbit radius.
const ORBIT_RAD_PER_PX := 0.006
const PITCH_RAD_PER_PX := 0.005
const PITCH_LIMIT := 1.45
const PAN_PER_PX := 0.0016
const ZOOM_MIN := 0.35
const ZOOM_MAX := 500.0
const ZOOM_WHEEL_IN := 0.88
const ZOOM_WHEEL_OUT := 1.14
const ZOOM_KEY_IN := 0.80
const ZOOM_KEY_OUT := 1.25

@export var default_view: String = "tee"

var camera: Camera3D = null

## False when someone else owns the mouse and routes gestures in. See the class
## comment.
var owns_input: bool = true
## Tracking rate, 1/s. Raised by an owner whose target moves fast: puzzle mode
## replays a flight at 1.6x and a chase camera that lags by v/rate puts the disc
## on the edge of the frame at the default.
var smooth_rate: float = RATE_NORMAL
## Field of view for the poses that do not fix one of their own.
var base_fov: float = 60.0
## The floor. The free camera never drops below it and a pan never pushes the
## pivot under it; puzzle rooms do not all have their floor at y = 0.
var ground_y: float = 0.0
## Optional box the free camera is kept inside, so an orbit cannot fly the
## player into the void 400 m from anything. Empty size = unbounded.
var free_bounds := AABB()
var has_free_bounds: bool = false

var _view: String = "tee"
var _switch_timer: float = 0.0

# Smoothed camera state.
var _pos := Vector3(0.0, 2.6, 12.0)
var _look := Vector3(0.0, 3.0, -45.0)
var _up := Vector3.UP

# What the app feeds in each frame.
var _target := Vector3.ZERO          ## disc position (or the tee before launch)
var _heading := Vector3(0.0, 0.0, -1.0)
var _speed: float = 0.0
var _flying: bool = false
var _frame_dist: float = 45.0        ## framing distance, grows with the flight
var _frame_height: float = 8.0

# Free-orbit state.
var _orbit_pivot := Vector3(0.0, 4.0, -45.0)
var _orbit_yaw: float = 0.0
var _orbit_pitch: float = -0.38
var _orbit_dist: float = 70.0
var _dragging: int = 0               ## 0 none, 1 orbit, 2 pan

# Owner-published pose, for the `custom` view.
var _custom: Dictionary = {}

# Where the disc came to rest, for the `landing` view, plus the second point
# that has to stay in shot with it (the flag, in puzzle mode).
var _landing := Vector3.ZERO
var _landing_companion := Vector3.ZERO
var _has_companion: bool = false

signal view_changed(view: String)


func _ready() -> void:
	if camera == null:
		camera = Camera3D.new()
		camera.name = "Camera3D"
		camera.fov = 60.0
		camera.near = 0.05
		camera.far = 900.0
		camera.current = true
		add_child(camera)
	else:
		# Adopted from an owner that had already built and configured one (puzzle
		# mode hands over the camera `PortalStage` renders its apertures with).
		# Start from wherever it is, so adopting is not a jump.
		_pos = camera.global_position
		_look = _pos - camera.global_transform.basis.z * 20.0
		base_fov = camera.fov
	if _custom.is_empty():
		_custom = {"pos": _pos, "look": _look, "up": Vector3.UP, "fov": base_fov}
	_view = default_view if VIEWS.has(default_view) else "tee"
	_apply(_pose_for(_view), true)


## Adopt a camera the owner built. Must be called before the rig enters the
## tree; `_ready` starts the smoother from wherever that camera already is.
func use_camera(cam: Camera3D) -> void:
	camera = cam


func set_view(view: String) -> void:
	if not VIEWS.has(view) or view == _view:
		return
	if view == "free":
		# Hand the orbit camera the pose it is inheriting so it does not jump.
		# When the disc is at rest, orbit the disc instead: someone reaching for
		# free look after a throw wants to walk around the disc or the landing,
		# not around whatever the previous view happened to be aimed at.
		_orbit_pivot = _target if (not _flying and _target.length_squared() > 1.0) else _look
		_set_orbit_offset(_pos - _orbit_pivot)
	_view = view
	_switch_timer = SWITCH_EASE
	view_changed.emit(view)


func get_view() -> String:
	return _view


func is_free() -> bool:
	return _view == "free"


# ---------------------------------------------------------------------------
# Owner-published poses (`custom`), and the landing hold
# ---------------------------------------------------------------------------

## Publish the pose the camera should ease toward. Switches to the `custom` view,
## because an owner that computes its own framings and the rig's own named views
## cannot both be driving. `immediate` skips the ease, for a level load where a
## swoop in from the previous level's geometry is not a transition, it is a
## camera flying through a wall.
func push_pose(pos: Vector3, look: Vector3, up: Vector3 = Vector3.UP,
		fov: float = -1.0, immediate: bool = false) -> void:
	_custom = {
		"pos": pos, "look": look, "up": up,
		"fov": base_fov if fov <= 0.0 else fov,
	}
	if _view != "custom":
		_view = "custom"
		_switch_timer = SWITCH_EASE
		view_changed.emit(_view)
	if immediate:
		_switch_timer = 0.0
		_apply(_custom, true)


## Hold on the landing. `companion` is a second point that must stay in shot —
## the flag — and is what makes the difference between "a beat on the landing"
## and two seconds of empty ground.
func hold_landing(landing: Vector3, companion: Vector3 = Vector3.ZERO,
		has_companion: bool = false) -> void:
	_landing = landing
	_landing_companion = companion
	_has_companion = has_companion
	if _view == "landing":
		return
	_view = "landing"
	_switch_timer = SWITCH_EASE
	view_changed.emit(_view)


# ---------------------------------------------------------------------------
# Free look. Public because the owner of the mouse is not always this node.
# ---------------------------------------------------------------------------

## Orbit by a mouse delta in pixels.
func orbit(dx: float, dy: float) -> void:
	_orbit_yaw -= dx * ORBIT_RAD_PER_PX
	_orbit_pitch = clampf(_orbit_pitch + dy * PITCH_RAD_PER_PX, -PITCH_LIMIT, PITCH_LIMIT)


## Slide the pivot across the view plane by a mouse delta in pixels. Scaled by
## the orbit radius so a drag moves the same fraction of the screen at any zoom.
func pan(dx: float, dy: float) -> void:
	var right := Vector3(cos(_orbit_yaw), 0.0, -sin(_orbit_yaw))
	var scale: float = _orbit_dist * PAN_PER_PX
	_orbit_pivot -= right * (dx * scale)
	_orbit_pivot += Vector3.UP * (dy * scale)
	_set_pivot(_orbit_pivot)


## The pivot is the centre of the frame, so keeping it inside the level is what
## guarantees there is always something to look at. Measured in the browser
## without it: a long pan at 200 m of orbit radius put the whole course in the
## bottom corner and filled the screen with empty background.
func _set_pivot(p: Vector3) -> void:
	_orbit_pivot = p
	if has_free_bounds:
		_orbit_pivot = _orbit_pivot.clamp(free_bounds.position, free_bounds.end)
	_orbit_pivot.y = maxf(_orbit_pivot.y, ground_y)


func zoom(factor: float) -> void:
	_orbit_dist = clampf(_orbit_dist * factor, ZOOM_MIN, ZOOM_MAX)


## One keypress worth of zoom. Coarser than a wheel notch, because a key is a
## discrete press and the wheel is a wrist movement.
func zoom_in() -> void:
	zoom(ZOOM_KEY_IN)


func zoom_out() -> void:
	zoom(ZOOM_KEY_OUT)


## Orbit this point instead, keeping the direction the eye is looking from.
## Entering free look first, so a snap-to-flag is also a way *into* inspection.
func focus_on(point: Vector3, distance: float = -1.0) -> void:
	set_view("free")
	_set_pivot(point)
	if distance > 0.0:
		_orbit_dist = clampf(distance, ZOOM_MIN, ZOOM_MAX)


## Orbit this point from a chosen side: `eye_offset` is where the eye should sit
## relative to it. This is what "look back down the line at the flag" is.
func focus_from(point: Vector3, eye_offset: Vector3) -> void:
	set_view("free")
	_set_pivot(point)
	_set_orbit_offset(eye_offset)


## Yaw, pitch and radius from a vector pointing pivot -> eye.
func _set_orbit_offset(off: Vector3) -> void:
	if off.length_squared() < 1e-6:
		off = Vector3(0.0, 8.0, 24.0)
	_orbit_dist = clampf(off.length(), ZOOM_MIN, ZOOM_MAX)
	_orbit_yaw = atan2(off.x, off.z)
	_orbit_pitch = clampf(asin(clampf(off.y / _orbit_dist, -1.0, 1.0)),
		-PITCH_LIMIT, PITCH_LIMIT)


## The orbit's state, so a test can assert an inspection gesture moved the camera
## and nothing else.
func orbit_state() -> Dictionary:
	return {"pivot": _orbit_pivot, "yaw": _orbit_yaw, "pitch": _orbit_pitch,
		"distance": _orbit_dist}


## Fed by the app every frame.
func track(target: Vector3, velocity: Vector3, flying: bool) -> void:
	_target = target
	_flying = flying
	_speed = velocity.length()
	var flat := Vector3(velocity.x, 0.0, velocity.z)
	if flat.length_squared() > 0.25:
		_heading = _heading.lerp(flat.normalized(), 0.12).normalized()
	var dist: float = Vector2(target.x, target.z).length()
	# Framing only ever grows during a flight, so top/side do not breathe.
	_frame_dist = maxf(_frame_dist, dist + 18.0)
	_frame_height = maxf(_frame_height, target.y + 5.0)


## Called on a new throw: let the auto-framed views re-tighten.
func reset_framing() -> void:
	_frame_dist = 45.0
	_frame_height = 8.0
	_heading = Vector3(0.0, 0.0, -1.0)


## Camera time is WALL-CLOCK time, not `_process`'s delta.
##
## Godot caps the delta it reports so a slow frame cannot run away with the
## physics: at `max_physics_steps_per_frame` = 8 and 60 Hz physics, `delta` never
## exceeds 0.133 s however long the frame actually took. That is right for a
## simulation and wrong for a transition, which is a promise about how long the
## PLAYER waits. Measured in the exported build under SwiftShader at ~1.2 fps: a
## 1.1 s ease took nine real seconds, and every camera move read as a fault.
## Nothing downstream of this node is simulated, so it uses the real clock, with
## a one-second ceiling on a single step in case the tab was backgrounded.
const MAX_REAL_STEP := 1.0

var _last_us: int = 0


func _process(_delta: float) -> void:
	if camera == null:
		return
	var now := Time.get_ticks_usec()
	if _last_us == 0:
		_last_us = now
	var delta: float = clampf(float(now - _last_us) / 1.0e6, 0.0, MAX_REAL_STEP)
	_last_us = now
	_switch_timer = maxf(_switch_timer - delta, 0.0)
	_apply(_pose_for(_view), false, delta)


# ---------------------------------------------------------------------------
# Poses
# ---------------------------------------------------------------------------

## Returns {pos, look, up, fov}.
func _pose_for(view: String) -> Dictionary:
	match view:
		"follow":
			return _pose_follow()
		"top":
			return _pose_top()
		"side":
			return _pose_side()
		"free":
			return _pose_free()
		"landing":
			return _pose_landing()
		"custom":
			return _custom if not _custom.is_empty() else _pose_tee()
		_:
			return _pose_tee()


func _pose_tee() -> Dictionary:
	# Pans to hold the disc, but only about a third as far as the disc actually
	# goes: a camera that tracks 1:1 puts the disc dead centre and takes the
	# range axis out of frame, which is the one thing this view exists to show.
	var look := Vector3(0.0, 4.0, -55.0)
	if _flying or _target.length_squared() > 1.0:
		look = Vector3(_target.x * 0.35, maxf(_target.y * 0.45, 2.0), -55.0)
	return {"pos": Vector3(0.0, 2.9, 13.0), "look": look, "up": Vector3.UP, "fov": 58.0}


func _pose_follow() -> Dictionary:
	if not _flying and _target.length_squared() < 1.0:
		return _pose_tee()
	# Behind, above and offset to the side: dead astern puts the camera inside
	# its own trail and the disc on the vanishing point, where it is 2 px wide.
	var back: float = clampf(8.0 + _speed * 0.28, 8.0, 18.0)
	var right := Vector3(-_heading.z, 0.0, _heading.x)
	var pos: Vector3 = _target - _heading * back + right * (back * 0.22) \
		+ Vector3(0.0, back * 0.34, 0.0)
	pos.y = maxf(pos.y, 1.6)
	return {
		"pos": pos,
		"look": _target + _heading * 2.5,
		"up": Vector3.UP,
		"fov": 60.0,
	}


func _pose_top() -> Dictionary:
	# Frame tee -> disc with margin. h = (half length) / tan(fov/2).
	var half: float = _frame_dist * 0.5 + 14.0
	var h: float = clampf(half / tan(deg_to_rad(27.0)), 55.0, 420.0)
	var mid := Vector3(_target.x * 0.35, 0.0, -_frame_dist * 0.5 + 6.0)
	# up = -Z puts downrange at the top of the screen, which is how every disc
	# golf flight chart in existence is drawn.
	return {
		"pos": mid + Vector3(0.0, h, 0.0),
		"look": mid,
		"up": Vector3(0.0, 0.0, -1.0),
		"fov": 58.0,
	}


func _pose_side() -> Dictionary:
	var half: float = _frame_dist * 0.5 + 14.0
	# Horizontal fov is the vertical one widened by the aspect ratio.
	var aspect: float = _aspect()
	# Held out past the tree line (|x| >= 50 m) so it never has to look through
	# it, and lifted just enough that the sight line clears a ~13 m canopy —
	# about 15 degrees, still low enough to read the height profile honestly.
	var d: float = clampf(half / (tan(deg_to_rad(27.0)) * aspect), 60.0, 400.0)
	var mid := Vector3(0.0, clampf(_frame_height * 0.45, 4.0, 40.0), -_frame_dist * 0.5 + 6.0)
	return {
		"pos": mid + Vector3(d, d * 0.18 + 5.0, 0.0),
		"look": mid,
		"up": Vector3.UP,
		"fov": 58.0,
	}


func _pose_free() -> Dictionary:
	var off := Vector3(
		sin(_orbit_yaw) * cos(_orbit_pitch),
		sin(_orbit_pitch),
		cos(_orbit_yaw) * cos(_orbit_pitch)) * _orbit_dist
	var pos: Vector3 = _orbit_pivot + off
	# Low enough to get right down on the disc; the mesh is 21 cm across and
	# there is no point shipping a parametric lathe you cannot look at.
	pos.y = maxf(pos.y, ground_y + 0.12)
	if has_free_bounds:
		pos = pos.clamp(free_bounds.position, free_bounds.end)
	return {"pos": pos, "look": _orbit_pivot, "up": Vector3.UP, "fov": base_fov}


## Where the disc came to rest, seen from behind it along the line it was
## travelling — or, when a companion point is given, along the line from the
## landing to that point, so the disc and the flag are both in shot with the
## flag beyond it.
##
## The landing is deliberately LOW in the frame. A result panel is a centred
## modal and lands on top of this view a couple of seconds later; a landing
## framed dead centre is a landing behind the card describing it.
func _pose_landing() -> Dictionary:
	var focus: Vector3 = _landing
	var spread: float = 0.0
	var dir: Vector3 = _heading
	if _has_companion:
		spread = _landing.distance_to(_landing_companion)
		focus = _landing.lerp(_landing_companion, 0.45)
		var to_flag := _landing_companion - _landing
		to_flag.y = 0.0
		if to_flag.length_squared() > 1.0:
			dir = to_flag.normalized()
	var flat := Vector3(dir.x, 0.0, dir.z)
	dir = flat.normalized() if flat.length_squared() > 1e-6 else Vector3(0.0, 0.0, -1.0)
	var d: float = clampf(20.0 + spread * 1.1, 20.0, 95.0)
	var pos: Vector3 = focus - dir * (d * 0.78) + Vector3(0.0, d * 0.44 + 2.0, 0.0)
	pos.y = maxf(pos.y, ground_y + 2.0)
	return {
		"pos": pos,
		"look": focus + Vector3(0.0, d * 0.16, 0.0),
		"up": Vector3.UP,
		"fov": base_fov,
	}


func _aspect() -> float:
	var vp := get_viewport()
	if vp == null:
		return 16.0 / 9.0
	var s: Vector2 = vp.get_visible_rect().size
	return s.x / maxf(s.y, 1.0)


func _apply(pose: Dictionary, immediate: bool, delta: float = 0.0) -> void:
	var target_pos: Vector3 = pose["pos"]
	var target_look: Vector3 = pose["look"]
	var target_up: Vector3 = pose["up"]
	var fov: float = pose["fov"]

	if immediate:
		_pos = target_pos
		_look = target_look
		_up = target_up
	else:
		var rate: float = RATE_SWITCH if _switch_timer > 0.0 else smooth_rate
		var k: float = 1.0 - exp(-rate * delta)
		_pos = _pos.lerp(target_pos, k)
		_look = _look.lerp(target_look, k)
		_up = _up.lerp(target_up, 1.0 - exp(-UP_RATE * delta))
		camera.fov = lerpf(camera.fov, fov, k)

	var dir: Vector3 = _look - _pos
	if dir.length_squared() < 1e-6:
		dir = Vector3(0.0, 0.0, -1.0)
	var up: Vector3 = _up
	if up.length_squared() < 1e-6:
		up = Vector3.UP
	up = up.normalized()
	# look_at() is undefined when up is parallel to the view direction; the
	# tee -> top blend passes close to it if the disc is directly overhead.
	if absf(up.dot(dir.normalized())) > 0.999:
		up = Vector3(0.0, 0.0, -1.0) if absf(up.y) > 0.5 else Vector3.UP
	camera.global_position = _pos
	camera.look_at(_pos + dir, up)


# ---------------------------------------------------------------------------
# Free-orbit input. `_unhandled_input` so UI controls always win.
# ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not owns_input or _view != "free":
		return
	# Keyboard zoom as well as the wheel: some embeddings swallow wheel events
	# before they reach the canvas, and orbit without zoom is close to useless.
	if event is InputEventKey and (event as InputEventKey).pressed:
		match (event as InputEventKey).keycode:
			KEY_EQUAL, KEY_KP_ADD:
				zoom(ZOOM_KEY_IN)
				get_viewport().set_input_as_handled()
			KEY_MINUS, KEY_KP_SUBTRACT:
				zoom(ZOOM_KEY_OUT)
				get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT:
				_dragging = 1 if mb.pressed else 0
			MOUSE_BUTTON_MIDDLE:
				_dragging = 2 if mb.pressed else 0
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					zoom(ZOOM_WHEEL_IN)
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					zoom(ZOOM_WHEEL_OUT)
	elif event is InputEventMouseMotion and _dragging != 0:
		var mm := event as InputEventMouseMotion
		if _dragging == 1:
			orbit(mm.relative.x, mm.relative.y)
		else:
			pan(mm.relative.x, mm.relative.y)

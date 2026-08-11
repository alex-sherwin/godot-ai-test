class_name CameraRig
extends Node3D

## Five camera views over one Camera3D, because a disc flight is four different
## stories depending on where you stand:
##
##   tee     fixed behind the tee, panning to track the disc. The thrower's
##           view, and the only one where turn and fade look like turn and fade.
##   follow  chase camera on the disc. Best for speed and the release itself.
##   top     plan view, auto-framed to the whole flight. Lateral shape.
##   side    elevation, auto-framed. Height and glide.
##   free    mouse orbit / pan / zoom.
##
## TRANSITIONS. Every view publishes a target pose each frame and the camera
## eases toward it with a critically-damped exponential, so a view change is
## just a target jump that the smoother absorbs — no tween bookkeeping, no
## special cases, and the camera never snaps even if the view changes mid-blend.
## The up vector is smoothed the same way, which is what makes tee -> top (where
## up rotates from +Y to -Z) roll over instead of flipping.

const VIEWS := ["tee", "follow", "top", "side", "free"]

## Exponential smoothing rates, 1/s. Higher = tighter tracking.
const RATE_NORMAL := 5.0
const RATE_SWITCH := 2.2      ## used for the first `SWITCH_EASE` seconds after a change
const SWITCH_EASE := 1.1
const UP_RATE := 3.2

@export var default_view: String = "tee"

var camera: Camera3D = null

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
	_view = default_view
	_apply(_pose_for(_view), true)


func set_view(view: String) -> void:
	if not VIEWS.has(view) or view == _view:
		return
	if view == "free":
		# Hand the orbit camera the pose it is inheriting so it does not jump.
		# When the disc is at rest, orbit the disc instead: someone reaching for
		# free look after a throw wants to walk around the disc or the landing,
		# not around whatever the previous view happened to be aimed at.
		_orbit_pivot = _target if (not _flying and _target.length_squared() > 1.0) else _look
		var off: Vector3 = _pos - _orbit_pivot
		_orbit_dist = clampf(off.length(), 2.0, 200.0)
		_orbit_yaw = atan2(off.x, off.z)
		_orbit_pitch = clampf(asin(clampf(off.y / _orbit_dist, -1.0, 1.0)), -1.45, 1.45)
	_view = view
	_switch_timer = SWITCH_EASE
	view_changed.emit(view)


func get_view() -> String:
	return _view


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


func _process(delta: float) -> void:
	if camera == null:
		return
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
	pos.y = maxf(pos.y, 0.12)
	return {"pos": pos, "look": _orbit_pivot, "up": Vector3.UP, "fov": 60.0}


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
		var rate: float = RATE_SWITCH if _switch_timer > 0.0 else RATE_NORMAL
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
	if _view != "free":
		return
	# Keyboard zoom as well as the wheel: some embeddings swallow wheel events
	# before they reach the canvas, and orbit without zoom is close to useless.
	if event is InputEventKey and (event as InputEventKey).pressed:
		match (event as InputEventKey).keycode:
			KEY_EQUAL, KEY_KP_ADD:
				_orbit_dist = clampf(_orbit_dist * 0.80, 0.35, 500.0)
				get_viewport().set_input_as_handled()
			KEY_MINUS, KEY_KP_SUBTRACT:
				_orbit_dist = clampf(_orbit_dist * 1.25, 0.35, 500.0)
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
					_orbit_dist = clampf(_orbit_dist * 0.88, 0.35, 500.0)
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					_orbit_dist = clampf(_orbit_dist * 1.14, 0.35, 500.0)
	elif event is InputEventMouseMotion and _dragging != 0:
		var mm := event as InputEventMouseMotion
		if _dragging == 1:
			_orbit_yaw -= mm.relative.x * 0.006
			_orbit_pitch = clampf(_orbit_pitch + mm.relative.y * 0.005, -1.45, 1.45)
		else:
			var right := Vector3(cos(_orbit_yaw), 0.0, -sin(_orbit_yaw))
			var scale: float = _orbit_dist * 0.0016
			_orbit_pivot -= right * (mm.relative.x * scale)
			_orbit_pivot += Vector3.UP * (mm.relative.y * scale)
			_orbit_pivot.y = maxf(_orbit_pivot.y, 0.0)

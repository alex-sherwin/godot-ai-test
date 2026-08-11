class_name PuzzleAimController
extends RefCounted

## The release parameters, and the two mouse gestures that set them.
##
## ---------------------------------------------------------------------------
## Why drag-to-aim, and why it is two gestures
## ---------------------------------------------------------------------------
## A puzzle retry loop is: look, adjust one thing, throw, watch, adjust. Seven
## sliders make that slow, so the primary control is a drag straight on the 3D
## view. A drag is two degrees of freedom and the throw needs four before it is
## interesting, so there are two drags, each carrying the pair of parameters that
## belong together:
##
##   LEFT DRAG   — WHERE.  A reticle on the ground follows the cursor.
##                 Its bearing from the tee is the aim; its distance is the
##                 power. "Drag it to where you want the disc to land" is one
##                 sentence and it covers both.
##   RIGHT DRAG  — SHAPE.  Horizontal is hyzer, vertical is launch angle. These
##                 are the two release angles, and they are the two axes every
##                 level after the first is actually about.
##   WHEEL       — hyzer, one degree a notch, because levels 2, 5 and 10 are won
##                 and lost on 2-4 degrees of bank and nobody wants to drag for
##                 that.
##
## Shift+left is a synonym for right-drag: a trackpad may not have a comfortable
## right button, and the browser eats a right-click if the page has not taken the
## context menu.
##
## The numbers stay authoritative. Every gesture writes the same values the
## advanced panel edits, `changed` fires either way, and `build_params()` is the
## single place degrees become radians (CONTRACT §1) — so a player can drag
## roughly, then type the exact value, and reproduce a throw precisely.
##
## ---------------------------------------------------------------------------
## Ranges
## ---------------------------------------------------------------------------
## Straight from `ThrowPanel` — the sandbox's per-category speed ranges and its
## angle limits — rather than a second set that could drift. LEVEL_DESIGN §0.9
## quotes those same limits as the design constraint every level was built
## against, so they are load-bearing: aim is ±45° and every target sits inside it.

signal changed()

const HEADING_LIMIT := 45.0
const HYZER_LIMIT := 60.0
const LAUNCH_MIN := -30.0
const LAUNCH_MAX := 45.0
const NOSE_LIMIT := 20.0
const SPIN_LIMIT := 45.0
const HEIGHT_MIN := 0.1
const HEIGHT_MAX := 2.5

## Reticle distance that maps to zero power and to full power, metres. Chosen so
## the useful band covers every shipped level: the shortest is 23 m past the
## portal (Level 8) and the longest is 115 m (Level 3).
const CARRY_MIN := 12.0
const CARRY_MAX := 135.0

## Degrees per pixel for the shape drag. 0.18 puts the full ±60° of hyzer inside
## a 660 px horizontal sweep, which is a comfortable drag at 1280 wide and still
## fine enough to place a single degree.
const SHAPE_DEG_PER_PX_X := 0.18
const SHAPE_DEG_PER_PX_Y := 0.14
const WHEEL_HYZER_STEP := 1.0

enum Drag { NONE, AIM, SHAPE }

var speed_mps: float = 22.0
var spin_rps: float = 20.0
var nose_deg: float = 0.0
var hyzer_deg: float = 4.0
var launch_deg: float = 8.0
var height_m: float = 1.4
var heading_deg: float = 0.0

var speed_min: float = 5.0
var speed_max: float = 36.0

## Where the aim reticle sits on the ground, in display world space. Derived from
## heading and power, so editing the numbers moves the reticle and dragging the
## reticle edits the numbers.
var tee_position: Vector3 = Vector3.ZERO
## Display-space forward direction for heading 0 (the tee's facing).
var tee_forward: Vector3 = Vector3(0, 0, -1)
var tee_right: Vector3 = Vector3(1, 0, 0)

## World-space floor rectangle of the LAUNCH room. The reticle is a power gauge
## drawn on the ground, and the ground it was drawn on was an infinite plane —
## so at high power it floated in the void outside every room, and on a level
## whose rooms are offset by `world_origin` (Level 1's second room is 130 m to
## the RIGHT) it pointed at nothing at all. Bounded, it slides to the wall and
## stops, and `reticle_clamped()` says so. The NUMBERS never clamp: the carry a
## throw is set up for is a property of the throw, not of the room it starts in,
## and the disc goes through the portal in that wall anyway.
var bounds_min: Vector3 = Vector3.ZERO
var bounds_max: Vector3 = Vector3.ZERO
var has_bounds: bool = false

var drag: int = Drag.NONE

var _category: String = ""
var _drag_start := Vector2.ZERO
var _drag_hyzer: float = 0.0
var _drag_launch: float = 0.0


# ================================================================= ranges ===

## Retune the speed range when the selected disc changes category. Values already
## set are clamped rather than reset, so switching discs mid-tune does not throw
## away the line the player was converging on.
func apply_category(category: String, reset_defaults: bool = false) -> void:
	var profile: Array = ThrowPanel.CATEGORY_PROFILE.get(category, ThrowPanel.DEFAULT_PROFILE)
	var was := _category
	_category = category
	speed_min = float(profile[0])
	speed_max = float(profile[1])
	if reset_defaults or was != category:
		speed_mps = float(profile[2])
		spin_rps = signf(spin_rps if absf(spin_rps) > 0.01 else 1.0) * float(profile[3])
		launch_deg = float(profile[4])
		hyzer_deg = float(profile[5])
		nose_deg = 0.0
		height_m = 1.4
		# Heading too. Carrying an aim of -27 deg from the previous level into a
		# new one is not a convenience — it is a wrong throw the player did not
		# ask for, and the reticle is somewhere they never dragged it.
		heading_deg = 0.0
	speed_mps = clampf(speed_mps, speed_min, speed_max)
	changed.emit()


func set_tee(position: Vector3, forward: Vector3) -> void:
	tee_position = position
	var f := Vector3(forward.x, 0.0, forward.z)
	tee_forward = f.normalized() if f.length_squared() > 1e-9 else Vector3(0, 0, -1)
	tee_right = Vector3(-tee_forward.z, 0.0, tee_forward.x)


# =================================================================== power ===

## 0..1 across the disc's speed range.
func power() -> float:
	if speed_max - speed_min < 1e-6:
		return 0.0
	return clampf((speed_mps - speed_min) / (speed_max - speed_min), 0.0, 1.0)


func set_power(fraction: float) -> void:
	set_speed(lerpf(speed_min, speed_max, clampf(fraction, 0.0, 1.0)))


## The distance from the tee the reticle sits at for the current power.
func reticle_distance() -> float:
	return lerpf(CARRY_MIN, CARRY_MAX, power())


## The unbounded reticle: tee + aim direction * carry. This is the AIM, and it
## is what the camera framing and the throw are measured from.
func reticle_position() -> Vector3:
	var dir := tee_forward.rotated(Vector3.UP, -deg_to_rad(heading_deg))
	return tee_position + dir * reticle_distance()


## Set the floor rectangle the reticle may be drawn on. Inset slightly so the
## marker does not sit exactly in a wall, where half of it is behind geometry.
func set_bounds(world_min: Vector3, world_max: Vector3) -> void:
	var inset := 1.5
	bounds_min = Vector3(minf(world_min.x + inset, world_max.x), world_min.y,
		minf(world_min.z + inset, world_max.z))
	bounds_max = Vector3(maxf(world_max.x - inset, world_min.x), world_max.y,
		maxf(world_max.z - inset, world_min.z))
	has_bounds = bounds_max.x > bounds_min.x and bounds_max.z > bounds_min.z
	changed.emit()


func clear_bounds() -> void:
	has_bounds = false
	changed.emit()


## Where the reticle is actually DRAWN: the aim point, pulled back along the aim
## line to the last point still inside the launch room. Pulling it back along the
## line rather than clamping each axis keeps the marker on the aim line, so it
## still reads as "this direction" and not as an arbitrary corner.
func reticle_draw_position() -> Vector3:
	var target := reticle_position()
	if not has_bounds:
		return target
	var from := tee_position
	var d := target - from
	d.y = 0.0
	var t := 1.0
	for i: int in [0, 2]:
		if absf(d[i]) < 1.0e-6:
			continue
		var limit: float = bounds_max[i] if d[i] > 0.0 else bounds_min[i]
		t = minf(t, (limit - from[i]) / d[i])
	return from + (target - from) * clampf(t, 0.0, 1.0)


## True when the aim carries past the launch room and the drawn reticle had to
## be pulled back. Not an error — the disc goes through the portal in that wall
## — but the marker must not read as "your disc lands in the void here".
func reticle_clamped() -> bool:
	return has_bounds \
		and reticle_draw_position().distance_squared_to(reticle_position()) > 0.25


# ================================================================== setters ==
# Each clamps, each emits once, and each is what BOTH the drag and the number
# box call — there is no second path that skips the clamp.

func set_speed(v: float) -> void:
	_assign("speed_mps", clampf(v, speed_min, speed_max))


func set_spin(v: float) -> void:
	_assign("spin_rps", clampf(v, -SPIN_LIMIT, SPIN_LIMIT))


func set_nose(v: float) -> void:
	_assign("nose_deg", clampf(v, -NOSE_LIMIT, NOSE_LIMIT))


func set_hyzer(v: float) -> void:
	_assign("hyzer_deg", clampf(v, -HYZER_LIMIT, HYZER_LIMIT))


func set_launch(v: float) -> void:
	_assign("launch_deg", clampf(v, LAUNCH_MIN, LAUNCH_MAX))


func set_height(v: float) -> void:
	_assign("height_m", clampf(v, HEIGHT_MIN, HEIGHT_MAX))


func set_heading(v: float) -> void:
	_assign("heading_deg", clampf(v, -HEADING_LIMIT, HEADING_LIMIT))


func _assign(field: String, value: float) -> void:
	if is_equal_approx(float(get(field)), value):
		return
	set(field, value)
	changed.emit()


# ==================================================================== drags ==

func begin_aim(_at: Vector2) -> void:
	drag = Drag.AIM


func begin_shape(at: Vector2) -> void:
	drag = Drag.SHAPE
	_drag_start = at
	_drag_hyzer = hyzer_deg
	_drag_launch = launch_deg


func end_drag() -> void:
	drag = Drag.NONE


## Left drag: a point on the ground plane, in display world space. Bearing sets
## the aim, distance sets the power. Both clamp, so dragging past the limit
## pins the reticle at the limit instead of silently doing nothing.
func aim_at_ground(point: Vector3) -> void:
	var rel := point - tee_position
	rel.y = 0.0
	if rel.length() < 0.5:
		return
	var forward := rel.dot(tee_forward)
	var lateral := rel.dot(tee_right)
	# atan2(lateral, forward) is positive to the thrower's right, matching the
	# sign of `launch_heading_rad` (`disc_flight_sim.launch`).
	var bearing := rad_to_deg(atan2(lateral, forward))
	var was_emitting := false
	var new_heading := clampf(bearing, -HEADING_LIMIT, HEADING_LIMIT)
	var new_power := clampf((rel.length() - CARRY_MIN) / (CARRY_MAX - CARRY_MIN), 0.0, 1.0)
	var new_speed := clampf(lerpf(speed_min, speed_max, new_power), speed_min, speed_max)
	if not is_equal_approx(new_heading, heading_deg):
		heading_deg = new_heading
		was_emitting = true
	if not is_equal_approx(new_speed, speed_mps):
		speed_mps = new_speed
		was_emitting = true
	if was_emitting:
		changed.emit()


## Right (or Shift+left) drag: absolute from the press point, so releasing and
## re-pressing does not accumulate drift.
func shape_to(at: Vector2) -> void:
	var d := at - _drag_start
	var new_hyzer := clampf(_drag_hyzer + d.x * SHAPE_DEG_PER_PX_X, -HYZER_LIMIT, HYZER_LIMIT)
	var new_launch := clampf(_drag_launch - d.y * SHAPE_DEG_PER_PX_Y, LAUNCH_MIN, LAUNCH_MAX)
	var dirty := false
	if not is_equal_approx(new_hyzer, hyzer_deg):
		hyzer_deg = new_hyzer
		dirty = true
	if not is_equal_approx(new_launch, launch_deg):
		launch_deg = new_launch
		dirty = true
	if dirty:
		changed.emit()


func nudge_hyzer(steps: float) -> void:
	set_hyzer(hyzer_deg + steps * WHEEL_HYZER_STEP)


# ================================================================== output ===

## THE units boundary, same as `ThrowPanel.build_params()`: degrees on screen,
## radians in the contract type.
func build_params() -> DiscFlightSim.ThrowParams:
	var p := DiscFlightSim.ThrowParams.new()
	p.speed_mps = speed_mps
	p.spin_rps = spin_rps
	p.nose_angle_rad = deg_to_rad(nose_deg)
	p.hyzer_angle_rad = deg_to_rad(hyzer_deg)
	p.launch_angle_rad = deg_to_rad(launch_deg)
	p.launch_height_m = height_m
	p.launch_heading_rad = deg_to_rad(heading_deg)
	return p


## Apply a validated line from the level file's `intended_solution` — the
## "load it" button. Values are clamped into the widget ranges rather than
## trusted: an authored line is data, and data can be wrong.
func apply_solution(step: PuzzleLevelData.SolutionStep) -> void:
	if step == null:
		return
	speed_mps = clampf(step.speed_mps, speed_min, speed_max)
	spin_rps = clampf(step.spin_rps, -SPIN_LIMIT, SPIN_LIMIT)
	nose_deg = clampf(step.nose_deg, -NOSE_LIMIT, NOSE_LIMIT)
	hyzer_deg = clampf(step.hyzer_deg, -HYZER_LIMIT, HYZER_LIMIT)
	launch_deg = clampf(step.launch_deg, LAUNCH_MIN, LAUNCH_MAX)
	heading_deg = clampf(step.heading_deg, -HEADING_LIMIT, HEADING_LIMIT)
	height_m = clampf(step.release_height_m, HEIGHT_MIN, HEIGHT_MAX)
	changed.emit()


func summary() -> String:
	return "%.0f m/s · %.0f rev/s · hyzer %s%.0f° · launch %.0f° · aim %s%.0f°" % [
		speed_mps, spin_rps,
		"+" if hyzer_deg >= 0.0 else "", hyzer_deg, launch_deg,
		"+" if heading_deg >= 0.0 else "", heading_deg]

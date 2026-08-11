class_name PuzzleGhost
extends RefCounted

## The predicted flight line shown while the player is setting up a throw.
##
## ---------------------------------------------------------------------------
## It stops at the first portal. That is a design rule, not a limitation.
## ---------------------------------------------------------------------------
## The ghost is drawn ONLY inside the launch room and is truncated at the portal
## plane. Predicting through a portal would hand the player the answer to every
## puzzle in the set — the whole game is "what does the far room do to this
## throw" — and it would also be a promise the sim cannot keep on Levels 6, 7, 9
## and 10, where the geometry beyond the portal depends on a throw that has not
## happened yet.
##
## The mechanism is deliberately dumb and therefore cannot leak: the ghost sim is
## configured with ONE room and NO portal links, and its hit oracle runs with
## `seal_portals = true`, so an aperture is a wall it stops against. There is no
## code path in this file that could follow a link even if the level data asked
## it to.
##
## ---------------------------------------------------------------------------
## Cost, and keeping it off the drag path
## ---------------------------------------------------------------------------
## `simulate_full()` measures 22.9 ms per flight in this project's own bench —
## 1.4 frames at 60 fps. Affordable once; ruinous if a slider drag fires one per
## input event. So `request()` is free (it stores parameters and marks the
## prediction stale) and `update(delta)` is the only thing that ever integrates,
## under two independent limits:
##
##   * DEBOUNCE — the crisp update lands once the controls have been still for
##     `debounce_s`. A drag that stops produces one prediction, not sixty.
##   * STALENESS — but a drag that never stops still gets a refresh every
##     `stale_after_s`, because a ghost frozen for the whole drag is worse than
##     no ghost. At the default that is ~3 predictions a second, ~2% of the
##     frame budget, against 100% if it ran per frame.
##   * RATE LIMIT — and never more often than `min_interval_s` under any
##     circumstances, which is the hard floor both of the above sit above.
##
## `preview_s` optionally caps how far ahead the ghost is drawn, for a level
## where the whole line would give too much away.

const LevelDataT := preload("res://scripts/puzzle/level_data.gd")
const WorldT := preload("res://scripts/puzzle/puzzle_world.gd")
const OracleT := preload("res://scripts/puzzle/puzzle_hit_oracle.gd")
const Sim := preload("res://scripts/physics/disc_flight_sim.gd")
const Library := preload("res://scripts/physics/disc_library.gd")

## Seconds the controls must be still before a prediction is computed.
var debounce_s: float = 0.08
## Floor on the interval between two predictions, seconds. Hard limit.
var min_interval_s: float = 0.15
## Refresh a stale prediction even while the controls are still moving, so a
## continuous drag is not left staring at a frozen line. <= 0 disables, making
## this a pure debounce.
var stale_after_s: float = 0.35
## Cap on predicted flight time, seconds. <= 0 means "to the end".
var preview_s: float = 0.0
var enabled: bool = true

# --- output -----------------------------------------------------------------
## World-space polyline, launch room only, ending at the floor, a wall or the
## first portal plane. Empty until the first prediction.
var trajectory: PackedVector3Array = PackedVector3Array()
## "floor" | "portal" | "wall" | "barrier" | "truncated" | "failed"
var end_kind: String = ""
## Portal / surface / barrier id the ghost ended against, "" for the floor.
var end_id: String = ""
var end_position: Vector3 = Vector3.ZERO
## Ground-plane distance from the tee to where the ghost ends. For a ghost that
## ends at a portal this is the distance to the portal, NOT to any flag.
var end_distance_m: float = 0.0
var flight_time_s: float = 0.0
## Wall-clock cost of the last prediction, milliseconds. Surface it on a dev
## overlay; it is the number that decides whether the throttle is tight enough.
var compute_ms: float = 0.0
## Predictions computed since `reset()`. A drag that produces more than a handful
## of these means the debounce is not working.
var predictions: int = 0

var _sim: Sim = null
var _oracle: OracleT = null
var _level: LevelDataT = null
var _world: WorldT = null
var _library: Library = null
var _disc_id: String = ""
var _params: Sim.ThrowParams = null
var _dirty: bool = false
var _since_change: float = 0.0
var _since_compute: float = 1e9
var _have: bool = false


func setup(world: WorldT, lib: Library) -> void:
	_world = world
	_level = world.level
	_library = lib
	_sim = Sim.new()
	# One room, no links. The ghost cannot cross a portal because there is no
	# portal in its world to cross.
	_oracle = OracleT.new(_level)
	_oracle.room = _level.tee_room
	_oracle.seal_portals = true
	_oracle.holes = world.oracle.holes
	_oracle.open_barriers = world.open_barriers
	_sim.hit_oracle = _oracle.callable()
	reset()


## Re-read the world's mutable state. Call after a portal is placed or a barrier
## opens, both of which change what the ghost should stop against.
func sync(world: WorldT) -> void:
	if _oracle == null:
		return
	_oracle.holes = world.oracle.holes
	_oracle.open_barriers = world.open_barriers
	_dirty = true


func reset() -> void:
	trajectory = PackedVector3Array()
	end_kind = ""
	end_id = ""
	end_distance_m = 0.0
	flight_time_s = 0.0
	predictions = 0
	_have = false
	_dirty = false
	_since_change = 0.0
	_since_compute = 1e9


func has_prediction() -> bool:
	return _have and not trajectory.is_empty()


## Portal links configured on the ghost simulator. Always 0, and asserted to be
## 0 in the suite: that is the structural guarantee that the ghost cannot predict
## through a portal, as opposed to a promise that it does not.
func sim_portal_count() -> int:
	return _sim.get_portals().size() if _sim != null else 0


## Free. Call it as often as the UI likes — on every slider tick, on every drag
## event. It stores the request and returns; nothing is integrated here.
func request(disc_id: String, p: Sim.ThrowParams) -> void:
	if not _same(disc_id, p):
		_disc_id = disc_id
		_params = p.duplicate_params()
		_dirty = true
		_since_change = 0.0


## Call once per frame. Returns true if a new prediction was computed this frame.
func update(delta: float) -> bool:
	_since_change += delta
	_since_compute += delta
	if not enabled or not _dirty or _params == null:
		return false
	if _since_compute < min_interval_s:
		return false
	var settled: bool = _since_change >= debounce_s
	var stale: bool = stale_after_s > 0.0 and _since_compute >= stale_after_s
	if not settled and not stale:
		return false
	_predict()
	return true


## Skip the throttle — for a one-shot refresh after the player changes disc, or
## on entering the level, where waiting a frame reads as a stutter.
func predict_now(disc_id: String, p: Sim.ThrowParams) -> void:
	_disc_id = disc_id
	_params = p.duplicate_params()
	_dirty = true
	_predict()


func _same(disc_id: String, p: Sim.ThrowParams) -> bool:
	if _params == null or disc_id != _disc_id:
		return false
	return is_equal_approx(p.speed_mps, _params.speed_mps) \
		and is_equal_approx(p.spin_rps, _params.spin_rps) \
		and is_equal_approx(p.nose_angle_rad, _params.nose_angle_rad) \
		and is_equal_approx(p.hyzer_angle_rad, _params.hyzer_angle_rad) \
		and is_equal_approx(p.launch_angle_rad, _params.launch_angle_rad) \
		and is_equal_approx(p.launch_height_m, _params.launch_height_m) \
		and is_equal_approx(p.launch_heading_rad, _params.launch_heading_rad)


func _predict() -> void:
	_dirty = false
	_since_compute = 0.0
	var t0 := Time.get_ticks_usec()

	var disc = _library.get_disc(_disc_id) if _library != null else null
	if disc == null or _level == null:
		trajectory = PackedVector3Array()
		end_kind = "failed"
		_have = false
		return

	_oracle.disc_radius = maxf(disc.diameter_m, 1e-4) * 0.5
	_oracle.room = _level.tee_room
	# ONE room, NO links: `configure_rooms` with an empty portal array is the
	# same one-room case sandbox mode uses.
	# The launch room's own environment, straight from the world so there is one
	# density/wind/gravity derivation in the project, not two.
	var env: Sim.FlightEnvironment = _world.room_environment(_level.tee_room)
	_sim.configure_rooms(disc, [env], [], 0)

	var res: Sim.FlightResult = _sim.simulate_full(_params)
	trajectory = res.trajectory
	flight_time_s = res.flight_time_s
	end_kind = "floor"
	end_id = ""
	if res.failed:
		end_kind = "failed"
	elif not res.impact.is_empty():
		var col: Dictionary = res.impact.get("collider", {})
		end_kind = String(col.get("kind", "wall"))
		if end_kind == "surface":
			end_kind = "wall"
		end_id = String(col.get("id", ""))

	if preview_s > 0.0 and flight_time_s > preview_s:
		_truncate_to(preview_s)

	end_position = trajectory[trajectory.size() - 1] if not trajectory.is_empty() \
		else Vector3.ZERO
	end_distance_m = Vector2(end_position.x, end_position.z).length()
	_have = true
	predictions += 1
	compute_ms = (Time.get_ticks_usec() - t0) / 1000.0



func _truncate_to(t: float) -> void:
	# `trajectory` is sampled at a fixed rate, so the cut index is arithmetic.
	var n: int = trajectory.size()
	if n < 2 or flight_time_s <= 0.0:
		return
	var keep: int = clampi(int(round(n * t / flight_time_s)), 2, n)
	if keep >= n:
		return
	trajectory = trajectory.slice(0, keep)
	end_kind = "truncated"
	end_id = ""
	flight_time_s = t

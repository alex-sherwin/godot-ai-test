class_name PuzzleSession
extends RefCounted

## One attempt at one puzzle level: throws, the disc budget, buttons, barriers
## that open between throws, portal-disc placement, objective evaluation and
## medals.
##
## This is the API Track P4 draws and Track P2 renders. It owns a `DiscFlightSim`
## and steps it; it holds no nodes and touches no scene tree, so the CI replay
## gate drives exactly the same code the game does.
##
## ---------------------------------------------------------------------------
## Lifecycle
## ---------------------------------------------------------------------------
##     var s := PuzzleSession.new()
##     s.start(level, library)
##     s.begin_throw("roc", params)          # or begin_throw(..., "portal_a")
##     while s.is_flying(): s.advance(delta) # or s.finish_throw() to skip
##     s.progress()                          # everything the HUD needs
##
## `simulate_throw()` is `begin_throw()` + `finish_throw()` and is what the
## replay gate and any "show me the solution" button use.
##
## ---------------------------------------------------------------------------
## Why the session steps the sim itself instead of calling `simulate_full()`
## ---------------------------------------------------------------------------
## Buttons are swept-sphere triggers on the FLIGHT PATH, not on the landing
## point, so they have to be tested against each substep segment — 0.11 m at
## 27 m/s. `FlightResult.trajectory` is sampled at 1/60 s (0.45 m at that speed)
## and carries no room labels, so testing against it would be both coarser and
## ambiguous about which room a sample is in. Stepping here also means the
## animated flight and the headless replay are the same arithmetic, not two
## implementations that agree until they don't.

const LevelDataT := preload("res://scripts/puzzle/level_data.gd")
const WorldT := preload("res://scripts/puzzle/puzzle_world.gd")
const Sim := preload("res://scripts/physics/disc_flight_sim.gd")
const Library := preload("res://scripts/physics/disc_library.gd")

## A throw ends here even if the disc is somehow still airborne. Matches
## `DiscFlightSim.MAX_FLIGHT_TIME`; Level 10's scoring line is the longest in the
## set at 11.0 s.
const MAX_THROW_TIME := 30.0

const MEDAL_RANK := {"": 0, "bronze": 1, "silver": 2, "gold": 3}


class ThrowRecord:
	extends RefCounted
	var index: int = 0
	var disc_id: String = ""
	var portal_disc_id: String = ""     ## "" for an ordinary throw
	var role: String = "score"
	var landed: bool = false
	var end_room: int = 0
	var landing_world: Vector3 = Vector3.ZERO
	var landing_local: Vector3 = Vector3.ZERO
	var flag_distance_m: float = INF    ## INF unless it landed in the flag's room
	var flight_time_s: float = 0.0
	var max_height_m: float = 0.0
	var crossings: int = 0
	var buttons_armed: PackedStringArray = PackedStringArray()
	var barriers_opened: PackedStringArray = PackedStringArray()
	## "floor" | "wall" | "barrier" | "timeout" | "failed"
	var outcome: String = "floor"
	var struck_id: String = ""          ## surface / barrier / wall id, if any
	var struck_portalable: bool = false
	var placed_portal_id: String = ""   ## "" if nothing was placed
	var placed_portal_center: Vector3 = Vector3.ZERO
	var trajectory: PackedVector3Array = PackedVector3Array()
	var crossing_points: Array = []

	func describe() -> String:
		var d: String = "%.2f m" % flag_distance_m if flag_distance_m < INF else "-"
		return "#%d %s%s %s -> %s (%s)" % [index + 1, disc_id,
			"" if portal_disc_id == "" else " [" + portal_disc_id + "]",
			role, outcome, d]


# --- authored ---------------------------------------------------------------
var level: LevelDataT = null
var world: WorldT = null
var library: Library = null

# --- attempt state ----------------------------------------------------------
var discs_used: int = 0
var throws: Array = []                 ## ThrowRecord
var best_flag_distance_m: float = INF
var best_medal: String = ""
var portal_discs_left: Dictionary = {} ## id -> int
var start_errors: PackedStringArray = PackedStringArray()

var _sim: Sim = null
var _flying: bool = false
var _current: ThrowRecord = null
var _log_len: int = 0
var _elapsed: float = 0.0
var _carry: float = 0.0


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func start(lv: LevelDataT, lib: Library) -> void:
	level = lv
	library = lib
	world = WorldT.new(lv)
	_sim = Sim.new()
	restart()


## Reset the attempt. The level itself is untouched, so this is cheap and is what
## a "retry" button calls.
func restart() -> void:
	start_errors.clear()
	discs_used = 0
	throws.clear()
	best_flag_distance_m = INF
	best_medal = ""
	_flying = false
	_current = null
	world.reset(level)
	portal_discs_left.clear()
	for pd in level.portal_discs:
		portal_discs_left[(pd as LevelDataT.PortalDiscData).id] = (pd as LevelDataT.PortalDiscData).count
	for e in world.build_errors:
		start_errors.append(e)


# ---------------------------------------------------------------------------
# Queries — the surface Track P4 draws
# ---------------------------------------------------------------------------

func is_flying() -> bool:
	return _flying


func discs_remaining() -> int:
	return maxi(level.max_discs - discs_used, 0)


func attempt_over() -> bool:
	return discs_used >= level.max_discs and not _flying


func buttons_armed() -> PackedStringArray:
	var out := PackedStringArray()
	for b in level.buttons:
		if world.armed_buttons.has((b as LevelDataT.ButtonData).id):
			out.append((b as LevelDataT.ButtonData).id)
	return out


func button_is_armed(bid: String) -> bool:
	return world.armed_buttons.has(bid)


func barrier_is_open(bid: String) -> bool:
	return world.open_barriers.has(bid)


func portal_discs_remaining(pid: String = "") -> int:
	if pid != "":
		return int(portal_discs_left.get(pid, 0))
	var total: int = 0
	for k in portal_discs_left:
		total += int(portal_discs_left[k])
	return total


## Medal the attempt would be awarded if the player stopped now. "" = none yet.
func medal_now() -> String:
	for m in level.medals:
		var t: LevelDataT.MedalTier = m
		if not _required_buttons_armed():
			continue
		if discs_used > t.max_discs or discs_used == 0:
			continue
		if best_flag_distance_m > t.max_flag_distance_m:
			continue
		return t.tier
	return ""


## The best tier still reachable from here; "" when even bronze is gone. Drives
## the "you can still get silver" line, and the decision to offer a retry.
##
## A tier is reachable if it is already earned, or if there is at least one throw
## left inside that tier's disc budget to earn it with.
func best_reachable_medal() -> String:
	var earned := medal_now()
	for m in level.medals:
		var t: LevelDataT.MedalTier = m
		if t.tier == earned:
			return t.tier
		if discs_used + 1 <= t.max_discs and discs_remaining() > 0 \
				and _required_buttons_reachable():
			return t.tier
	return earned


## Could the objective's required buttons still be armed? They can, as long as
## there is a disc left to arm them with.
func _required_buttons_reachable() -> bool:
	return _required_buttons_armed() or discs_remaining() > 0


func _required_buttons_armed() -> bool:
	for b in level.requires_buttons:
		if not world.armed_buttons.has(b):
			return false
	return true


## Everything a HUD needs, in one call, with no object graph to walk.
func progress() -> Dictionary:
	var need := PackedStringArray()
	for b in level.requires_buttons:
		if not world.armed_buttons.has(b):
			need.append(b)
	return {
		"level_id": level.id,
		"level_name": level.name,
		"order": level.order,
		"hint": level.hint,
		"concept": level.concept,
		"objective": level.objective_type,
		"objective_text": objective_text(),
		"portal_disc_convention": level.portal_disc_convention,
		"discs_used": discs_used,
		"discs_remaining": discs_remaining(),
		"max_discs": level.max_discs,
		"portal_discs_remaining": portal_discs_remaining(),
		"buttons_total": level.buttons.size(),
		"buttons_armed": buttons_armed(),
		"buttons_outstanding": need,
		"best_flag_distance_m": best_flag_distance_m,
		"medal_now": medal_now(),
		"best_medal": best_medal,
		"medal_targets": medal_targets(),
		"flying": _flying,
		"attempt_over": attempt_over(),
		"allowed_discs": level.allowed_disc_ids(),
		"last_throw": throws.back().describe() if not throws.is_empty() else "",
	}


func medal_targets() -> Array:
	var out: Array = []
	for m in level.medals:
		var t: LevelDataT.MedalTier = m
		out.append({"tier": t.tier, "max_discs": t.max_discs,
			"max_flag_distance_m": t.max_flag_distance_m})
	return out


func objective_text() -> String:
	match level.objective_type:
		LevelDataT.OBJ_CLOSEST:
			return "Land as close to the flag as you can. %d disc%s." % [
				level.max_discs, "" if level.max_discs == 1 else "s"]
		LevelDataT.OBJ_MIN_DISCS:
			return "Reach the flag in as few discs as possible, then get close."
		LevelDataT.OBJ_BUTTONS:
			return "Arm every lock, then land close to the flag — in as few discs as you can."
	return level.objective_type


# ---------------------------------------------------------------------------
# Throwing
# ---------------------------------------------------------------------------

## Is this throw legal right now? Returns "" if it is, else why not.
func throw_error(disc_id: String, portal_disc_id: String = "") -> String:
	if _flying:
		return "a disc is still in the air"
	if discs_used >= level.max_discs:
		return "no discs left"
	if not level.allowed_disc_ids().has(disc_id):
		return "%s is not in this level's bag" % disc_id
	if library == null or library.get_disc(disc_id) == null:
		return "unknown disc '%s'" % disc_id
	if portal_disc_id != "" and portal_discs_remaining(portal_disc_id) <= 0:
		return "no %s left" % portal_disc_id
	return ""


## Launch. `portal_disc_id` non-empty makes it a portal disc: it opens a portal
## where it strikes a portalable panel and never scores, and it is spent whether
## or not it lands anywhere useful.
func begin_throw(disc_id: String, params: Sim.ThrowParams,
		portal_disc_id: String = "") -> ThrowRecord:
	var err := throw_error(disc_id, portal_disc_id)
	var rec := ThrowRecord.new()
	rec.index = throws.size()
	rec.disc_id = disc_id
	rec.portal_disc_id = portal_disc_id
	rec.role = "place_portal" if portal_disc_id != "" else "score"
	if err != "":
		rec.outcome = "rejected: " + err
		return rec

	var disc = library.get_disc(disc_id)
	world.configure(_sim, disc)
	_sim.launch(params)
	discs_used += 1
	if portal_disc_id != "":
		portal_discs_left[portal_disc_id] = int(portal_discs_left[portal_disc_id]) - 1

	_current = rec
	_flying = true
	_elapsed = 0.0
	_carry = 0.0
	_log_len = 0
	throws.append(rec)
	return rec


## Step the in-flight disc. Call from `_physics_process`. Returns true while it
## is still flying.
func advance(delta: float) -> bool:
	if not _flying:
		return false
	var dt: float = _sim.substep_dt
	# Carried, not discarded: a frame time that is not a whole number of substeps
	# would otherwise lose the remainder every frame and run the flight slow.
	_carry += delta
	while _carry >= dt and _flying:
		_carry -= dt
		_step_once(dt)
	return _flying


## Run the current throw to its end without animating it.
func finish_throw() -> ThrowRecord:
	var dt: float = _sim.substep_dt
	while _flying:
		_step_once(dt)
	return throws.back()


## `begin_throw` + `finish_throw`. What the CI replay gate and the "show me"
## button use.
func simulate_throw(disc_id: String, params: Sim.ThrowParams,
		portal_disc_id: String = "") -> ThrowRecord:
	var rec := begin_throw(disc_id, params, portal_disc_id)
	if not _flying:
		return rec
	return finish_throw()


## Live state for the renderer while a disc is in the air.
func flight_state() -> Sim.DiscState:
	return _sim.get_state()


func flight_room() -> int:
	return _sim.get_room()


func sim() -> Sim:
	return _sim


# ---------------------------------------------------------------------------
# Replaying an authored solution
# ---------------------------------------------------------------------------

## `ThrowParams` for one authored solution step. The JSON is in degrees because
## it is a design document; the sim is in radians.
static func params_for(step: LevelDataT.SolutionStep) -> Sim.ThrowParams:
	var p := Sim.ThrowParams.new()
	p.speed_mps = step.speed_mps
	p.spin_rps = step.spin_rps
	p.nose_angle_rad = deg_to_rad(step.nose_deg)
	p.hyzer_angle_rad = deg_to_rad(step.hyzer_deg)
	p.launch_angle_rad = deg_to_rad(step.launch_deg)
	p.launch_heading_rad = deg_to_rad(step.heading_deg)
	p.launch_height_m = step.release_height_m
	return p


## Play an authored sequence (`intended_solution` / `alternate_solutions`) from
## the CURRENT state. Used by the CI replay gate and by a "show me" button; the
## sequence goes through the ordinary throw path, so anything it proves is a fact
## about the game and not about a test harness.
func replay(steps: Array) -> Array:
	var out: Array = []
	for s in steps:
		var st: LevelDataT.SolutionStep = s
		out.append(simulate_throw(st.disc, params_for(st), st.places()))
	return out


func _step_once(dt: float) -> void:
	var before: Vector3 = _sim.get_state().position
	var before_room: int = _sim.get_room()
	_sim.step(dt)
	_elapsed += dt
	_sweep_buttons(before, before_room, _sim.get_state().position)
	if not _sim.is_flying() or _sim.has_failed() or _elapsed >= MAX_THROW_TIME:
		_resolve()


## Arm any button whose trigger sphere the last substep's path passed through.
## The path is split at every portal crossing inside the substep, because the two
## halves are in different rooms and a straight line between them is not a path
## the disc ever took.
func _sweep_buttons(from: Vector3, from_room: int, to: Vector3) -> void:
	if level.buttons.is_empty():
		return
	var log: Array = _sim.get_crossing_log()
	var p: Vector3 = from
	var room: int = from_room
	for i in range(_log_len, log.size()):
		var e: Dictionary = log[i]
		_sweep_segment(p, e["enter"], room)
		room = int(e["to_room"])
		p = e["exit"]
	_log_len = log.size()
	_sweep_segment(p, to, room)


func _sweep_segment(a: Vector3, b: Vector3, room: int) -> void:
	for btn in level.buttons:
		var bd: LevelDataT.ButtonData = btn
		if bd.room != room or world.armed_buttons.has(bd.id):
			continue
		var c: Vector3 = bd.center + level.get_room(bd.room).world_origin
		if not _segment_hits_sphere(a, b, c, bd.radius_m):
			continue
		var opened := world.arm_button(bd.id)
		if _current != null:
			_current.buttons_armed.append(bd.id)
			for o in opened:
				_current.barriers_opened.append(o)


static func _segment_hits_sphere(a: Vector3, b: Vector3, c: Vector3, r: float) -> bool:
	var d: Vector3 = b - a
	var dd: float = d.length_squared()
	if dd < 1e-18:
		return a.distance_to(c) <= r
	var t: float = clampf((c - a).dot(d) / dd, 0.0, 1.0)
	return (a + d * t).distance_to(c) <= r


func _resolve() -> void:
	_flying = false
	var rec: ThrowRecord = _current
	_current = null
	if rec == null:
		return

	var st: Sim.DiscState = _sim.get_state()
	rec.end_room = _sim.get_room()
	rec.landing_world = st.position
	var r: LevelDataT.RoomData = level.get_room(rec.end_room)
	rec.landing_local = st.position - (r.world_origin if r != null else Vector3.ZERO)
	rec.flight_time_s = st.time
	rec.crossings = _sim.get_crossing_count()
	rec.trajectory = _sim.get_trajectory()
	rec.crossing_points = _sim.get_crossing_log()
	rec.max_height_m = 0.0
	for p in rec.trajectory:
		rec.max_height_m = maxf(rec.max_height_m, p.y)

	var impact: Dictionary = _sim.get_last_impact()
	if _sim.has_failed():
		rec.outcome = "failed"
	elif not impact.is_empty():
		var col: Dictionary = impact.get("collider", {})
		rec.struck_id = String(col.get("id", ""))
		rec.struck_portalable = bool(col.get("portalable", false))
		rec.outcome = "barrier" if String(col.get("kind", "")) == "barrier" else "wall"
		rec.landing_local = col.get("local", rec.landing_local)
	elif _elapsed >= MAX_THROW_TIME:
		rec.outcome = "timeout"
	else:
		rec.outcome = "floor"
		rec.landed = true

	if rec.portal_disc_id != "":
		_place(rec, impact)
	elif rec.landed:
		var d: float = level.flag_distance(rec.landing_world, rec.end_room)
		rec.flag_distance_m = d
		if d < best_flag_distance_m:
			best_flag_distance_m = d

	var m := medal_now()
	if MEDAL_RANK.get(m, 0) > MEDAL_RANK.get(best_medal, 0):
		best_medal = m


func _place(rec: ThrowRecord, impact: Dictionary) -> void:
	var spec: LevelDataT.PortalDiscData = null
	for pd in level.portal_discs:
		if (pd as LevelDataT.PortalDiscData).id == rec.portal_disc_id:
			spec = pd
			break
	if spec == null or not rec.struck_portalable:
		return
	var p := world.place_portal(spec, rec.struck_id, rec.landing_local)
	if p == null:
		return
	rec.placed_portal_id = p.id
	rec.placed_portal_center = p.center

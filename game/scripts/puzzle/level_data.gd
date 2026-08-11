class_name PuzzleLevelData
extends RefCounted

## Parsed, validated puzzle level. THIS FILE IS THE SCHEMA (Track P3 owns it;
## Track P2 consumes it). `game/data/levels/README.md` is the prose copy.
##
## Cross-file references go through `preload()` rather than the global
## `class_name` identifiers — see the note at the top of `aero_table.gd`. CI runs
## the suites as a bare `godot --headless --script`, which never populates the
## global script-class cache, and a `class_name` reference there is a parse
## error at load time.
##
## ---------------------------------------------------------------------------
## Coordinate frames — read this before touching anything geometric
## ---------------------------------------------------------------------------
## Every room authors its geometry in its OWN local frame with the floor at
## y = 0 (`bounds`, `portals[].center`, `surfaces[].rect`, `barriers[].box`,
## `buttons[].center`, `tee.position`, `flag.position` are all room-local).
##
## `rooms[].world_origin` translates that frame into the single shared world the
## simulator and the renderer both use:
##
##     world = local + world_origin            (TRANSLATION ONLY, never rotation)
##
## Two invariants the generator maintains and `validate()` re-checks:
##
##   1. `world_origin.y == 0` for every room, because `DiscFlightSim` has ONE
##      ground plane (`ground_height_m`, 0) and every room floor is y = 0.
##   2. The tee lands exactly on the world origin. `DiscFlightSim.launch()`
##      always starts the disc at `(0, release_height, 0)` and takes no tee
##      parameter, so the level data is what has to move, not the sim.
##
## Because the offsets are pure translations and the dynamics are
## translation-invariant, room-LOCAL results are identical whatever the layout
## is. `test_puzzle.gd` asserts exactly that by replaying every level twice, once
## with the shipped offsets and once with all of them zeroed, and requiring the
## room-local landings to agree. If you ever see that test fail, some piece of
## geometry is not being translated.

const LevelDataT := preload("res://scripts/puzzle/level_data.gd")

const SCHEMA_VERSION := 1

## Objective kinds. `type` in the JSON.
const OBJ_CLOSEST := "closest_to_flag"
const OBJ_MIN_DISCS := "min_discs_then_closest"
const OBJ_BUTTONS := "buttons_then_flag"

const TIERS := ["gold", "silver", "bronze"]

const AXIS_VECTORS := {
	"+x": Vector3(1.0, 0.0, 0.0), "-x": Vector3(-1.0, 0.0, 0.0),
	"+y": Vector3(0.0, 1.0, 0.0), "-y": Vector3(0.0, -1.0, 0.0),
	"+z": Vector3(0.0, 0.0, 1.0), "-z": Vector3(0.0, 0.0, -1.0),
}


# ---------------------------------------------------------------------------
# Sub-records
# ---------------------------------------------------------------------------

class RoomEnv:
	extends RefCounted
	var altitude_m: float = 0.0
	var temperature_c: float = 15.0
	## Optional sealed-chamber override; when > 0 it WINS over altitude/temp.
	var density_override: float = 0.0
	var wind: Vector3 = Vector3.ZERO
	var gravity: float = 9.81
	var note: String = ""


class RoomData:
	extends RefCounted
	var id: String = ""
	var name: String = ""
	var index: int = 0
	## Room-local axis-aligned bounds. `min.y` is the floor and is always 0.
	var bounds_min: Vector3 = Vector3.ZERO
	var bounds_max: Vector3 = Vector3.ONE
	var world_origin: Vector3 = Vector3.ZERO
	var env: RoomEnv = null
	var surfaces: Array = []   ## SurfaceData
	var barriers: Array = []   ## BarrierData

	func world_min() -> Vector3:
		return bounds_min + world_origin

	func world_max() -> Vector3:
		return bounds_max + world_origin

	func size() -> Vector3:
		return bounds_max - bounds_min

	## World-space centre, which is what a renderer wants to place a box at.
	func world_center() -> Vector3:
		return (bounds_min + bounds_max) * 0.5 + world_origin


class SurfaceData:
	extends RefCounted
	var id: String = ""
	var room: int = 0
	var axis: int = 2            ## 0 = x, 1 = y, 2 = z
	var value: float = 0.0       ## room-local plane coordinate
	var normal: Vector3 = Vector3.FORWARD  ## points INTO the room
	## Rectangle over the two non-plane axes, room-local, indexed by axis number.
	var rect_min: Vector3 = Vector3.ZERO
	var rect_max: Vector3 = Vector3.ZERO
	var portalable: bool = false

	func world_value(origin: Vector3) -> float:
		return value + origin[axis]

	## Is a WORLD point inside this panel's rectangle (plane coordinate ignored)?
	func contains_world(p: Vector3, origin: Vector3, eps: float = 1e-4) -> bool:
		for i in 3:
			if i == axis:
				continue
			var v: float = p[i] - origin[i]
			if v < rect_min[i] - eps or v > rect_max[i] + eps:
				return false
		return true


class BarrierData:
	extends RefCounted
	var id: String = ""
	var room: int = 0
	var box_min: Vector3 = Vector3.ZERO
	var box_max: Vector3 = Vector3.ZERO
	var starts_solid: bool = true
	## ALL of these buttons must be armed before the barrier opens. Empty means
	## the barrier is permanent (Level 9's lintel).
	var opened_by: PackedStringArray = PackedStringArray()
	var opens_between_throws: bool = true


class PortalData:
	extends RefCounted
	var id: String = ""
	var room: int = 0
	var center: Vector3 = Vector3.ZERO   ## room-local
	var facing: Vector3 = Vector3.FORWARD ## outward normal, points INTO the room
	var up: Vector3 = Vector3.UP
	var width_m: float = 1.0
	var height_m: float = 1.0
	var link: String = ""
	## true on EITHER end makes the pair a DIVE portal (PORTAL_CONTRACT §6).
	var inverting: bool = false
	var starts_open: bool = true
	var opened_by: PackedStringArray = PackedStringArray()
	## Set for portals created at runtime by a portal disc; empty for authored.
	var placed_by: String = ""

	func world_center(origin: Vector3) -> Vector3:
		return center + origin


class ButtonData:
	extends RefCounted
	var id: String = ""
	var room: int = 0
	var center: Vector3 = Vector3.ZERO
	var radius_m: float = 3.5
	var unlocks: PackedStringArray = PackedStringArray()


class PortalDiscData:
	extends RefCounted
	var id: String = ""
	var count: int = 1
	var inverting: bool = false
	var opens_portal_id: String = ""
	var link: String = ""
	var width_m: float = 10.0
	var height_m: float = 8.0
	var note: String = ""


class MedalTier:
	extends RefCounted
	var tier: String = ""
	var max_discs: int = 1
	var max_flag_distance_m: float = 1e9


class SolutionStep:
	extends RefCounted
	var role: String = "score"
	var disc: String = ""
	var speed_mps: float = 20.0
	var spin_rps: float = 20.0
	var nose_deg: float = 0.0
	var hyzer_deg: float = 0.0
	var launch_deg: float = 0.0
	var heading_deg: float = 0.0
	var release_height_m: float = 1.4
	## `expected` verbatim, as authored. `{}` when the step has no measurement.
	var expected: Dictionary = {}

	## The portal-disc id this step places, or "" if it places nothing.
	## Roles are "score", "arm", "place_portal_<x>", "arm+place_portal_<x>".
	func places() -> String:
		var i: int = role.find("place_portal_")
		return "" if i < 0 else "portal_" + role.substr(i + 13)

	func scores() -> bool:
		return role.find("score") >= 0


# ---------------------------------------------------------------------------
# The level
# ---------------------------------------------------------------------------

var schema: int = SCHEMA_VERSION
var id: String = ""
var order: int = 0
var name: String = ""
var concept: String = ""
var hint: String = ""
var teaches: PackedStringArray = PackedStringArray()
var portal_disc_convention: String = ""

var rooms: Array = []          ## RoomData, index == room index
var portals: Array = []        ## PortalData, authored only
var buttons: Array = []        ## ButtonData
var portal_discs: Array = []   ## PortalDiscData

var tee_room: int = 0
var tee_position: Vector3 = Vector3.ZERO
var flag_room: int = 0
var flag_position: Vector3 = Vector3.ZERO

var objective_type: String = OBJ_CLOSEST
var max_discs: int = 1
var requires_buttons: PackedStringArray = PackedStringArray()
var score_note: String = ""

var medals: Array = []         ## MedalTier, gold first
var allowed_discs: Array = []  ## [{id: String, count: int}], -1 = unlimited
var intended_solution: Array = []   ## SolutionStep
var alternate_solutions: Array = [] ## SolutionStep
var validation: Dictionary = {}

var source_path: String = ""
var errors: PackedStringArray = PackedStringArray()

var _room_index: Dictionary = {}
var _portal_index: Dictionary = {}


func is_valid() -> bool:
	return errors.is_empty()


func room_index(rid: String) -> int:
	return int(_room_index.get(rid, -1))


func get_room(i: int) -> RoomData:
	return rooms[i] if i >= 0 and i < rooms.size() else null


func get_portal(pid: String) -> PortalData:
	return _portal_index.get(pid, null)


func get_portal_disc(disc_id: String) -> PortalDiscData:
	for p in portal_discs:
		if (p as PortalDiscData).id == disc_id:
			return p
	return null


## World-space flag position (y forced to the floor: it is a ground target).
func flag_world() -> Vector3:
	var r: RoomData = get_room(flag_room)
	var o: Vector3 = r.world_origin if r != null else Vector3.ZERO
	return Vector3(flag_position.x + o.x, o.y, flag_position.z + o.z)


func tee_world() -> Vector3:
	var r: RoomData = get_room(tee_room)
	var o: Vector3 = r.world_origin if r != null else Vector3.ZERO
	return tee_position + o


## Ground-plane distance from a WORLD landing point to the flag, or INF if the
## disc did not land in the flag's room.
func flag_distance(landing_world: Vector3, landed_room: int) -> float:
	if landed_room != flag_room:
		return INF
	var f: Vector3 = flag_world()
	return Vector2(landing_world.x - f.x, landing_world.z - f.z).length()


func allowed_disc_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for e in allowed_discs:
		out.append(String(e.get("id", "")))
	return out


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

static func from_file(path: String) -> LevelDataT:
	var lv := LevelDataT.new()
	lv.source_path = path
	if not FileAccess.file_exists(path):
		lv.errors.append("%s: no such file" % path)
		return lv
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		lv.errors.append("%s: not a JSON object" % path)
		return lv
	lv._parse(parsed)
	return lv


static func from_dict(d: Dictionary, path: String = "<dict>") -> LevelDataT:
	var lv := LevelDataT.new()
	lv.source_path = path
	lv._parse(d)
	return lv


func _err(msg: String) -> void:
	errors.append("%s: %s" % [source_path, msg])


static func _vec(v: Variant, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	if v is Array and (v as Array).size() >= 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return fallback


static func _axis_vec(s: Variant, fallback: Vector3) -> Vector3:
	return AXIS_VECTORS.get(String(s).to_lower(), fallback)


static func _axis_num(s: String) -> int:
	match s.to_lower():
		"x": return 0
		"y": return 1
		"z": return 2
	return -1


func _parse(d: Dictionary) -> void:
	schema = int(d.get("schema", 0))
	if schema != SCHEMA_VERSION:
		_err("schema %d, expected %d" % [schema, SCHEMA_VERSION])
	id = String(d.get("id", ""))
	order = int(d.get("order", 0))
	name = String(d.get("name", id))
	concept = String(d.get("concept", ""))
	hint = String(d.get("hint", ""))
	portal_disc_convention = String(d.get("portal_disc_convention", ""))
	for t in (d.get("teaches", []) as Array):
		teaches.append(String(t))

	_parse_rooms(d.get("rooms", []) as Array)
	_parse_portals(d.get("portals", []) as Array)
	_parse_buttons(d.get("buttons", []) as Array)
	_parse_portal_discs(d.get("portal_discs", []) as Array)

	var tee: Dictionary = d.get("tee", {})
	tee_room = room_index(String(tee.get("room", "")))
	tee_position = _vec(tee.get("position", []))
	if tee_room < 0:
		_err("tee references unknown room '%s'" % String(tee.get("room", "")))
		tee_room = 0

	var flag: Dictionary = d.get("flag", {})
	flag_room = room_index(String(flag.get("room", "")))
	flag_position = _vec(flag.get("position", []))
	if flag_room < 0:
		_err("flag references unknown room '%s'" % String(flag.get("room", "")))
		flag_room = 0

	_parse_objective(d.get("objective", {}))
	_parse_medals(d.get("medals", {}))

	for e in (d.get("allowed_discs", []) as Array):
		allowed_discs.append({"id": String(e.get("id", "")), "count": int(e.get("count", -1))})
	if allowed_discs.is_empty():
		_err("allowed_discs is empty — the level cannot be played")

	for s in (d.get("intended_solution", []) as Array):
		intended_solution.append(_parse_step(s))
	for s in (d.get("alternate_solutions", []) as Array):
		alternate_solutions.append(_parse_step(s))
	validation = d.get("validation", {})

	_validate()


func _parse_rooms(arr: Array) -> void:
	for i in arr.size():
		var rd: Dictionary = arr[i]
		var r := RoomData.new()
		r.id = String(rd.get("id", "room%d" % i))
		r.name = String(rd.get("name", r.id))
		r.index = i
		var b: Dictionary = rd.get("bounds", {})
		var bx: Array = b.get("x", [-10, 10])
		var by: Array = b.get("y", [0, 10])
		var bz: Array = b.get("z", [-10, 10])
		r.bounds_min = Vector3(float(bx[0]), float(by[0]), float(bz[0]))
		r.bounds_max = Vector3(float(bx[1]), float(by[1]), float(bz[1]))
		r.world_origin = _vec(rd.get("world_origin", []), Vector3.ZERO)

		var e: Dictionary = rd.get("environment", {})
		var env := RoomEnv.new()
		env.altitude_m = float(e.get("altitude_m", 0.0))
		env.temperature_c = float(e.get("temperature_c", 15.0))
		env.density_override = float(e.get("air_density_override_kg_m3", 0.0))
		env.wind = _vec(e.get("wind_mps", []), Vector3.ZERO)
		env.gravity = float(e.get("gravity_mps2", 9.81))
		env.note = String(e.get("note", ""))
		r.env = env

		for sd in (rd.get("surfaces", []) as Array):
			var s := SurfaceData.new()
			s.id = String(sd.get("id", ""))
			s.room = i
			var pl: Dictionary = sd.get("plane", {})
			s.axis = _axis_num(String(pl.get("axis", "z")))
			if s.axis < 0:
				_err("surface '%s' has a bad plane axis" % s.id)
				s.axis = 2
			s.value = float(pl.get("value", 0.0))
			s.normal = _axis_vec(sd.get("normal", "+z"), Vector3.FORWARD)
			s.portalable = bool(sd.get("portalable", false))
			var rect: Dictionary = sd.get("rect", {})
			# Unstated axes inherit the room's own extent, so a panel only has to
			# name the axes it actually bounds.
			var rmin: Vector3 = r.bounds_min
			var rmax: Vector3 = r.bounds_max
			for k in ["x", "y", "z"]:
				if not rect.has(k):
					continue
				var n: int = _axis_num(k)
				var pair: Array = rect[k]
				rmin[n] = float(pair[0])
				rmax[n] = float(pair[1])
			s.rect_min = rmin
			s.rect_max = rmax
			r.surfaces.append(s)

		for bd in (rd.get("barriers", []) as Array):
			var ba := BarrierData.new()
			ba.id = String(bd.get("id", ""))
			ba.room = i
			var box: Dictionary = bd.get("box", {})
			var kx: Array = box.get("x", [0, 0])
			var ky: Array = box.get("y", [0, 0])
			var kz: Array = box.get("z", [0, 0])
			ba.box_min = Vector3(float(kx[0]), float(ky[0]), float(kz[0]))
			ba.box_max = Vector3(float(kx[1]), float(ky[1]), float(kz[1]))
			ba.starts_solid = bool(bd.get("starts_solid", true))
			for k in (bd.get("opened_by", []) as Array):
				ba.opened_by.append(String(k))
			ba.opens_between_throws = bool(bd.get("opens_between_throws", true))
			r.barriers.append(ba)

		rooms.append(r)
		_room_index[r.id] = i
	if rooms.is_empty():
		_err("no rooms")


func _parse_portals(arr: Array) -> void:
	for pd in arr:
		var p := PortalData.new()
		p.id = String(pd.get("id", ""))
		p.room = room_index(String(pd.get("room", "")))
		if p.room < 0:
			_err("portal '%s' references unknown room '%s'" % [p.id, String(pd.get("room", ""))])
			continue
		p.center = _vec(pd.get("center", []))
		p.facing = _axis_vec(pd.get("facing", "+z"), Vector3.FORWARD)
		p.up = _axis_vec(pd.get("up", "+y"), Vector3.UP)
		p.width_m = float(pd.get("width_m", 1.0))
		p.height_m = float(pd.get("height_m", 1.0))
		p.link = String(pd.get("link", ""))
		p.inverting = bool(pd.get("inverting", false))
		if p.inverting:
			# `up` in the JSON is the pre-inversion mounting; `inverting` is the
			# authoritative flag. A dive portal is a frame mounted UPSIDE DOWN —
			# a proper rotation, never a reflection (PORTAL_CONTRACT §6) — so
			# from here on `PortalData.up` is the real mounted up and every
			# consumer (links, holes, renderer) can read it without knowing about
			# the flag.
			p.up = -p.up
		p.starts_open = bool(pd.get("starts_open", true))
		for k in (pd.get("opened_by", []) as Array):
			p.opened_by.append(String(k))
		portals.append(p)
		_portal_index[p.id] = p


func _parse_buttons(arr: Array) -> void:
	for bd in arr:
		var b := ButtonData.new()
		b.id = String(bd.get("id", ""))
		b.room = room_index(String(bd.get("room", "")))
		if b.room < 0:
			_err("button '%s' references unknown room" % b.id)
			continue
		b.center = _vec(bd.get("center", []))
		b.radius_m = float(bd.get("radius_m", 3.5))
		for u in (bd.get("unlocks", []) as Array):
			b.unlocks.append(String(u))
		buttons.append(b)


func _parse_portal_discs(arr: Array) -> void:
	for pd in arr:
		var p := PortalDiscData.new()
		p.id = String(pd.get("id", ""))
		p.count = int(pd.get("count", 1))
		p.inverting = bool(pd.get("inverting", false))
		p.opens_portal_id = String(pd.get("opens_portal_id", ""))
		p.link = String(pd.get("link", ""))
		p.width_m = float(pd.get("width_m", 10.0))
		p.height_m = float(pd.get("height_m", 8.0))
		p.note = String(pd.get("note", ""))
		portal_discs.append(p)


func _parse_objective(o: Dictionary) -> void:
	objective_type = String(o.get("type", OBJ_CLOSEST))
	if objective_type != OBJ_CLOSEST and objective_type != OBJ_MIN_DISCS \
			and objective_type != OBJ_BUTTONS:
		_err("unknown objective type '%s'" % objective_type)
	max_discs = int(o.get("max_discs", 0))
	for b in (o.get("requires_buttons", []) as Array):
		requires_buttons.append(String(b))
	score_note = String(o.get("score", ""))


func _parse_medals(m: Dictionary) -> void:
	for tier in TIERS:
		if not m.has(tier):
			continue
		var t: Dictionary = m[tier]
		var mt := MedalTier.new()
		mt.tier = tier
		mt.max_discs = int(t.get("max_discs", 1))
		mt.max_flag_distance_m = float(t.get("max_flag_distance_m", 1e9))
		medals.append(mt)
	if medals.is_empty():
		_err("no medal tiers")
	if max_discs <= 0:
		# A level that does not state a budget gets the most generous tier's.
		for mt in medals:
			max_discs = maxi(max_discs, (mt as MedalTier).max_discs)
		max_discs = maxi(max_discs, 1)


func _parse_step(s: Dictionary) -> SolutionStep:
	var st := SolutionStep.new()
	st.role = String(s.get("role", "score"))
	st.disc = String(s.get("disc", ""))
	st.speed_mps = float(s.get("speed_mps", 20.0))
	st.spin_rps = float(s.get("spin_rps", 20.0))
	st.nose_deg = float(s.get("nose_deg", 0.0))
	st.hyzer_deg = float(s.get("hyzer_deg", 0.0))
	st.launch_deg = float(s.get("launch_deg", 0.0))
	st.heading_deg = float(s.get("heading_deg", 0.0))
	st.release_height_m = float(s.get("release_height_m", 1.4))
	st.expected = s.get("expected", {})
	return st


# ---------------------------------------------------------------------------
# Structural validation
# ---------------------------------------------------------------------------

func _validate() -> void:
	var seen := {}
	for r in rooms:
		var rd: RoomData = r
		if seen.has(rd.id):
			_err("duplicate room id '%s'" % rd.id)
		seen[rd.id] = true
		if absf(rd.bounds_min.y) > 1e-6:
			_err("room '%s' floor is y = %.3f; every room floor must be y = 0 because the sim has one ground plane" % [rd.id, rd.bounds_min.y])
		if absf(rd.world_origin.y) > 1e-6:
			_err("room '%s' has world_origin.y = %.3f; layout offsets must not move a floor" % [rd.id, rd.world_origin.y])
		for i in 3:
			if rd.bounds_max[i] <= rd.bounds_min[i]:
				_err("room '%s' has empty bounds on axis %d" % [rd.id, i])

	# The tee must land on the world origin: `DiscFlightSim.launch()` starts the
	# disc at (0, h, 0) and takes no tee parameter.
	var tw: Vector3 = tee_world()
	if Vector2(tw.x, tw.z).length() > 1e-4:
		_err("tee is at world %s, but launch() always starts at the world origin — set rooms[%d].world_origin so the tee lands on it" % [str(tw), tee_room])

	var pseen := {}
	for p in portals:
		var pd: PortalData = p
		if pseen.has(pd.id):
			_err("duplicate portal id '%s'" % pd.id)
		pseen[pd.id] = true
		if pd.width_m <= 0.0 or pd.height_m <= 0.0:
			_err("portal '%s' has a non-positive aperture" % pd.id)
		if absf(pd.facing.dot(pd.up)) > 1e-6:
			_err("portal '%s' has up parallel to facing" % pd.id)
		# PORTAL_CONTRACT §6 / LEVEL_DESIGN §0.1: a non-inverting wall portal
		# MUST use world-up, or the pair stops being a pure yaw and the flight
		# silently changes. Inversion is opt-in, never accidental.
		if not pd.inverting and pd.up.dot(Vector3.UP) < 0.999:
			_err("portal '%s' is not inverting but its up is %s — non-inverting wall portals must use world-up" % [pd.id, str(pd.up)])
		var link_target: PortalData = get_portal(pd.link)
		var placed_link: bool = is_placed_portal_id(pd.link)
		if link_target == null and not placed_link:
			_err("portal '%s' links to unknown portal '%s'" % [pd.id, pd.link])
		if _plane_offset(pd) > 1e-6:
			_err("portal '%s' centre is %.3f m off its room wall — a portal must be flush in a wall" % [pd.id, _plane_offset(pd)])

	var bseen := {}
	for b in buttons:
		var bd: ButtonData = b
		if bseen.has(bd.id):
			_err("duplicate button id '%s'" % bd.id)
		bseen[bd.id] = true
		if bd.radius_m <= 0.0:
			_err("button '%s' has a non-positive radius" % bd.id)

	for r2 in rooms:
		for ba in (r2 as RoomData).barriers:
			for k in (ba as BarrierData).opened_by:
				if not bseen.has(k):
					_err("barrier '%s' is opened by unknown button '%s'" % [(ba as BarrierData).id, k])

	for pd2 in portal_discs:
		var pdd: PortalDiscData = pd2
		if get_portal(pdd.link) == null:
			_err("portal disc '%s' links to unknown portal '%s'" % [pdd.id, pdd.link])
		if pdd.count <= 0:
			_err("portal disc '%s' has count %d" % [pdd.id, pdd.count])

	for s in intended_solution:
		var st: SolutionStep = s
		var placed_id: String = st.places()
		if placed_id != "" and _portal_disc(placed_id) == null:
			_err("intended_solution step role '%s' places unknown portal disc '%s'" % [st.role, placed_id])
	if intended_solution.is_empty():
		_err("no intended_solution — the CI replay gate needs one")


func _portal_disc(pid: String) -> PortalDiscData:
	for p in portal_discs:
		if (p as PortalDiscData).id == pid:
			return p
	return null


## True if `pid` is the id a portal disc will create at runtime. Such a portal
## is legitimately absent until the player throws the disc that opens it, so an
## unresolved link to one is a STATE, not an error.
func is_placed_portal_id(pid: String) -> bool:
	for p in portal_discs:
		if (p as PortalDiscData).opens_portal_id == pid:
			return true
	return false


## How far a portal's centre sits off the nearest bounding wall of its room.
func _plane_offset(p: PortalData) -> float:
	var r: RoomData = get_room(p.room)
	if r == null:
		return 0.0
	for i in 3:
		if absf(p.facing[i]) > 0.5:
			# `facing` points INTO the room, so the wall it is set in is the one
			# on the opposite side.
			var wall: float = r.bounds_min[i] if p.facing[i] > 0.0 else r.bounds_max[i]
			return absf(p.center[i] - wall)
	return 0.0

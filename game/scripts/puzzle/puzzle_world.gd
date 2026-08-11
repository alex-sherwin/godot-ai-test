class_name PuzzleWorld
extends RefCounted

## Compiles a `PuzzleLevelData` plus the mutable state of one attempt (which
## barriers are open, which portals have been placed) into the three things
## `DiscFlightSim.configure_rooms()` wants: an ordered array of
## `FlightEnvironment`, an ordered array of `PortalLink`, and a hit oracle.
##
## Everything here is world-frame. `PuzzleLevelData` documents the room-local ->
## world translation; nothing in this file rotates a room, and nothing may,
## because a rotated room would leave its world-frame wind pointing the wrong
## way while the level data still described it in local terms.
##
## Ordering is deterministic and load-bearing. `configure_rooms()` takes ordered
## arrays specifically because iteration order decides which of two simultaneous
## crossings is taken, and `test_determinism.gd` requires that to be
## reproducible. Links are emitted in authored portal order, both directions of
## each pair adjacent, placed portals last.

const LevelDataT := preload("res://scripts/puzzle/level_data.gd")
const OracleT := preload("res://scripts/puzzle/puzzle_hit_oracle.gd")
const PortalLinkT := preload("res://scripts/physics/portal_link.gd")
const Sim := preload("res://scripts/physics/disc_flight_sim.gd")
const Atmos := preload("res://scripts/physics/atmosphere.gd")

var level: LevelDataT = null

## Authored portals plus any placed at runtime, in a stable order.
var portals: Array = []          ## PortalData
var environments: Array = []     ## FlightEnvironment, indexed by room
var links: Array = []            ## PortalLink
var oracle: OracleT = null

## Barrier ids currently open, and button ids currently armed.
var open_barriers: Dictionary = {}
var armed_buttons: Dictionary = {}

var build_errors: PackedStringArray = PackedStringArray()

var _by_id: Dictionary = {}
## "<from id> <to id>" -> the PortalLink emitted for that directed hop.
## Rendering looks a link up here so a portal camera is driven by the very
## object the simulator flies against, rather than by an equal one built a
## second time (PORTAL_CONTRACT §3: there is one implementation of M).
var _link_by_pair: Dictionary = {}


func _init(lv: LevelDataT = null) -> void:
	if lv != null:
		reset(lv)


## Back to the level's authored state: no placed portals, no armed buttons, every
## lockable barrier solid again.
func reset(lv: LevelDataT) -> void:
	level = lv
	open_barriers.clear()
	armed_buttons.clear()
	portals = lv.portals.duplicate()
	oracle = OracleT.new(lv)
	_rebuild()


# ---------------------------------------------------------------------------
# Mutation between throws (PORTAL_CONTRACT §7: never mid-flight)
# ---------------------------------------------------------------------------

## Arm a button and open anything all of whose buttons are now armed. Returns
## the barrier ids that opened as a result.
func arm_button(button_id: String) -> PackedStringArray:
	var opened := PackedStringArray()
	if armed_buttons.has(button_id):
		return opened
	armed_buttons[button_id] = true
	for r in level.rooms:
		for b in (r as LevelDataT.RoomData).barriers:
			var bd: LevelDataT.BarrierData = b
			if bd.opened_by.is_empty() or open_barriers.has(bd.id):
				continue
			var all_armed: bool = true
			for k in bd.opened_by:
				if not armed_buttons.has(k):
					all_armed = false
					break
			if all_armed:
				open_barriers[bd.id] = true
				opened.append(bd.id)
	if not opened.is_empty():
		_rebuild()
	return opened


## Open a portal-disc portal at a surface impact. `impact_local` is in the struck
## room's local frame. Returns the created `PortalData`, or null if the surface
## is not portalable (in which case the portal disc is simply spent).
##
## The rectangle is clamped to fit inside the panel, which is why Level 10's
## impact at y = 4.88 opens a 14 x 12 portal centred at y = 8.00: the panel's
## lower edge is y = 2 and half the portal height is 6.
func place_portal(spec: LevelDataT.PortalDiscData, surface_id: String,
		impact_local: Vector3) -> LevelDataT.PortalData:
	var sd: LevelDataT.SurfaceData = surface_by_id(surface_id)
	if sd == null or not sd.portalable:
		return null

	var p := LevelDataT.PortalData.new()
	p.id = spec.opens_portal_id
	p.room = sd.room
	p.facing = sd.normal
	p.up = Vector3.DOWN if spec.inverting else Vector3.UP
	p.width_m = spec.width_m
	p.height_m = spec.height_m
	p.link = spec.link
	p.inverting = spec.inverting
	p.starts_open = true
	p.placed_by = spec.id
	p.center = clamp_portal_center(sd, spec, impact_local)

	# Replace rather than append if this portal disc has already been used, so a
	# level that grants `count > 1` moves its portal instead of growing an army.
	for i in portals.size():
		if (portals[i] as LevelDataT.PortalData).id == p.id:
			portals[i] = p
			_rebuild()
			return p
	portals.append(p)
	_rebuild()
	return p


## Where a portal disc striking `sd` at `impact_local` actually opens its portal:
## the impact point, clamped so the whole rectangle fits inside the panel.
##
## Extracted from `place_portal` so the UI can draw the SAME rectangle before the
## throw. A missed portal disc is spent — that is Level 7's whole tension — so
## the player is owed a prediction, and a prediction computed by a second copy of
## this clamp would eventually stop matching the placement it predicts.
static func clamp_portal_center(sd: LevelDataT.SurfaceData,
		spec: LevelDataT.PortalDiscData, impact_local: Vector3) -> Vector3:
	# Half-extents per axis: `up` is vertical, so the height goes on y and the
	# width on whichever horizontal axis is not the plane's.
	var c: Vector3 = impact_local
	for i in 3:
		if i == sd.axis:
			continue
		var half: float = (spec.height_m if i == 1 else spec.width_m) * 0.5
		var lo: float = sd.rect_min[i] + half
		var hi: float = sd.rect_max[i] - half
		# A panel narrower than the portal centres it rather than inverting the
		# clamp — `clampf(v, lo, hi)` with lo > hi returns hi and would jam the
		# portal against one edge.
		c[i] = clampf(c[i], lo, hi) if lo <= hi else (sd.rect_min[i] + sd.rect_max[i]) * 0.5
	c[sd.axis] = sd.value
	return c


## The `PortalLink` for one DIRECTED hop, or null. See `_link_by_pair`.
func link_for(from_id: String, to_id: String) -> PortalLinkT:
	return _link_by_pair.get("%s %s" % [from_id, to_id], null) as PortalLinkT


## The panel with this id, or null.
func surface_by_id(surface_id: String) -> LevelDataT.SurfaceData:
	for r in level.rooms:
		for s in (r as LevelDataT.RoomData).surfaces:
			if (s as LevelDataT.SurfaceData).id == surface_id:
				return s
	return null


## Is `pid` open right now? A portal with `opened_by` stays shut until all of
## those buttons are armed.
func portal_open(p: LevelDataT.PortalData) -> bool:
	if not p.starts_open and p.opened_by.is_empty():
		return false
	for k in p.opened_by:
		if not armed_buttons.has(k):
			return false
	return true


# ---------------------------------------------------------------------------
# Compilation
# ---------------------------------------------------------------------------

func _rebuild() -> void:
	build_errors.clear()
	_by_id.clear()
	for p in portals:
		_by_id[(p as LevelDataT.PortalData).id] = p

	environments.clear()
	for r in level.rooms:
		environments.append(_environment(r))

	links.clear()
	_link_by_pair.clear()
	var holes: Array = []
	var emitted := {}
	for p in portals:
		var pd: LevelDataT.PortalData = p
		var other: LevelDataT.PortalData = _by_id.get(pd.link, null)
		var open: bool = portal_open(pd)
		holes.append(_hole(pd, open and other != null))
		if other == null:
			# A fixed portal whose partner is opened by a portal disc is simply
			# waiting: no link, no hole, and the wall it is set in stays solid
			# until the player opens the other end.
			if pd.link != "" and not level.is_placed_portal_id(pd.link):
				build_errors.append("portal '%s' links to '%s', which does not exist"
					% [pd.id, pd.link])
			continue
		if emitted.has(pd.id) or not open or not portal_open(other):
			continue
		emitted[pd.id] = true
		emitted[other.id] = true
		var forward := _link(pd, other)
		var back := _link(other, pd)
		links.append(forward)
		links.append(back)
		_link_by_pair["%s %s" % [pd.id, other.id]] = forward
		_link_by_pair["%s %s" % [other.id, pd.id]] = back

	oracle.level = level
	oracle.holes = holes
	oracle.open_barriers = open_barriers


func _environment(r: LevelDataT.RoomData) -> Sim.FlightEnvironment:
	var e := Sim.FlightEnvironment.new()
	var env: LevelDataT.RoomEnv = r.env
	e.air_density = env.density_override if env.density_override > 0.0 \
		else Atmos.air_density(env.altitude_m, env.temperature_c)
	e.wind = env.wind
	e.gravity = env.gravity
	return e


func _hole(p: LevelDataT.PortalData, open: bool) -> Dictionary:
	var o: Vector3 = level.get_room(p.room).world_origin
	return {"room": p.room, "center": p.center + o, "facing": p.facing,
		"up": p.up, "half_w": p.width_m * 0.5, "half_h": p.height_m * 0.5,
		"open": open, "id": p.id}


## World transform of a portal: local +Z is the outward normal, local +Y the
## mounted up (PORTAL_CONTRACT §1). A DIVE portal is exactly the case where that
## up is world-DOWN, which is why `PuzzleLevelData` folds the `inverting` flag
## into `PortalData.up` at parse time and nothing below here has to branch on it.
func transform_of(p: LevelDataT.PortalData) -> Transform3D:
	var n: Vector3 = p.facing.normalized()
	var u: Vector3 = (p.up - n * p.up.dot(n))
	u = u.normalized() if u.length() > 1e-6 else Vector3.UP
	# right = up x n makes (right, up, n) right-handed: det = +1 by construction,
	# never a reflection. Do NOT use look_at(): it orients -Z, and errors out
	# returning identity when up is parallel to the look direction.
	var right: Vector3 = u.cross(n).normalized()
	u = n.cross(right).normalized()
	var o: Vector3 = level.get_room(p.room).world_origin
	return Transform3D(Basis(right, u, n), p.center + o)


func _link(from_p: LevelDataT.PortalData, to_p: LevelDataT.PortalData) -> PortalLinkT:
	var lk := PortalLinkT.make(transform_of(from_p), transform_of(to_p),
		from_p.room, to_p.room, from_p.width_m * 0.5, from_p.height_m * 0.5)
	if not lk.valid:
		for w in lk.warnings:
			build_errors.append("link %s -> %s: %s" % [from_p.id, to_p.id, w])
	return lk


# ---------------------------------------------------------------------------
# Handing the world to the simulator
# ---------------------------------------------------------------------------

## Configure `sim` for this world and this disc. The oracle's inset must match
## the sim's own disc radius or the hole it cuts in the wall and the aperture the
## sim fires on describe different rectangles.
func configure(sim: Sim, disc) -> void:
	oracle.disc_radius = maxf(disc.diameter_m, 1e-4) * 0.5
	oracle.room = level.tee_room
	# The oracle must read the room the sim is in AT THE MOMENT OF THE QUERY: a
	# substep is split at a portal crossing and queried again for the remainder,
	# by which time the disc is already in the destination room.
	oracle.room_provider = Callable(sim, "get_room")
	sim.configure_rooms(disc, environments, links, level.tee_room)
	sim.hit_oracle = oracle.callable()


## Environment of a single room, for the ghost predictor (which runs one room
## with no portals at all).
func room_environment(room: int) -> Sim.FlightEnvironment:
	return environments[room] if room >= 0 and room < environments.size() \
		else Sim.FlightEnvironment.new()

class_name PuzzleHitOracle
extends RefCounted

## The analytic wall/barrier hit oracle `DiscFlightSim` calls through
## `hit_oracle` (PORTAL_CONTRACT §7). Pure geometry: no scene tree, no physics
## server, no nodes — which is what lets the whole puzzle runtime, including the
## CI replay gate, run under a bare `godot --headless --script`.
##
## In the shipped game the same oracle runs: the level geometry is axis-aligned
## boxes and the analytic test is both exact and cheaper than a raycast, so
## there is no second implementation to drift.
##
## What it reports a hit on, in the disc's CURRENT room only:
##
##   * the room's own bounding walls — ±x, +y (ceiling), ±z. NOT the floor:
##     y = 0 is the sim's ground plane and `_g_ground` owns it.
##   * solid barriers (Level 5's gate, Level 9's lintel, Level 10's shutter).
##
## and what it deliberately does NOT report:
##
##   * anything inside an OPEN portal's aperture. PORTAL_CONTRACT §7 offers two
##     ways to stop a wall stealing a crossing — a 2 cm tie-break, or cutting a
##     hole in the collider — and says the hole is better. This is the hole, and
##     it is cut to exactly the aperture the sim will fire on: the rectangle
##     INSET BY THE DISC RADIUS. Cutting the full rectangle instead would let a
##     disc whose centre passes within one radius of the rim slip through a hole
##     the sim then declines to teleport it through, and it would leave the room
##     entirely.
##
## `collider` in the returned dictionary is a Dictionary describing what was hit,
## so the puzzle layer can tell a portalable panel from stone without a second
## lookup:
##
##     {kind: "surface"|"wall"|"barrier", id: String, room: int,
##      portalable: bool, local: Vector3}
##
## `local` is the impact point in the struck room's LOCAL frame, which is the
## frame the level data and every published measurement are in.

const LevelDataT := preload("res://scripts/puzzle/level_data.gd")

## Plane-coincidence tolerance when deciding whether a wall hit lands on an
## authored surface or inside a portal aperture. Generous compared to the
## sub-millimetre accuracy of the event locator, tight compared to any real
## geometric feature in the levels.
const PLANE_EPS := 0.01

## Faces of the room box, as (axis, sign). The floor (1, -1) is absent on
## purpose — see the class comment.
const WALL_FACES := [[0, -1], [0, 1], [1, 1], [2, -1], [2, 1]]

var level: LevelDataT = null

## Index of the room the disc is in.
##
## Set `room_provider` to `Callable(sim, "get_room")` and this is refreshed on
## every query. That is not a convenience — it is REQUIRED for correctness. One
## `_substep` is split at every event inside it, so a substep containing a portal
## crossing calls the oracle again, for the remainder, with the disc already in
## the destination room. A `room` written once per frame would hand that second
## call the departure room's geometry, at a world position that may be hundreds
## of metres outside it.
##
## Left as a plain field when no provider is set, so the ghost predictor (which
## is pinned to one room by construction) and the unit tests can drive it
## directly.
var room: int = 0
var room_provider: Callable = Callable()

## Aperture inset, metres. Must equal the sim's `_disc_radius` for the thrown
## disc, or the hole and the crossing test disagree.
var disc_radius: float = 0.105

## Barrier ids currently open. Only barriers with a non-empty `opened_by` can
## ever be in here.
var open_barriers: Dictionary = {}

## Portals to cut holes for, as an array of dictionaries:
## `{room, center (world), facing, up, half_w, half_h, open}`. Built by
## `PuzzleWorld`, which is also what builds the `PortalLink`s, so the two cannot
## describe different rectangles.
var holes: Array = []

## Set when the last reported hit was a portalable panel — a convenience for the
## portal-disc path, which needs the panel and the impact point together.
var last_surface: String = ""

## Ghost mode. With portals SEALED, an aperture stops the disc instead of
## swallowing it, and the hit is reported as `kind: "portal"`. That is how the
## ghost trajectory is truncated at the first portal boundary without the ghost
## sim needing to know what a portal is: it is configured with one room and no
## links, and the portal simply reads as a wall it cannot pass.
var seal_portals: bool = false


func _init(lv: LevelDataT = null) -> void:
	level = lv


func callable() -> Callable:
	return Callable(self, "query")


## `func(from: Vector3, to: Vector3) -> Dictionary`, per PORTAL_CONTRACT §7.
func query(from: Vector3, to: Vector3) -> Dictionary:
	if level == null:
		return {}
	if room_provider.is_valid():
		room = int(room_provider.call())
	var rd: LevelDataT.RoomData = level.get_room(room)
	if rd == null:
		return {}

	var best_f: float = INF
	var best: Dictionary = {}

	var wall := _room_exit(from, to, rd)
	if not wall.is_empty():
		best_f = wall["fraction"]
		best = wall

	for b in rd.barriers:
		var bd: LevelDataT.BarrierData = b
		if not _barrier_solid(bd):
			continue
		var hit := _box_entry(from, to, bd.box_min + rd.world_origin,
			bd.box_max + rd.world_origin)
		if hit.is_empty() or hit["fraction"] >= best_f:
			continue
		best_f = hit["fraction"]
		hit["collider"] = {"kind": "barrier", "id": bd.id, "room": room,
			"portalable": false, "local": (hit["position"] as Vector3) - rd.world_origin}
		best = hit

	last_surface = ""
	if not best.is_empty():
		var c: Dictionary = best["collider"]
		if bool(c.get("portalable", false)):
			last_surface = String(c.get("id", ""))
	return best


func _barrier_solid(b: LevelDataT.BarrierData) -> bool:
	if not b.starts_solid:
		return false
	if b.opened_by.is_empty():
		return true   # permanent (Level 9's lintel)
	return not open_barriers.has(b.id)


## Where the segment leaves the room box, ignoring the floor and any open portal
## aperture. `{}` if it stays inside (or leaves through a hole).
func _room_exit(from: Vector3, to: Vector3, rd: LevelDataT.RoomData) -> Dictionary:
	var lo: Vector3 = rd.world_min()
	var hi: Vector3 = rd.world_max()
	var d: Vector3 = to - from

	var best_f: float = INF
	var axis: int = -1
	var sign: int = 0
	for face in WALL_FACES:
		var i: int = face[0]
		var sg: int = face[1]
		var dd: float = d[i]
		if absf(dd) < 1e-12:
			continue
		var limit: float = hi[i] if sg > 0 else lo[i]
		if (sg > 0 and dd <= 0.0) or (sg < 0 and dd >= 0.0):
			continue
		var f: float = (limit - from[i]) / dd
		if f < 0.0 or f > 1.0 or f >= best_f:
			continue
		best_f = f
		axis = i
		sign = sg
	if axis < 0:
		return {}

	var pos: Vector3 = from + d * best_f
	var nrm := Vector3.ZERO
	nrm[axis] = -float(sign)
	var local: Vector3 = pos - rd.world_origin

	# A portal is set flush into a wall. The hole is the aperture the sim will
	# actually fire on, so a disc in the hole is the portal's business, not ours
	# — unless we are predicting a ghost, where the portal is where we stop.
	var hole: Dictionary = _hole_at(pos)
	if not hole.is_empty():
		if not seal_portals:
			return {}
		return {"fraction": best_f, "position": pos, "normal": nrm,
			"collider": {"kind": "portal", "id": String(hole["id"]), "room": room,
				"portalable": false, "local": local}}

	var col: Dictionary = {"kind": "wall",
		"id": "%s:%s%s" % [rd.id, "-" if sign < 0 else "+", "xyz"[axis]],
		"room": room, "portalable": false, "local": local}
	for s in rd.surfaces:
		var sd: LevelDataT.SurfaceData = s
		if sd.axis != axis:
			continue
		if absf(local[axis] - sd.value) > PLANE_EPS:
			continue
		if not sd.contains_world(pos, rd.world_origin):
			continue
		col = {"kind": "surface", "id": sd.id, "room": room,
			"portalable": sd.portalable, "local": local}
		break
	return {"fraction": best_f, "position": pos, "normal": nrm, "collider": col}


## The open portal whose aperture contains `p`, or `{}`.
func _hole_at(p: Vector3) -> Dictionary:
	for h in holes:
		var hd: Dictionary = h
		if int(hd["room"]) != room or not bool(hd["open"]):
			continue
		var c: Vector3 = hd["center"]
		var n: Vector3 = hd["facing"]
		var d: Vector3 = p - c
		if absf(d.dot(n)) > PLANE_EPS:
			continue
		var u: Vector3 = hd["up"]
		var r: Vector3 = u.cross(n).normalized()
		if absf(d.dot(r)) <= maxf(float(hd["half_w"]) - disc_radius, 0.0) \
				and absf(d.dot(u)) <= maxf(float(hd["half_h"]) - disc_radius, 0.0):
			return hd
	return {}


## Where the segment first enters an axis-aligned box, or `{}`. Slab method; a
## segment that starts inside is reported at fraction 0 with the normal facing
## back the way it came, which stops a disc that is somehow already inside a
## barrier from sailing on through it.
func _box_entry(from: Vector3, to: Vector3, lo: Vector3, hi: Vector3) -> Dictionary:
	var d: Vector3 = to - from
	var t0: float = 0.0
	var t1: float = 1.0
	var axis: int = -1
	var sign: int = 0
	for i in 3:
		if absf(d[i]) < 1e-12:
			if from[i] < lo[i] or from[i] > hi[i]:
				return {}
			continue
		var inv: float = 1.0 / d[i]
		var ta: float = (lo[i] - from[i]) * inv
		var tb: float = (hi[i] - from[i]) * inv
		var sg: int = -1
		if ta > tb:
			var tmp: float = ta
			ta = tb
			tb = tmp
			sg = 1
		if ta > t0:
			t0 = ta
			axis = i
			sign = sg
		t1 = minf(t1, tb)
		if t0 > t1:
			return {}
	if t0 > 1.0 or t1 < 0.0:
		return {}
	var pos: Vector3 = from + d * t0
	var nrm := Vector3.ZERO
	if axis >= 0:
		nrm[axis] = float(sign)
	else:
		nrm = (from - to).normalized()
	return {"fraction": t0, "position": pos, "normal": nrm}

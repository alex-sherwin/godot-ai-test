class_name PortalStage
extends Node3D

## THE SEAM. Track P2 built a portal renderer and proved it in an exported web
## build; Track P3 built the levels, the rooms and the links; Track P4 built the
## UI against a flat-shaded diagram and wrote down that the real renderer was
## not wired in. This file is the wire.
##
## ---------------------------------------------------------------------------
## What it does
## ---------------------------------------------------------------------------
## Takes a `PuzzleLevelData` + the `PuzzleWorld` compiled from it and builds the
## *solid* half of the scene:
##
##   * one `PortalRoom` per room — a box with single-sided inward walls and the
##     portal apertures cut out of it as real holes;
##   * one `Portal` per currently-open portal, at exactly the transform the
##     simulator uses;
##   * a `PortalRenderer` driving two pooled SubViewports, so looking at an
##     aperture shows the destination room from the correct transformed eye;
##   * a `PortalGhost`, so the disc does not pop as it crosses.
##
## `PuzzleLevelPreview` keeps everything else — the grid, the medal rings, the
## flag, the buttons, the barriers, the hatched portalable panels and the flown
## trajectories — drawn flat on top of this. The diagram and the rooms are
## complementary, not alternatives: the diagram is the instrumentation and this
## is the place it is instrumenting.
##
## ---------------------------------------------------------------------------
## One transform, one link object
## ---------------------------------------------------------------------------
## Portal nodes are placed with `PuzzleWorld.transform_of()` and linked with the
## very `PortalLink` objects `PuzzleWorld.links()` hands to
## `DiscFlightSim.configure_rooms()`. Not an equivalent transform computed the
## same way — the same object. A portal camera at `p.to_peer * eye` and a disc
## crossing at `link.transform` therefore cannot disagree, and if the
## determinant guard ever repairs a link the picture is repaired with it.
##
## ---------------------------------------------------------------------------
## Why the rooms can be solid and you can still see the disc
## ---------------------------------------------------------------------------
## `PortalRoom`'s walls are single-sided and face INWARD, so from outside a room
## they are back-face culled and simply are not there. A camera behind the tee,
## or above the level, therefore looks straight into every room; the only wall
## that ever occludes anything is the one the camera is *inside*, which is the
## wall the portal is cut into. That is the entire game, and it is also leg (c)
## of PORTAL_CONTRACT §8's fallback for the oblique near plane Godot cannot
## express.

const LevelDataT := preload("res://scripts/puzzle/level_data.gd")
const WorldT := preload("res://scripts/puzzle/puzzle_world.gd")
const Facts := preload("res://scripts/ui/puzzle/level_facts.gd")

## Room palettes, cycled. Each room gets its own so "which room am I looking
## into" is answerable from a still frame — the question the player asks every
## time they line up a throw through an aperture.
const ROOM_TINTS: Array[Color] = [
	Color(0.46, 0.55, 0.72),
	Color(0.42, 0.64, 0.60),
	Color(0.60, 0.50, 0.70),
	Color(0.68, 0.58, 0.44),
]

## Margin around a cut aperture, metres. Large enough that the wall never shows
## a hairline of itself inside the frame, small enough that `Portal`'s frame
## bars still cover the gap (they are at least 0.10 m wide).
const APERTURE_MARGIN := 0.06

## Puzzle rooms are up to 120 m across and the camera can sit 250 m back, so
## the per-room exponential fog `PortalRoom` defaults to would swallow the
## level. Rooms carry their identity in tint and vertex shading instead.
const FOG_DENSITY := 0.0

## Inset of a room's streamer volume from its own walls, metres. Keeps the
## streaks off the shell so nothing z-fights the grid and nothing pokes through
## a wall into the void between rooms — which WOULD be visible, because the
## shell is single-sided and back-face culled from outside. Sized against the
## two things that reach past the swept box: half a streak's length (up to about
## 3 m) and the 2° spawn spread over a 50 m sweep (under 2 m).
const WIND_INSET := 3.5

var renderer: PortalRenderer = null
var ghost: PortalGhost = null

var rooms: Array[PortalRoom] = []
var portals: Array[Portal] = []
## One per room that actually has moving air, so a level with two calm chambers
## and one windy one pays for one. Parallel to nothing — look them up by
## `room_index` on the node, or just read `stats()["windy_rooms"]`.
var wind_visuals: Array[WindVisualizer] = []
## Per-room Environment for the MAIN camera, and the LINEAR-tonemap copy a
## PORTAL camera must use. Indexed by room index.
var environments: Array[Environment] = []
var portal_environments: Array[Environment] = []

var problems: PackedStringArray = PackedStringArray()

var _level: LevelDataT = null
var _world: WorldT = null
var _camera: Camera3D = null
var _by_id: Dictionary = {}


func _ready() -> void:
	renderer = PortalRenderer.new()
	renderer.name = "PortalRenderer"
	add_child(renderer)
	ghost = PortalGhost.new()
	ghost.name = "DiscGhost"
	add_child(ghost)
	ghost.visible = false
	if _camera != null:
		renderer.attach_main_camera(_camera)


## `remove_child` BEFORE `queue_free`, and this is not defensive tidying.
## `queue_free` defers deletion to the end of the frame, so a node freed that way
## is still a child while the replacements are added — which means the old
## aperture is still drawn for a frame, and Godot renames the new node to avoid
## the name collision. That renaming is how this was found: the diagnostic line
## reported `@Node3D@443` instead of `Portal_p1a` after a rebuild.
static func _drop(n: Node) -> void:
	if n == null or not is_instance_valid(n):
		return
	var parent := n.get_parent()
	if parent != null:
		parent.remove_child(n)
	n.queue_free()


## The main camera. Also fixes its cull mask so it sees live apertures and not
## the flat depth-1 stand-ins.
func attach_camera(cam: Camera3D) -> void:
	_camera = cam
	if renderer != null:
		renderer.attach_main_camera(cam)


## The disc mesh the ghost clones and clips. Its material_override is REPLACED,
## because the clip has to apply to the real mesh as well as to the clone.
func attach_disc(disc: MeshInstance3D, colour: Color) -> void:
	if ghost != null and disc != null:
		ghost.setup(disc, colour)
		ghost.visible = false


# ===================================================================== build ===

## Full rebuild: rooms, apertures, portals, links. Call on level load.
func build(level: LevelDataT, world: WorldT) -> void:
	_level = level
	_world = world
	problems = PackedStringArray()
	if renderer != null:
		renderer.clear_portals()
	for wv: WindVisualizer in wind_visuals:
		_drop(wv)
	for r: PortalRoom in rooms:
		_drop(r)
	for p: Portal in portals:
		_drop(p)
	rooms.clear()
	portals.clear()
	wind_visuals.clear()
	environments.clear()
	portal_environments.clear()
	_by_id.clear()
	if level == null or world == null:
		return

	for i in level.rooms.size():
		var rd: LevelDataT.RoomData = level.rooms[i]
		var room := PortalRoom.new()
		room.name = "Room%d_%s" % [i, rd.id]
		room.size = rd.size()
		room.tint = ROOM_TINTS[i % ROOM_TINTS.size()]
		room.fog_density = FOG_DENSITY
		room.ambient_energy = 0.62
		room.room_index = i
		room.position = rd.world_center()
		add_child(room)
		room.build_shared()
		rooms.append(room)
		environments.append(room.environment)
		portal_environments.append(room.portal_environment)
		_build_room_wind(i, rd)

	# A portal must still be worth a render pass from the overview camera, which
	# `PuzzleLevelPreview._fit_distance()` puts a level-radius away. Level 10 is
	# 290 m across, so the renderer's 110 m default — sized for the 30 m test
	# pair — would leave every aperture dark in the one view that explains the
	# level. `SLOTS` still bounds the cost at two passes.
	var span := AABB()
	for i in level.rooms.size():
		var rd2: LevelDataT.RoomData = level.rooms[i]
		var box := AABB(rd2.world_min(), rd2.world_max() - rd2.world_min())
		span = box if i == 0 else span.merge(box)
	if renderer != null:
		renderer.max_render_distance = clampf(span.size.length() * 1.6, 110.0, 900.0)

	_build_portals()


## PER-ROOM AIR, MADE VISIBLE. Every room carries its own wind vector and
## several levels are built entirely around the fact that the room behind the
## portal has different air — Level 1 is a calm tee chamber looking into a 6 m/s
## crosswind, Level 4 turns the corner twice through two differently-blown
## galleries. The conditions panel says so in words; this makes the player able
## to SEE the crosswind through the aperture before committing to a throw,
## because the streamers live in the room and the portal camera is on
## `LAYER_WORLD`.
##
## Driven by `rd.env.wind` — the very field `PuzzleWorld._environment()` copies
## into the `FlightEnvironment` the simulator integrates, so the streamers and
## the flight cannot disagree.
##
## A calm room gets NO node at all: no cost, and — more importantly — a level
## whose point is "this room is windy and that one is not" should read that way
## at a glance, which it does not if both rooms shimmer. Streamers are also the
## one thing here that can be drawn twice (once directly, once inside a portal
## view), so this is the object worth being stingy with.
func _build_room_wind(index: int, rd: LevelDataT.RoomData) -> void:
	if rd.env == null or rd.env.wind.length() < WindVisualizer.STREAMER_MIN_WIND:
		return
	var size: Vector3 = rd.size()
	var inset: float = minf(WIND_INSET, size.y * 0.25)
	var wv := WindVisualizer.new()
	wv.name = "Wind%d_%s" % [index, rd.id]
	# Instruments off: a windsock in every chamber is eight draw calls saying
	# what the conditions panel already says. Ambient drift off: see above.
	wv.instruments = false
	wv.ambient_when_calm = false
	wv.position = rd.world_center()
	add_child(wv)
	# No distance fade: the overview camera sits a level-radius back — 250 m on
	# Level 10 — and that view is exactly the one that has to show three rooms'
	# air at once. A room's streamers always have one of its own walls behind
	# them, so the sky-scratch problem the fade solves outdoors cannot happen.
	wv.configure_fade(0.0, 0.0)
	# The room's own interior, minus a margin, in the visualiser's local space —
	# which is room-centred because the node sits at `world_center()`.
	wv.configure_volume(Vector3.ZERO, size * 0.5 - Vector3(inset, inset, inset))
	wv.set_wind(rd.env.wind)
	wind_visuals.append(wv)


## Portals and only portals. A portal disc opens an aperture and a button opens
## a barrier, both of which change which portals exist and which are open, so
## this runs again between throws while the rooms stay put. It re-cuts the room
## shells, which is why `PortalRoom.rebuild_shell()` is idempotent.
func rebuild_portals() -> void:
	if _level == null or _world == null:
		return
	if renderer != null:
		renderer.clear_portals()
	for p: Portal in portals:
		_drop(p)
	portals.clear()
	_by_id.clear()
	for room: PortalRoom in rooms:
		room.clear_apertures()
	_build_portals()


func _build_portals() -> void:
	# Authored order, so slot selection and anything downstream of it is
	# reproducible (PORTAL_CONTRACT §5 asks the same of the physics side).
	for p in _world.portals:
		var pd: LevelDataT.PortalData = p
		if not _world.portal_open(pd):
			continue
		var room_index: int = pd.room
		if room_index < 0 or room_index >= rooms.size():
			problems.append("portal '%s': no room %d" % [pd.id, room_index])
			continue
		var room: PortalRoom = rooms[room_index]
		var xf: Transform3D = _world.transform_of(pd)

		var portal := Portal.new()
		portal.name = "Portal_%s" % pd.id
		portal.width = pd.width_m
		portal.height = pd.height_m
		portal.room_index = room_index
		# THE dive-portal identity fix. P3's data marks only the physically
		# inverted END of the pair, because that is the end whose `up` is world
		# DOWN — but the player throws into the OTHER one and never sees the
		# marked end until the disc is already falling. `Facts.portal_dives`
		# marks both, exactly as `PuzzleLevelPreview` does, so the aperture at
		# the tee wears the orange chevrons that say what is about to happen.
		portal.kind = Portal.Kind.DISC if not pd.placed_by.is_empty() \
			else (Portal.Kind.DIVE if Facts.portal_dives(_level, pd) else Portal.Kind.NORMAL)
		add_child(portal)
		portal.global_transform = xf
		portal.build()
		portals.append(portal)
		_by_id[pd.id] = portal

		var cut: Variant = _aperture_of(_level.get_room(room_index), pd, xf)
		if cut == null:
			problems.append("portal '%s' is not flush in any wall of room %d"
				% [pd.id, room_index])
		else:
			var c: Array = cut
			room.add_aperture(int(c[0]), c[1] as Rect2)

	# Apertures are cut before the shell is built, so every portal has to be
	# placed before any room can be re-shelled.
	for room: PortalRoom in rooms:
		room.rebuild_shell()

	_link_pairs()

	if renderer != null:
		renderer.room_environments = portal_environments
		for portal: Portal in portals:
			renderer.register(portal)


## Link every open pair using P3's own `PortalLink` objects — see the class
## comment. A portal whose partner has not been opened yet (a portal disc that
## has not been thrown) simply has no peer and renders as a flat stand-in.
func _link_pairs() -> void:
	for p in _world.portals:
		var pd: LevelDataT.PortalData = p
		var a: Portal = _by_id.get(pd.id) as Portal
		var b: Portal = _by_id.get(pd.link) as Portal
		if a == null or b == null:
			continue
		var lk: RefCounted = _world.link_for(pd.id, pd.link)
		if lk == null:
			continue
		a.adopt_link(b, lk)
		if a.link_error != "":
			problems.append(a.link_error)


## Which face of the room a portal is mounted in, and the rectangle to cut out
## of it, in that face's own (u, v) metres with the origin at the face centre.
## Returns null when the portal is not on any wall — which is a level-data
## error, not something to silently paper over.
static func _aperture_of(rd: LevelDataT.RoomData, pd: LevelDataT.PortalData,
		xf: Transform3D) -> Variant:
	var face := _face_of(pd.facing)
	if face < 0:
		return null
	var basis: Array = PortalRoom.FACE_BASIS[face]
	var rel: Vector3 = xf.origin - rd.world_center()
	# The portal must actually lie ON that wall, not merely face the same way.
	var half: Vector3 = rd.size() * 0.5
	var n: Vector3 = basis[0]
	if absf(absf(rel.dot(n)) - absf(half.dot(n.abs()))) > 0.5:
		return null
	var u: float = rel.dot(basis[1] as Vector3)
	var v: float = rel.dot(basis[2] as Vector3)
	var m := APERTURE_MARGIN
	return [face, Rect2(u - pd.width_m * 0.5 - m, v - pd.height_m * 0.5 - m,
		pd.width_m + m * 2.0, pd.height_m + m * 2.0)]


## `facing` points INTO the room, which is exactly how `PortalRoom.FACE_BASIS`
## defines a face's normal, so the mapping is a direct lookup on the dominant
## axis.
static func _face_of(facing: Vector3) -> int:
	var ax := 0
	var best := absf(facing.x)
	if absf(facing.y) > best:
		ax = 1
		best = absf(facing.y)
	if absf(facing.z) > best:
		ax = 2
		best = absf(facing.z)
	if best < 0.5:
		return -1
	var positive: bool = facing[ax] > 0.0
	match ax:
		0:
			return PortalRoom.Face.WEST if positive else PortalRoom.Face.EAST
		1:
			return PortalRoom.Face.FLOOR if positive else PortalRoom.Face.CEILING
		_:
			return PortalRoom.Face.NORTH if positive else PortalRoom.Face.SOUTH
	return -1


# ================================================================== per-frame ===

## Where the disc is, so the renderer spends its two slots on the portals the
## disc is approaching rather than on whichever happens to be biggest on screen.
func set_focus(point: Vector3) -> void:
	if renderer != null:
		renderer.set_focus(point)


func clear_focus() -> void:
	if renderer != null:
		renderer.clear_focus()


## Drive the crossing ghost. Call once a frame with the disc's transform, after
## the simulation has moved it; `visible = false` when nothing is in flight.
func track_disc(xform: Transform3D, flying: bool) -> void:
	if ghost == null:
		return
	if not flying:
		ghost.track(xform, ([] as Array[Portal]))
		ghost.visible = false
		return
	ghost.track(xform, portals)


func set_enabled(on: bool) -> void:
	if renderer != null:
		renderer.enabled = on


## The Environment the MAIN camera should use for a viewpoint. Rooms do not
## overlap, so a linear scan over a handful of boxes is the whole of the
## "which room am I in" problem; outside every room, the first room's air.
func environment_at(p: Vector3) -> Environment:
	if _level == null or environments.is_empty():
		return null
	for i in _level.rooms.size():
		var rd: LevelDataT.RoomData = _level.rooms[i]
		var lo := rd.world_min()
		var hi := rd.world_max()
		if p.x >= lo.x and p.x <= hi.x and p.y >= lo.y and p.y <= hi.y \
				and p.z >= lo.z and p.z <= hi.z:
			return environments[i]
	return environments[0]


func portal_by_id(id: String) -> Portal:
	return _by_id.get(id) as Portal


## The on-screen rectangle of the largest LIVE portal aperture, or an empty
## dictionary when none is being rendered.
##
## This exists to be printed. A headless browser has no DOM to query inside the
## canvas, so the console is the only place a rendering claim can be asserted
## from outside the engine — and "a portal is live" is not the claim that
## matters. godot#86258 reports SubViewport textures rendering BLACK in exported
## builds specifically, which is this repository's historical failure mode: fine
## locally, broken only in the browser. Printing where to sample turns "you can
## see through the portal" into something a driver can measure in pixels instead
## of something a screenshot has to be eyeballed for.
func live_portal_rect() -> Dictionary:
	if _camera == null or renderer == null:
		return {}
	var best := {}
	var best_area := 0.0
	for p: Portal in portals:
		if p == null or not is_instance_valid(p) or p.peer == null:
			continue
		if not p.is_in_front(_camera.global_position):
			continue
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		var behind := false
		for v: Vector3 in p.corners():
			if _camera.is_position_behind(v):
				behind = true
				break
			var s := _camera.unproject_position(v)
			lo = lo.min(s)
			hi = hi.max(s)
		if behind or not lo.is_finite() or not hi.is_finite():
			continue
		var area: float = (hi.x - lo.x) * (hi.y - lo.y)
		if area > best_area:
			best_area = area
			best = {"id": p.name, "x": lo.x, "y": lo.y,
				"w": hi.x - lo.x, "h": hi.y - lo.y, "kind": int(p.kind)}
	return best


func stats() -> Dictionary:
	var s: Dictionary = renderer.debug_stats() if renderer != null else {}
	s["rooms"] = rooms.size()
	s["portals"] = portals.size()
	s["windy_rooms"] = wind_visuals.size()
	s["problems"] = problems.size()
	return s

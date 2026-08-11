class_name PortalLevel
extends Node3D

## Builds a puzzle level — rooms, portals, links, spawn — from level data, and
## hands the result to a `PortalRenderer`.
##
## ---------------------------------------------------------------------------
## Provisional schema
## ---------------------------------------------------------------------------
## Track P3 owns `data/levels/**` and will define the real schema. Until then
## this reads the shape below, which is written straight from PORTAL_CONTRACT §7
## and is deliberately tolerant: unknown keys are ignored, missing keys fall
## back, and a level that fails to parse yields the hand-authored test pair
## rather than an empty scene. When P3's schema lands, `_parse` is the only
## function that should need to change.
##
##   {
##     "name":  "two rooms",
##     "rooms": [ { "name": "A", "size": [16, 6, 26], "origin": [0, 0, 0],
##                  "tint": "#7f93ad", "fog_density": 0.010 } ],
##     "portals": [ { "id": "a1", "room": 0, "face": "north",
##                    "u": 0.0, "v": -1.0, "width": 2.4, "height": 3.0,
##                    "kind": "normal" } ],
##     "links": [ ["a1", "b1"], ["b1", "a1"] ],
##     "spawn": { "position": [0, 1.5, 9] }          // world metres
##   }
##
## `links` is a list of ORDERED pairs, not a list of couples: a one-way portal
## is a legitimate puzzle piece, so linking B back to A is something the level
## says explicitly.
##
## `face` / `u` / `v` mount a portal flush in a wall (see
## `PortalRoom.mount_transform`), which is also what keeps wall-to-wall pairs
## pure yaw and therefore free of the flight change described in contract §6.

const PortalLinkT := preload("res://scripts/physics/portal_link.gd")

const FACE_NAMES := {
	"west": PortalRoom.Face.WEST, "east": PortalRoom.Face.EAST,
	"floor": PortalRoom.Face.FLOOR, "ceiling": PortalRoom.Face.CEILING,
	"north": PortalRoom.Face.NORTH, "south": PortalRoom.Face.SOUTH,
}
const KIND_NAMES := {
	"normal": Portal.Kind.NORMAL, "dive": Portal.Kind.DIVE,
	"disc": Portal.Kind.DISC,
}

var rooms: Array[PortalRoom] = []
var portals: Array[Portal] = []
var environments: Array[Environment] = []
var portal_environments: Array[Environment] = []
var spawn_transform: Transform3D = Transform3D.IDENTITY
var level_name: String = ""
var load_errors: PackedStringArray = PackedStringArray()

var _by_id: Dictionary = {}


## Load from `res://data/levels/<id>.json` if Track P3 has landed it, otherwise
## build the hand-authored pair. Never returns an empty level.
func load_level(path: String) -> void:
	var data: Dictionary = {}
	if path != "" and ResourceLoader.exists(path):
		var text := FileAccess.get_file_as_string(path)
		var parsed: Variant = JSON.parse_string(text)
		if parsed is Dictionary:
			data = parsed
		else:
			load_errors.append("%s did not parse as a JSON object" % path)
	if data.is_empty():
		if path != "":
			load_errors.append("%s missing; using the built-in test pair" % path)
		data = hand_authored()
	_parse(data)


## The one hand-authored level: two rooms, a normal pair and a dive pair. This
## is what proves the renderer works before there is any level content, and it
## stays as the fallback afterwards.
static func hand_authored() -> Dictionary:
	return {
		"name": "test pair",
		"rooms": [
			{"name": "Blue", "size": [18.0, 6.0, 30.0], "origin": [0.0, 3.0, 0.0],
				"tint": "#5d7fa8", "fog_density": 0.008},
			{"name": "Amber", "size": [18.0, 6.0, 30.0], "origin": [40.0, 3.0, 0.0],
				"tint": "#a8875d", "fog_density": 0.020},
		],
		"portals": [
			{"id": "a_far", "room": 0, "face": "north", "u": -4.0, "v": -1.0,
				"width": 2.6, "height": 3.2, "kind": "normal"},
			{"id": "b_near", "room": 1, "face": "south", "u": -4.0, "v": -1.0,
				"width": 2.6, "height": 3.2, "kind": "normal"},
			{"id": "a_dive", "room": 0, "face": "north", "u": 4.5, "v": -1.0,
				"width": 2.6, "height": 3.2, "kind": "dive"},
			{"id": "b_dive", "room": 1, "face": "ceiling", "u": 4.5, "v": 2.0,
				"width": 2.6, "height": 3.2, "kind": "dive"},
		],
		"links": [["a_far", "b_near"], ["b_near", "a_far"],
			["a_dive", "b_dive"], ["b_dive", "a_dive"]],
		"spawn": {"position": [0.0, 1.6, 11.0]},
	}


func _parse(data: Dictionary) -> void:
	level_name = str(data.get("name", "level"))

	for i in (data.get("rooms", []) as Array).size():
		var rd: Dictionary = data["rooms"][i]
		var r := PortalRoom.new()
		r.name = "Room%d_%s" % [i, str(rd.get("name", ""))]
		r.size = _vec3(rd.get("size", [16.0, 6.0, 26.0]), Vector3(16.0, 6.0, 26.0))
		r.tint = Color.from_string(str(rd.get("tint", "#7f93ad")), Color(0.5, 0.58, 0.68))
		r.fog_density = float(rd.get("fog_density", 0.010))
		r.ambient_energy = float(rd.get("ambient_energy", 0.85))
		r.room_index = i
		r.position = _vec3(rd.get("origin", [0.0, 0.0, 0.0]), Vector3.ZERO)
		add_child(r)
		r.build_shared()
		rooms.append(r)
		environments.append(r.environment)
		portal_environments.append(r.portal_environment)

	for pd_v: Variant in (data.get("portals", []) as Array):
		var pd: Dictionary = pd_v
		var room_index: int = int(pd.get("room", 0))
		if room_index < 0 or room_index >= rooms.size():
			load_errors.append("portal %s: no room %d" % [str(pd.get("id", "?")), room_index])
			continue
		var room: PortalRoom = rooms[room_index]
		var face: int = FACE_NAMES.get(str(pd.get("face", "north")).to_lower(),
			PortalRoom.Face.NORTH)
		var w := float(pd.get("width", 2.4))
		var h := float(pd.get("height", 3.0))
		var u := float(pd.get("u", 0.0))
		var v := float(pd.get("v", 0.0))

		var p := Portal.new()
		p.name = "Portal_%s" % str(pd.get("id", "p%d" % portals.size()))
		p.width = w
		p.height = h
		p.kind = KIND_NAMES.get(str(pd.get("kind", "normal")).to_lower(), Portal.Kind.NORMAL)
		p.room_index = room_index
		add_child(p)
		p.global_transform = room.mount_transform(face, u, v)
		p.build()
		# The hole is cut with a little margin so the wall never shows a hairline
		# of itself inside the frame.
		room.add_aperture(face, Rect2(u - w * 0.5 - 0.02, v - h * 0.5 - 0.02,
			w + 0.04, h + 0.04))
		portals.append(p)
		_by_id[str(pd.get("id", p.name))] = p

	# Apertures are cut before the shell is built, so the shell has to wait for
	# every portal to be placed. Rooms are built empty above and re-shelled here.
	for r: PortalRoom in rooms:
		r.rebuild_shell()

	for link_v: Variant in (data.get("links", []) as Array):
		var link: Array = link_v
		if link.size() != 2:
			continue
		var a := _by_id.get(str(link[0])) as Portal
		var b := _by_id.get(str(link[1])) as Portal
		if a == null or b == null:
			load_errors.append("link %s -> %s: unknown id" % [str(link[0]), str(link[1])])
			continue
		a.link(b)
		if a.link_error != "":
			load_errors.append(a.link_error)

	# Spawn is in WORLD metres. Rooms carry their own origin, so making spawn
	# room-relative would mean two conventions in one file for no gain.
	var sp: Dictionary = data.get("spawn", {})
	spawn_transform = Transform3D(Basis.IDENTITY,
		_vec3(sp.get("position", [0.0, 1.6, 8.0]), Vector3(0.0, 1.6, 8.0)))


## Hand every portal to the renderer, along with the per-room environments.
func attach_to(renderer: PortalRenderer) -> void:
	renderer.room_environments = portal_environments
	for p: Portal in portals:
		renderer.register(p)


## Which room contains `p`, or -1. Rooms are boxes and do not overlap, so a
## linear scan over a handful of them is the whole of the "which room am I in"
## problem.
func room_at(p: Vector3) -> int:
	for i in rooms.size():
		var r: PortalRoom = rooms[i]
		var h := r.size * 0.5
		var l := p - r.global_position
		if absf(l.x) <= h.x and absf(l.y) <= h.y and absf(l.z) <= h.z:
			return i
	return -1


## The Environment of the room containing `p`. Assign it to the MAIN camera as
## the player moves between rooms; portal cameras get the destination room's
## through `PortalRenderer.room_environments`.
func environment_at(p: Vector3) -> Environment:
	var i := room_at(p)
	if i < 0:
		return environments[0] if not environments.is_empty() else null
	return environments[i]


## The `PortalLink`s for every linked portal, in a STABLE order — the order the
## level file declares them in. Feed this straight to
## `DiscFlightSim.configure_rooms()`: the rendering and the simulation then use
## the same objects, so the picture and the flight cannot disagree, and
## `test_determinism.gd`'s requirement that portal iteration order be fixed
## (contract §5) is satisfied by construction rather than by convention.
func links() -> Array:
	var out: Array = []
	for p: Portal in portals:
		if p.link_data != null:
			out.append(p.link_data)
	return out


## Every problem found while building the level, for a dev overlay. Empty is the
## only acceptable value in a shipped level, and it is the level tests' job to
## say so — a portal pair silently repaired by the determinant guard renders
## fine and flies wrong.
func problems() -> PackedStringArray:
	var out := load_errors.duplicate()
	for p: Portal in portals:
		if p.link_error != "":
			out.append(p.link_error)
	return out


func portal_by_id(id: String) -> Portal:
	return _by_id.get(id) as Portal


## Runtime placement (contract §7). Immutability is the caller's job: portals
## must not move while a disc is in flight, so a placement is queued by the
## puzzle layer and applied here when nothing is airborne.
func place_disc_portal(id: String, hit_position: Vector3, hit_normal: Vector3,
		travel_dir: Vector3, room_index: int, w: float = 2.2, h: float = 2.8) -> Portal:
	var p := _by_id.get(id) as Portal
	if p == null:
		p = Portal.new()
		p.name = "DiscPortal_%s" % id
		p.width = w
		p.height = h
		p.kind = Portal.Kind.DISC
		add_child(p)
		p.build()
		portals.append(p)
		_by_id[id] = p
	p.room_index = room_index
	# Track P1's basis: +Z = n̂, world-up projected into the plane, the
	# floor/ceiling fallback taking the disc's travel direction as its hint, and
	# the 1 mm surface lift. Contract §7, one implementation.
	p.global_transform = PortalLinkT.transform_from_surface_hit(
		hit_position, hit_normal, travel_dir)
	return p


static func _vec3(v: Variant, fallback: Vector3) -> Vector3:
	if v is Array and (v as Array).size() >= 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return fallback

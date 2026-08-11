class_name PuzzleLevelPreview
extends Node3D

## The 3D view puzzle mode is played against: rooms, portals, portalable panels,
## barriers, buttons, tee and flag, drawn in the one shared world Track P3's
## `PuzzleLevelData` defines (`world = local + rooms[].world_origin`, translation
## only). Because that is the *simulator's* frame, a disc's position needs no
## mapping to be drawn — which is the whole reason to use it rather than a
## picture-only layout.
##
## ---------------------------------------------------------------------------
## Scope, and the seam to Track P2
## ---------------------------------------------------------------------------
## P2 owns portal *rendering* — the real thing, with the far side visible through
## the aperture. This is not that. It is a diagram you can fly through, built
## from the level data so the aim, the ghost and the HUD have something true to
## sit on. Everything is unshaded flat colour: no lights, no shadows, no render
## targets, nothing outside the GL Compatibility feature set, and cheap enough
## that the whole level is three draw calls plus one per button.
##
## ---------------------------------------------------------------------------
## Colour is the whole legend (LEVEL_DESIGN §1)
## ---------------------------------------------------------------------------
##   blue rim, chevrons pointing up      a normal portal
##   ORANGE rim, chevrons pointing DOWN  a DIVE portal — and nothing else in the
##                                       scene is ever that colour
##   pale hatched panel                  a portalable surface
##   translucent red slab                a barrier that is currently solid
##   amber sphere, green when armed      a button
##
## The dive portal's identity is load-bearing, not decorative: a disc through one
## loses 40-45% of its distance and lands in under three seconds
## (PORTAL_CONTRACT §6), and no amount of looking at the geometry will tell you
## that.

const T := preload("res://scripts/ui/flight_lab_theme.gd")
const PT := preload("res://scripts/ui/puzzle/puzzle_theme.gd")
const LevelDataT := preload("res://scripts/puzzle/level_data.gd")
const WorldT := preload("res://scripts/puzzle/puzzle_world.gd")
const Facts := preload("res://scripts/ui/puzzle/level_facts.gd")

const GRID_SPACING := 10.0
const RIM_THICKNESS := 0.45

## Portals are set INTO a wall and share its plane exactly. GL Compatibility has
## 24-bit depth and no reverse-Z (PORTAL_CONTRACT §7), so coplanar geometry
## z-fights and the wall wins about half the time — measured: the aperture and
## its rim vanished entirely at 20 m, leaving three floating chevrons. The
## contract's 1e-3 lift is for a raycast hit; a whole quad seen at 100 m needs
## considerably more.
const PORTAL_LIFT_M := 0.06

## Room tints, cycled. Enough separation that two rooms laid end to end read as
## two rooms, little enough that the level still reads as one space.
const ROOM_TINTS: Array[Color] = [
	Color(0.115, 0.140, 0.190),
	Color(0.098, 0.155, 0.178),
	Color(0.142, 0.122, 0.186),
]

var camera: Camera3D = null

var _static_solid: MeshInstance3D = null
var _static_glass: MeshInstance3D = null
var _static_wire: MeshInstance3D = null
var _portal_node: MeshInstance3D = null
var _barrier_node: MeshInstance3D = null
var _buttons_root: Node3D = null
var _paths: Node3D = null
var _disc: MeshInstance3D = null

var _level: LevelDataT = null
var _world: WorldT = null
var _bounds := AABB()
var _button_nodes: Dictionary = {}


func _ready() -> void:
	var env_node := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = T.BG
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color.WHITE
	e.ambient_light_energy = 1.0
	env_node.environment = e
	add_child(env_node)

	camera = Camera3D.new()
	camera.fov = 62.0
	camera.near = 0.25
	camera.far = 3000.0
	add_child(camera)

	_buttons_root = Node3D.new()
	add_child(_buttons_root)
	_paths = Node3D.new()
	add_child(_paths)

	_disc = MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.85
	mesh.height = 0.5
	mesh.radial_segments = 16
	mesh.rings = 6
	_disc.mesh = mesh
	_disc.material_override = _flat(false)
	_disc.visible = false
	add_child(_disc)


# ==================================================================== build ===

func build(level: LevelDataT, world: WorldT) -> void:
	_level = level
	_world = world
	_button_nodes.clear()
	clear_flight_paths()
	for node in [_static_solid, _static_glass, _static_wire]:
		if node != null:
			node.queue_free()
	for child in _buttons_root.get_children():
		child.queue_free()

	var solid := SurfaceTool.new()
	solid.begin(Mesh.PRIMITIVE_TRIANGLES)
	var glass := SurfaceTool.new()
	glass.begin(Mesh.PRIMITIVE_TRIANGLES)
	var wire := SurfaceTool.new()
	wire.begin(Mesh.PRIMITIVE_LINES)

	_bounds = AABB()
	var first := true
	for i in level.rooms.size():
		var room: LevelDataT.RoomData = level.rooms[i]
		_room(solid, wire, room, ROOM_TINTS[i % ROOM_TINTS.size()])
		var box := AABB(room.world_min(), room.world_max() - room.world_min())
		_bounds = box if first else _bounds.merge(box)
		first = false
	for i in level.rooms.size():
		_surfaces(solid, wire, level.rooms[i])
	_markers(solid, wire)

	_static_solid = _attach(solid, false)
	_static_glass = _attach(glass, true)
	_static_wire = _attach(wire, true)

	_build_buttons()
	rebuild_dynamic()


## Portals and barriers change between throws — a button opens a gate, a portal
## disc opens an aperture — so they are their own meshes and are rebuilt rather
## than baked into the static geometry.
func rebuild_dynamic() -> void:
	for node in [_portal_node, _barrier_node]:
		if node != null:
			node.queue_free()
	if _level == null:
		return
	var portals := SurfaceTool.new()
	portals.begin(Mesh.PRIMITIVE_TRIANGLES)
	_portals(portals)
	_portal_node = _attach(portals, true)

	var barriers := SurfaceTool.new()
	barriers.begin(Mesh.PRIMITIVE_TRIANGLES)
	_barriers(barriers)
	_barrier_node = _attach(barriers, true)


func _attach(st: SurfaceTool, transparent: bool) -> MeshInstance3D:
	var mesh: ArrayMesh = st.commit()
	if mesh == null or mesh.get_surface_count() == 0:
		return null
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _flat(transparent)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	move_child(mi, 0)
	return mi


func _flat(transparent: bool, albedo: Color = Color.WHITE) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.albedo_color = albedo
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	if transparent:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	return m


# ---------------------------------------------------------------- pieces ---

func _room(solid: SurfaceTool, wire: SurfaceTool, room: LevelDataT.RoomData,
		tint: Color) -> void:
	var lo := room.world_min()
	var hi := room.world_max()
	_quad(solid, Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z),
		Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z), tint)

	# A 10 m grid, so distance is countable by eye rather than only readable off
	# a number.
	var grid := Color(1, 1, 1, 0.13)
	var x := ceilf(lo.x / GRID_SPACING) * GRID_SPACING
	while x <= hi.x:
		_line(wire, Vector3(x, lo.y + 0.02, lo.z), Vector3(x, lo.y + 0.02, hi.z), grid)
		x += GRID_SPACING
	var z := ceilf(lo.z / GRID_SPACING) * GRID_SPACING
	while z <= hi.z:
		_line(wire, Vector3(lo.x, lo.y + 0.02, z), Vector3(hi.x, lo.y + 0.02, z), grid)
		z += GRID_SPACING

	# The cage, not filled walls: the point of laying the rooms out end to end is
	# that you can see where the disc is going, and a solid far wall hides it.
	_box_outline(wire, AABB(lo, hi - lo), Color(0.42, 0.52, 0.68, 0.55))


func _surfaces(solid: SurfaceTool, wire: SurfaceTool, room: LevelDataT.RoomData) -> void:
	for s in room.surfaces:
		var surface: LevelDataT.SurfaceData = s
		var corners := _surface_corners(surface, room.world_origin)
		if corners.size() < 4:
			continue
		if surface.portalable:
			_quad(solid, corners[0], corners[1], corners[2], corners[3],
				Color(0.70, 0.75, 0.82, 1.0))
			for i in 4:
				_line(wire, corners[i], corners[(i + 1) % 4], Color(1, 1, 1, 0.9))
			# Diagonal hatching: the one thing separating "a wall you may open a
			# portal on" from "a wall that happens to be pale".
			var u := corners[1] - corners[0]
			var v := corners[3] - corners[0]
			for i in range(1, 10):
				var f := float(i) / 10.0
				_line(wire, corners[0] + u * f, corners[0] + v * f, Color(1, 1, 1, 0.18))
		else:
			_quad(solid, corners[0], corners[1], corners[2], corners[3],
				Color(0.10, 0.11, 0.14, 1.0))
			for i in 4:
				_line(wire, corners[i], corners[(i + 1) % 4], Color(0.35, 0.42, 0.55, 0.5))


## `SurfaceData` gives the plane axis plus a rectangle over the other two axes.
static func _surface_corners(s: LevelDataT.SurfaceData, origin: Vector3) -> PackedVector3Array:
	var out := PackedVector3Array()
	var a := (s.axis + 1) % 3
	var b := (s.axis + 2) % 3
	for uv: Array in [[false, false], [true, false], [true, true], [false, true]]:
		var p := Vector3.ZERO
		p[s.axis] = s.value
		p[a] = s.rect_max[a] if bool(uv[0]) else s.rect_min[a]
		p[b] = s.rect_max[b] if bool(uv[1]) else s.rect_min[b]
		out.append(p + origin)
	return out


func _barriers(glass: SurfaceTool) -> void:
	for room in _level.rooms:
		var r: LevelDataT.RoomData = room
		for b in r.barriers:
			var barrier: LevelDataT.BarrierData = b
			var open: bool = _world != null and _world.open_barriers.has(barrier.id)
			var box := AABB(barrier.box_min + r.world_origin, barrier.box_max - barrier.box_min)
			if open:
				# An opened barrier leaves its frame behind, so the player can
				# see what they unlocked rather than watch it vanish.
				_box_edges(glass, box, Color(PT.BUTTON_ARMED.r, PT.BUTTON_ARMED.g,
					PT.BUTTON_ARMED.b, 0.55), 0.35)
			else:
				_box_faces(glass, box, Color(0.78, 0.16, 0.22, 0.22))
				_box_edges(glass, box, Color(1.0, 0.35, 0.42, 0.75), 0.3)


func _portals(glass: SurfaceTool) -> void:
	var list: Array = _world.portals if _world != null else _level.portals
	for p in list:
		var portal: LevelDataT.PortalData = p
		var open: bool = _world == null or _world.portal_open(portal)
		if not open:
			continue
		var frame: Transform3D = _world.transform_of(portal) if _world != null \
			else Transform3D(Basis.IDENTITY, portal.center)
		frame.origin += frame.basis.z.normalized() * PORTAL_LIFT_M
		# Either end of the pair makes BOTH ends orange. The player throws into
		# the near one and never sees the far one, so marking only the end that
		# is mounted upside down would leave the aperture they actually aim at
		# looking like an ordinary portal.
		var dive := Facts.portal_dives(_level, portal)
		var color: Color = PT.DIVE if dive else PT.PORTAL
		var hw := portal.width_m * 0.5
		var hh := portal.height_m * 0.5

		var corners := PackedVector3Array()
		for uv: Array in [[-hw, -hh], [hw, -hh], [hw, hh], [-hw, hh]]:
			corners.append(frame * Vector3(uv[0], uv[1], 0.0))
		_quad(glass, corners[0], corners[1], corners[2], corners[3],
			Color(color.r, color.g, color.b, 0.24))

		# The rim is filled quads, not lines: GL Compatibility renders every line
		# one pixel wide whatever width you ask for, and a one-pixel rim on a
		# 36 m portal is not a portal.
		# The rim scales with the aperture: a fixed 0.45 m rim is invisible on a
		# 36 m portal and swallows a 10 m one.
		var t: float = clampf(minf(hw, hh) * 0.06, RIM_THICKNESS, 1.2)
		for edge: Array in [
				[Vector3(-hw, hh, 0), Vector3(hw, hh, 0), Vector3(0, t, 0)],
				[Vector3(-hw, -hh, 0), Vector3(hw, -hh, 0), Vector3(0, -t, 0)],
				[Vector3(-hw, -hh, 0), Vector3(-hw, hh, 0), Vector3(-t, 0, 0)],
				[Vector3(hw, -hh, 0), Vector3(hw, hh, 0), Vector3(t, 0, 0)]]:
			var a: Vector3 = frame * (edge[0] as Vector3)
			var b: Vector3 = frame * (edge[1] as Vector3)
			var off: Vector3 = frame.basis * (edge[2] as Vector3)
			_quad(glass, a, b, b + off, a + off, Color(color.r, color.g, color.b, 0.95))

		_chevrons(glass, frame, hw, hh, dive, color)


## Chevrons point the way through for a normal portal and straight DOWN for a
## dive portal. `PuzzleLevelData` folds the inversion into the portal's `up`
## vector, so an inverting portal's frame is already upside down and drawing the
## same upward chevron in it produces a downward one on screen — but relying on
## that would be a coincidence, so the direction is chosen explicitly.
func _chevrons(glass: SurfaceTool, frame: Transform3D, hw: float, hh: float,
		dive: bool, color: Color) -> void:
	var scale: float = clampf(minf(hw, hh) * 0.30, 0.6, 2.4)
	var up: Vector3 = frame.basis.y.normalized()
	var sign_y: float = -1.0 if (dive != (up.y < 0.0)) else 1.0
	for i in 3:
		var v := lerpf(-hh * 0.5, hh * 0.5, float(i) * 0.5)
		var tip := Vector3(0, v + sign_y * scale, 0)
		var left := Vector3(-scale, v - sign_y * scale * 0.25, 0)
		var right := Vector3(scale, v - sign_y * scale * 0.25, 0)
		_tri(glass, frame * tip, frame * left, frame * right,
			Color(color.r, color.g, color.b, 0.6))


func _markers(solid: SurfaceTool, wire: SurfaceTool) -> void:
	var tee := _level.tee_world()
	_quad(solid, tee + Vector3(-1.6, 0.03, -1.6), tee + Vector3(1.6, 0.03, -1.6),
		tee + Vector3(1.6, 0.03, 1.6), tee + Vector3(-1.6, 0.03, 1.6),
		Color(0.55, 0.62, 0.72, 1.0))
	_ring(wire, tee + Vector3(0, 0.05, 0), 3.0, Color(1, 1, 1, 0.35))

	var flag := _level.flag_world()
	var green := PT.BUTTON_ARMED
	_line(wire, flag, flag + Vector3(0, 4.0, 0), green)
	_tri(solid, flag + Vector3(0, 4.0, 0), flag + Vector3(2.2, 3.4, 0),
		flag + Vector3(0, 2.8, 0), green)
	# Rings at the three medal radii, so "within 4 m" is a thing on the floor
	# rather than a number in a panel.
	for m in _level.medals:
		var tier: LevelDataT.MedalTier = m
		var c: Color = PT.medal_color(tier.tier)
		_ring(wire, flag + Vector3(0, 0.06, 0), maxf(tier.max_flag_distance_m, 0.5),
			Color(c.r, c.g, c.b, 0.5), 44)


func _build_buttons() -> void:
	for b in _level.buttons:
		var button: LevelDataT.ButtonData = b
		var room: LevelDataT.RoomData = _level.get_room(button.room)
		var mi := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = button.radius_m
		sphere.height = button.radius_m * 2.0
		sphere.radial_segments = 20
		sphere.rings = 10
		mi.mesh = sphere
		mi.position = button.center + (room.world_origin if room != null else Vector3.ZERO)
		mi.material_override = _flat(true)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_buttons_root.add_child(mi)
		_button_nodes[button.id] = mi
	set_buttons_armed(PackedStringArray())


## Amber ring, green once armed (LEVEL_DESIGN §1).
func set_buttons_armed(armed: PackedStringArray) -> void:
	for id: String in _button_nodes:
		var mi: MeshInstance3D = _button_nodes[id]
		var lit := armed.has(id)
		var c: Color = PT.BUTTON_ARMED if lit else PT.BUTTON_IDLE
		var m: StandardMaterial3D = mi.material_override
		m.albedo_color = Color(c.r, c.g, c.b, 0.42 if lit else 0.20)


# ------------------------------------------------------------ flight paths ---

## A flown trajectory, kept on screen so the next attempt can be aimed against
## the last one rather than against memory.
func add_flight_path(points: PackedVector3Array, color: Color) -> void:
	if points.size() < 2:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_LINES)
	for i in range(points.size() - 1):
		# A portal crossing is a real discontinuity in the polyline; skipping the
		# long segment keeps the trail from drawing a straight line across the
		# whole level between two rooms.
		if points[i].distance_squared_to(points[i + 1]) > 400.0:
			continue
		var f := float(i) / float(maxi(points.size() - 1, 1))
		var c := Color(color.r, color.g, color.b, lerpf(0.85, 0.30, f))
		st.set_color(c)
		st.add_vertex(points[i])
		st.set_color(c)
		st.add_vertex(points[i + 1])
	var mesh: ArrayMesh = st.commit()
	if mesh == null or mesh.get_surface_count() == 0:
		return
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _flat(true)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_paths.add_child(mi)


func clear_flight_paths() -> void:
	if _paths == null:
		return
	for child in _paths.get_children():
		child.queue_free()


func show_disc(at: Vector3) -> void:
	_disc.position = at
	_disc.visible = true


func hide_disc() -> void:
	if _disc != null:
		_disc.visible = false


# =================================================================== camera ===

func level_bounds() -> AABB:
	return _bounds


func tee_world() -> Vector3:
	return _level.tee_world() if _level != null else Vector3.ZERO


func flag_world() -> Vector3:
	return _level.flag_world() if _level != null else Vector3.ZERO


## Behind and above the tee, looking along the aim. The default view, because it
## is the one in which the drag gesture means what it looks like it means.
func view_tee(aim_dir: Vector3) -> void:
	if camera == null:
		return
	var dir := _flat_dir(aim_dir)
	# Low and close. A high camera flattens a 12 m portal into two horizontal
	# bars — measured on Level 1 at 12 m up, where the aperture read as a stripe
	# rather than as a hole you could throw through.
	camera.position = tee_world() - dir * 30.0 + Vector3(0, 7.0, 0)
	camera.look_at(tee_world() + dir * 55.0 + Vector3(0, 5.0, 0), Vector3.UP)


## Straight down over the whole level. The view that explains a portal chain,
## because P3 lays the rooms out end to end in one world.
func view_top() -> void:
	if camera == null:
		return
	var c := _bounds.get_center()
	camera.position = Vector3(c.x, _bounds.end.y + _fit_distance(), c.z)
	camera.look_at(Vector3(c.x, 0.0, c.z), Vector3(0, 0, -1))


func view_level() -> void:
	if camera == null:
		return
	var c := _bounds.get_center()
	var d := _fit_distance()
	camera.position = c + Vector3(0.42, 0.55, 0.72).normalized() * d
	camera.look_at(c, Vector3.UP)


## Far enough back that the level's bounding sphere fits in the frame, with a
## margin. Rooms are laid side by side in one world and Level 8's two are 95 m
## apart, so a fixed offset frames some levels and cuts others in half.
func _fit_distance() -> float:
	var radius: float = maxf(_bounds.size.length() * 0.5, 12.0)
	var half_fov: float = deg_to_rad(camera.fov) * 0.5
	# The vertical FOV is the tighter axis on a 16:9 canvas, so fitting to it
	# fits both.
	return radius / maxf(tan(half_fov), 0.05) * 1.15


## Frame where the disc came to rest, with the landing deliberately LOW in the
## frame. The results panel is a centred modal, so a landing framed dead centre
## is a landing behind the panel describing it — measured on Level 8, where the
## whole level ended up under the results card.
func view_landing(landing: Vector3) -> void:
	if camera == null:
		return
	camera.position = landing + Vector3(0.0, 16.0, 34.0)
	camera.look_at(landing + Vector3(0.0, 14.0, 0.0), Vector3.UP)


func view_follow(target: Vector3, aim_dir: Vector3) -> void:
	if camera == null:
		return
	var dir := _flat_dir(aim_dir)
	var want := target - dir * 24.0 + Vector3(0, 10.0, 0)
	camera.position = camera.position.lerp(want, 0.15)
	camera.look_at(target, Vector3.UP)


static func _flat_dir(v: Vector3) -> Vector3:
	var d := Vector3(v.x, 0.0, v.z)
	return d.normalized() if d.length_squared() > 1e-6 else Vector3(0, 0, -1)


# ------------------------------------------------------------- primitives ---

func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		color: Color) -> void:
	_tri(st, a, b, c, color)
	_tri(st, a, c, d, color)


func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
	for v: Vector3 in [a, b, c]:
		st.set_color(color)
		st.add_vertex(v)


func _line(st: SurfaceTool, a: Vector3, b: Vector3, color: Color) -> void:
	st.set_color(color)
	st.add_vertex(a)
	st.set_color(color)
	st.add_vertex(b)


func _ring(st: SurfaceTool, centre: Vector3, radius: float, color: Color,
		segments: int = 32) -> void:
	var prev := centre + Vector3(radius, 0, 0)
	for i in range(1, segments + 1):
		var a := TAU * float(i) / float(segments)
		var p := centre + Vector3(cos(a) * radius, 0, sin(a) * radius)
		_line(st, prev, p, color)
		prev = p


func _box_outline(st: SurfaceTool, box: AABB, color: Color) -> void:
	for edge: Array in _EDGES:
		_line(st, box.get_endpoint(int(edge[0])), box.get_endpoint(int(edge[1])), color)


## `AABB.get_endpoint` orders corners by the bits of the index (x, y, z), so
## these pairs are the twelve edges of that ordering.
const _EDGES := [[0, 1], [0, 2], [0, 4], [1, 3], [1, 5], [2, 3],
	[2, 6], [3, 7], [4, 5], [4, 6], [5, 7], [6, 7]]


## Edges as thin filled bars rather than lines, for the things that have to read
## as solid at any distance.
func _box_edges(st: SurfaceTool, box: AABB, color: Color, thickness: float) -> void:
	for edge: Array in _EDGES:
		var a := box.get_endpoint(int(edge[0]))
		var b := box.get_endpoint(int(edge[1]))
		var dir := (b - a).normalized()
		var side := dir.cross(Vector3.UP)
		if side.length_squared() < 1e-6:
			side = dir.cross(Vector3(1, 0, 0))
		side = side.normalized() * thickness
		_quad(st, a - side, b - side, b + side, a + side, color)


func _box_faces(st: SurfaceTool, box: AABB, color: Color) -> void:
	var lo := box.position
	var hi := box.end
	_quad(st, Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z),
		Vector3(hi.x, hi.y, lo.z), Vector3(lo.x, hi.y, lo.z), color)
	_quad(st, Vector3(lo.x, lo.y, hi.z), Vector3(hi.x, lo.y, hi.z),
		Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z), color)
	_quad(st, Vector3(lo.x, lo.y, lo.z), Vector3(lo.x, lo.y, hi.z),
		Vector3(lo.x, hi.y, hi.z), Vector3(lo.x, hi.y, lo.z), color)
	_quad(st, Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z),
		Vector3(hi.x, hi.y, hi.z), Vector3(hi.x, hi.y, lo.z), color)

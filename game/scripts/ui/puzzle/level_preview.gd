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
## Scope, and the seam to Track P2 — NOW CLOSED
## ---------------------------------------------------------------------------
## This file used to be the whole 3D view: a flat-shaded diagram with portals
## drawn as translucent quads, because P2's renderer had not been wired in and
## you could not see through a portal in puzzle mode. That gap is closed.
## `PortalStage` (`scripts/portal/portal_stage.gd`) now builds the SOLID half —
## real rooms with real holes in their walls, real `Portal` apertures showing
## the destination room live through a SubViewport — and this file is what it
## always should have been: the instrumentation drawn over the top.
##
## The division now:
##
##   PortalStage    rooms, walls, floors, portal apertures, the crossing ghost.
##                  Shaded. Two draw calls a room, ~14 per live portal pass.
##   this file      the 10 m grid, the medal rings, the tee, the flag, the
##                  buttons, the barriers, the hatched portalable panels, the
##                  predicted portal rectangle and the flown trajectories.
##                  Unshaded flat colour, so it stays legible against any wall.
##
## Everything here is lifted clear of the stage's geometry by `DECAL_LIFT`:
## GL Compatibility has 24-bit depth and no reverse-Z, so a decoration drawn
## exactly on the floor z-fights with it from about 60 m out, and these levels
## are 290 m across.
##
## ---------------------------------------------------------------------------
## Colour is the whole legend (LEVEL_DESIGN §1)
## ---------------------------------------------------------------------------
##   blue rim, quiet edge                a normal portal
##   ORANGE rim, chevrons scrolling DOWN a DIVE portal — and nothing else in the
##                                       scene is ever that colour
##   pale hatched panel                  a portalable surface
##   violet dashed rectangle             where your portal disc is predicted to
##                                       open its portal
##   translucent red slab                a barrier that is currently solid
##   amber sphere, green when armed      a button
##
## The dive portal's identity is load-bearing, not decorative: a disc through one
## loses 40-45% of its distance and lands in under three seconds
## (PORTAL_CONTRACT §6), and no amount of looking at the geometry will tell you
## that. `PortalStage` marks BOTH ends of a dive pair for the same reason this
## file did: P3's data marks only the physically inverted end, and the player
## throws into the other one.

const T := preload("res://scripts/ui/flight_lab_theme.gd")
const PT := preload("res://scripts/ui/puzzle/puzzle_theme.gd")
const LevelDataT := preload("res://scripts/puzzle/level_data.gd")
const WorldT := preload("res://scripts/puzzle/puzzle_world.gd")
const Facts := preload("res://scripts/ui/puzzle/level_facts.gd")
const RigT := preload("res://scripts/app/camera_rig.gd")

const GRID_SPACING := 10.0

## How far every flat decoration is lifted off the stage geometry it annotates.
## GL Compatibility has 24-bit depth and no reverse-Z (PORTAL_CONTRACT §7), so
## coplanar geometry z-fights and the wall wins about half the time — measured
## by P4 at 20 m with a 0.0 lift, where a portal rim vanished entirely. These
## levels are up to 290 m across, and depth resolution goes as the square of
## distance: 0.08 m holds to roughly 350 m with this near/far pair.
const DECAL_LIFT := 0.08

var camera: Camera3D = null
## The sandbox's camera rig, adopted rather than reimplemented: it owns the
## easing between framings and the free-look orbit, and this file owns the
## framings themselves, because only the level knows where a camera may stand.
var rig: CameraRig = null
## The solid world: rooms, walls, apertures, live portal views. See the class
## comment — this file draws over it, it does not replace it.
var stage: PortalStage = null

var _static_solid: MeshInstance3D = null
var _static_wire: MeshInstance3D = null
var _predict_node: MeshInstance3D = null
var _barrier_node: MeshInstance3D = null
var _landing_node: MeshInstance3D = null
var _buttons_root: Node3D = null
var _paths: Node3D = null
var _disc: MeshInstance3D = null

## Where the armed portal disc is predicted to strike, pushed by the mode
## controller from the ghost's terminus. Empty surface id = draw nothing.
var predicted_portal_surface: String = ""
var predicted_portal_disc: String = ""
var predicted_portal_impact: Vector3 = Vector3.ZERO

var _level: LevelDataT = null
var _world: WorldT = null
var _bounds := AABB()
var _button_nodes: Dictionary = {}


func _ready() -> void:
	camera = Camera3D.new()
	camera.fov = 62.0
	camera.near = 0.25
	camera.far = 3000.0
	# The camera carries its own Environment rather than a WorldEnvironment,
	# because `PortalStage` swaps it for the room the eye is standing in and a
	# WorldEnvironment would fight that. A portal CAMERA gets the destination
	# room's LINEAR-tonemap copy — see `PortalRoom._make_portal_environment`.
	camera.environment = _fallback_environment()
	add_child(camera)

	# One camera system for both modes. The rig is handed the camera the portal
	# renderer draws with, publishes nothing of its own until this file pushes a
	# pose, and does not read the mouse: `PuzzleAimOverlay` is a full-screen
	# Control that takes every click before `_unhandled_input` runs, so it routes
	# inspection gestures in explicitly. One owner of the mouse, so free look
	# cannot fight drag-to-aim.
	rig = RigT.new()
	rig.name = "CameraRig"
	rig.default_view = "custom"
	rig.owns_input = false
	# The flight is replayed at 1.6x, so the chase camera is tracking a target
	# doing up to ~48 m/s. At the sandbox's rate it would trail far enough to put
	# the disc on the edge of the frame.
	rig.smooth_rate = 9.0
	rig.use_camera(camera)
	add_child(rig)
	# The room air is chosen from where the eye ENDS UP, and the rig moves the eye
	# in its own `_process`. A higher priority number runs later, so this node's
	# `_process` sees the pose the player is actually looking through.
	process_priority = 10

	stage = PortalStage.new()
	stage.name = "PortalStage"
	add_child(stage)
	stage.attach_camera(camera)

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
	_disc.visible = false
	add_child(_disc)
	# Hands the disc to `PortalGhost`, which REPLACES its material with the clip
	# shader: the clip has to apply to the real mesh as well as to the clone, or
	# the two halves of a crossing disc do not add up to one disc.
	stage.attach_disc(_disc, T.ACCENT)


## The air outside every room, and what the camera uses before a level is
## loaded. Tonemap and exposure match `PortalRoom`'s, so stepping from the void
## into a room is not a brightness step.
static func _fallback_environment() -> Environment:
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = T.BG
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.72, 0.78, 0.88)
	e.ambient_light_energy = 0.62
	e.reflected_light_source = Environment.REFLECTION_SOURCE_BG
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.tonemap_exposure = 1.05
	return e


# ==================================================================== build ===

func build(level: LevelDataT, world: WorldT) -> void:
	_level = level
	_world = world
	_button_nodes.clear()
	clear_flight_paths()
	for node in [_static_solid, _static_wire]:
		if node != null:
			node.queue_free()
	for child in _buttons_root.get_children():
		child.queue_free()

	var solid := SurfaceTool.new()
	solid.begin(Mesh.PRIMITIVE_TRIANGLES)
	var wire := SurfaceTool.new()
	wire.begin(Mesh.PRIMITIVE_LINES)

	# The rooms themselves — walls, floors, apertures, live portal views.
	stage.build(level, world)
	for e in stage.problems:
		push_warning("PortalStage: %s" % e)

	_bounds = AABB()
	var first := true
	for i in level.rooms.size():
		var room: LevelDataT.RoomData = level.rooms[i]
		_room(wire, room)
		var box := AABB(room.world_min(), room.world_max() - room.world_min())
		_bounds = box if first else _bounds.merge(box)
		first = false
	for i in level.rooms.size():
		_surfaces(solid, wire, level.rooms[i])
	_markers(solid, wire)

	_static_solid = _attach(solid, false)
	_static_wire = _attach(wire, true)

	clear_landing_marker()
	_build_buttons()
	rebuild_dynamic(false)

	# Free look is bounded by the level plus a margin: a mis-swiped orbit that
	# ends 400 m out in the void is not a camera, it is a lost player. The margin
	# is generous enough to get outside a room and look at the whole layout, which
	# is half of what inspection is for.
	if rig != null:
		rig.ground_y = _bounds.position.y
		rig.free_bounds = _bounds.grow(60.0)
		rig.has_free_bounds = true


## Portals and barriers change between throws — a button opens a gate, a portal
## disc opens an aperture — so they are their own meshes and are rebuilt rather
## than baked into the static geometry.
## `rebuild_stage` is false only when `build()` calls this, because `build()` has
## just cut every aperture already: rebuilding there would free and re-register
## every portal, which costs the renderer its warm SubViewports and shows as a
## flicker on the first frame of a level.
func rebuild_dynamic(rebuild_stage: bool = true) -> void:
	if _barrier_node != null:
		_barrier_node.queue_free()
		_barrier_node = null
	if _level == null:
		return
	# The apertures are `PortalStage`'s now — a placed portal is a real hole in a
	# real wall, so re-cutting the room shells is part of this.
	if rebuild_stage:
		stage.rebuild_portals()
		for e in stage.problems:
			push_warning("PortalStage: %s" % e)

	var barriers := SurfaceTool.new()
	barriers.begin(Mesh.PRIMITIVE_TRIANGLES)
	_barriers(barriers)
	_barrier_node = _attach(barriers, true)
	refresh_prediction()


## Just the predicted portal rectangle. Separate from `rebuild_dynamic()` and
## deliberately cheap: this runs every time the aim changes — several times a
## second through a drag — and re-cutting room geometry at that rate would both
## cost real time and make the portal renderer drop and re-warm its slots.
func refresh_prediction() -> void:
	if _predict_node != null:
		_predict_node.queue_free()
		_predict_node = null
	if _level == null:
		return
	var marks := SurfaceTool.new()
	marks.begin(Mesh.PRIMITIVE_LINES)
	_predicted_portal(marks)
	_predict_node = _attach(marks, true)


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

## The floor and walls belong to `PortalStage` now. What stays here is the 10 m
## grid — countable distance, which `PortalRoom`'s own 2 m texture grid is too
## fine to give at 130 m — and the cage outline, which is how you read a room's
## extent from OUTSIDE it, where its walls are back-face culled and invisible.
func _room(wire: SurfaceTool, room: LevelDataT.RoomData) -> void:
	var lo := room.world_min()
	var hi := room.world_max()
	var y := lo.y + DECAL_LIFT

	var grid := Color(1, 1, 1, 0.13)
	var x := ceilf(lo.x / GRID_SPACING) * GRID_SPACING
	while x <= hi.x:
		_line(wire, Vector3(x, y, lo.z), Vector3(x, y, hi.z), grid)
		x += GRID_SPACING
	var z := ceilf(lo.z / GRID_SPACING) * GRID_SPACING
	while z <= hi.z:
		_line(wire, Vector3(lo.x, y, z), Vector3(hi.x, y, z), grid)
		z += GRID_SPACING

	_box_outline(wire, AABB(lo, hi - lo), Color(0.42, 0.52, 0.68, 0.55))


## Only the PORTALABLE panels are drawn now: a plain wall is a wall, and
## `PortalStage` draws it. The pale fill, the bright border and the hatching are
## the whole answer to "where may I open a portal", which in Levels 6, 7, 9 and
## 10 is the question the level is about.
func _surfaces(solid: SurfaceTool, wire: SurfaceTool, room: LevelDataT.RoomData) -> void:
	for s in room.surfaces:
		var surface: LevelDataT.SurfaceData = s
		if not surface.portalable:
			continue
		var corners := _surface_corners(surface, room.world_origin)
		if corners.size() < 4:
			continue
		_quad(solid, corners[0], corners[1], corners[2], corners[3],
			Color(0.62, 0.70, 0.80, 0.85))
		for i in 4:
			_line(wire, corners[i], corners[(i + 1) % 4], Color(1, 1, 1, 0.9))
		# Diagonal hatching: the one thing separating "a wall you may open a
		# portal on" from "a wall that happens to be pale".
		var u := corners[1] - corners[0]
		var v := corners[3] - corners[0]
		for i in range(1, 10):
			var f := float(i) / 10.0
			_line(wire, corners[0] + u * f, corners[0] + v * f, Color(1, 1, 1, 0.18))


## `SurfaceData` gives the plane axis plus a rectangle over the other two axes.
## Lifted off the wall along its inward normal, or it z-fights with the wall it
## is marking — the panels are exactly coplanar with `PortalStage`'s shell.
static func _surface_corners(s: LevelDataT.SurfaceData, origin: Vector3) -> PackedVector3Array:
	var out := PackedVector3Array()
	var a := (s.axis + 1) % 3
	var b := (s.axis + 2) % 3
	var lift: Vector3 = s.normal.normalized() * DECAL_LIFT
	for uv: Array in [[false, false], [true, false], [true, true], [false, true]]:
		var p := Vector3.ZERO
		p[s.axis] = s.value
		p[a] = s.rect_max[a] if bool(uv[0]) else s.rect_min[a]
		p[b] = s.rect_max[b] if bool(uv[1]) else s.rect_min[b]
		out.append(p + origin + lift)
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


## WHERE THE PORTAL DISC IS PREDICTED TO OPEN ITS PORTAL.
##
## A missed portal disc is spent — that is Level 7's whole tension, and Levels
## 6, 9 and 10 turn on it too — so "you may open a portal somewhere on this
## panel" is not enough. The hatched panel says where it is legal; this says
## where it would actually land, at the current aim, as the rectangle the portal
## will occupy after `PuzzleWorld` clamps it to fit the panel. It is the same
## clamp the placement uses (`clamp_portal_center`), not a second copy of it.
##
## Drawn as a dashed violet outline with corner ticks — the disc-placed portal
## colour — so it cannot be mistaken for a portal that already exists.
func _predicted_portal(wire: SurfaceTool) -> void:
	if _level == null or _world == null or predicted_portal_surface.is_empty():
		return
	var spec: LevelDataT.PortalDiscData = _level.get_portal_disc(predicted_portal_disc)
	if spec == null:
		return
	var sd: LevelDataT.SurfaceData = _world.surface_by_id(predicted_portal_surface)
	if sd == null or not sd.portalable:
		return
	var origin: Vector3 = _level.get_room(sd.room).world_origin
	var centre: Vector3 = _world.clamp_portal_center(sd, spec,
		predicted_portal_impact - origin) + origin
	var lift: Vector3 = sd.normal.normalized() * (DECAL_LIFT * 1.5)
	var a := (sd.axis + 1) % 3
	var b := (sd.axis + 2) % 3
	var ha := Vector3.ZERO
	ha[a] = (spec.height_m if a == 1 else spec.width_m) * 0.5
	var hb := Vector3.ZERO
	hb[b] = (spec.height_m if b == 1 else spec.width_m) * 0.5

	var c := PT.PLACED
	var corners := PackedVector3Array([
		centre - ha - hb + lift, centre + ha - hb + lift,
		centre + ha + hb + lift, centre - ha + hb + lift])
	for i in 4:
		_dashed_line(wire, corners[i], corners[(i + 1) % 4],
			Color(c.r, c.g, c.b, 0.95), 1.6)
	# Corner ticks pointing inward, so the rectangle still reads at 130 m where
	# the dashes have collapsed into a line.
	for i in 4:
		var here: Vector3 = corners[i]
		for other: Vector3 in [corners[(i + 1) % 4], corners[(i + 3) % 4]]:
			var d: Vector3 = (other - here)
			_line(wire, here, here + d * 0.18, Color(c.r, c.g, c.b, 1.0))
	# The impact point itself, so a clamped placement visibly differs from the
	# line the ghost drew.
	var hit: Vector3 = predicted_portal_impact + lift
	for axis: Vector3 in [ha.normalized(), hb.normalized()]:
		_line(wire, hit - axis * 1.2, hit + axis * 1.2, Color(c.r, c.g, c.b, 0.8))


func _markers(solid: SurfaceTool, wire: SurfaceTool) -> void:
	# All of these sit on `PortalStage`'s floor, so every one is lifted clear of
	# it; see DECAL_LIFT.
	var lift := Vector3(0.0, DECAL_LIFT, 0.0)
	var tee := _level.tee_world() + lift
	_quad(solid, tee + Vector3(-1.6, 0.0, -1.6), tee + Vector3(1.6, 0.0, -1.6),
		tee + Vector3(1.6, 0.0, 1.6), tee + Vector3(-1.6, 0.0, 1.6),
		Color(0.55, 0.62, 0.72, 1.0))
	_ring(wire, tee + Vector3(0, 0.01, 0), 3.0, Color(1, 1, 1, 0.35))

	var flag := _level.flag_world() + lift
	var green := PT.BUTTON_ARMED
	_line(wire, flag, flag + Vector3(0, 4.0, 0), green)
	_tri(solid, flag + Vector3(0, 4.0, 0), flag + Vector3(2.2, 3.4, 0),
		flag + Vector3(0, 2.8, 0), green)
	# Rings at the three medal radii, so "within 4 m" is a thing on the floor
	# rather than a number in a panel.
	for m in _level.medals:
		var tier: LevelDataT.MedalTier = m
		var c: Color = PT.medal_color(tier.tier)
		_ring(wire, flag + Vector3(0, 0.01, 0), maxf(tier.max_flag_distance_m, 0.5),
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


## Every framing goes through here: the rig eases toward the pose and applies it,
## so a view change is a glide rather than a cut, and the landing hold gets its
## drift toward the disc for free. `immediate` is for a level load, where easing
## in from the previous level's geometry would fly the camera through a wall.
func _push(pos: Vector3, look: Vector3, immediate: bool = false) -> void:
	if rig == null:
		# No rig (a bare instance in a test): place the camera directly.
		if camera != null:
			camera.position = pos
			camera.look_at(look, Vector3.UP)
			_apply_room_air()
		return
	rig.push_pose(pos, look, Vector3.UP, camera.fov if camera != null else 62.0, immediate)


## The room air is chosen from where the eye actually is, and after this node's
## `process_priority` the rig has already moved it this frame.
func _process(_delta: float) -> void:
	_apply_room_air()


## Behind and above the tee, looking along the aim. The default view, because it
## is the one in which the drag gesture means what it looks like it means.
func view_tee(aim_dir: Vector3, immediate: bool = false) -> void:
	if camera == null:
		return
	var dir := _flat_dir(aim_dir)
	# Low and close. A high camera flattens a 12 m portal into two horizontal
	# bars — measured on Level 1 at 12 m up, where the aperture read as a stripe
	# rather than as a hole you could throw through.
	_push(tee_world() - dir * 30.0 + Vector3(0, 7.0, 0),
		tee_world() + dir * 55.0 + Vector3(0, 5.0, 0), immediate)


## The main camera renders with the air of the room its eye is in. A PORTAL
## camera renders with the DESTINATION room's air, tonemapped LINEAR so the main
## viewport tonemaps the result exactly once — `PortalRenderer` handles that
## half; this is the other half, and without it a portal view and the room
## beside it are lit by different Environments for no reason.
func _apply_room_air() -> void:
	if camera == null or stage == null:
		return
	var e: Environment = stage.environment_at(camera.global_position)
	if e != null and camera.environment != e:
		camera.environment = e


## Straight down over the whole level. The view that explains a portal chain,
## because P3 lays the rooms out end to end in one world.
func view_top() -> void:
	if camera == null:
		return
	var c := _bounds.get_center()
	# up = -Z, so downrange is up the screen. Pushed through the rig like every
	# other framing, which is also what smooths the roll from tee to top.
	if rig != null:
		rig.push_pose(Vector3(c.x, _bounds.end.y + _fit_distance(), c.z),
			Vector3(c.x, 0.0, c.z), Vector3(0, 0, -1), camera.fov)
	else:
		camera.position = Vector3(c.x, _bounds.end.y + _fit_distance(), c.z)
		camera.look_at(Vector3(c.x, 0.0, c.z), Vector3(0, 0, -1))
		_apply_room_air()


func view_level() -> void:
	if camera == null:
		return
	var c := _bounds.get_center()
	var d := _fit_distance()
	_push(c + Vector3(0.42, 0.55, 0.72).normalized() * d, c)


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
##
## When the flag is in the same room the shot is taken from BEHIND the landing
## along the landing-to-flag line, so the marker, the distance and the flag are
## one composition rather than three things the player has to hunt for. The eye
## is then clamped into the room the disc stopped in: these rooms are closed
## shells and a camera pushed through the ceiling by a wide framing sees the back
## faces of a room, which is to say nothing at all.
func view_landing(landing: Vector3, flag: Vector3, include_flag: bool,
		incoming: Vector3 = Vector3.ZERO) -> void:
	if camera == null:
		return
	var focus := landing
	var spread := 0.0
	var dir := _flat_dir(incoming)
	if include_flag:
		spread = landing.distance_to(flag)
		focus = landing.lerp(flag, 0.45)
		var to_flag := flag - landing
		to_flag.y = 0.0
		if to_flag.length_squared() > 1.0:
			dir = to_flag.normalized()
	var d: float = clampf(22.0 + spread * 1.1, 22.0, 78.0)
	var eye: Vector3 = focus - dir * (d * 0.78) + Vector3(0.0, d * 0.42 + 3.0, 0.0)
	_push(_inside_room_of(landing, eye), focus + Vector3(0.0, d * 0.15, 0.0))


## Keep a viewpoint inside the room a given point is in. Outside every room, or
## when the point is in none, the eye is returned untouched — the gaps between
## rooms are a legitimate place to stand and read the layout from.
func _inside_room_of(point: Vector3, eye: Vector3) -> Vector3:
	if _level == null:
		return eye
	for r in _level.rooms:
		var room: LevelDataT.RoomData = r
		var lo := room.world_min()
		var hi := room.world_max()
		if point.x < lo.x or point.x > hi.x or point.z < lo.z or point.z > hi.z:
			continue
		var inset := 1.5
		return Vector3(
			clampf(eye.x, minf(lo.x + inset, hi.x), maxf(hi.x - inset, lo.x)),
			clampf(eye.y, lo.y + inset, maxf(hi.y - inset, lo.y + inset)),
			clampf(eye.z, minf(lo.z + inset, hi.z), maxf(hi.z - inset, lo.z)))
	return eye


func view_follow(target: Vector3, aim_dir: Vector3) -> void:
	if camera == null:
		return
	var dir := _flat_dir(aim_dir)
	_push(target - dir * 24.0 + Vector3(0, 10.0, 0), target)


# ------------------------------------------------------------- inspection ---

## Free look, inheriting whatever the camera is doing now so entering it is not
## a jump. From here the mouse orbits, pans and zooms — "reading the green".
func view_inspect() -> void:
	if rig != null:
		rig.set_view("free")


## Orbit the flag, seen from the tee's side of it: the approach the throw has to
## make, which is the thing worth walking around.
func focus_flag() -> void:
	if rig == null:
		return
	var flag := flag_world()
	var back := tee_world() - flag
	back.y = 0.0
	if back.length_squared() < 1.0:
		back = Vector3(0.0, 0.0, 1.0)
	rig.focus_from(flag, back.normalized() * 26.0 + Vector3(0.0, 11.0, 0.0))


## Orbit a portal, from inside the room it opens into and square-on to it, which
## is the one angle that says what is on the other side.
func focus_portal(index: int = 0) -> bool:
	if rig == null or _level == null or _level.portals.is_empty():
		return false
	var portal: LevelDataT.PortalData = _level.portals[posmod(index, _level.portals.size())]
	var room: LevelDataT.RoomData = _level.get_room(portal.room)
	var origin: Vector3 = room.world_origin if room != null else Vector3.ZERO
	var centre: Vector3 = portal.world_center(origin)
	# `facing` points INTO the room the portal is in, so that is the side to
	# stand on.
	var out := Vector3(portal.facing.x, 0.0, portal.facing.z)
	if out.length_squared() < 1e-6:
		out = Vector3(0.0, 0.0, 1.0)
	var span: float = maxf(portal.width_m, portal.height_m)
	rig.focus_from(centre, out.normalized() * (span * 1.4 + 12.0) + Vector3(0.0, 6.0, 0.0))
	return true


func portal_count() -> int:
	return _level.portals.size() if _level != null else 0


# --------------------------------------------------------- landing marker ---

## Where the disc came to rest, as a thing on the floor. Without it the two
## seconds this mode now holds after a throw are two seconds of looking at an
## unmarked patch of ground — the trail says how it flew, not where it stopped.
func set_landing_marker(at: Vector3) -> void:
	clear_landing_marker()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_LINES)
	var c := T.ACCENT
	var base := Vector3(at.x, _floor_y_at(at) + DECAL_LIFT, at.z)
	for radius: float in [1.4, 2.6]:
		_ring(st, base, radius, Color(c.r, c.g, c.b, 0.95), 40)
	# A stalk, so the marker is findable from across a 130 m room and does not
	# vanish into the floor grid at a shallow angle.
	_line(st, base, base + Vector3(0.0, 3.2, 0.0), Color(c.r, c.g, c.b, 0.85))
	for a: float in [0.0, PI * 0.5, PI, PI * 1.5]:
		var d := Vector3(cos(a), 0.0, sin(a))
		_line(st, base + d * 2.6, base + d * 4.2, Color(c.r, c.g, c.b, 0.55))
	# The disc itself, lying where it stopped.
	_ring(st, Vector3(at.x, at.y + DECAL_LIFT, at.z), 0.6, Color(1, 1, 1, 0.8), 20)
	_landing_node = _attach(st, true)


func clear_landing_marker() -> void:
	if _landing_node != null:
		_landing_node.queue_free()
		_landing_node = null


## The floor of the room a point is in — rooms do not all sit at y = 0.
func _floor_y_at(p: Vector3) -> float:
	if _level == null:
		return 0.0
	for r in _level.rooms:
		var room: LevelDataT.RoomData = r
		var lo := room.world_min()
		var hi := room.world_max()
		if p.x >= lo.x and p.x <= hi.x and p.z >= lo.z and p.z <= hi.z:
			return lo.y
	return 0.0


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


## A dashed 3D line, `dash` metres on and `dash` metres off. Used for the
## predicted portal rectangle, which must not be mistakable for one that exists.
func _dashed_line(st: SurfaceTool, a: Vector3, b: Vector3, color: Color,
		dash: float) -> void:
	var span := a.distance_to(b)
	if span < 1.0e-4:
		return
	var steps: int = clampi(int(span / maxf(dash, 0.05)), 2, 200)
	var dir := (b - a) / float(steps)
	for i in steps:
		if i % 2 == 1:
			continue
		_line(st, a + dir * float(i), a + dir * float(i + 1), color)


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

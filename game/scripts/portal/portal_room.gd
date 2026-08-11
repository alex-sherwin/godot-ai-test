class_name PortalRoom
extends Node3D

## A room: a box with holes cut in it for portals, plus the Environment that
## gives it its own air.
##
## ---------------------------------------------------------------------------
## SINGLE-SIDED WALLS ARE LOAD-BEARING, NOT A SAVING
## ---------------------------------------------------------------------------
## Every face is one-sided and faces INWARD. From outside the box the walls are
## back-face culled and simply are not there. That is leg (c) of the contract
## §8 fallback for the missing oblique near plane: a portal camera sits *behind*
## the wall the exit portal is set into, and with two-sided walls that wall
## would fill the entire portal view with solid grey. It costs nothing and
## removes the single worst artefact. The player never sees a room from
## outside, so the cost is zero as well.
##
## The aperture is a real hole in the mesh, cut by rectangle subtraction — not a
## quad laid over the wall. A coplanar overlay z-fights on Compatibility's
## 24-bit depth buffer with no reverse-Z, and the fix (a depth offset) then
## shows as a visible lip when you fly a disc through at a grazing angle.
##
## ---------------------------------------------------------------------------
## Draw-call budget
## ---------------------------------------------------------------------------
## Two surfaces per room — walls+ceiling, and floor — so a room is 2 draw calls
## however many holes it has. Baseline for the sandbox scene is ~190 calls and
## the WebGL2 ceiling is ~500-800, so rooms must stay this cheap.

## Face indices. CONTRACT §1 puts downrange at −Z, so NORTH — the wall you
## throw at — is the −Z one, and its inward normal is +Z.
enum Face { WEST, EAST, FLOOR, CEILING, NORTH, SOUTH }

## Track P1 owns portal basis construction (`+Z = n̂`, world-up projected into
## the plane, with the floor/ceiling fallback). Mounting a portal in a wall is
## the authored version of the same operation, so it goes through the same
## function rather than a second copy of the rule.
const PortalLinkT := preload("res://scripts/physics/portal_link.gd")

## Inward normal, and the (u, v) basis of each face, with `u × v = n`.
const FACE_BASIS := {
	Face.WEST: [Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)],
	Face.EAST: [Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0)],
	Face.FLOOR: [Vector3(0, 1, 0), Vector3(1, 0, 0), Vector3(0, 0, -1)],
	Face.CEILING: [Vector3(0, -1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)],
	Face.NORTH: [Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0)],
	Face.SOUTH: [Vector3(0, 0, -1), Vector3(-1, 0, 0), Vector3(0, 1, 0)],
}

## Grid spacing of the shell texture, metres.
const GRID_M := 2.0

## Per-face brightness multiplier baked into vertex colour. See `_shade`.
const FACE_SHADE := {
	Face.FLOOR: 0.52, Face.CEILING: 1.16,
	Face.WEST: 0.86, Face.EAST: 0.86,
	Face.NORTH: 1.00, Face.SOUTH: 0.94,
}

static var _grid_tex: ImageTexture = null

@export var size := Vector3(16.0, 6.0, 26.0)
## Room tint. Everything else in the palette is derived from it, so a level file
## only has to name one colour to get a room that reads as its own place.
@export var tint := Color(0.55, 0.62, 0.72)
@export var fog_density: float = 0.010
@export var ambient_energy: float = 0.55
@export var room_index: int = 0

## For the MAIN camera when the player is in this room.
var environment: Environment = null
## For a PORTAL camera looking into this room. Same air, but with tonemapping
## and exposure removed — see `_make_environment`.
var portal_environment: Environment = null

var _holes: Dictionary = {}  ## Face -> Array[Rect2] in that face's (u, v) coords
var _built: bool = false


## Cut a hole. `rect` is in the face's own (u, v) metres, origin at face centre.
## Call before `build()`.
func add_aperture(face: int, rect: Rect2) -> void:
	if not _holes.has(face):
		_holes[face] = []
	_holes[face].append(rect)


## Where a portal of `w` x `h` metres goes if it is mounted flush in `face` at
## offset `(u, v)` from the face centre.
##
## Contract §6: wall portals ALWAYS use world-up. A wall-to-wall pair is then
## pure yaw plus translation, and pure yaw leaves the flight *exactly* unchanged
## (measured: 0.0 m error). Inversion — the disc-killer — becomes something a
## level author has to ask for, never something a room accidentally does.
## Returns a WORLD transform, ready to assign to `Portal.global_transform`.
func mount_transform(face: int, u: float, v: float) -> Transform3D:
	var b: Array = FACE_BASIS[face]
	var n: Vector3 = b[0]
	var uu: Vector3 = b[1]
	var vv: Vector3 = b[2]
	var half := size * 0.5
	var centre: Vector3 = -n * Vector3(half.x, half.y, half.z).dot(n.abs())
	var local: Vector3 = centre + uu * u + vv * v
	var world_n: Vector3 = (global_transform.basis * n).normalized()
	# `transform_from_surface_hit` also applies P1's 1 mm surface lift, which
	# Compatibility's 24-bit depth buffer with no reverse-Z needs (contract §7).
	return PortalLinkT.transform_from_surface_hit(global_transform * local, world_n)


## Everything that does not depend on where the portals are: the Environment and
## the light. `PortalLevel` calls this first, mounts the portals (which cut the
## apertures), and only then calls `rebuild_shell()` — the shell cannot be built
## until every hole in it is known.
func build_shared() -> void:
	if _built:
		return
	_built = true
	environment = _make_environment()
	portal_environment = _make_portal_environment(environment)
	_build_light()


func build() -> void:
	build_shared()
	rebuild_shell()


# ---------------------------------------------------------------------------
# Shell
# ---------------------------------------------------------------------------

## Idempotent: drops any previous shell first, so apertures can be added and the
## room re-cut without rebuilding the room.
func rebuild_shell() -> void:
	var old := get_node_or_null("Shell")
	if old != null:
		remove_child(old)
		old.queue_free()

	# ONE surface for the whole room — walls, floor and ceiling together, so a
	# room is a single draw call no matter how many holes are cut in it. What
	# separates floor from wall from ceiling is vertex colour, not material.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for face in [Face.WEST, Face.EAST, Face.FLOOR, Face.CEILING,
			Face.NORTH, Face.SOUTH]:
		_emit_face(st, face)
	st.index()

	var mi := MeshInstance3D.new()
	mi.name = "Shell"
	mi.mesh = st.commit()
	mi.material_override = _wall_material()
	mi.layers = Portal.LAYER_WORLD
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


func _emit_face(st: SurfaceTool, face: int) -> void:
	var b: Array = FACE_BASIS[face]
	var n: Vector3 = b[0]
	var uu: Vector3 = b[1]
	var vv: Vector3 = b[2]
	var half := size * 0.5
	var centre: Vector3 = -n * Vector3(half.x, half.y, half.z).dot(n.abs())
	var eu: float = absf(uu.dot(half))
	var ev: float = absf(vv.dot(half))

	var rects: Array[Rect2] = [Rect2(-eu, -ev, eu * 2.0, ev * 2.0)]
	for hole: Rect2 in _holes.get(face, []):
		var next: Array[Rect2] = []
		for r: Rect2 in rects:
			next.append_array(_subtract(r, hole))
		rects = next

	for r: Rect2 in rects:
		if r.size.x <= 1.0e-4 or r.size.y <= 1.0e-4:
			continue
		var p00: Vector3 = centre + uu * r.position.x + vv * r.position.y
		var p10: Vector3 = centre + uu * r.end.x + vv * r.position.y
		var p11: Vector3 = centre + uu * r.end.x + vv * r.end.y
		var p01: Vector3 = centre + uu * r.position.x + vv * r.end.y
		# WINDING. Godot's front face is CLOCKWISE, not the counter-clockwise
		# convention most references assume — so the order that makes the
		# geometric normal come out as +n is the one that renders the face as a
		# BACK face and culls it. Authored the intuitive way round, these rooms
		# were invisible from the inside and solid from the outside: precisely
		# backwards, and it read in a screenshot as "the walls are not being
		# drawn at all" rather than as a winding bug. Hence (00, 11, 10).
		_tri(st, n, face, half, p00, p11, p10,
			r.position, r.end, Vector2(r.end.x, r.position.y))
		_tri(st, n, face, half, p00, p01, p11,
			r.position, Vector2(r.position.x, r.end.y), r.end)


func _tri(st: SurfaceTool, n: Vector3, face: int, half: Vector3,
		a: Vector3, b: Vector3, c: Vector3,
		ua: Vector2, ub: Vector2, uc: Vector2) -> void:
	for pair: Array in [[a, ua], [b, ub], [c, uc]]:
		var v: Vector3 = pair[0]
		st.set_normal(n)
		st.set_uv(pair[1] / GRID_M)
		st.set_color(_shade(v, face, half))
		st.add_vertex(v)


## Baked lighting, in the only currency Compatibility hands out for free.
##
## There is no SSAO, no SDFGI and no lightmapper in this budget, and an ambient
## term plus one shadowless omni renders a box as very nearly a single flat
## colour: no corner, no floor, no ceiling, and no way to judge the distance to
## a portal — which in a game about judging a throw is not a cosmetic problem.
## A per-vertex shade term costs nothing at all (it rides in a vertex buffer
## that already exists) and restores the three cues a room needs: the floor is
## darker than the walls, the ceiling is lighter, and brightness falls off
## downward. The 2 m grid in `_grid_texture` carries the rest.
func _shade(local: Vector3, face: int, half: Vector3) -> Color:
	var g: float = FACE_SHADE.get(face, 1.0)
	# Height gradient, applied to the walls only: on the floor and ceiling it
	# would be a constant and would just fight FACE_SHADE.
	if face != Face.FLOOR and face != Face.CEILING:
		var t: float = clampf((local.y + half.y) / maxf(size.y, 0.001), 0.0, 1.0)
		g *= lerpf(0.70, 1.10, t)
	return Color(g, g, g)


## `r` minus `hole`, as up to four axis-aligned rectangles. Enough for portal
## apertures, which are rectangles in a rectangle; not a general CSG.
static func _subtract(r: Rect2, hole: Rect2) -> Array[Rect2]:
	var clip := r.intersection(hole)
	if clip.size.x <= 0.0 or clip.size.y <= 0.0:
		return [r]
	var out: Array[Rect2] = []
	if clip.position.y > r.position.y:
		out.append(Rect2(r.position.x, r.position.y, r.size.x, clip.position.y - r.position.y))
	if clip.end.y < r.end.y:
		out.append(Rect2(r.position.x, clip.end.y, r.size.x, r.end.y - clip.end.y))
	if clip.position.x > r.position.x:
		out.append(Rect2(r.position.x, clip.position.y,
			clip.position.x - r.position.x, clip.size.y))
	if clip.end.x < r.end.x:
		out.append(Rect2(clip.end.x, clip.position.y, r.end.x - clip.end.x, clip.size.y))
	return out


# ---------------------------------------------------------------------------
# Look
# ---------------------------------------------------------------------------

func _wall_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = tint
	m.albedo_texture = _grid_texture()
	m.vertex_color_use_as_albedo = true
	m.uv1_scale = Vector3.ONE
	m.roughness = 0.94
	m.metallic = 0.0
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	# The one thing that must not be relaxed: two-sided walls put the exit
	# wall in front of every portal camera. See the class comment.
	m.cull_mode = BaseMaterial3D.CULL_BACK
	return m


## A 2 m grid, generated once and shared by every room; each room tints it with
## its own `albedo_color`. Straight lines at a known spacing are the cheapest
## depth cue there is, and in a puzzle where the player is judging a throw
## through a hole in a wall, "how far away is that" is the whole question.
static func _grid_texture() -> ImageTexture:
	if _grid_tex != null:
		return _grid_tex
	var n := 128
	var img := Image.create_empty(n, n, true, Image.FORMAT_RGB8)
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_VALUE
	noise.seed = 20260811
	noise.frequency = 0.22
	for y in n:
		for x in n:
			var line: float = 1.0
			# Two-pixel lines on two edges of the tile: a closed grid, not a
			# checker, so the seams line up across adjacent faces.
			if x < 2 or y < 2:
				line = 0.72
			elif x < 3 or y < 3:
				line = 0.88
			var g: float = line * (1.0 + noise.get_noise_2d(float(x), float(y)) * 0.05)
			img.set_pixel(x, y, Color(g, g, g))
	img.generate_mipmaps()
	_grid_tex = ImageTexture.create_from_image(img)
	return _grid_tex


## Per-room air. Fog colour and ambient are the cheap, reliable cues on
## Compatibility — no volumetric fog, no SDFGI, no SSAO exist here — and they
## are genuinely useful in the puzzle: "which room am I looking into" is a
## question the player asks every time they line up a throw.
func _make_environment() -> Environment:
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = tint.darkened(0.82)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = tint.lightened(0.18)
	e.ambient_light_energy = ambient_energy
	e.reflected_light_source = Environment.REFLECTION_SOURCE_BG
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.tonemap_exposure = 1.05
	e.fog_enabled = true
	e.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	e.fog_light_color = tint.darkened(0.35)
	e.fog_light_energy = 1.0
	e.fog_density = fog_density
	e.fog_sky_affect = 1.0
	e.fog_aerial_perspective = 0.0
	return e


## MEASURED, and a correction to PORTAL_CONTRACT §8, which only warned to
## "expect a gamma/tonemap calibration session".
##
## The defect is not gamma, it is DOUBLE TONEMAPPING. On Compatibility the
## tonemap and the sRGB encode happen at the end of the scene fragment shader,
## per viewport. So a portal pixel is tonemapped once by the SubViewport's
## camera and then again by the main viewport when the quad is drawn. Measured
## on an unshaded, unfogged 0.5 grey swatch placed both beside a portal and
## through it: direct read sRGB 165,165,165 and through-portal read
## 197,205,210 — the portal view was washed out by about +19% and picked up the
## rim tint on top.
##
## The fix is to make the SubViewport pass produce LINEAR light and let the
## main viewport tonemap it exactly once, which is also the physically sensible
## reading: the portal is a window, and the eye looking through it is the main
## camera's. Everything else about the room's air — fog, ambient, background —
## is kept, because those are properties of the destination room and must show.
##
## `source_color` on the sampler in `portal_surface.gdshader` is the other half
## of this: the RGBA8 render target holds sRGB bytes, and without the hint they
## are read as linear and brightened a second time.
static func _make_portal_environment(src: Environment) -> Environment:
	var e: Environment = src.duplicate()
	e.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	e.tonemap_exposure = 1.0
	e.tonemap_white = 1.0
	return e


func _build_light() -> void:
	var l := OmniLight3D.new()
	l.name = "RoomLight"
	l.position = Vector3(0.0, size.y * 0.34, 0.0)
	l.omni_range = maxf(size.x, size.z) * 1.15
	l.light_energy = 1.1
	l.light_color = tint.lightened(0.35)
	# Omni shadows on Compatibility are a cube render per light per frame, and
	# a room lit by ambient plus one soft omni does not need them.
	l.shadow_enabled = false
	add_child(l)

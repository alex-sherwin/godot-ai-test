class_name Portal
extends Node3D

## One portal aperture: the quad the view is drawn on, its frame, and the link
## to its peer.
##
## CONVENTION (PORTAL_CONTRACT §1): the surface normal is **local +Z**, the
## opposite of Godot's Node3D "forward". `QuadMesh` also faces +Z, so an
## un-rotated Portal already faces the right way and `look_at()` is never used
## on one — see `PortalLink.transform_from_surface_hit`.
##
## RENDER LAYERS. Three, and the split is what stops a portal rendering itself:
##
##   1 (bit 0)  world geometry            every camera
##   2 (bit 1)  live portal apertures     the MAIN camera only
##   3 (bit 2)  flat portal stand-ins     PORTAL cameras only
##
## Every portal therefore carries two coincident quads. The main camera sees the
## live one; a portal camera sees the flat one, which terminates recursion at
## depth 1 with a solid surface rather than the hole in the wall you would get
## by masking the aperture out entirely (contract §8).
##
## A portal is a *pure visual + geometric* object. It knows nothing about the
## simulation: `Portal.to_peer` is handed to the physics side, not read from it.

enum Kind {
	NORMAL,  ## Wall-mounted, world-up. Pure yaw, so flight is unchanged (§6).
	DIVE,    ## Inverts the disc. 40-45% of distance is lost. Must be obvious.
	DISC,    ## Opened at runtime by a portal disc.
}

const LAYER_WORLD := 1 << 0
const LAYER_PORTAL_LIVE := 1 << 1
const LAYER_PORTAL_FLAT := 1 << 2

## Contract §7: the aperture test is inset by the disc radius, so a disc whose
## centre clears the rim cannot scythe through solid wall.
const DISC_RADIUS := 0.105

const SURFACE_SHADER := preload("res://scenes/portal/portal_surface.gdshader")
## Track P1's transform. There is exactly ONE implementation of
## `M = T_B · R_y(π) · T_A⁻¹` in this repository and it lives in the physics
## core: two of them disagreeing by a sign would put the rendered view and the
## flown disc in different places, and the symptom would be almost impossible to
## localise. `Portal.link()` is the only caller on the rendering side.
## `preload()` rather than the bare `class_name`, per the repo's headless rule.
const PortalLinkT := preload("res://scripts/physics/portal_link.gd")

## Per-kind visual identity. A player cannot infer "this will make my disc fall
## out of the sky" from geometry, so colour, rim weight and animation carry it.
const STYLE := {
	Kind.NORMAL: {
		"rim": Color(0.42, 0.78, 1.0),
		"frame": Color(0.62, 0.86, 1.0),
		"rim_width": 0.055, "tint": 0.05, "speed": 1.0, "frame_depth": 0.10,
		"label": "",
	},
	Kind.DIVE: {
		"rim": Color(1.0, 0.52, 0.12),
		"frame": Color(1.0, 0.66, 0.10),
		"rim_width": 0.085, "tint": 0.16, "speed": 1.0, "frame_depth": 0.20,
		"label": "DIVE",
	},
	Kind.DISC: {
		"rim": Color(0.78, 0.42, 1.0),
		"frame": Color(0.72, 0.52, 1.0),
		"rim_width": 0.062, "tint": 0.12, "speed": 1.6, "frame_depth": 0.07,
		"label": "",
	},
}

@export var width: float = 2.4
@export var height: float = 3.0
@export var kind: Kind = Kind.NORMAL
## Index into the level's room array. The renderer needs it to pick the
## Environment the peer's camera should render with.
@export var room_index: int = 0
## Set in the editor or by the level loader; resolved once in `_ready`.
@export var peer_path: NodePath

var peer: Portal = null
## The directed hop to `peer`, built and validated by Track P1's `PortalLink`.
## Hand this straight to `DiscFlightSim.configure_rooms()` — the picture and the
## flight then cannot disagree, because they are the same object.
var link_data: RefCounted = null
## `M = T_B · R_y(π) · T_A⁻¹`, cached at link time and invalidated only there
## (contract §3). Portals are immutable while a disc is in flight (§7), so this
## cannot go stale mid-crossing.
var to_peer: Transform3D = Transform3D.IDENTITY
## Non-empty when the pair failed P1's determinant guard. Surfaced on the dev
## overlay; never crashes the browser.
var link_error: String = ""

var live_surface: MeshInstance3D = null
var flat_surface: MeshInstance3D = null

var _live_mat: ShaderMaterial = null
var _flat_mat: ShaderMaterial = null
var _frame: MeshInstance3D = null
var _built: bool = false


func _ready() -> void:
	build()
	if not peer_path.is_empty():
		var other := get_node_or_null(peer_path) as Portal
		if other != null:
			link(other)


# ---------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------

func build() -> void:
	if _built:
		return
	_built = true
	var style: Dictionary = STYLE[kind]

	var quad := QuadMesh.new()
	quad.size = Vector2(width, height)

	_live_mat = _make_surface_material(style, true)
	live_surface = MeshInstance3D.new()
	live_surface.name = "Aperture"
	live_surface.mesh = quad
	live_surface.material_override = _live_mat
	live_surface.layers = LAYER_PORTAL_LIVE
	live_surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(live_surface)

	# The depth-1 terminator. Same quad, flat fill, portal cameras only.
	_flat_mat = _make_surface_material(style, false)
	flat_surface = MeshInstance3D.new()
	flat_surface.name = "ApertureFlat"
	flat_surface.mesh = quad
	flat_surface.material_override = _flat_mat
	flat_surface.layers = LAYER_PORTAL_FLAT
	flat_surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(flat_surface)

	_build_frame(style)


func _make_surface_material(style: Dictionary, is_live: bool) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SURFACE_SHADER
	m.set_shader_parameter("live", 0.0)
	m.set_shader_parameter("pattern", int(kind))
	m.set_shader_parameter("rim_color", style["rim"])
	m.set_shader_parameter("rim_width", style["rim_width"])
	m.set_shader_parameter("tint_strength", style["tint"] if is_live else 0.0)
	m.set_shader_parameter("anim_speed", style["speed"])
	# The flat stand-in is darker than the live view so a portal seen through a
	# portal reads as "further in", not as a lit surface.
	m.set_shader_parameter("flat_color",
		Color(0.055, 0.075, 0.115) if is_live else Color(0.035, 0.048, 0.075))
	return m


## The frame is the second half of the identity signal: a dive portal's frame is
## deeper and hazard-coloured, so the kind is legible from behind and from a
## grazing angle where the aperture itself is a sliver.
func _build_frame(style: Dictionary) -> void:
	var depth: float = style["frame_depth"]
	var bar := 0.10
	var mat := StandardMaterial3D.new()
	mat.albedo_color = style["frame"]
	mat.emission_enabled = true
	mat.emission = style["frame"]
	mat.emission_energy_multiplier = 0.55 if kind == Kind.NORMAL else 1.15
	mat.roughness = 0.42
	mat.metallic = 0.15

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hw := width * 0.5 + bar * 0.5
	var hh := height * 0.5 + bar * 0.5
	# Four bars, laid out in the portal's own XY plane and pushed back so the
	# frame sits *in* the wall rather than floating in front of the aperture.
	_add_box(st, Vector3(0.0, hh, -depth * 0.5), Vector3(hw * 2.0 + bar, bar, depth))
	_add_box(st, Vector3(0.0, -hh, -depth * 0.5), Vector3(hw * 2.0 + bar, bar, depth))
	_add_box(st, Vector3(-hw, 0.0, -depth * 0.5), Vector3(bar, hh * 2.0, depth))
	_add_box(st, Vector3(hw, 0.0, -depth * 0.5), Vector3(bar, hh * 2.0, depth))
	st.generate_normals()

	_frame = MeshInstance3D.new()
	_frame.name = "Frame"
	_frame.mesh = st.commit()
	_frame.material_override = mat
	_frame.layers = LAYER_WORLD
	_frame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_frame)

	var label: String = style["label"]
	if label != "":
		var l := Label3D.new()
		l.text = label
		l.font_size = 64
		l.pixel_size = 0.34 / 64.0
		l.position = Vector3(0.0, hh + bar * 1.4, 0.02)
		l.modulate = style["frame"]
		l.outline_modulate = Color(0.05, 0.02, 0.0, 0.9)
		l.outline_size = 14
		l.double_sided = true
		l.layers = LAYER_WORLD
		add_child(l)


static func _add_box(st: SurfaceTool, centre: Vector3, size: Vector3) -> void:
	var h := size * 0.5
	var c := [
		centre + Vector3(-h.x, -h.y, -h.z), centre + Vector3(h.x, -h.y, -h.z),
		centre + Vector3(h.x, h.y, -h.z), centre + Vector3(-h.x, h.y, -h.z),
		centre + Vector3(-h.x, -h.y, h.z), centre + Vector3(h.x, -h.y, h.z),
		centre + Vector3(h.x, h.y, h.z), centre + Vector3(-h.x, h.y, h.z),
	]
	var faces := [[0, 1, 2, 3], [5, 4, 7, 6], [4, 0, 3, 7], [1, 5, 6, 2],
		[3, 2, 6, 7], [4, 5, 1, 0]]
	for f: Array in faces:
		for i in [0, 1, 2, 0, 2, 3]:
			st.add_vertex(c[f[i]])


# ---------------------------------------------------------------------------
# Linking
# ---------------------------------------------------------------------------

## Link this portal to `other` and cache the pair transform, one way only.
## Call it on both members to make the pair bidirectional — a one-way portal is
## a legitimate puzzle piece, so this does NOT link the peer back implicitly.
func link(other: Portal) -> void:
	peer = other
	link_error = ""
	link_data = null
	if other == null:
		to_peer = Transform3D.IDENTITY
		return
	# `PortalLink.make` computes M and runs the determinant guard — a real
	# runtime check, not `assert()`, because asserts are stripped from release
	# GDScript and the web export is a release build. A reflecting pair errors
	# loudly in the editor and produces silent garbage in the browser
	# (contract §3): the same failure class as the six green deploys that
	# shipped without a physics core.
	var lk := PortalLinkT.make(global_transform, other.global_transform,
		room_index, other.room_index, width * 0.5, height * 0.5)
	link_data = lk
	to_peer = lk.transform
	if not lk.valid or lk.repaired:
		link_error = "%s -> %s: %s" % [name, other.name, ", ".join(lk.warnings)]
		push_warning("[Portal] " + link_error)


func unlink() -> void:
	peer = null
	link_data = null
	to_peer = Transform3D.IDENTITY
	link_error = ""


# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

## World-space surface normal (contract §1: local +Z).
func normal() -> Vector3:
	return global_transform.basis.z.normalized()


func plane() -> Plane:
	return Plane(normal(), global_position)


## The four aperture corners in world space, in the order bl, br, tl, tr.
func corners() -> PackedVector3Array:
	var t := global_transform
	var hw := width * 0.5
	var hh := height * 0.5
	return PackedVector3Array([
		t * Vector3(-hw, -hh, 0.0), t * Vector3(hw, -hh, 0.0),
		t * Vector3(-hw, hh, 0.0), t * Vector3(hw, hh, 0.0),
	])


## True when `p` is in front of the portal (on the +Z side).
func is_in_front(p: Vector3) -> bool:
	return normal().dot(p - global_position) > 0.0


## Aperture test, inset by the disc radius per contract §5. A crossing outside
## this is NOT a portal crossing — it is a wall hit.
func contains_local(p_world: Vector3, inset: float = DISC_RADIUS) -> bool:
	var l := global_transform.affine_inverse() * p_world
	return absf(l.x) <= width * 0.5 - inset and absf(l.y) <= height * 0.5 - inset


# ---------------------------------------------------------------------------
# Renderer hooks (called only by PortalRenderer)
# ---------------------------------------------------------------------------

func set_live_texture(tex: Texture2D) -> void:
	if _live_mat != null:
		_live_mat.set_shader_parameter("portal_tex", tex)
		_live_mat.set_shader_parameter("live", 1.0 if tex != null else 0.0)


func set_live(on: bool) -> void:
	if _live_mat != null:
		_live_mat.set_shader_parameter("live", 1.0 if on else 0.0)

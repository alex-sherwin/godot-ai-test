class_name PortalGhost
extends MeshInstance3D

## The disc's clone at the exit portal, and the clipping that makes the two
## halves add up to one disc.
##
## Without this, a disc crossing a portal *pops*: it is drawn whole on the
## entrance side right up to the crossing frame, then whole on the exit side
## afterwards, and the moment the player is actually watching is the moment the
## illusion breaks. The standard fix, and the one both mature implementations
## use, is a second mesh driven by the pair transform, with each mesh clipped by
## its own portal's plane:
##
##   real disc  keeps the half-space in FRONT of the entrance portal (+Z)
##   ghost      keeps the half-space in FRONT of the exit portal    (+Z)
##
## Before the crossing the ghost is entirely behind the exit plane and every one
## of its fragments is discarded, so it costs a vertex pass and nothing else.
## Through the crossing the two clipped halves are exactly complementary. After
## it, the roles swap when the physics moves the disc into the destination room.
##
## `discard` in the fragment shader, never `ALPHA = 0.0` — see
## `portal_clip.gdshader` for why.

const CLIP_SHADER := preload("res://scenes/portal/portal_clip.gdshader")

## Beyond this from the nearest portal there is nothing to blend, so the ghost
## and both clip planes switch off and the disc renders as an ordinary mesh.
const ARM_DISTANCE := 3.0

## Debug switch only. Turning it off is what the artefact looks like.
var clip_enabled: bool = true

var source: MeshInstance3D = null
var source_material: ShaderMaterial = null

var _ghost_material: ShaderMaterial = null
var _armed_portal: Portal = null


## `disc` is the scene's real disc mesh; its material is REPLACED with a clip
## material carrying the same colour, because the clip has to apply to the real
## mesh as well as to the clone.
func setup(disc: MeshInstance3D, colour: Color) -> void:
	source = disc
	source_material = make_clip_material(colour)
	if source != null:
		source.material_override = source_material

	mesh = disc.mesh if disc != null else null
	_ghost_material = make_clip_material(colour)
	# A faint rim on the ghost only: it is emerging from a portal, and a little
	# edge light sells that without making it a different disc.
	_ghost_material.set_shader_parameter("rim_light", 0.35)
	material_override = _ghost_material
	layers = Portal.LAYER_WORLD
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	visible = false


static func make_clip_material(colour: Color) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = CLIP_SHADER
	m.set_shader_parameter("albedo", colour)
	m.set_shader_parameter("roughness_v", 0.55)
	m.set_shader_parameter("metallic_v", 0.0)
	m.set_shader_parameter("rim_light", 0.0)
	m.set_shader_parameter("clip_enabled", 0.0)
	return m


## Drive the ghost from the disc's world transform. Returns the portal it armed
## against, or null. Call once per frame, after the simulation has moved the
## disc.
func track(disc_xform: Transform3D, portals: Array[Portal]) -> Portal:
	var p := _nearest_armed(disc_xform.origin, portals)
	_armed_portal = p
	if p == null or p.peer == null:
		visible = false
		_set_clip(source_material, null)
		_set_clip(_ghost_material, null)
		return null

	global_transform = p.to_peer * disc_xform
	visible = true
	_set_clip(source_material, p if clip_enabled else null)
	_set_clip(_ghost_material, p.peer if clip_enabled else null)
	return p


func armed_portal() -> Portal:
	return _armed_portal


## Nearest portal whose plane the disc is within `ARM_DISTANCE` of AND whose
## aperture it is actually lined up with. Arming on plane distance alone lights
## up a ghost for a disc sailing past the far end of the same wall.
static func _nearest_armed(pos: Vector3, portals: Array[Portal]) -> Portal:
	var best: Portal = null
	var best_d := ARM_DISTANCE
	for p: Portal in portals:
		if p == null or not is_instance_valid(p) or p.peer == null:
			continue
		var d := absf(p.plane().distance_to(pos))
		if d >= best_d:
			continue
		# Generous lateral margin: the ghost may legitimately be half outside
		# the aperture, it is the clip plane's job to hide the rest.
		if not p.contains_local(pos, -0.5):
			continue
		best = p
		best_d = d
	return best


static func _set_clip(mat: ShaderMaterial, p: Portal) -> void:
	if mat == null:
		return
	if p == null:
		mat.set_shader_parameter("clip_enabled", 0.0)
		return
	var pl := Plane(p.normal(), p.global_position)
	# Godot maps a Plane onto a vec4 uniform as (normal.xyz, d), which is what
	# the shader's half-space test expects.
	mat.set_shader_parameter("clip_plane", pl)
	mat.set_shader_parameter("clip_enabled", 1.0)

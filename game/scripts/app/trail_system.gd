class_name TrailSystem
extends Node3D

## Trajectory trails, ground projections and landing markers.
##
## The point of this is comparison. One flight in isolation tells you almost
## nothing; a Destroyer's trail sitting next to an Aviar's, both drawn from the
## same tee with the same legend colours, tells you the whole story at a glance.
## So every landed flight is frozen into a ghost that stays until cleared.
##
## Each trail is drawn three times:
##   * the trail itself, a screen-facing ribbon (see RibbonBuilder)
##   * its projection flattened onto the range floor, which is the only
##     unambiguous read of lateral deflection — in a perspective view a high
##     straight flight and a low turning one look identical
##   * a landing marker with the distance and signed lateral offset
##
## A landed ghost is static geometry: no per-frame cost regardless of how many
## are on screen.

const MAX_GHOSTS := 8
const MIN_POINT_SPACING := 0.40   ## m; the sim samples far finer than we need
const SHADOW_Y := 0.05
const TRAIL_WIDTH := 0.26
const SHADOW_WIDTH := 0.20

## Distinct, colour-blind-tolerant hues that stay legible against grass.
const PALETTE: Array[Color] = [
	Color(0.35, 0.78, 1.00),   # cyan
	Color(1.00, 0.72, 0.28),   # amber
	Color(0.55, 0.92, 0.55),   # green
	Color(1.00, 0.47, 0.62),   # pink
	Color(0.72, 0.55, 1.00),   # violet
	Color(1.00, 0.95, 0.45),   # yellow
	Color(0.40, 0.95, 0.85),   # teal
	Color(1.00, 0.58, 0.38),   # coral
]

var _live_points := PackedVector3Array()
var _live_color: Color = PALETTE[0]
var _live_mesh: MeshInstance3D = null
var _live_shadow: MeshInstance3D = null
var _live_dirty: bool = false
var _live_label: String = ""

var _ghosts: Array = []           ## [{node, color, label, distance, lateral}]
var _next_color: int = 0
var _blob: MeshInstance3D = null

var _trail_mat: ShaderMaterial = null
var _shadow_mat: ShaderMaterial = null


func _ready() -> void:
	# The ribbon shader treats model space as world space.
	transform = Transform3D.IDENTITY
	_trail_mat = RibbonBuilder.make_material(TRAIL_WIDTH, 0.0024, 1.0, 4.0, 20.0)
	_shadow_mat = RibbonBuilder.make_material(SHADOW_WIDTH, 0.0016, 1.0, 3.0, 14.0)

	_live_mesh = MeshInstance3D.new()
	_live_mesh.name = "LiveTrail"
	_live_mesh.material_override = _trail_mat
	_live_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_live_mesh)

	_live_shadow = MeshInstance3D.new()
	_live_shadow.name = "LiveShadow"
	_live_shadow.material_override = _shadow_mat
	_live_shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_live_shadow)

	_build_blob()


func _process(_delta: float) -> void:
	if _live_dirty:
		_rebuild_live()
		_live_dirty = false


# ---------------------------------------------------------------------------
# Live trail
# ---------------------------------------------------------------------------

## Start a new flight. Returns the colour assigned to it, for the legend.
func begin_flight(label: String) -> Color:
	_live_points = PackedVector3Array()
	_live_color = PALETTE[_next_color % PALETTE.size()]
	_live_label = label
	_live_mesh.mesh = null
	_live_shadow.mesh = null
	if _blob:
		_blob.visible = true
	return _live_color


func add_point(p: Vector3) -> void:
	var n := _live_points.size()
	if n > 0 and _live_points[n - 1].distance_squared_to(p) < MIN_POINT_SPACING * MIN_POINT_SPACING:
		return
	_live_points.append(p)
	_live_dirty = true


func set_disc_altitude(pos: Vector3) -> void:
	if _blob == null:
		return
	# The blob is the cheap always-there shadow: it grows and fades with height
	# so the disc's altitude reads even where the sun shadow is off-screen.
	var h: float = maxf(pos.y, 0.0)
	var s: float = clampf(0.55 + h * 0.045, 0.55, 2.6)
	_blob.global_position = Vector3(pos.x, SHADOW_Y + 0.005, pos.z)
	_blob.scale = Vector3(s, 1.0, s)
	var a: float = clampf(0.42 - h * 0.006, 0.10, 0.42)
	var m: StandardMaterial3D = _blob.material_override
	if m:
		m.albedo_color = Color(0.05, 0.08, 0.06, a)


func _rebuild_live() -> void:
	if _live_points.size() < 2:
		return
	var head: Color = _live_color
	var tail: Color = _live_color.darkened(0.25)
	tail.a = 0.85
	_live_mesh.mesh = RibbonBuilder.build(_live_points, head, tail)
	var sc := Color(0.06, 0.10, 0.08, 0.45)
	_live_shadow.mesh = RibbonBuilder.build(_live_points, sc, sc, 0.0, SHADOW_Y)


## Freeze the live trail into a ghost and drop a landing marker.
func end_flight(distance_m: float, lateral_m: float, landing: Vector3) -> void:
	_live_dirty = false
	_rebuild_live()
	if _blob:
		_blob.visible = false
	if _live_points.size() < 2:
		return

	var g := Node3D.new()
	g.name = "Ghost%d" % _next_color
	add_child(g)

	var ghost_color: Color = _live_color
	ghost_color.a = 0.80
	var trail := MeshInstance3D.new()
	trail.mesh = RibbonBuilder.build(_live_points, ghost_color, ghost_color.darkened(0.2))
	trail.material_override = _trail_mat
	trail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	g.add_child(trail)

	var sc := Color(0.06, 0.10, 0.08, 0.35)
	var shadow := MeshInstance3D.new()
	shadow.mesh = RibbonBuilder.build(_live_points, sc, sc, 0.0, SHADOW_Y)
	shadow.material_override = _shadow_mat
	shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	g.add_child(shadow)

	_add_marker(g, landing, _live_color, distance_m, lateral_m)

	_ghosts.append({
		"node": g, "color": _live_color, "label": _live_label,
		"distance": distance_m, "lateral": lateral_m,
	})
	_next_color += 1

	_live_mesh.mesh = null
	_live_shadow.mesh = null
	_live_points = PackedVector3Array()

	while _ghosts.size() > MAX_GHOSTS:
		var old: Dictionary = _ghosts.pop_front()
		(old["node"] as Node).queue_free()


func clear_all() -> void:
	for gh in _ghosts:
		(gh["node"] as Node).queue_free()
	_ghosts.clear()
	_live_points = PackedVector3Array()
	_live_mesh.mesh = null
	_live_shadow.mesh = null
	_next_color = 0
	if _blob:
		_blob.visible = false


## [{color, label, distance, lateral}] oldest first, for the HUD legend.
func legend_entries() -> Array:
	var out: Array = []
	for gh in _ghosts:
		out.append({"color": gh["color"], "label": gh["label"],
			"distance": gh["distance"], "lateral": gh["lateral"]})
	return out


func live_color() -> Color:
	return _live_color


# ---------------------------------------------------------------------------
# Markers
# ---------------------------------------------------------------------------

func _add_marker(parent: Node3D, landing: Vector3, color: Color,
		distance_m: float, lateral_m: float) -> void:
	var root := Node3D.new()
	root.position = Vector3(landing.x, 0.0, landing.z)
	parent.add_child(root)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.75
	tm.outer_radius = 1.05
	tm.rings = 20
	tm.ring_segments = 5
	ring.mesh = tm
	ring.position = Vector3(0.0, SHADOW_Y + 0.02, 0.0)
	ring.material_override = mat
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(ring)

	var pin := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.035
	cm.bottom_radius = 0.035
	cm.height = 2.0
	cm.radial_segments = 5
	cm.rings = 1
	pin.mesh = cm
	pin.position = Vector3(0.0, 1.0, 0.0)
	pin.material_override = mat
	pin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(pin)

	var side := "R" if lateral_m >= 0.0 else "L"
	var label := Label3D.new()
	label.text = "%.1f m\n%.1f m %s" % [distance_m, absf(lateral_m), side]
	label.position = Vector3(0.0, 2.4, 0.0)
	label.modulate = color
	label.outline_modulate = Color(0.02, 0.04, 0.07, 0.9)
	label.outline_size = 14
	label.font_size = 64
	label.pixel_size = 0.60 / 64.0
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.double_sided = true
	root.add_child(label)


func _build_blob() -> void:
	_blob = MeshInstance3D.new()
	_blob.name = "DiscShadowBlob"
	var qm := QuadMesh.new()
	qm.size = Vector2(1.4, 1.4)
	qm.orientation = PlaneMesh.FACE_Y
	_blob.mesh = qm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(0.05, 0.08, 0.06, 0.4)
	m.albedo_texture = _blob_texture()
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_blob.material_override = m
	_blob.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_blob.visible = false
	add_child(_blob)


func _blob_texture(size: int = 64) -> ImageTexture:
	var img := Image.create_empty(size, size, true, Image.FORMAT_RGBA8)
	var c: float = float(size) * 0.5
	for y in size:
		for x in size:
			var d: float = Vector2(float(x) - c + 0.5, float(y) - c + 0.5).length() / c
			var a: float = clampf(1.0 - smoothstep(0.35, 1.0, d), 0.0, 1.0)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

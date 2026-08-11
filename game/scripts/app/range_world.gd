class_name RangeWorld
extends Node3D

## The measured test range: 200 m of instrumented ground, built procedurally.
##
## The brief is an *instrument*, not a golf course. Every mark on the ground is
## a readable measurement — 10 m ticks, 50 m labelled gates, lateral offset
## gridlines every 5 m — so a flight's distance and deflection can be read off
## the floor without a HUD. Scenery exists only to give the eye a scale
## reference and a horizon; it is deliberately sparse.
##
## World frame per CONTRACT §1: -Z is downrange, +X is the thrower's right,
## Y is up, and the tee is the origin.
##
## GL COMPATIBILITY (WebGL2) BUDGET. Everything here is either a static mesh or
## a MultiMesh:
##   * ground + lane            2 draw calls, procedural noise albedo
##   * all markings             1 draw call   (one ArrayMesh of unshaded quads)
##   * tee pad, basket          ~5 draw calls
##   * tree line                2 MultiMesh draw calls, ~120 instances
##   * labels                   1 per label (Label3D), ~18 total
## No SDFGI / SSAO / SSR / volumetric fog anywhere: none of them exist in the
## Compatibility renderer, and a Forward+ feature fails silently on web.

const LANE_HALF_WIDTH := 22.0     ## mown lane half-width, m
const GROUND_HALF := 320.0        ## ground plane half-extent, m
const MARK_Y := 0.02              ## markings sit just above the lane
const TREE_LINE_X := 47.0

@export var range_length_m: float = 200.0
@export var tick_spacing_m: float = 10.0
@export var label_spacing_m: float = 50.0
@export var lateral_spacing_m: float = 5.0
@export var lateral_extent_m: float = 20.0
@export var basket_distance_m: float = 80.0
@export var show_basket: bool = true

var _basket: Node3D = null
var _labels: Array[Label3D] = []


func _ready() -> void:
	build()


func build() -> void:
	_build_ground()
	_build_markings()
	_build_labels()
	_build_tee_pad()
	_build_basket()
	_build_tree_line()


func set_basket_distance(d: float) -> void:
	basket_distance_m = clampf(d, 10.0, range_length_m)
	if _basket:
		_basket.position = Vector3(0.0, 0.0, -basket_distance_m)


func set_basket_visible(v: bool) -> void:
	show_basket = v
	if _basket:
		_basket.visible = v


# ---------------------------------------------------------------------------
# Ground
# ---------------------------------------------------------------------------

func _build_ground() -> void:
	# Rough ground, well outside the lane.
	var rough := MeshInstance3D.new()
	rough.name = "Ground"
	var pm := PlaneMesh.new()
	pm.size = Vector2(GROUND_HALF * 2.0, GROUND_HALF * 2.0)
	pm.subdivide_width = 1
	pm.subdivide_depth = 1
	rough.mesh = pm
	rough.material_override = _grass_material(Color(0.271, 0.361, 0.180), 42.0, 0.14)
	rough.position = Vector3(0.0, -0.02, -range_length_m * 0.35)
	rough.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(rough)

	# The mown lane: lighter, and long enough to run past the far markers.
	var lane := MeshInstance3D.new()
	lane.name = "Lane"
	var lm := PlaneMesh.new()
	lm.size = Vector2(LANE_HALF_WIDTH * 2.0, range_length_m + 40.0)
	lane.mesh = lm
	lane.material_override = _grass_material(Color(0.365, 0.482, 0.223), 9.0, 0.09)
	lane.position = Vector3(0.0, 0.0, -(range_length_m - 20.0) * 0.5)
	lane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(lane)


## Procedural grass: value noise baked once into a small tiling texture. Gives
## the ground enough variation to read as a surface without a texture asset and
## without a shader that Compatibility might not like.
func _grass_material(base: Color, tiles: float, contrast: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color.WHITE
	m.albedo_texture = _noise_texture(base, contrast)
	m.uv1_scale = Vector3(tiles, tiles, 1.0)
	m.roughness = 1.0
	m.metallic = 0.0
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return m


func _noise_texture(base: Color, contrast: float, size: int = 128) -> ImageTexture:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.seed = 20260811
	noise.frequency = 0.045
	noise.fractal_octaves = 3
	var fine := FastNoiseLite.new()
	fine.noise_type = FastNoiseLite.TYPE_VALUE
	fine.seed = 991
	fine.frequency = 0.32

	var img := Image.create_empty(size, size, true, Image.FORMAT_RGB8)
	for y in size:
		for x in size:
			# Sampled on a torus so the tile wraps without a visible seam.
			var a := TAU * float(x) / float(size)
			var b := TAU * float(y) / float(size)
			var r := float(size) / TAU
			var n: float = noise.get_noise_3d(cos(a) * r, sin(a) * r, cos(b) * r) * 0.6
			n += fine.get_noise_2d(float(x), float(y)) * 0.4
			img.set_pixel(x, y, base.lightened(maxf(n, 0.0) * contrast)
				.darkened(maxf(-n, 0.0) * contrast))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


# ---------------------------------------------------------------------------
# Markings — one mesh, one draw call
# ---------------------------------------------------------------------------

func _build_markings() -> void:
	var quads: Array = []
	var minor := Color(0.80, 0.86, 0.90, 0.55)
	var major := Color(1.0, 1.0, 1.0, 0.92)
	var axis := Color(0.62, 0.82, 1.0, 0.80)
	var lat := Color(0.72, 0.80, 0.88, 0.42)
	var lat_major := Color(0.86, 0.92, 1.0, 0.62)

	# Downrange ticks, drawn across the lane.
	var d: float = tick_spacing_m
	while d <= range_length_m + 0.01:
		var is_major: bool = fmod(d + 0.001, label_spacing_m) < 0.01
		var w: float = 0.55 if is_major else 0.26
		var half: float = LANE_HALF_WIDTH if is_major else lateral_extent_m + 2.0
		quads.append(_quad(-half, half, -d - w * 0.5, -d + w * 0.5,
			major if is_major else minor))
		d += tick_spacing_m

	# Lateral offset gridlines, running the length of the range.
	var z0: float = 4.0
	var z1: float = -(range_length_m + 8.0)
	var x: float = -lateral_extent_m
	while x <= lateral_extent_m + 0.01:
		if absf(x) < 0.01:
			quads.append(_quad(-0.22, 0.22, z1, z0, axis))
		else:
			var is_major: bool = fmod(absf(x) + 0.001, 10.0) < 0.01
			var w: float = 0.22 if is_major else 0.13
			quads.append(_quad(x - w, x + w, z1, z0, lat_major if is_major else lat))
		x += lateral_spacing_m

	# Tee line.
	quads.append(_quad(-LANE_HALF_WIDTH, LANE_HALF_WIDTH, -0.3, 0.3,
		Color(1.0, 0.85, 0.35, 0.9)))

	var mi := MeshInstance3D.new()
	mi.name = "Markings"
	mi.mesh = RibbonBuilder.build_quads(quads)
	mi.material_override = _marking_material()
	mi.position = Vector3(0.0, MARK_Y, 0.0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


func _quad(x0: float, x1: float, z0: float, z1: float, c: Color) -> Dictionary:
	return {
		"a": Vector3(x0, 0.0, z0), "b": Vector3(x1, 0.0, z0),
		"c": Vector3(x0, 0.0, z1), "d": Vector3(x1, 0.0, z1),
		"color": c,
	}


func _marking_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Markings are painted ON the ground, so they must not fight it for depth.
	m.render_priority = 1
	m.no_depth_test = false
	return m


# ---------------------------------------------------------------------------
# Labels
# ---------------------------------------------------------------------------

func _build_labels() -> void:
	# Distance gates: a post either side of the lane at every label interval,
	# each carrying a billboarded number so it reads from every camera view.
	var d: float = label_spacing_m
	while d <= range_length_m + 0.01:
		for side in [-1.0, 1.0]:
			_add_post(Vector3(side * (lateral_extent_m + 1.6), 0.0, -d), 2.4)
			_add_label("%d m" % int(round(d)),
				Vector3(side * (lateral_extent_m + 1.6), 2.9, -d),
				Color(1.0, 0.98, 0.90), 0.80)
		d += label_spacing_m

	# Lateral offset callouts, near enough to the tee to be read at release.
	var x: float = -lateral_extent_m
	while x <= lateral_extent_m + 0.01:
		if absf(x) > 0.01 and fmod(absf(x) + 0.001, 10.0) < 0.01:
			var txt := "%+d m" % int(round(x))
			_add_label(txt, Vector3(x, 1.05, -18.0), Color(0.78, 0.88, 1.0), 0.55)
		x += lateral_spacing_m
	_add_label("TEE", Vector3(0.0, 1.05, 3.4), Color(1.0, 0.85, 0.35), 0.55)


func _add_label(text: String, pos: Vector3, color: Color, height_m: float) -> void:
	var l := Label3D.new()
	l.text = text
	l.position = pos
	l.modulate = color
	l.outline_modulate = Color(0.02, 0.04, 0.07, 0.85)
	l.outline_size = 12
	l.font_size = 64
	# Label3D sizes glyphs as font_size * pixel_size metres.
	l.pixel_size = height_m / 64.0
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = false
	l.fixed_size = false
	l.double_sided = true
	l.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	add_child(l)
	_labels.append(l)


func _add_post(base: Vector3, height: float) -> void:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.045
	cm.bottom_radius = 0.055
	cm.height = height
	cm.radial_segments = 6
	cm.rings = 1
	mi.mesh = cm
	mi.position = base + Vector3(0.0, height * 0.5, 0.0)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.86, 0.88, 0.90)
	m.roughness = 0.7
	mi.material_override = m
	add_child(mi)


# ---------------------------------------------------------------------------
# Tee pad and basket
# ---------------------------------------------------------------------------

func _build_tee_pad() -> void:
	var mi := MeshInstance3D.new()
	mi.name = "TeePad"
	var bm := BoxMesh.new()
	bm.size = Vector3(3.0, 0.12, 4.5)
	mi.mesh = bm
	mi.position = Vector3(0.0, 0.04, 1.9)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.40, 0.41, 0.43)
	m.roughness = 0.95
	mi.material_override = m
	add_child(mi)


func _build_basket() -> void:
	var root := Node3D.new()
	root.name = "Basket"
	root.position = Vector3(0.0, 0.0, -basket_distance_m)
	add_child(root)
	_basket = root

	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.68, 0.70, 0.74)
	metal.metallic = 0.55
	metal.roughness = 0.42

	var band := StandardMaterial3D.new()
	band.albedo_color = Color(0.95, 0.78, 0.22)
	band.roughness = 0.6

	var pole := MeshInstance3D.new()
	var pm := CylinderMesh.new()
	pm.top_radius = 0.035
	pm.bottom_radius = 0.05
	pm.height = 1.36
	pm.radial_segments = 8
	pole.mesh = pm
	pole.position = Vector3(0.0, 0.68, 0.0)
	pole.material_override = metal
	root.add_child(pole)

	var basket := MeshInstance3D.new()
	var bm := CylinderMesh.new()
	bm.top_radius = 0.33
	bm.bottom_radius = 0.24
	bm.height = 0.22
	bm.radial_segments = 14
	basket.mesh = bm
	basket.position = Vector3(0.0, 0.72, 0.0)
	basket.material_override = metal
	root.add_child(basket)

	var top := MeshInstance3D.new()
	var tm := CylinderMesh.new()
	tm.top_radius = 0.34
	tm.bottom_radius = 0.34
	tm.height = 0.05
	tm.radial_segments = 14
	top.mesh = tm
	top.position = Vector3(0.0, 1.36, 0.0)
	top.material_override = band
	root.add_child(top)

	# Chains as a thin cylindrical shell — cheaper and reads better at distance
	# than modelling links that are 2 px wide.
	var chains := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.30
	cm.bottom_radius = 0.20
	cm.height = 0.60
	cm.radial_segments = 12
	cm.rings = 1
	chains.mesh = cm
	chains.position = Vector3(0.0, 1.05, 0.0)
	var chain_mat := StandardMaterial3D.new()
	chain_mat.albedo_color = Color(0.72, 0.74, 0.78, 0.55)
	chain_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	chain_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	chain_mat.metallic = 0.5
	chain_mat.roughness = 0.35
	chains.material_override = chain_mat
	root.add_child(chains)

	_add_label("BASKET %d m" % int(round(basket_distance_m)),
		Vector3(0.0, 2.1, -basket_distance_m), Color(0.95, 0.85, 0.45), 0.55)
	root.visible = show_basket


# ---------------------------------------------------------------------------
# Scenery
# ---------------------------------------------------------------------------

## A sparse tree line well outside the lane. Its only job is scale and horizon
## interest — without it a 200 m field of grass reads as an empty wedge with no
## depth cue at all.
func _build_tree_line() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242

	var trunk_mesh := CylinderMesh.new()
	trunk_mesh.top_radius = 0.16
	trunk_mesh.bottom_radius = 0.28
	trunk_mesh.height = 2.6
	trunk_mesh.radial_segments = 5
	trunk_mesh.rings = 1

	var canopy_mesh := CylinderMesh.new()
	canopy_mesh.top_radius = 0.0
	canopy_mesh.bottom_radius = 2.6
	canopy_mesh.height = 8.5
	canopy_mesh.radial_segments = 7
	canopy_mesh.rings = 1

	var trunk_mat := StandardMaterial3D.new()
	trunk_mat.albedo_color = Color(0.263, 0.192, 0.137)
	trunk_mat.roughness = 1.0
	trunk_mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	trunk_mesh.material = trunk_mat

	var canopy_mat := StandardMaterial3D.new()
	canopy_mat.albedo_color = Color(0.180, 0.290, 0.161)
	canopy_mat.roughness = 1.0
	canopy_mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	canopy_mesh.material = canopy_mat

	var transforms: Array[Transform3D] = []
	var z: float = 24.0
	while z > -(range_length_m + 70.0):
		for side in [-1.0, 1.0]:
			var x: float = side * (TREE_LINE_X + rng.randf_range(0.0, 16.0))
			var s: float = rng.randf_range(0.8, 1.5)
			var t := Transform3D(Basis.from_euler(Vector3(0.0, rng.randf_range(0.0, TAU), 0.0))
				.scaled(Vector3(s, s, s)), Vector3(x, 0.0, z + rng.randf_range(-6.0, 6.0)))
			transforms.append(t)
		z -= rng.randf_range(12.0, 22.0)
	# Close the far end so the range reads as a bounded field.
	var xb: float = -85.0
	while xb <= 85.0:
		var s2: float = rng.randf_range(0.9, 1.6)
		transforms.append(Transform3D(
			Basis.from_euler(Vector3(0.0, rng.randf_range(0.0, TAU), 0.0)).scaled(Vector3(s2, s2, s2)),
			Vector3(xb + rng.randf_range(-6.0, 6.0), 0.0,
				-(range_length_m + 62.0) + rng.randf_range(-14.0, 14.0))))
		xb += rng.randf_range(9.0, 16.0)

	_add_multimesh("TreeTrunks", trunk_mesh, transforms, Vector3(0.0, 1.3, 0.0))
	_add_multimesh("TreeCanopies", canopy_mesh, transforms, Vector3(0.0, 6.4, 0.0))


func _add_multimesh(node_name: String, mesh: Mesh, transforms: Array[Transform3D],
		local_offset: Vector3) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for i in transforms.size():
		var t: Transform3D = transforms[i]
		mm.set_instance_transform(i, t.translated_local(local_offset))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)

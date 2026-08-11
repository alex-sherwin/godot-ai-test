class_name WindVisualizer
extends Node3D

## Honest wind: everything here is driven by the actual `wind` vector handed to
## the physics core, so if the streamers drift downrange the disc really is
## getting a tailwind. Three readouts, because one is not enough:
##
##   * drifting streamers through the flight volume — direction and, through
##     their speed, rough magnitude
##   * a windsock by the tee, which droops toward vertical as the wind drops to
##     nothing rather than pretending there is a breeze
##   * a ground arrow and a numeric label, for the cases where you need the
##     actual number
##
## CPUParticles3D rather than GPUParticles3D: CPU particles are a MultiMesh
## under the hood and are guaranteed in the Compatibility renderer.

const MIN_WIND := 0.15    ## m/s below which we show "calm" and hide the streamers
const SOCK_POS := Vector3(-15.0, 0.0, -8.0)

var _particles: CPUParticles3D = null
var _sock_pivot: Node3D = null
var _arrow: Node3D = null
var _label: Label3D = null
var _wind := Vector3.ZERO


func _ready() -> void:
	_build_particles()
	_build_sock()
	set_wind(Vector3.ZERO)


func set_wind(w: Vector3) -> void:
	_wind = w
	var speed: float = w.length()
	var calm: bool = speed < MIN_WIND
	var dir: Vector3 = Vector3(0.0, 0.0, -1.0) if calm else w / speed

	if _particles:
		_particles.emitting = not calm
		if not calm:
			_particles.direction = dir
			_particles.initial_velocity_min = speed * 0.85
			_particles.initial_velocity_max = speed * 1.15
			# Long enough to cross the volume, capped so the count stays honest.
			_particles.lifetime = clampf(190.0 / maxf(speed, 0.5), 3.0, 14.0)

	if _sock_pivot:
		# A real sock hangs under its own weight and only lifts as the wind
		# picks up; ~5 m/s is roughly full extension.
		var droop: Vector3 = dir * speed + Vector3(0.0, -4.0, 0.0)
		_sock_pivot.quaternion = Quaternion(Vector3.UP, droop.normalized())

	if _arrow:
		_arrow.visible = not calm
		if not calm:
			var flat := Vector3(dir.x, 0.0, dir.z)
			if flat.length_squared() < 1e-6:
				flat = Vector3(0.0, 0.0, -1.0)
			_arrow.quaternion = Quaternion(Vector3.UP, flat.normalized())

	if _label:
		if calm:
			_label.text = "WIND  calm"
		else:
			# Downrange / crosswind split is what a thrower actually wants: -Z is
			# downrange, +X is to the thrower's right (CONTRACT §1).
			var along: float = -w.z
			var cross: float = w.x
			_label.text = "WIND %.1f m/s\n%+.1f down-range  %+.1f cross" % [speed, along, cross]


func get_wind() -> Vector3:
	return _wind


# ---------------------------------------------------------------------------

func _build_particles() -> void:
	var p := CPUParticles3D.new()
	p.name = "Streamers"
	p.amount = 190
	p.lifetime = 8.0
	p.preprocess = 4.0
	p.local_coords = false
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(42.0, 9.0, 105.0)
	p.position = Vector3(0.0, 9.0, -95.0)
	p.gravity = Vector3.ZERO
	p.spread = 4.0
	p.particle_flag_align_y = true   # streaks lie along their own velocity
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.5

	var bm := BoxMesh.new()
	bm.size = Vector3(0.05, 2.2, 0.05)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.78, 0.90, 1.0, 0.34)
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	bm.material = m
	p.mesh = bm

	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1, 0))
	ramp.set_color(1, Color(1, 1, 1, 0))
	ramp.add_point(0.25, Color(1, 1, 1, 1))
	ramp.add_point(0.75, Color(1, 1, 1, 1))
	p.color_ramp = ramp

	add_child(p)
	_particles = p


func _build_sock() -> void:
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.80, 0.82, 0.85)
	metal.roughness = 0.6

	var pole := MeshInstance3D.new()
	var pm := CylinderMesh.new()
	pm.top_radius = 0.05
	pm.bottom_radius = 0.07
	pm.height = 4.2
	pm.radial_segments = 8
	pole.mesh = pm
	pole.position = SOCK_POS + Vector3(0.0, 2.1, 0.0)
	pole.material_override = metal
	add_child(pole)

	var pivot := Node3D.new()
	pivot.position = SOCK_POS + Vector3(0.0, 4.2, 0.0)
	add_child(pivot)
	_sock_pivot = pivot

	# Two bands so rotation is visible, cone opening upwind.
	var sock_mat_a := StandardMaterial3D.new()
	sock_mat_a.albedo_color = Color(0.95, 0.42, 0.18)
	sock_mat_a.cull_mode = BaseMaterial3D.CULL_DISABLED
	sock_mat_a.roughness = 0.85
	var sock_mat_b := StandardMaterial3D.new()
	sock_mat_b.albedo_color = Color(0.96, 0.95, 0.92)
	sock_mat_b.cull_mode = BaseMaterial3D.CULL_DISABLED
	sock_mat_b.roughness = 0.85

	var seg_len := 0.55
	for i in 4:
		var seg := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.bottom_radius = lerpf(0.34, 0.20, float(i) / 4.0)
		cm.top_radius = lerpf(0.34, 0.20, float(i + 1) / 4.0)
		cm.height = seg_len
		cm.radial_segments = 10
		cm.rings = 1
		seg.mesh = cm
		seg.position = Vector3(0.0, seg_len * (float(i) + 0.5), 0.0)
		seg.material_override = sock_mat_a if i % 2 == 0 else sock_mat_b
		pivot.add_child(seg)

	# Ground arrow + numeric readout beside the sock.
	var arrow := Node3D.new()
	arrow.position = SOCK_POS + Vector3(0.0, 0.06, 0.0)
	add_child(arrow)
	_arrow = arrow

	var arrow_mat := StandardMaterial3D.new()
	arrow_mat.albedo_color = Color(0.98, 0.86, 0.35, 0.9)
	arrow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	arrow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	arrow_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var shaft := MeshInstance3D.new()
	var sb := BoxMesh.new()
	sb.size = Vector3(0.30, 0.02, 1.0)
	shaft.mesh = sb
	# The arrow node's +Y is rotated onto the wind direction, so the mesh must
	# extend along +Y before rotation.
	shaft.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	shaft.position = Vector3(0.0, 0.5, 0.0)
	shaft.material_override = arrow_mat
	arrow.add_child(shaft)

	var head := MeshInstance3D.new()
	var hm := CylinderMesh.new()
	hm.top_radius = 0.0
	hm.bottom_radius = 0.42
	hm.height = 0.9
	hm.radial_segments = 4
	hm.rings = 1
	head.mesh = hm
	head.position = Vector3(0.0, 1.45, 0.0)
	head.material_override = arrow_mat
	arrow.add_child(head)

	var l := Label3D.new()
	l.position = SOCK_POS + Vector3(0.0, 5.4, 0.0)
	l.modulate = Color(0.98, 0.90, 0.55)
	l.outline_modulate = Color(0.02, 0.04, 0.07, 0.9)
	l.outline_size = 12
	l.font_size = 64
	l.pixel_size = 0.55 / 64.0
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.double_sided = true
	add_child(l)
	_label = l

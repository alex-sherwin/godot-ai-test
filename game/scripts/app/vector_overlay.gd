class_name VectorOverlay
extends Node3D

## Live force and moment vectors drawn on the disc: lift, drag, weight, the spin
## axis and the airspeed vector.
##
## SCALING. These quantities span orders of magnitude — weight is a fixed 1.7 N
## while lift at release can be 6 N and at the apex of a hyzer flip is near zero
## — so an arbitrary "looks nice" scale would be a lie. The scale here is fixed
## and stated: WEIGHT IS ALWAYS 1.6 m LONG, and every other force is drawn at
## the same newtons-per-metre. Lift twice as long as weight means lift is twice
## the weight. Each arrow is labelled with its magnitude, and an arrow that hits
## the length clamp is marked so a clipped arrow can never be misread.
##
## The spin arrow is a moment, not a force, so it is drawn on its own fixed
## length along the physical angular-velocity direction. Per CONTRACT §1 that
## points DOWN through the disc for a RHBH throw: if this arrow ever points up
## on a positive-spin throw, the sign convention has inverted somewhere.

const WEIGHT_LENGTH := 1.6      ## metres drawn per (mass * g) newtons
const MAX_LENGTH := 7.0
const SPIN_LENGTH := 1.5
const VELOCITY_SCALE := 0.11    ## metres per m/s

const COL_LIFT := Color(0.35, 0.95, 0.45)
const COL_DRAG := Color(1.00, 0.42, 0.35)
const COL_WEIGHT := Color(0.62, 0.72, 1.00)
const COL_SPIN := Color(1.00, 0.86, 0.25)
const COL_VEL := Color(0.45, 0.85, 1.00)

var _arrows: Dictionary = {}    ## name -> {root, shaft, head, label}
var _enabled: bool = true


func _ready() -> void:
	_make_arrow("velocity", COL_VEL, 0.030, 0.95)
	_make_arrow("drag", COL_DRAG, 0.045, 0.25)
	_make_arrow("lift", COL_LIFT, 0.045, 0.25)
	_make_arrow("weight", COL_WEIGHT, 0.045, 0.55)
	_make_arrow("spin", COL_SPIN, 0.038, 0.25)
	set_enabled(true)


func set_enabled(on: bool) -> void:
	_enabled = on
	visible = on


func is_enabled() -> bool:
	return _enabled


func hide_all() -> void:
	for k in _arrows:
		(_arrows[k]["root"] as Node3D).visible = false


## `forces` carries lift/drag/weight in newtons (world frame), `spin_axis` as a
## unit vector along the physical angular velocity, and `velocity` in m/s.
func update_vectors(origin: Vector3, forces: Dictionary, mass_kg: float,
		gravity: float) -> void:
	if not _enabled:
		return
	global_position = Vector3.ZERO
	var newtons_per_m: float = maxf(mass_kg * gravity, 1e-4) / WEIGHT_LENGTH

	_place("lift", origin, forces.get("lift", Vector3.ZERO) / newtons_per_m,
		"Lift %.2f N" % (forces.get("lift", Vector3.ZERO) as Vector3).length())
	_place("drag", origin, forces.get("drag", Vector3.ZERO) / newtons_per_m,
		"Drag %.2f N" % (forces.get("drag", Vector3.ZERO) as Vector3).length())
	_place("weight", origin, forces.get("weight", Vector3.ZERO) / newtons_per_m,
		"Weight %.2f N" % (forces.get("weight", Vector3.ZERO) as Vector3).length())
	var vel: Vector3 = forces.get("velocity", Vector3.ZERO)
	_place("velocity", origin, vel * VELOCITY_SCALE, "%.1f m/s" % vel.length())
	var axis: Vector3 = forces.get("spin_axis", Vector3.ZERO)
	var rps: float = forces.get("spin_rps", 0.0)
	_place("spin", origin, axis * SPIN_LENGTH, "spin %.0f rev/s" % absf(rps))


func _place(key: String, origin: Vector3, vec: Vector3, label_text: String) -> void:
	var a: Dictionary = _arrows[key]
	var root: Node3D = a["root"]
	var length: float = vec.length()
	if length < 0.02:
		root.visible = false
		return
	var clipped: bool = length > MAX_LENGTH
	if clipped:
		length = MAX_LENGTH
	root.visible = true
	root.global_position = origin
	root.quaternion = Quaternion(Vector3.UP, vec.normalized())

	var head_len: float = clampf(length * 0.22, 0.10, 0.42)
	var shaft_len: float = maxf(length - head_len, 0.02)
	var shaft: MeshInstance3D = a["shaft"]
	shaft.scale = Vector3(1.0, shaft_len, 1.0)
	shaft.position = Vector3(0.0, shaft_len * 0.5, 0.0)
	var head: MeshInstance3D = a["head"]
	head.scale = Vector3(1.0, head_len, 1.0)
	head.position = Vector3(0.0, shaft_len + head_len * 0.5, 0.0)

	var label: Label3D = a["label"]
	# Lift, drag and velocity often point within 30 degrees of each other, so a
	# per-arrow stand-off keeps their billboarded text from stacking up.
	label.position = Vector3(0.0, length + float(a["label_offset"]), 0.0)
	label.text = label_text + (" (clipped)" if clipped else "")


func _make_arrow(key: String, color: Color, radius: float,
		label_offset: float) -> void:
	var root := Node3D.new()
	root.name = key
	add_child(root)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# Force arrows are diagrams, not objects: they read through the disc and the
	# ground rather than being occluded by them.
	mat.no_depth_test = true
	mat.render_priority = 4

	var shaft := MeshInstance3D.new()
	var sm := CylinderMesh.new()
	sm.top_radius = radius
	sm.bottom_radius = radius
	sm.height = 1.0
	sm.radial_segments = 7
	sm.rings = 1
	shaft.mesh = sm
	shaft.material_override = mat
	shaft.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(shaft)

	var head := MeshInstance3D.new()
	var hm := CylinderMesh.new()
	hm.top_radius = 0.0
	hm.bottom_radius = radius * 2.6
	hm.height = 1.0
	hm.radial_segments = 9
	hm.rings = 1
	head.mesh = hm
	head.material_override = mat
	head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(head)

	var label := Label3D.new()
	label.modulate = color
	label.outline_modulate = Color(0.02, 0.04, 0.07, 0.9)
	label.outline_size = 12
	label.font_size = 64
	label.pixel_size = 0.30 / 64.0
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.render_priority = 5
	label.double_sided = true
	root.add_child(label)

	_arrows[key] = {"root": root, "shaft": shaft, "head": head, "label": label,
		"label_offset": label_offset}

extends Node3D

# PLACEHOLDER ------------------------------------------------------------------
# This scene exists only to prove the Godot -> web export -> Vite -> GitHub Pages
# pipeline end to end. It draws a fairway, a tee pad and a basket, and slowly
# orbits the camera so a real render is visibly happening.
#
# The gameplay/physics agents own everything below and should feel free to gut
# it. The one thing to preserve is the SEAM:
#
#   * `res://scenes/main.tscn` is `run/main_scene` in project.godot. Keep that
#     path stable (build the real sim inside it, or make it a thin loader) so
#     the export preset and CI never need to change.
#   * Simulation state belongs in a dedicated node/script under `scripts/`,
#     not in here. The intended split is:
#       - a pure, headless-testable aerodynamics module (no Node dependency)
#         that maps disc parameters + release conditions -> a trajectory
#       - a thin presentation layer (this scene) that renders that trajectory
#     Keeping the aero math free of engine types is what lets it be unit tested
#     with `godot --headless --script`.
# ------------------------------------------------------------------------------

## Seconds for one full camera orbit around the fairway.
const ORBIT_PERIOD := 60.0
## Radius and height of the placeholder camera orbit, in meters. Tuned to frame
## the whole hole: tee pad at z=+2, basket at z=-88.
const ORBIT_RADIUS := 52.0
const ORBIT_HEIGHT := 24.0
## Point the placeholder camera looks at (roughly mid-fairway).
const ORBIT_FOCUS := Vector3(0.0, 2.0, -42.0)

## Tree positions flanking the fairway, as (x, z) pairs in meters.
const TREE_SPOTS: Array[Vector2] = [
	Vector2(-12.0, -6.0), Vector2(13.0, -12.0),
	Vector2(-14.0, -22.0), Vector2(11.5, -28.0),
	Vector2(-11.5, -38.0), Vector2(15.0, -44.0),
	Vector2(-15.0, -54.0), Vector2(12.0, -60.0),
	Vector2(-12.5, -70.0), Vector2(14.5, -76.0),
	Vector2(-13.5, -84.0), Vector2(11.8, -92.0),
]

@onready var _camera: Camera3D = $Camera3D
@onready var _status_label: Label = $UI/Panel/Status

var _elapsed := 0.0


func _ready() -> void:
	# Surfaced in the browser console; handy when diagnosing a bad web export.
	print("Disc Golf Flight Lab placeholder booted. Renderer: %s" % \
		ProjectSettings.get_setting("rendering/renderer/rendering_method"))
	if _status_label:
		_status_label.text = "Flight model under construction"
	_spawn_scenery()


## PLACEHOLDER: cheap conifers flanking the fairway, purely so the hole reads as
## a corridor with a sense of scale. Built in code to keep main.tscn small and
## trivially deletable.
func _spawn_scenery() -> void:
	var trunk_mat := StandardMaterial3D.new()
	trunk_mat.albedo_color = Color(0.19, 0.13, 0.09)
	trunk_mat.roughness = 1.0

	var canopy_mat := StandardMaterial3D.new()
	canopy_mat.albedo_color = Color(0.09, 0.19, 0.11)
	canopy_mat.roughness = 1.0

	var trunk_mesh := CylinderMesh.new()
	trunk_mesh.top_radius = 0.22
	trunk_mesh.bottom_radius = 0.34
	trunk_mesh.height = 3.0
	trunk_mesh.radial_segments = 8
	trunk_mesh.material = trunk_mat

	var canopy_mesh := CylinderMesh.new()  # top_radius 0 makes it a cone.
	canopy_mesh.top_radius = 0.0
	canopy_mesh.bottom_radius = 2.7
	canopy_mesh.height = 9.5
	canopy_mesh.radial_segments = 10
	canopy_mesh.material = canopy_mat

	var trees := Node3D.new()
	trees.name = "Scenery"
	add_child(trees)

	# Deterministic jitter so the tree line never looks like a picket fence.
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260811

	for spot in TREE_SPOTS:
		var tree := Node3D.new()
		var scale_factor := rng.randf_range(0.82, 1.35)
		tree.position = Vector3(spot.x, 0.0, spot.y)
		tree.scale = Vector3.ONE * scale_factor
		tree.rotate_y(rng.randf_range(0.0, TAU))

		var trunk := MeshInstance3D.new()
		trunk.mesh = trunk_mesh
		trunk.position = Vector3(0.0, 1.5, 0.0)
		tree.add_child(trunk)

		var canopy := MeshInstance3D.new()
		canopy.mesh = canopy_mesh
		canopy.position = Vector3(0.0, 7.2, 0.0)
		tree.add_child(canopy)

		trees.add_child(tree)


func _process(delta: float) -> void:
	_elapsed += delta
	var angle := TAU * (_elapsed / ORBIT_PERIOD)
	# Orbit a little way behind the tee so the fairway stays in frame.
	_camera.global_position = ORBIT_FOCUS + Vector3(
		sin(angle) * ORBIT_RADIUS,
		ORBIT_HEIGHT,
		cos(angle) * ORBIT_RADIUS
	)
	_camera.look_at(ORBIT_FOCUS, Vector3.UP)

class_name PortalProbe
extends Node3D

## The feasibility probe for PORTAL_CONTRACT §8 — the hand-authored portal pair,
## in a scene small enough to be driven by a script in an exported web build.
##
## ---------------------------------------------------------------------------
## Why this scene exists at all
## ---------------------------------------------------------------------------
## Everything §8 says about rendering is reasoning from the renderer feature
## matrix, not measurement: no GPU was available when it was written. In
## particular godot#86258 reports SubViewport textures rendering BLACK in
## *exported* builds while working perfectly in the editor — which is precisely
## this repository's historical failure mode, the one that shipped six green
## deploys with no physics in them. So the portal renderer had to be provable in
## a real browser against a real export before a single line of level content
## was written, and this is the scene that proves it.
##
## Run it directly:
##     godot --path game res://scenes/portal/portal_probe.tscn
## Or point `run/main_scene` at it, export, and drive it in Chromium — which is
## what was actually done; see the track report.
##
## Keys (this scene only; it is not part of the sandbox key map):
##     1-6  camera stations      P  toggle the portal renderer
##     [ ]  step the disc through the portal
##     0    print stats now
##
## Every station prints one machine-readable line, so a headless driver can read
## the draw-call cost of 0, 1 and 2 simultaneous portals out of the console:
##     [PortalProbe] station=1 portals=2 draw_calls=... primitives=...

## Track P3 owns `data/levels/**`. Point this at one of their files when the
## schema lands; empty means "use the built-in hand-authored pair", which is
## what proved the renderer.
@export var level_path: String = ""

## Camera stations. `disc` is the disc's parameter along its path through the
## normal portal: +ve is short of the aperture, -ve is through it.
const STATIONS := [
	{"name": "both", "eye": Vector3(0.0, 1.8, 9.0), "at": Vector3(0.0, 2.0, -15.0), "disc": 6.0},
	{"name": "normal-near", "eye": Vector3(-4.0, 2.0, -6.0), "at": Vector3(-4.0, 2.0, -15.0), "disc": 6.0},
	{"name": "none", "eye": Vector3(0.0, 1.8, -6.0), "at": Vector3(0.0, 2.0, 12.0), "disc": 6.0},
	{"name": "room-b", "eye": Vector3(44.0, 1.8, 7.0), "at": Vector3(44.0, 2.0, 15.0), "disc": 6.0},
	{"name": "grazing", "eye": Vector3(1.5, 2.0, -13.6), "at": Vector3(-9.0, 2.2, -14.4), "disc": 6.0},
	{"name": "crossing", "eye": Vector3(-3.05, 2.30, -13.85), "at": Vector3(-4.0, 2.0, -15.0), "disc": 0.0},
	# COLOUR-SPACE CALIBRATION. Two identical unshaded, fog-exempt swatches: one
	# beside the portal, seen directly; one placed through the pair transform so
	# it appears inside the aperture. Unshaded and unfogged means neither
	# lighting nor the two rooms' different air can contribute, so any
	# difference between the two is the SubViewport round trip and nothing else
	# — which is how the contract's open `OUTPUT_IS_SRGB` question gets an
	# answer instead of a caveat. The probe prints both sample positions.
	{"name": "calibration", "eye": Vector3(-4.0, 2.0, -8.0), "at": Vector3(-4.0, 2.0, -15.0),
		"disc": 24.0, "calibrate": true},
]

var level: PortalLevel = null
var renderer: PortalRenderer = null
var camera: Camera3D = null
var ghost: PortalGhost = null

var _disc: MeshInstance3D = null
var _disc_s: float = 6.0
var _station: int = 0
var _frames: int = 0
var _report_at: int = -1

## Self-capture mode, for iterating on the look without a 12-minute
## export-and-drive cycle:
##
##     xvfb-run -a godot --path game --rendering-driver opengl3 \
##         res://scenes/portal/portal_probe.tscn -- --capture=/tmp/shots
##
## It walks every station, writes a PNG for each and quits. Software GL under
## Xvfb is NOT evidence the exported build works — only Chromium against
## `web/public/game/` is — but it is a truthful preview of the *shading*, which
## is what the loop is usually about.
var _disc_override: float = 0.0
var _disc_overridden: bool = false
var _swatches: Array[MeshInstance3D] = []
var _swatch_apparent: Array[Vector3] = []
var _capture_dir: String = ""
var _capture_next: int = 0
var _capture_at: int = 0


func _ready() -> void:
	print("[PortalProbe] renderer=%s msaa_3d=%s" % [
		ProjectSettings.get_setting("rendering/renderer/rendering_method"),
		str(ProjectSettings.get_setting("rendering/anti_aliasing/quality/msaa_3d"))])

	level = PortalLevel.new()
	level.name = "Level"
	add_child(level)
	level.load_level(level_path)
	for e in level.load_errors:
		print("[PortalProbe] level: %s" % e)

	camera = Camera3D.new()
	camera.name = "MainCamera"
	camera.fov = 68.0
	camera.near = 0.05
	camera.far = 400.0
	camera.current = true
	add_child(camera)

	renderer = PortalRenderer.new()
	renderer.name = "PortalRenderer"
	add_child(renderer)
	renderer.attach_main_camera(camera)
	level.attach_to(renderer)

	_build_disc()
	_build_landmarks()
	_build_swatches()
	_apply_station(0)
	_start_capture()

	print("[PortalProbe] rooms=%d portals=%d links_ok=%d" % [
		level.rooms.size(), level.portals.size(), _linked_count()])
	for p: Portal in level.portals:
		if p.peer != null:
			print("[PortalProbe] link %s -> %s det=%.6f conformal=%s" % [
				p.name, p.peer.name, p.to_peer.basis.determinant(),
				str(p.to_peer.basis.is_conformal())])


func _linked_count() -> int:
	var n := 0
	for p: Portal in level.portals:
		if p.peer != null:
			n += 1
	return n


func _process(_delta: float) -> void:
	_frames += 1
	_capture_step()
	_place_disc()
	if ghost != null:
		ghost.track(_disc.global_transform, level.portals)
	if renderer != null:
		renderer.set_focus(_disc.global_position)
	# Report once the warm-up has settled, again a few frames after every station
	# change, and then periodically — SwiftShader runs this at about 1 fps, so a
	# 40-frame cadence would be a 40-second wait for a reading.
	if _frames == 12 or _frames == _report_at or (_frames > 12 and _frames % 20 == 0):
		_report()


func _report() -> void:
	if renderer == null:
		return
	var s := renderer.debug_stats()
	print("[PortalProbe] station=%d name=%s portals=%d draw_calls=%d primitives=%d vp=%s warm=%s" % [
		_station + 1, STATIONS[_station]["name"], s["active"], s["draw_calls"],
		s["primitives"], str(s["viewport"]), str(s["warm"])])


func _start_capture() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--capture="):
			_capture_dir = a.substr("--capture=".length())
		elif a == "--noclip":
			# A/B for the clip planes: with them off, the real disc keeps being
			# drawn after it has passed through the wall and the ghost is drawn
			# before it has emerged. Capturing both is how "the disc does not pop"
			# stops being an assertion.
			ghost.clip_enabled = false
		elif a.begins_with("--disc="):
			# Override every station's disc parameter, so the crossing can be
			# walked frame by frame from a shell loop.
			_disc_override = a.substr("--disc=".length()).to_float()
			_disc_overridden = true
	if _capture_dir == "":
		return
	DirAccess.make_dir_recursive_absolute(_capture_dir)
	_capture_next = 0
	_capture_at = _frames + 6
	_apply_station(0)


func _capture_step() -> void:
	if _capture_dir == "" or _frames < _capture_at:
		return
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%d-%s.png" % [_capture_dir, _capture_next + 1,
		STATIONS[_capture_next]["name"]]
	img.save_png(path)
	print("[PortalProbe] captured %s" % path)
	_capture_next += 1
	if _capture_next >= STATIONS.size():
		get_tree().quit(0)
		return
	_apply_station(_capture_next)
	_capture_at = _frames + 6


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	match k.keycode:
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7:
			_apply_station(k.keycode - KEY_1)
		KEY_0:
			_report()
		KEY_P:
			renderer.enabled = not renderer.enabled
			if not renderer.enabled:
				for p: Portal in level.portals:
					p.set_live(false)
			print("[PortalProbe] renderer.enabled=%s" % str(renderer.enabled))
		KEY_BRACKETLEFT:
			_disc_s += 0.35
		KEY_BRACKETRIGHT:
			_disc_s -= 0.35


func _apply_station(i: int) -> void:
	_station = clampi(i, 0, STATIONS.size() - 1)
	var st: Dictionary = STATIONS[_station]
	var eye: Vector3 = st["eye"]
	var at: Vector3 = st["at"]
	# The main camera is an ordinary Node3D and -Z IS its forward, so look_at is
	# right here. It is only wrong for a Portal, whose normal is +Z.
	camera.global_transform = Transform3D(Basis.IDENTITY, eye)
	camera.look_at(at, Vector3.UP)
	# Per-room air applies to the direct view too, not only to portal views:
	# walking from the blue room to the amber one should change the light.
	camera.environment = level.environment_at(eye)
	_show_swatches(bool(st.get("calibrate", false)))
	_disc_s = _disc_override if _disc_overridden else float(st["disc"])
	_place_disc()
	# Two frames for the SubViewports to re-render at the new pose, then report.
	_report_at = _frames + 3
	print("[PortalProbe] -> station %d (%s)" % [_station + 1, st["name"]])


func _show_swatches(on: bool) -> void:
	for m: MeshInstance3D in _swatches:
		m.visible = on
	if not on or _swatches.size() < 2:
		return
	# Print where to sample, so the measurement does not depend on anyone
	# eyeballing a pixel coordinate off a screenshot. Both are unprojected from
	# their APPARENT position — the through-portal swatch really sits 40 m away
	# in room B, but it is seen where its pre-transform position would be.
	for i in _swatch_apparent.size():
		var sp := camera.unproject_position(_swatch_apparent[i])
		print("[PortalProbe] swatch %s at screen %d,%d" % [
			"DIRECT" if i == 0 else "THROUGH-PORTAL", int(sp.x), int(sp.y)])


func _build_swatches() -> void:
	var p := level.portal_by_id("a_far")
	if p == null or p.peer == null:
		return
	var sh := Shader.new()
	sh.code = """shader_type spatial;
render_mode unshaded, fog_disabled, cull_disabled, shadows_disabled;
uniform vec3 c : source_color = vec3(0.5, 0.5, 0.5);
void fragment() { ALBEDO = c; }
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("c", Color(0.5, 0.5, 0.5))

	var quad := QuadMesh.new()
	quad.size = Vector2(1.2, 1.2)
	var xf := p.global_transform
	var apparent := [
		xf * Transform3D(Basis.IDENTITY, Vector3(2.2, 0.0, 0.02)),
		xf * Transform3D(Basis.IDENTITY, Vector3(-0.6, 0.0, -0.6)),
	]
	# The first stays where it is; the second is pushed through the pair
	# transform so that it LANDS in room B and is seen inside the aperture.
	var places := [apparent[0], p.to_peer * apparent[1]]
	for t: Transform3D in apparent:
		_swatch_apparent.append(t.origin)
	for t: Transform3D in places:
		var mi := MeshInstance3D.new()
		mi.mesh = quad
		mi.material_override = mat
		mi.layers = Portal.LAYER_WORLD
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		mi.global_transform = t
		_swatches.append(mi)


# ---------------------------------------------------------------------------
# A stand-in disc, so the ghost and the clip planes can be seen
# ---------------------------------------------------------------------------

func _build_disc() -> void:
	_disc = MeshInstance3D.new()
	_disc.name = "Disc"
	var cm := CylinderMesh.new()
	cm.top_radius = 0.105
	cm.bottom_radius = 0.105
	cm.height = 0.021
	cm.radial_segments = 20
	cm.rings = 1
	_disc.mesh = cm
	_disc.layers = Portal.LAYER_WORLD
	add_child(_disc)

	ghost = PortalGhost.new()
	ghost.name = "DiscGhost"
	add_child(ghost)
	ghost.setup(_disc, Color(0.30, 0.72, 0.98))


func _place_disc() -> void:
	var p := level.portal_by_id("a_far")
	if p == null:
		return
	# Along the entrance portal's own normal, so the disc really does travel
	# through the aperture rather than near it.
	_disc.global_position = p.global_position + p.normal() * _disc_s
	_disc.global_basis = Basis.IDENTITY


# ---------------------------------------------------------------------------
# Landmarks: the point is to be able to tell, from a screenshot, WHICH room the
# portal is showing. Two boxes of the room's own colour, at known positions.
# ---------------------------------------------------------------------------

func _build_landmarks() -> void:
	var specs := [
		{"pos": Vector3(-7.0, 1.1, -10.5), "size": Vector3(1.6, 2.2, 1.6),
			"col": Color(0.25, 0.55, 0.95)},
		{"pos": Vector3(6.5, 0.7, -9.0), "size": Vector3(1.0, 1.4, 1.0),
			"col": Color(0.90, 0.95, 1.00)},
		{"pos": Vector3(41.0, 1.4, -6.0), "size": Vector3(1.8, 2.8, 1.8),
			"col": Color(0.98, 0.62, 0.18)},
		{"pos": Vector3(47.0, 0.8, 1.0), "size": Vector3(1.2, 1.6, 1.2),
			"col": Color(1.00, 0.92, 0.72)},
		{"pos": Vector3(44.5, 0.5, 2.0), "size": Vector3(2.4, 1.0, 2.4),
			"col": Color(0.62, 0.22, 0.10)},
	]
	for s_v: Variant in specs:
		var s: Dictionary = s_v
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = s["size"]
		mi.mesh = bm
		mi.position = s["pos"]
		var m := StandardMaterial3D.new()
		m.albedo_color = s["col"]
		m.roughness = 0.85
		mi.material_override = m
		mi.layers = Portal.LAYER_WORLD
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)

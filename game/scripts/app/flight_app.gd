class_name FlightApp
extends Node3D

## Application controller: owns the simulation loop and mediates between the
## physics core (Track B), the disc/aero data (Track A) and the control panel
## (Track D).
##
## `DiscFlightSim` is deliberately node-free, so something has to own a node and
## step it. That is this. Everything downstream of the sim — mesh, trails,
## vectors, cameras, HUD — is driven from the single `DiscState` this pulls out
## each physics frame, so there is exactly one source of truth for where the
## disc is.
##
## ---------------------------------------------------------------------------
## Degrading gracefully
## ---------------------------------------------------------------------------
## Four tracks are landing in parallel, so nothing here assumes the others
## arrived:
##   * Track A's `data/discs.json` missing -> DiscLibrary falls back to its
##     built-in roster and `data_present()` says so, which is surfaced in the
##     status line rather than hidden (CONTRACT §7).
##   * Track D's `scenes/ui/control_panel.tscn` missing -> a built-in debug
##     panel appears instead and every keyboard shortcut still works.
##   * Track D's panel present but missing a method or signal -> each call and
##     each connection is guarded individually, so a partial panel still works.
##
## ---------------------------------------------------------------------------
## The C <-> D interface (agreed; do not change unilaterally)
## ---------------------------------------------------------------------------
## Signals consumed: throw_requested, disc_selected, geometry_changed,
##   environment_changed, camera_view_changed, clear_trails_requested,
##   vectors_toggled.
## Methods called: set_disc_roster, set_active_disc, set_live_state,
##   set_flight_result, set_status.
##
## One deviation, inherited from Track B: CONTRACT §4 names the environment type
## `Environment`, which Godot reserves for a native class, so the real type is
## `DiscFlightSim.FlightEnvironment`. `environment_changed` is accepted as that
## type, as a Dictionary, or as anything exposing air_density/wind/gravity.

const UI_SCENE_PATH := "res://scenes/ui/control_panel.tscn"
const RANGE_SCENE_PATH := "res://scenes/world/range.tscn"

## True disc scale is 21 cm, which is 5 px at 100 m. Rather than lie about the
## size up close, the disc is drawn 1:1 until it is far enough away to vanish
## and is then floated up to a floor of ~0.008 rad of screen angle, capped at
## 4x. Close-range views — where size is judged — are always exact.
const VISUAL_ANGULAR_FLOOR := 0.0075
const VISUAL_SCALE_CAP := 4.0

@export var auto_demo_throw: bool = true
@export var demo_delay_s: float = 1.4

var sim: DiscFlightSim = null
var library: DiscLibrary = null
var disc: DiscDefinition = null
var env: DiscFlightSim.FlightEnvironment = null

var mesh_builder: DiscMeshBuilder = null

var _range: RangeWorld = null
var _rig: CameraRig = null
var _trails: TrailSystem = null
var _vectors: VectorOverlay = null
var _wind: WindVisualizer = null
var _hud: HudOverlay = null
var _panel: Node = null            ## Track D's ControlPanel, or null

var _disc_node: MeshInstance3D = null
var _plate_mat: StandardMaterial3D = null
var _body_mat: StandardMaterial3D = null
var _disc_color: Color = Color(0.30, 0.62, 0.95)
var _mat_color: Color = Color(0, 0, 0, 0)

var _throw := DiscFlightSim.ThrowParams.new()
var _flying: bool = false
var _spin_phase: float = 0.0
var _launch_pos := Vector3.ZERO
var _launch_right := Vector3.RIGHT
var _launch_forward := Vector3.FORWARD
var _max_height: float = 0.0
var _max_right: float = 0.0
var _max_left: float = 0.0
var _samples: Array = []
var _next_sample_t: float = 0.0
var _demo_timer: float = -1.0
var _idle_pose := Vector3(0.0, 1.4, 0.0)
var _perf_report_t: float = 0.0
var _perf_reports: int = 0
var _last_result: DiscFlightSim.FlightResult = null

const DISC_COLORS: Array[Color] = [
	Color(0.30, 0.62, 0.95), Color(0.95, 0.42, 0.30), Color(0.42, 0.82, 0.48),
	Color(0.86, 0.62, 0.95), Color(0.98, 0.78, 0.26), Color(0.35, 0.85, 0.85),
]


# ---------------------------------------------------------------------------
# Boot
# ---------------------------------------------------------------------------

func _ready() -> void:
	print("[FlightApp] renderer=%s" % ProjectSettings.get_setting(
		"rendering/renderer/rendering_method"))

	env = DiscFlightSim.make_environment(Atmosphere.air_density(0.0, 15.0), Vector3.ZERO, 9.81)
	sim = DiscFlightSim.new()
	library = DiscLibrary.load_default()
	for e in library.load_errors:
		print("[FlightApp] roster: %s" % e)

	_build_world()
	_build_disc_node()
	_build_overlays()

	disc = library.get_index(_default_disc_index())
	_apply_disc(disc)

	_default_throw()
	_reset_to_tee()

	_setup_ui()
	_refresh_status()

	if auto_demo_throw:
		_demo_timer = demo_delay_s
	print("[FlightApp] ready. discs=%d data_present=%s ui=%s" % [
		library.size(), str(library.data_present()), "track-d" if _panel else "builtin"])


func _build_world() -> void:
	# main.tscn instances the range; fall back to loading or building one so the
	# app is also usable as a bare node.
	_range = get_node_or_null("Range") as RangeWorld
	if _range == null:
		var packed: PackedScene = null
		if ResourceLoader.exists(RANGE_SCENE_PATH):
			packed = load(RANGE_SCENE_PATH) as PackedScene
		if packed:
			_range = packed.instantiate() as RangeWorld
		else:
			push_warning("[FlightApp] %s missing; building a bare range" % RANGE_SCENE_PATH)
			_range = RangeWorld.new()
		_range.name = "Range"
		add_child(_range)

	_rig = CameraRig.new()
	_rig.name = "CameraRig"
	add_child(_rig)

	_wind = WindVisualizer.new()
	_wind.name = "Wind"
	add_child(_wind)

	_trails = TrailSystem.new()
	_trails.name = "Trails"
	add_child(_trails)

	_vectors = VectorOverlay.new()
	_vectors.name = "Vectors"
	add_child(_vectors)


func _build_disc_node() -> void:
	mesh_builder = DiscMeshBuilder.new()
	_disc_node = MeshInstance3D.new()
	_disc_node.name = "Disc"
	_disc_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(_disc_node)


func _build_overlays() -> void:
	var layer := CanvasLayer.new()
	layer.name = "UI"
	add_child(layer)
	_hud = HudOverlay.new()
	_hud.name = "Hud"
	layer.add_child(_hud)
	_hud.set_hint("SPACE throw   1-5 camera   V vectors   C clear trails   "
		+ "[ ] disc   W wind   H panel")


func _default_disc_index() -> int:
	# Prefer something that shows off turn and fade if the roster has one.
	for i in library.size():
		var d := library.get_index(i)
		if d.speed >= 9.0:
			return i
	return 0


# ---------------------------------------------------------------------------
# Disc and geometry
# ---------------------------------------------------------------------------

func _apply_disc(d: DiscDefinition) -> void:
	if d == null:
		return
	disc = d
	_disc_color = DISC_COLORS[abs(hash(d.id)) % DISC_COLORS.size()]
	sim.configure(disc, env)
	_rebuild_disc_mesh(DiscMeshBuilder.geometry_from(disc))
	_call_panel("set_active_disc", [_disc_entry(disc)])
	_refresh_status()


## Live designer edits (CONTRACT §2 keys). The mesh AND the mass properties the
## integrator uses are rebuilt from the same dictionary, which is the whole
## point of the parameterisation: there is no separate "aero shape".
##
## The reference area and both moments of inertia are re-integrated from the
## edited cross-section by the same Green's-theorem pass that reproduces Track
## A's published `I_zz`/`I_xy` to better than 0.1% — so a slider drag moves the
## numbers the integrator uses, not just the silhouette. This is preferred over
## DiscDefinition's own coarse `k * m * r^2` fallback precisely because it agrees
## with Track A's offline integration.
##
## Honesty note: the CL/CD/CM table does NOT follow the edit. Mapping geometry
## onto coefficients is Track A's offline fit and cannot be redone at 60 Hz, so
## a drag changes the mesh, the reference area and the moments while the
## coefficients stay as shipped.
func apply_geometry(geometry: Dictionary) -> void:
	if disc == null or geometry.is_empty():
		return
	for k in DiscMeshBuilder.GEOMETRY_KEYS:
		if geometry.has(k):
			disc.set(k, float(geometry[k]))
	var mass_props := DiscMeshBuilder.integrate_inertia(
		DiscMeshBuilder.geometry_from(disc), 120)
	if float(mass_props["volume_m3"]) > 1e-9:
		disc.area_m2 = float(mass_props["area_m2"])
		disc.i_zz = float(mass_props["i_zz"])
		disc.i_xy = float(mass_props["i_xy"])
		disc.parting_ratio = float(mass_props["parting_ratio"])
	elif disc.has_method("_recompute_derived"):
		disc._recompute_derived()
	sim.configure(disc, env)
	_rebuild_disc_mesh(DiscMeshBuilder.geometry_from(disc))
	_refresh_status()


func _rebuild_disc_mesh(geometry: Dictionary) -> void:
	if not mesh_builder.set_geometry(geometry) and _disc_node.mesh != null:
		return
	_disc_node.mesh = mesh_builder.get_mesh()
	if _plate_mat == null:
		_plate_mat = DiscMeshBuilder.make_plate_material(_disc_color)
		_body_mat = DiscMeshBuilder.make_body_material(_disc_color.darkened(0.15))
		_mat_color = _disc_color
	elif _mat_color != _disc_color:
		# The stamp is a function of the colour only, so a geometry slider drag
		# must not re-rasterise it 60 times a second.
		_plate_mat.albedo_texture = DiscMeshBuilder.make_plate_texture(
			_disc_color, _disc_color.lightened(0.35))
		_body_mat.albedo_color = _disc_color.darkened(0.15)
		_mat_color = _disc_color
	_disc_node.set_surface_override_material(DiscMeshBuilder.SURFACE_PLATE, _plate_mat)
	_disc_node.set_surface_override_material(DiscMeshBuilder.SURFACE_BODY, _body_mat)


## The cross-section polyline, for a UI diagram. Same polyline the mesh is
## revolved from — a diagram drawn from this cannot drift from the geometry.
func get_cross_section() -> PackedVector2Array:
	return mesh_builder.get_cross_section()


func _disc_entry(d: DiscDefinition) -> Dictionary:
	if d == null:
		return {}
	var geom := {}
	for k in DiscMeshBuilder.GEOMETRY_KEYS:
		geom[k] = d.get(k)
	return {
		"id": d.id, "name": d.name, "category": d.category,
		"flight_numbers": {"speed": d.speed, "glide": d.glide, "turn": d.turn,
			"fade": d.fade},
		"geometry": geom,
		"derived": {"area_m2": d.area_m2, "I_zz": d.i_zz, "I_xy": d.i_xy,
			"parting_ratio": d.parting_ratio},
		"aero_provenance": d.aero_provenance,
		"mass_kg": d.mass_kg,
		"definition": d,
	}


# ---------------------------------------------------------------------------
# Throwing
# ---------------------------------------------------------------------------

func _default_throw() -> void:
	# CONTRACT §5's first sanity target: a distance driver at ~27 m/s and
	# ~25 rev/s with a little hyzer, which should fly 105-130 m with a visible
	# right turn and a left fade finish.
	_throw.speed_mps = 27.0
	_throw.spin_rps = 25.0
	_throw.nose_angle_rad = 0.0
	_throw.hyzer_angle_rad = deg_to_rad(5.0)
	_throw.launch_angle_rad = deg_to_rad(10.0)
	_throw.launch_height_m = 1.4
	_throw.launch_heading_rad = 0.0


func throw(params: DiscFlightSim.ThrowParams = null) -> void:
	if disc == null:
		return
	if params != null:
		_throw = params
	sim.configure(disc, env)
	sim.launch(_throw)
	_flying = true
	_spin_phase = 0.0
	_max_height = _throw.launch_height_m
	_max_right = 0.0
	_max_left = 0.0
	_samples.clear()
	_next_sample_t = 0.0
	_last_result = null

	var st := sim.get_state()
	_launch_pos = st.position
	var fwd := Vector3(st.velocity.x, 0.0, st.velocity.z)
	fwd = fwd.normalized() if fwd.length_squared() > 1e-9 else Vector3(0.0, 0.0, -1.0)
	_launch_forward = fwd
	# Same construction the integrator uses, so `lateral_m` here and in
	# `simulate_full()` mean the same thing: + is right of the launch heading.
	_launch_right = Vector3(-fwd.z, 0.0, fwd.x)

	_hud.clear_alpha()
	_trails.begin_flight(disc.name if disc else "disc")
	_trails.add_point(st.position)
	_rig.reset_framing()
	if _rig.get_view() == "tee":
		# Behind the tee at release, chasing once it is away — the default the
		# brief asks for.
		_switch_view_after(0.9, "follow")
	_refresh_status()


func _switch_view_after(delay: float, view: String) -> void:
	var t := get_tree().create_timer(delay)
	t.timeout.connect(func() -> void:
		if _flying and _rig.get_view() == "tee":
			set_camera_view(view))


func _reset_to_tee() -> void:
	_flying = false
	_idle_pose = Vector3(0.0, _throw.launch_height_m, 0.0)
	_disc_node.global_position = _idle_pose
	_disc_node.quaternion = Quaternion(Vector3(0.0, 0.0, 1.0), _throw.hyzer_angle_rad)
	_vectors.hide_all()
	_rig.track(_idle_pose, Vector3.ZERO, false)


# ---------------------------------------------------------------------------
# The loop
# ---------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if _demo_timer > 0.0:
		_demo_timer -= delta
		if _demo_timer <= 0.0:
			_demo_timer = -1.0
			throw()
	if not _flying:
		return

	sim.step(delta)
	var st := sim.get_state()
	var diag := sim.get_aero_diagnostics()
	var alpha: float = diag["alpha"]

	_max_height = maxf(_max_height, st.position.y)
	var lateral: float = (st.position - _launch_pos).dot(_launch_right)
	_max_right = maxf(_max_right, lateral)
	_max_left = minf(_max_left, lateral)

	if st.time >= _next_sample_t - 1e-9:
		_samples.append({
			"t": st.time, "pos": st.position, "vel": st.velocity,
			"quat": st.orientation, "spin": st.spin, "alpha": alpha,
			"cl": diag["cl"], "cd": diag["cd"], "cm": diag["cm"],
		})
		_next_sample_t += 1.0 / 60.0

	_update_disc_transform(st, delta)
	_trails.add_point(st.position)
	_trails.set_disc_altitude(st.position)
	_rig.track(st.position, st.velocity, true)
	_update_vectors(st, diag)
	if _hud.is_enabled():
		_hud.push_alpha(st.time, rad_to_deg(alpha))
		_update_telemetry(st, diag)
	_call_panel("set_live_state", [st, rad_to_deg(alpha)])

	if not sim.is_flying():
		_land(st)


func _process(delta: float) -> void:
	# Screen-size floor for the disc; see VISUAL_ANGULAR_FLOOR.
	if _rig and _rig.camera and _disc_node:
		var d: float = _rig.camera.global_position.distance_to(_disc_node.global_position)
		var want: float = clampf(VISUAL_ANGULAR_FLOOR * d, disc.diameter_m if disc else 0.211,
			(disc.diameter_m if disc else 0.211) * VISUAL_SCALE_CAP)
		var s: float = want / maxf(disc.diameter_m if disc else 0.211, 1e-4)
		_disc_node.scale = _disc_node.scale.lerp(Vector3(s, s, s), 1.0 - exp(-6.0 * delta))
	if _perf_reports < 3:
		_perf_report_t += delta
		if _perf_report_t > 5.0:
			_perf_report_t = 0.0
			_perf_reports += 1
			print("[FlightApp] perf fps=%.1f draw_calls=%d prims=%d mesh_build_us=%d" % [
				Engine.get_frames_per_second(),
				RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
				RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
				mesh_builder.last_build_usec()])


## The sim tracks the NON-SPINNING disc frame plus a scalar spin rate
## (CONTRACT §4), so the visible rotation has to be integrated here. Internally
## the physical rate about the disc's +normal is -spin, which for a RHBH throw
## (positive spin) is a negative rotation about local +Y — clockwise seen from
## above, exactly as CONTRACT §1 requires. If a RHBH disc ever appears to spin
## anticlockwise from above, this sign is wrong.
func _update_disc_transform(st: DiscFlightSim.DiscState, delta: float) -> void:
	_spin_phase = fposmod(_spin_phase - st.spin * delta, TAU)
	_disc_node.global_position = st.position
	_disc_node.quaternion = st.orientation * Quaternion(Vector3.UP, _spin_phase)


## Reconstructs the aerodynamic force vectors from the state and the sampled
## coefficients, using the same triad the integrator does, so the arrows are the
## forces that are actually being applied rather than a lookalike.
func _update_vectors(st: DiscFlightSim.DiscState, diag: Dictionary) -> void:
	if not _vectors.is_enabled():
		return
	var n: Vector3 = st.orientation * Vector3.UP
	var vair: Vector3 = st.velocity - env.wind
	var v: float = vair.length()
	var lift := Vector3.ZERO
	var drag := Vector3.ZERO
	if v > 1e-4:
		var vhat: Vector3 = vair / v
		var q_a: float = 0.5 * env.air_density * v * v * disc.area_m2
		var lat: Vector3 = vhat.cross(n)
		if lat.length_squared() > 1e-18:
			lift = lat.normalized().cross(vhat) * (float(diag["cl"]) * q_a)
		drag = -vhat * (float(diag["cd"]) * q_a)
	# CONTRACT §1: positive spin (RHBH) means the angular velocity vector points
	# DOWN through the disc, i.e. along -normal.
	var spin_axis: Vector3 = (-n if st.spin >= 0.0 else n)
	_vectors.update_vectors(st.position, {
		"lift": lift,
		"drag": drag,
		"weight": Vector3(0.0, -disc.mass_kg * env.gravity, 0.0),
		"velocity": st.velocity,
		"spin_axis": spin_axis,
		"spin_rps": st.spin / TAU,
	}, disc.mass_kg, env.gravity)


func _land(st: DiscFlightSim.DiscState) -> void:
	_flying = false
	var rel: Vector3 = st.position - _launch_pos
	var r := DiscFlightSim.FlightResult.new()
	r.trajectory = sim.get_trajectory()
	r.samples = _samples.duplicate()
	r.distance_m = rel.length()
	r.lateral_m = rel.dot(_launch_right)
	r.max_height_m = _max_height
	r.flight_time_s = st.time
	r.landed = not sim.has_failed()
	# Track B's additive extras are outside the contract and have already been
	# renamed once, so they are filled only where the field still exists.
	_set_if(r, "landing_position", st.position)
	_set_if(r, "horizontal_distance_m", Vector2(rel.x, rel.z).length())
	_set_if(r, "downrange_m", rel.dot(_launch_forward))
	_set_if(r, "final_spin", st.spin)
	_set_if(r, "spin_retained", absf(st.spin) / maxf(absf(_throw.spin_rps * TAU), 1e-6))
	_set_if(r, "max_right_m", _max_right)
	_set_if(r, "max_left_m", _max_left)
	_set_if(r, "max_lateral_m", _max_right if absf(_max_right) >= absf(_max_left) else _max_left)
	_set_if(r, "failed", sim.has_failed())
	_last_result = r

	_trails.end_flight(r.distance_m, r.lateral_m, st.position)
	# The legend is only refreshed from the live-telemetry path, which stops
	# with the flight; the new ghost has to be pushed explicitly.
	if _hud.is_enabled():
		_update_legend_only()
	_vectors.hide_all()
	# Let it lie flat on the ground rather than half-buried: the mesh origin is
	# the parting line, which sits above the resting plane.
	var norm := DiscMeshBuilder.normalize_geometry(DiscMeshBuilder.geometry_from(disc))
	_disc_node.global_position = Vector3(st.position.x,
		float(norm["parting_line_m"]), st.position.z)
	_disc_node.quaternion = Quaternion(Vector3.UP, _spin_phase)
	_call_panel("set_flight_result", [r])
	_refresh_status()
	print("[FlightApp] landed distance=%.1f m lateral=%+.1f m peak=%.1f m t=%.2f s" % [
		r.distance_m, r.lateral_m, r.max_height_m, r.flight_time_s])


## Assign only if the property still exists on the object.
func _set_if(obj: Object, prop: String, value: Variant) -> void:
	if prop in obj:
		obj.set(prop, value)


func get_last_result() -> DiscFlightSim.FlightResult:
	return _last_result


# ---------------------------------------------------------------------------
# HUD
# ---------------------------------------------------------------------------

func _update_telemetry(st: DiscFlightSim.DiscState, diag: Dictionary) -> void:
	var rel: Vector3 = st.position - _launch_pos
	_hud.set_telemetry({
		"time": "%.2f s" % st.time,
		"distance": "%.1f m" % Vector2(rel.x, rel.z).length(),
		"lateral": "%+.1f m" % rel.dot(_launch_right),
		"height": "%.1f m" % st.position.y,
		"airspeed": "%.1f m/s" % float(diag["airspeed"]),
		"spin": "%.1f rev/s" % (st.spin / TAU),
		"alpha": "%+.1f deg" % rad_to_deg(float(diag["alpha"])),
		"CM": "%+.4f" % float(diag["cm"]),
	})
	_hud.set_legend(_trails.legend_entries(), _trails.live_color())


func _refresh_status() -> void:
	if disc == null:
		_hud.set_status("no disc loaded")
		return
	# CONTRACT §7: never let a derived coefficient set read as a measured one.
	var prov := disc.aero_provenance
	var prov_text := "measured CFD" if prov == "measured" else "derived"
	var text := "%s   %d/%d/%d/%d   coefficients: %s" % [disc.name, int(disc.speed),
		int(disc.glide), int(disc.turn), int(disc.fade), prov_text]
	if not library.data_present():
		text += "   (fallback roster)"
	_hud.set_status(text)
	_call_panel("set_status", [text])


func _update_legend_only() -> void:
	_hud.set_legend(_trails.legend_entries(), _trails.live_color())


# ---------------------------------------------------------------------------
# Track D wiring
# ---------------------------------------------------------------------------

func _setup_ui() -> void:
	if ResourceLoader.exists(UI_SCENE_PATH):
		var packed := load(UI_SCENE_PATH) as PackedScene
		if packed:
			var inst := packed.instantiate()
			# A panel whose script failed to compile still instantiates, as a
			# bare Control with none of the agreed signals. Treat that as absent
			# rather than silently shipping a scene with no controls at all.
			if not (inst is CanvasLayer or inst is Control):
				push_warning("[FlightApp] control_panel.tscn root is neither Control nor CanvasLayer")
				inst.queue_free()
			elif not inst.has_signal("throw_requested"):
				push_warning("[FlightApp] control_panel.tscn has no 'throw_requested' signal "
					+ "(script failed to load?) - falling back to the debug panel")
				inst.queue_free()
			else:
				var layer := get_node_or_null("UI") as CanvasLayer
				if inst is Control and layer:
					layer.add_child(inst)
				else:
					add_child(inst)
				_panel = inst
	if _panel == null:
		push_warning("[FlightApp] no usable control panel at %s - running with the "
			% UI_SCENE_PATH + "built-in debug panel")
		_hud.build_debug_panel()
		_hud.debug_throw_requested.connect(func() -> void: throw())
		_hud.debug_clear_requested.connect(_on_clear_trails)
		_hud.debug_vectors_toggled.connect(_on_vectors_toggled)
		_hud.debug_view_requested.connect(set_camera_view)
		_hud.debug_disc_cycled.connect(cycle_disc)
		return

	_connect_panel("throw_requested", _on_throw_requested)
	_connect_panel("disc_selected", _on_disc_selected)
	_connect_panel("geometry_changed", apply_geometry)
	_connect_panel("environment_changed", _on_environment_changed)
	_connect_panel("camera_view_changed", set_camera_view)
	_connect_panel("clear_trails_requested", _on_clear_trails)
	_connect_panel("vectors_toggled", _on_vectors_toggled)

	var roster: Array = []
	for i in library.size():
		roster.append(_disc_entry(library.get_index(i)))
	_call_panel("set_disc_roster", [roster])
	_call_panel("set_active_disc", [_disc_entry(disc)])
	# Track D owns the instrument display. Our overlay exists only for the
	# standalone case; running both would put two live telemetry panels on the
	# same screen, so it is switched off entirely rather than shuffled sideways.
	_hud.set_enabled(false)


func _connect_panel(sig: String, cb: Callable) -> void:
	if _panel == null:
		return
	if not _panel.has_signal(sig):
		push_warning("[FlightApp] control panel has no signal '%s'" % sig)
		return
	_panel.connect(sig, cb)


func _call_panel(method: String, args: Array) -> void:
	if _panel == null or not _panel.has_method(method):
		return
	_panel.callv(method, args)


func _on_throw_requested(params: Variant = null) -> void:
	throw(_coerce_throw(params))


func _on_disc_selected(disc_id: Variant) -> void:
	var d := library.get_disc(str(disc_id))
	if d:
		_apply_disc(d)
		_reset_to_tee()


func _on_environment_changed(e: Variant) -> void:
	env = _coerce_env(e)
	sim.configure(disc, env)
	_wind.set_wind(env.wind)
	_refresh_status()


func _on_clear_trails() -> void:
	_trails.clear_all()
	_hud.clear_alpha()
	_update_legend_only()


func _on_vectors_toggled(on: bool) -> void:
	_vectors.set_enabled(on)


func set_camera_view(view: Variant) -> void:
	_rig.set_view(str(view))


## Debug/demo shortcut for the wind, so the wind visualisation is exercisable
## without Track D's environment panel. Track D's `environment_changed` is the
## real path; this writes the same `env.wind` field it does.
const WIND_PRESETS: Array[Vector3] = [
	Vector3(0.0, 0.0, 0.0),
	Vector3(0.0, 0.0, -5.0),   # tailwind: blowing downrange
	Vector3(0.0, 0.0, 5.0),    # headwind
	Vector3(4.5, 0.0, -1.5),   # crosswind from the thrower's left
]
var _wind_preset: int = 0


func cycle_wind() -> void:
	_wind_preset = (_wind_preset + 1) % WIND_PRESETS.size()
	env.wind = WIND_PRESETS[_wind_preset]
	sim.configure(disc, env)
	_wind.set_wind(env.wind)


func cycle_disc(step: int) -> void:
	if library.size() == 0:
		return
	var idx: int = 0
	for i in library.size():
		if library.get_index(i) == disc:
			idx = i
			break
	idx = posmod(idx + step, library.size())
	_apply_disc(library.get_index(idx))
	if not _flying:
		_reset_to_tee()


# ---------------------------------------------------------------------------
# Duck-typed coercion at the Track D boundary
# ---------------------------------------------------------------------------

func _coerce_throw(p: Variant) -> DiscFlightSim.ThrowParams:
	if p == null:
		return null
	if p is DiscFlightSim.ThrowParams:
		return p
	var out := DiscFlightSim.ThrowParams.new()
	var src: Dictionary = p if p is Dictionary else {}
	if p is Dictionary:
		for k in ["speed_mps", "spin_rps", "nose_angle_rad", "hyzer_angle_rad",
				"launch_angle_rad", "launch_height_m", "launch_heading_rad"]:
			if src.has(k):
				out.set(k, float(src[k]))
		# Tolerate a degrees-at-the-edge panel.
		for pair in [["nose_angle_deg", "nose_angle_rad"], ["hyzer_angle_deg", "hyzer_angle_rad"],
				["launch_angle_deg", "launch_angle_rad"], ["launch_heading_deg", "launch_heading_rad"]]:
			if src.has(pair[0]):
				out.set(pair[1], deg_to_rad(float(src[pair[0]])))
		return out
	# Any object exposing the same property names.
	for k in ["speed_mps", "spin_rps", "nose_angle_rad", "hyzer_angle_rad",
			"launch_angle_rad", "launch_height_m", "launch_heading_rad"]:
		var v: Variant = p.get(k)
		if v != null:
			out.set(k, float(v))
	return out


func _coerce_env(e: Variant) -> DiscFlightSim.FlightEnvironment:
	var out := DiscFlightSim.make_environment(env.air_density, env.wind, env.gravity)
	if e == null:
		return out
	if e is DiscFlightSim.FlightEnvironment:
		return e
	if e is Dictionary:
		var d: Dictionary = e
		if d.has("altitude_m") or d.has("temperature_c"):
			out.air_density = Atmosphere.air_density(
				float(d.get("altitude_m", 0.0)), float(d.get("temperature_c", 15.0)))
		if d.has("air_density"):
			out.air_density = float(d["air_density"])
		if d.has("wind"):
			out.wind = d["wind"]
		elif d.has("wind_speed"):
			# Meteorological heading in degrees: the direction the wind comes FROM.
			var spd: float = float(d["wind_speed"])
			var from_deg: float = float(d.get("wind_from_deg", 0.0))
			var a: float = deg_to_rad(from_deg)
			out.wind = Vector3(-sin(a), 0.0, cos(a)) * spd
		if d.has("gravity"):
			out.gravity = float(d["gravity"])
		return out
	for k in ["air_density", "gravity"]:
		var v: Variant = e.get(k)
		if v != null:
			out.set(k, float(v))
	var w: Variant = e.get("wind")
	if w != null:
		out.wind = w
	return out


# ---------------------------------------------------------------------------
# Keyboard. Always live, whichever panel is in charge.
# ---------------------------------------------------------------------------

## Track D binds its own shortcuts (SPACE / R / C / V / T / H, digits for tabs)
## and its panel is the authority on input when it exists, so these are only
## live in the built-in debug mode. Two nodes racing for the same key means a
## double throw or a toggle that cancels itself out.
func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if _panel != null:
		# W is the one key Track D does not bind, and it is the only way to
		# exercise the wind visualisation without their Env tab.
		if k.keycode == KEY_W:
			cycle_wind()
			get_viewport().set_input_as_handled()
		return
	match k.keycode:
		KEY_SPACE:
			throw()
		KEY_1:
			set_camera_view("tee")
		KEY_2:
			set_camera_view("follow")
		KEY_3:
			set_camera_view("top")
		KEY_4:
			set_camera_view("side")
		KEY_5:
			set_camera_view("free")
		KEY_V:
			_on_vectors_toggled(not _vectors.is_enabled())
		KEY_C:
			_on_clear_trails()
		KEY_H:
			_hud.toggle_panel()
		KEY_BRACKETLEFT:
			cycle_disc(-1)
		KEY_BRACKETRIGHT:
			cycle_disc(1)
		KEY_R:
			_reset_to_tee()
		KEY_W:
			cycle_wind()
		_:
			return
	get_viewport().set_input_as_handled()

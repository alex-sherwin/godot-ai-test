extends Node

## Standalone harness for the control panel.
##
## Track C owns `scenes/main.tscn` and wires the panel into the real world
## scene; this exists so Track D can run, exercise and screenshot the panel on
## its own — including against the real `DiscFlightSim`, which is the only way
## to check that the units crossing the C ↔ D interface are right.
##
## It is not part of the shipped scene and nothing in `scripts/app/` depends on
## it. `scenes/ui/ui_preview.tscn` is its scene.

var panel: ControlPanel
var sim := DiscFlightSim.new()
var library := DiscLibrary.load_default()
var disc: DiscDefinition
var env: DiscFlightSim.FlightEnvironment
var flying := false
var pending: DiscFlightSim.FlightResult = null


func _ready() -> void:
	panel = preload("res://scenes/ui/control_panel.tscn").instantiate()
	add_child(panel)

	panel.throw_requested.connect(_on_throw)
	panel.disc_selected.connect(_on_disc_selected)
	panel.geometry_changed.connect(_on_geometry_changed)
	panel.environment_changed.connect(_on_env_changed)
	panel.camera_view_changed.connect(func(v: String) -> void:
		panel.set_status("Camera → %s" % v))
	panel.clear_trails_requested.connect(func() -> void:
		panel.set_status("Trails cleared."))
	panel.vectors_toggled.connect(func(on: bool) -> void:
		panel.set_status("Force vectors %s." % ("on" if on else "off")))

	env = DiscFlightSim.FlightEnvironment.new()
	disc = library.get_index(0)
	print("[ui_preview] roster: %d discs, data_present=%s" % [
		library.size(), library.data_present()])

	var args := OS.get_cmdline_user_args()
	var i := args.find("--shots")
	if i >= 0 and i + 1 < args.size():
		_capture_sequence(args[i + 1])


func _on_disc_selected(disc_id: String) -> void:
	var d := library.get_disc(disc_id)
	if d != null:
		disc = d
	panel.set_status("Selected %s" % disc_id)


func _on_geometry_changed(g: Dictionary) -> void:
	panel.set_status("Geometry → rim %.1f mm, parting %.1f mm" % [
		float(g.get("rim_width_m", 0.0)) * 1000.0,
		float(g.get("parting_line_m", 0.0)) * 1000.0])


func _on_env_changed(e: DiscFlightSim.FlightEnvironment) -> void:
	env = e


func _on_throw(p: DiscFlightSim.ThrowParams) -> void:
	if disc == null:
		disc = library.get_index(0)
	if disc == null:
		panel.set_status("No disc available to throw.")
		return
	sim.configure(disc, env)
	pending = sim.simulate_full(p)
	sim.launch(p)
	flying = true


# ---------------------------------------------------------------------------
# Screenshot harness
# ---------------------------------------------------------------------------
# `godot --path game --resolution 1280x720 res://scenes/ui/ui_preview.tscn --
#        --shots /some/dir`
# walks the panel through every state and writes a PNG of each, so the layout
# can be inspected at several window sizes without a human at a keyboard.

func _capture_sequence(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	await _settle(6)
	await _shot(dir, "01-throw")
	for tab in range(1, 5):
		panel._tabs.current_tab = tab
		await _settle(4)
		await _shot(dir, "0%d-%s" % [tab + 1, ControlPanel.TAB_NAMES[tab].to_lower()])
	panel._tabs.current_tab = 4
	panel.do_throw()
	await _settle(45)
	await _shot(dir, "06-inflight")
	var guard := 0
	while flying and guard < 1200:
		guard += 1
		await get_tree().process_frame
	await _settle(6)
	await _shot(dir, "07-landed")
	panel._show_info()
	await _settle(4)
	await _shot(dir, "08-provenance")
	panel._info_overlay.visible = false
	panel.set_drawer_open(false)
	await _settle(4)
	await _shot(dir, "09-collapsed")
	get_tree().quit()


func _settle(frames: int) -> void:
	for i in frames:
		await get_tree().process_frame


func _shot(dir: String, name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [dir, name]
	image.save_png(path)
	print("[ui_preview] wrote %s (%dx%d)" % [path, image.get_width(), image.get_height()])


func _process(delta: float) -> void:
	if not flying:
		return
	sim.step(delta)
	var diagnostics := sim.get_aero_diagnostics()
	panel.set_live_state(sim.get_state(), rad_to_deg(float(diagnostics.get("alpha", 0.0))))
	if not sim.is_flying():
		flying = false
		if pending != null:
			panel.set_flight_result(pending)

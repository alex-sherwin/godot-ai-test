extends RefCounted

## Performance measurement. Reports real numbers; never fails the build.
##
## The budget that matters: at 60 fps a frame is 16.67 ms and the sim owes four
## 1/240 substeps per frame. Anything under ~1% of the frame is comfortable.
## The other number Track C cares about is how long a whole flight takes, since
## an instant trajectory preview means calling `simulate_full()` inside a frame.

const DiscDef := preload("res://scripts/physics/disc_definition.gd")
const Library := preload("res://scripts/physics/disc_library.gd")
const Sim := preload("res://scripts/physics/disc_flight_sim.gd")
const Support := preload("res://tests/test_support.gd")


func run(t: Support, lib: Library) -> void:
	t.suite("performance")
	var disc := lib.get_index(0)
	for i in lib.size():
		var c := lib.get_index(i)
		if c.speed >= 9.0:
			disc = c
			break

	var p := Sim.make_throw_params()
	p.speed_mps = 27.0
	p.spin_rps = 25.0
	p.launch_angle_rad = deg_to_rad(12.0)
	p.hyzer_angle_rad = deg_to_rad(8.0)
	p.launch_height_m = 1.4

	var sim := Sim.new()
	sim.configure(disc, Sim.make_environment())

	# --- warm up (first call pays for lazily-built caches)
	for _i in 3:
		sim.simulate_full(p)

	# --- cost of one 1/240 substep, isolated from sampling and landing logic
	sim.ground_height_m = -1.0e9
	sim.launch(p)
	var substeps := 24000
	var t0 := Time.get_ticks_usec()
	for _i in substeps:
		sim.step(sim.substep_dt)
	var t1 := Time.get_ticks_usec()
	var us_per_substep := float(t1 - t0) / float(substeps)
	sim.ground_height_m = 0.0

	# --- cost of a whole flight through simulate_full (samples + landing solve)
	var runs := 40
	t0 = Time.get_ticks_usec()
	var r: Sim.FlightResult = null
	for _i in runs:
		r = sim.simulate_full(p)
	t1 = Time.get_ticks_usec()
	var ms_per_flight := float(t1 - t0) / float(runs) / 1000.0

	# --- cost of a frame's worth of real-time stepping
	sim.launch(p)
	var frames := 2000
	t0 = Time.get_ticks_usec()
	for _i in frames:
		if not sim.is_flying():
			sim.launch(p)
		sim.step(1.0 / 60.0)
	t1 = Time.get_ticks_usec()
	var us_per_frame := float(t1 - t0) / float(frames)

	var frame_budget_us := 1000000.0 / 60.0
	var pct := 100.0 * us_per_frame / frame_budget_us

	t.note("substep cost: %.2f us (%d substeps timed)" % [us_per_substep, substeps])
	t.note("real-time stepping: %.2f us per 60 fps frame = %.2f%% of the 16.67 ms budget"
		% [us_per_frame, pct])
	t.note("simulate_full: %.2f ms per flight (%.2f s of flight, %d substeps, %d samples)"
		% [ms_per_flight, r.flight_time_s, int(round(r.flight_time_s * 240.0)),
			r.samples.size()])
	t.note("simulate_full is %.1f frames at 60 fps" % (ms_per_flight / 16.667))

	# Not assertions about a specific machine — just guards against a regression
	# that would make the sim unusable at all.
	t.check("real-time stepping fits in the 60 fps budget", pct < 25.0,
		"%.2f%% of a frame" % pct)
	t.check("a full flight simulates in well under a second", ms_per_flight < 500.0,
		"%.2f ms" % ms_per_flight)
	t.end_suite()

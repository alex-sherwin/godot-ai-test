extends RefCounted

## Numerical robustness. Nothing in here asserts that the answers are *good* —
## a tumbling, spinless disc is outside the model's validity. What it asserts is
## that the integrator never produces a NaN, an infinity, or a hang, because
## Track C will be feeding it live slider values and a UI that can be dragged
## into a divide-by-zero is a UI that crashes.

const DiscDef := preload("res://scripts/physics/disc_definition.gd")
const Library := preload("res://scripts/physics/disc_library.gd")
const Sim := preload("res://scripts/physics/disc_flight_sim.gd")
const Support := preload("res://tests/test_support.gd")


func run(t: Support, lib: Library) -> void:
	t.suite("numerical robustness")
	_test_extremes(t, lib)
	_test_wind_exceeds_airspeed(t, lib)
	_test_spin_sweep_through_zero(t, lib)
	_test_launch_below_ground(t, lib)
	_test_interactive_stepping(t, lib)
	t.end_suite()


func _disc(lib: Library) -> DiscDef:
	var best := lib.get_index(0)
	for i in lib.size():
		var d := lib.get_index(i)
		if d.speed >= 9.0:
			return d
	return best


func _finite(v: Vector3) -> bool:
	return is_finite(v.x) and is_finite(v.y) and is_finite(v.z)


func _result_sane(r: Sim.FlightResult) -> bool:
	if not (is_finite(r.distance_m) and is_finite(r.lateral_m)
			and is_finite(r.max_height_m) and is_finite(r.flight_time_s)):
		return false
	if not _finite(r.landing_position):
		return false
	for s in r.samples:
		if not _finite(s["pos"]) or not _finite(s["vel"]):
			return false
		var q: Quaternion = s["quat"]
		if not (is_finite(q.x) and is_finite(q.y) and is_finite(q.z) and is_finite(q.w)):
			return false
		if not is_finite(float(s["spin"])) or not is_finite(float(s["alpha"])):
			return false
	for v in r.trajectory:
		if not _finite(v):
			return false
	return true


func _case(speed: float, spin: float, launch_deg: float, hyzer_deg: float,
		nose_deg: float, height: float, heading_deg: float = 0.0) -> Sim.ThrowParams:
	var p := Sim.make_throw_params()
	p.speed_mps = speed
	p.spin_rps = spin
	p.launch_angle_rad = deg_to_rad(launch_deg)
	p.hyzer_angle_rad = deg_to_rad(hyzer_deg)
	p.nose_angle_rad = deg_to_rad(nose_deg)
	p.launch_height_m = height
	p.launch_heading_rad = deg_to_rad(heading_deg)
	return p


func _test_extremes(t: Support, lib: Library) -> void:
	var disc := _disc(lib)
	var cases := {
		"zero spin": _case(25.0, 0.0, 10.0, 0.0, 0.0, 1.4),
		"near-zero spin (0.01 rev/s)": _case(25.0, 0.01, 10.0, 0.0, 0.0, 1.4),
		"zero velocity": _case(0.0, 25.0, 0.0, 0.0, 0.0, 20.0),
		"zero velocity and zero spin": _case(0.0, 0.0, 0.0, 0.0, 0.0, 20.0),
		"nose +80 deg": _case(25.0, 25.0, 0.0, 0.0, 80.0, 1.4),
		"nose -80 deg": _case(25.0, 25.0, 0.0, 0.0, -80.0, 1.4),
		"hyzer +90 deg (knife edge)": _case(25.0, 25.0, 10.0, 90.0, 0.0, 1.4),
		"hyzer -90 deg": _case(25.0, 25.0, 10.0, -90.0, 0.0, 1.4),
		"hyzer 180 deg (inverted)": _case(25.0, 25.0, 10.0, 180.0, 0.0, 1.4),
		"straight up": _case(25.0, 25.0, 90.0, 0.0, 0.0, 1.4),
		"straight down from height": _case(25.0, 25.0, -90.0, 0.0, 0.0, 50.0),
		"very high spin (200 rev/s)": _case(27.0, 200.0, 12.0, 8.0, 0.0, 1.4),
		"very high speed (100 m/s)": _case(100.0, 25.0, 12.0, 8.0, 0.0, 1.4),
		"negative launch angle": _case(25.0, 25.0, -45.0, 0.0, 0.0, 30.0),
		"heading 170 deg": _case(25.0, 25.0, 10.0, 8.0, 0.0, 1.4, 170.0),
		"heading -170 deg": _case(25.0, 25.0, 10.0, 8.0, 0.0, 1.4, -170.0),
		"tiny speed, huge spin": _case(0.001, 300.0, 0.0, 45.0, 0.0, 5.0),
	}
	var bad := PackedStringArray()
	for name in cases:
		var sim := Sim.new()
		sim.configure(disc, Sim.make_environment())
		var r := sim.simulate_full(cases[name])
		if not _result_sane(r) or r.failed:
			bad.append("%s (failed=%s)" % [name, r.failed])
	t.check("no NaN/inf across %d extreme launch cases" % cases.size(), bad.is_empty(),
		"bad: " + ", ".join(bad) if not bad.is_empty() else "all clean")

	# Degenerate environments.
	var envs := {
		"zero gravity": Sim.make_environment(1.225, Vector3.ZERO, 0.0),
		"zero air density": Sim.make_environment(0.0, Vector3.ZERO, 9.81),
		"zero air and zero gravity": Sim.make_environment(0.0, Vector3.ZERO, 0.0),
		"10x gravity": Sim.make_environment(1.225, Vector3.ZERO, 98.1),
		"10x air density": Sim.make_environment(12.25, Vector3.ZERO, 9.81),
	}
	var bad_env := PackedStringArray()
	for name in envs:
		var sim := Sim.new()
		sim.configure(disc, envs[name])
		# Zero gravity with lift would fly forever; MAX_FLIGHT_TIME must bound it.
		var r := sim.simulate_full(_case(25.0, 25.0, 10.0, 5.0, 0.0, 1.4))
		if not _result_sane(r) or r.failed:
			bad_env.append(name)
		# The guard is checked before each substep, so overshooting by up to one
		# substep is correct behaviour, not a runaway.
		if r.flight_time_s > Sim.MAX_FLIGHT_TIME + Sim.FIXED_DT + 1e-6:
			bad_env.append(name + " (exceeded MAX_FLIGHT_TIME)")
	t.check("no NaN/inf across %d degenerate environments" % envs.size(),
		bad_env.is_empty(), "bad: " + ", ".join(bad_env) if not bad_env.is_empty() else "all clean")


## A headwind bigger than the launch speed drives the airspeed vector through
## zero and out the other side. That reverses the sign of the relative flow and
## makes vhat undefined at the crossing.
func _test_wind_exceeds_airspeed(t: Support, lib: Library) -> void:
	var disc := _disc(lib)
	var winds := {
		"30 m/s headwind vs 20 m/s throw": Vector3(0.0, 0.0, 20.0),
		"exact cancelling headwind": Vector3(0.0, 0.0, 20.0 * cos(deg_to_rad(10.0))),
		"30 m/s tailwind": Vector3(0.0, 0.0, -30.0),
		"pure crosswind": Vector3(25.0, 0.0, 0.0),
		"violent updraft": Vector3(0.0, 40.0, 0.0),
		"downdraft": Vector3(0.0, -40.0, 0.0),
	}
	var bad := PackedStringArray()
	for name in winds:
		var sim := Sim.new()
		sim.configure(disc, Sim.make_environment(1.225, winds[name], 9.81))
		var r := sim.simulate_full(_case(20.0, 20.0, 10.0, 5.0, 0.0, 1.4))
		if not _result_sane(r) or r.failed:
			bad.append(name)
	t.check("no NaN/inf with wind at or beyond the airspeed", bad.is_empty(),
		"bad: " + ", ".join(bad) if not bad.is_empty() else "all clean")

	# Galilean invariance. Every aerodynamic force depends only on (v - wind) and
	# gravity is uniform, so flying into a steady wind MUST be identical to flying
	# in still air with the launch velocity reduced by the wind, then translating
	# the whole trajectory by wind*t. This is an exact identity, so it is a much
	# sharper check of the airspeed plumbing than any "a tailwind goes further"
	# intuition — which is in fact false for a disc, since a tailwind also removes
	# the lift that keeps it up.
	var w: float = 8.0
	var wind := Vector3(0.0, 0.0, -w)          # blowing downrange (tailwind)
	var u: float = 25.0
	var with_wind := Sim.new()
	with_wind.configure(disc, Sim.make_environment(1.225, wind, 9.81))
	with_wind.ground_height_m = -1.0e9
	with_wind.launch(_case(u, 25.0, 0.0, 5.0, 0.0, 1.4))
	var still := Sim.new()
	still.configure(disc, Sim.make_environment(1.225, Vector3.ZERO, 9.81))
	still.ground_height_m = -1.0e9
	still.launch(_case(u - w, 25.0, 0.0, 5.0, 0.0, 1.4))
	var worst: float = 0.0
	for _i in 360:
		with_wind.step(with_wind.substep_dt)
		still.step(still.substep_dt)
		var tt: float = still.get_state().time
		var a := with_wind.get_state().position
		var b: Vector3 = still.get_state().position + wind * tt
		worst = maxf(worst, a.distance_to(b))
	t.check("a steady wind is exactly a Galilean shift of still air",
		worst < 1e-3, "max divergence over 1.5 s = %s m" % Support.g(worst, 3))

	var sim_h := Sim.new()
	sim_h.configure(disc, Sim.make_environment(1.225, Vector3(0.0, 0.0, 8.0), 9.81))
	var head := sim_h.simulate_full(_case(25.0, 25.0, 10.0, 5.0, 0.0, 1.4))
	var sim_c := Sim.new()
	sim_c.configure(disc, Sim.make_environment(1.225, Vector3.ZERO, 9.81))
	var calm := sim_c.simulate_full(_case(25.0, 25.0, 10.0, 5.0, 0.0, 1.4))
	var sim_t := Sim.new()
	sim_t.configure(disc, Sim.make_environment(1.225, Vector3(0.0, 0.0, -8.0), 9.81))
	var tail := sim_t.simulate_full(_case(25.0, 25.0, 10.0, 5.0, 0.0, 1.4))
	t.note("8 m/s wind, downrange distance: headwind %.1f, calm %.1f, tailwind %.1f m "
		% [head.downrange_m, calm.downrange_m, tail.downrange_m]
		+ "(a tailwind shortening the flight is correct — it removes airspeed, "
		+ "hence lift)")


## Spin crossing zero is the one genuinely singular point in the precession law.
## Sweep across it and check every result is finite and that the response varies
## smoothly rather than jumping.
func _test_spin_sweep_through_zero(t: Support, lib: Library) -> void:
	var disc := _disc(lib)
	var sim := Sim.new()
	sim.configure(disc, Sim.make_environment())
	var last := INF
	var worst_jump: float = 0.0
	var bad := 0
	var rps: float = -6.0
	while rps <= 6.0001:
		var r := sim.simulate_full(_case(22.0, rps, 10.0, 0.0, 0.0, 1.4))
		if not _result_sane(r) or r.failed:
			bad += 1
		elif last != INF:
			worst_jump = maxf(worst_jump, absf(r.lateral_m - last))
		if _result_sane(r):
			last = r.lateral_m
		rps += 0.25
	t.check("spin sweep through zero stays finite", bad == 0, "%d bad results" % bad)
	t.check("spin sweep through zero has no discontinuous jump", worst_jump < 25.0,
		"largest step-to-step lateral change %.2f m" % worst_jump)


func _test_launch_below_ground(t: Support, lib: Library) -> void:
	var disc := _disc(lib)
	var sim := Sim.new()
	sim.configure(disc, Sim.make_environment())
	var r := sim.simulate_full(_case(25.0, 25.0, 10.0, 0.0, 0.0, 0.0))
	t.check("launching exactly on the ground plane terminates", _result_sane(r)
		and r.flight_time_s <= Sim.MAX_FLIGHT_TIME, "t = %.3f s" % r.flight_time_s)
	var r2 := sim.simulate_full(_case(25.0, 25.0, -10.0, 0.0, 0.0, -5.0))
	t.check("launching below the ground plane terminates", _result_sane(r2)
		and r2.flight_time_s <= Sim.MAX_FLIGHT_TIME, "t = %.3f s" % r2.flight_time_s)


## The interactive path (launch + step) must survive the same abuse, and must not
## keep stepping after landing.
func _test_interactive_stepping(t: Support, lib: Library) -> void:
	var disc := _disc(lib)
	var sim := Sim.new()
	sim.configure(disc, Sim.make_environment())
	sim.launch(_case(27.0, 25.0, 12.0, 8.0, 0.0, 1.4))
	var guard := 0
	while sim.is_flying() and guard < 10000:
		sim.step(1.0 / 60.0)
		guard += 1
	var s := sim.get_state()
	t.check("interactive flight terminates", not sim.is_flying() and guard < 10000,
		"%d frames" % guard)
	t.check("interactive state is finite", _finite(s.position) and _finite(s.velocity)
		and _finite(s.angular_velocity) and is_finite(s.spin))
	var before := sim.get_state().position
	sim.step(1.0)
	t.check("stepping after landing is a no-op",
		before.distance_to(sim.get_state().position) == 0.0)
	# Negative and zero deltas must not move anything or corrupt the accumulator.
	sim.launch(_case(27.0, 25.0, 12.0, 8.0, 0.0, 1.4))
	var p0 := sim.get_state().position
	sim.step(0.0)
	sim.step(-1.0)
	t.check("zero and negative deltas are no-ops",
		p0.distance_to(sim.get_state().position) == 0.0)

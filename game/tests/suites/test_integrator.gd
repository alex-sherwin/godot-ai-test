extends RefCounted

## Integrator-only tests. These deliberately isolate the RK4 core from the
## aerodynamic model: if one of these fails the bug is in the integration, not
## in the coefficient data.

const AeroTable := preload("res://scripts/physics/aero_table.gd")
const DiscDef := preload("res://scripts/physics/disc_definition.gd")
const Library := preload("res://scripts/physics/disc_library.gd")
const Sim := preload("res://scripts/physics/disc_flight_sim.gd")
const Support := preload("res://tests/test_support.gd")


func run(t: Support, lib: Library) -> void:
	t.suite("integrator")
	_test_ballistic(t, lib)
	_test_ballistic_ignores_wind(t, lib)
	_test_energy_no_drag(t, lib)
	_test_quaternion_normalised(t, lib)
	_test_convergence(t, lib)
	_test_landing_interpolation(t, lib)
	_test_frame_rate_independence(t, lib)
	t.end_suite()


func _drive_disc(lib: Library) -> DiscDef:
	var d := lib.get_index(0)
	for i in lib.size():
		var c := lib.get_index(i)
		if c.speed >= 9.0:
			return c
	return d


## With rho = 0 there is no aerodynamic force at all, so the disc must follow the
## closed-form parabola exactly. RK4 integrates a constant acceleration exactly
## (the solution is a degree-2 polynomial), so any deviation here is arithmetic
## error or a wiring bug — not truncation.
func _test_ballistic(t: Support, lib: Library) -> void:
	var sim := Sim.new()
	var g := 9.81
	sim.configure(_drive_disc(lib), Sim.make_environment(0.0, Vector3.ZERO, g))
	sim.ground_height_m = -1.0e9  # never land; we want a pure free-flight check

	var p := Sim.make_throw_params()
	p.speed_mps = 27.0
	p.spin_rps = 25.0
	p.launch_angle_rad = deg_to_rad(18.0)
	p.launch_height_m = 1.4
	p.launch_heading_rad = deg_to_rad(23.0)
	sim.launch(p)

	# Read the raw double state, not get_state(): Vector3 is single precision, so
	# a 50 m coordinate read through one carries ~4e-6 m of rounding, which would
	# be the entire "error" this test claims to measure.
	var y0 := sim.get_state_vector()
	var x0 := [y0[0], y0[1], y0[2]]
	var v0 := [y0[3], y0[4], y0[5]]

	var worst_pos: float = 0.0
	var worst_vel: float = 0.0
	for _i in 480:  # 2 s at 1/240
		sim.step(sim.substep_dt)
		var y := sim.get_state_vector()
		var tt: float = sim.get_state().time
		for k in 3:
			var drop: float = -0.5 * g * tt * tt if k == 1 else 0.0
			var dv: float = -g * tt if k == 1 else 0.0
			worst_pos = maxf(worst_pos, absf(y[k] - (float(x0[k]) + float(v0[k]) * tt + drop)))
			worst_vel = maxf(worst_vel, absf(y[3 + k] - (float(v0[k]) + dv)))
	t.check("zero-density flight matches the closed-form parabola",
		worst_pos < 1e-11, "max position error %s m over 2 s" % Support.g(worst_pos, 3))
	t.check("zero-density velocity matches v0 + g t",
		worst_vel < 1e-12, "max velocity error %s m/s" % Support.g(worst_vel, 3))
	# Attitude must be frozen too: no air, no moment, no precession.
	var yq := sim.get_state_vector()
	var qmove: float = 0.0
	for i in range(6, 10):
		qmove = maxf(qmove, absf(yq[i] - y0[i]))
	# One-time renormalisation only: the launch quaternion is built through
	# Godot's Basis, which is single precision, so the first RK4 step normalises
	# it in double and moves it by ~1 float32 ulp. After that it is frozen.
	t.check("no air means no precession", qmove < 1e-6,
		"quaternion moved %s" % Support.g(qmove, 3))
	t.close("no air means no spin loss", sim.get_state().spin, p.spin_rps * TAU, 1e-9)


func _test_ballistic_ignores_wind(t: Support, lib: Library) -> void:
	# Wind only enters through the airspeed vector, which only matters through
	# rho. With rho = 0 a gale must change nothing (CONTRACT §6).
	var results: Array[Vector3] = []
	for wind in [Vector3.ZERO, Vector3(30.0, -5.0, 12.0)]:
		var sim := Sim.new()
		sim.configure(_drive_disc(lib), Sim.make_environment(0.0, wind, 9.81))
		var p := Sim.make_throw_params()
		p.speed_mps = 20.0
		p.spin_rps = 20.0
		p.launch_angle_rad = deg_to_rad(15.0)
		results.append(sim.simulate_full(p).landing_position)
	t.check("wind has no effect at zero air density",
		results[0].distance_to(results[1]) < 1e-9,
		"landing moved %s m" % Support.g(results[0].distance_to(results[1]), 3))


## Drag off, lift off, moments off: the only force is gravity, so total
## mechanical energy must be conserved to integrator precision. This is a
## sharper check on the velocity integration than the parabola, because it is
## sensitive to any spurious force the aero path might inject.
func _test_energy_no_drag(t: Support, lib: Library) -> void:
	var disc := DiscDef.builtin("reference_driver")
	var tab := AeroTable.new()
	var n := 361
	tab.alpha_rad.resize(n)
	tab.cl.resize(n)
	tab.cd.resize(n)
	tab.cm.resize(n)
	for i in n:
		tab.alpha_rad[i] = deg_to_rad(-90.0 + 0.5 * float(i))
		tab.cl[i] = 0.0
		tab.cd[i] = 0.0
		tab.cm[i] = 0.0
	tab.finalize()
	disc.aero = tab

	var sim := Sim.new()
	sim.configure(disc, Sim.make_environment(1.225, Vector3.ZERO, 9.81))
	sim.ground_height_m = -1.0e9
	var p := Sim.make_throw_params()
	p.speed_mps = 25.0
	p.spin_rps = 25.0
	p.launch_angle_rad = deg_to_rad(20.0)
	sim.launch(p)

	var m := disc.mass_kg
	var y := sim.get_state_vector()
	var e0: float = _energy(y, m, 9.81)
	var worst: float = 0.0
	for _i in 720:
		sim.step(sim.substep_dt)
		worst = maxf(worst, absf(_energy(sim.get_state_vector(), m, 9.81) - e0) / e0)
	t.check("energy conserved with all coefficients zeroed", worst < 1e-12,
		"max relative drift %s over 3 s" % Support.g(worst, 3))


func _energy(y: PackedFloat64Array, m: float, g: float) -> float:
	var v2: float = y[3] * y[3] + y[4] * y[4] + y[5] * y[5]
	return 0.5 * m * v2 + m * g * y[1]


func _test_quaternion_normalised(t: Support, lib: Library) -> void:
	var sim := Sim.new()
	sim.configure(_drive_disc(lib), Sim.make_environment())
	var p := Sim.make_throw_params()
	p.speed_mps = 27.0
	p.spin_rps = 25.0
	p.launch_angle_rad = deg_to_rad(12.0)
	p.hyzer_angle_rad = deg_to_rad(8.0)
	var r := sim.simulate_full(p)
	var worst: float = 0.0
	for s in r.samples:
		var q: Quaternion = s["quat"]
		worst = maxf(worst, absf(q.length() - 1.0))
	t.check("quaternion stays unit over a whole flight", worst < 1e-6,
		"max |q|-1 = %s over %d samples" % [Support.g(worst, 3), r.samples.size()])


## Halve dt and the error must fall by ~16x. This proves the integrator really is
## 4th order and has not silently degraded to something lower (a mis-weighted
## stage, or a stage evaluated at the wrong time, typically drops it to 2nd).
##
## Measured on the disc NORMAL rather than position: the normal is a unit vector,
## so its float32 noise floor is ~1e-7 regardless of how far the disc has flown,
## which leaves several decades of clean dynamic range. Position is reported too.
func _test_convergence(t: Support, lib: Library) -> void:
	# Convergence is measured on a GLOBALLY LINEAR coefficient table, not a shipped
	# one. The shipped tables are sampled on a 0.5 deg grid and read with linear
	# interpolation, so the right-hand side has a slope discontinuity at every
	# node; RK4 on a C0 right-hand side is not 4th order, and measuring it there
	# would be measuring the table, not the integrator. A table that is linear in
	# alpha everywhere is reproduced exactly by linear interpolation, which makes
	# the right-hand side smooth. The shipped-table order is reported below too.
	var disc := _smooth_disc(lib)
	var horizon := 1.0

	var p := Sim.make_throw_params()
	p.speed_mps = 27.0
	p.spin_rps = 25.0
	p.launch_angle_rad = deg_to_rad(12.0)
	p.hyzer_angle_rad = deg_to_rad(8.0)
	p.nose_angle_rad = deg_to_rad(3.0)

	var reference := _state_after(disc, p, horizon, 1.0 / 7680.0)
	var dts := [1.0 / 10.0, 1.0 / 20.0, 1.0 / 40.0, 1.0 / 80.0]
	var errs_n: Array[float] = []
	var errs_p: Array[float] = []
	for dt in dts:
		var st := _state_after(disc, p, horizon, float(dt))
		errs_n.append(_quat_dist(st, reference))
		errs_p.append(_pos_dist(st, reference))

	var detail := ""
	for i in dts.size():
		detail += "1/%d:%s/%s " % [int(round(1.0 / float(dts[i]))), Support.g(errs_n[i], 3), Support.g(errs_p[i], 3)]
	t.note("convergence (dt: quat-err/pos-err vs dt=1/7680) " + detail.strip_edges())

	# Only the first two ratios are used for the order estimate. Godot's Vector3
	# and Quaternion are single precision, so every derivative evaluation carries
	# ~1e-7 relative noise no matter how small dt is; once truncation error drops
	# below that floor the ladder saturates and the ratio stops meaning anything.
	# The ladder above is chosen coarse enough that the first two rungs sit well
	# clear of it, and all four are reported so the floor is visible.
	var order_ok := true
	var orders := ""
	for i in 2:
		var ratio: float = errs_n[i] / maxf(errs_n[i + 1], 1e-300)
		var order: float = log(ratio) / log(2.0)
		orders += "%.2f " % order
		if order < 3.5:
			order_ok = false
	t.check("RK4 is 4th order in the disc attitude", order_ok,
		"observed orders: %s(expect ~4)" % orders)

	var order_ok_p := true
	var orders_p := ""
	for i in 2:
		var ratio: float = errs_p[i] / maxf(errs_p[i + 1], 1e-300)
		var order: float = log(ratio) / log(2.0)
		orders_p += "%.2f " % order
		if order < 3.5:
			order_ok_p = false
	t.check("RK4 is 4th order in position", order_ok_p,
		"observed orders: %s(expect ~4)" % orders_p)

	# Same ladder on a real shipped table, reported not asserted: this is the
	# order the sim actually runs at, and it is lower because the interpolated
	# table is only C0. Worth knowing; not worth failing over, since the absolute
	# error at 1/240 is still far below anything that matters (see the landing
	# and cross-validation tests).
	var real_disc := _drive_disc(lib)
	var ref2 := _state_after(real_disc, p, horizon, 1.0 / 7680.0)
	var e2: Array[float] = []
	for dt in dts:
		e2.append(_quat_dist(_state_after(real_disc, p, horizon, float(dt)), ref2))
	var ord2 := ""
	for i in 2:
		ord2 += "%.2f " % (log(e2[i] / maxf(e2[i + 1], 1e-300)) / log(2.0))
	t.note("observed order on a real (piecewise-linear, C0) shipped table: %s"
		% ord2.strip_edges()
		+ " — lower than 4 because linear interpolation puts a slope "
		+ "discontinuity at every 0.5 deg node")


## Distance between two raw states' orientation quaternions, in double. The
## quaternion is a unit 4-vector so this has a float64 noise floor of ~1e-16,
## which leaves the whole RK4 convergence ladder measurable.
## A disc whose coefficients are exactly linear in alpha, so that the table's
## linear interpolation is exact and the ODE right-hand side is smooth.
func _smooth_disc(lib: Library) -> DiscDef:
	var src := _drive_disc(lib)
	var tab := AeroTable.new()
	var n := 361
	tab.alpha_rad.resize(n)
	tab.cl.resize(n)
	tab.cd.resize(n)
	tab.cm.resize(n)
	for i in n:
		var a: float = deg_to_rad(-90.0 + 0.5 * float(i))
		tab.alpha_rad[i] = a
		tab.cl[i] = 0.15 + 2.4 * a
		tab.cd[i] = 0.08 + 0.50 * a
		tab.cm[i] = -0.015 + 0.30 * a
	tab.c_mq = src.aero.c_mq
	tab.c_rp = src.aero.c_rp
	tab.c_nr = src.aero.c_nr
	tab.finalize()
	var d := DiscDef.new()
	d.id = "smooth_linear"
	d.mass_kg = src.mass_kg
	d.diameter_m = src.diameter_m
	d.area_m2 = src.area_m2
	d.i_zz = src.i_zz
	d.i_xy = src.i_xy
	d.aero = tab
	return d


func _quat_dist(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	var s: float = 0.0
	for i in range(6, 10):
		var d: float = a[i] - b[i]
		s += d * d
	return sqrt(s)


func _pos_dist(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	var s: float = 0.0
	for i in 3:
		var d: float = a[i] - b[i]
		s += d * d
	return sqrt(s)


func _state_after(disc: DiscDef, p: Sim.ThrowParams, horizon: float, dt: float) -> PackedFloat64Array:
	var sim := Sim.new()
	sim.configure(disc, Sim.make_environment())
	sim.ground_height_m = -1.0e9
	sim.substep_dt = dt
	sim.launch(p)
	var steps: int = int(round(horizon / dt))
	for _i in steps:
		sim.step(dt)
	return sim.get_state_vector()


## CONTRACT §4: interpolate the ground crossing inside the final substep — a
## 1/240 step at 25 m/s is 10 cm of landing error otherwise. Compare the landing
## point against a run at 1/3840, which resolves the crossing 16x more finely.
func _test_landing_interpolation(t: Support, lib: Library) -> void:
	var disc := _drive_disc(lib)
	var p := Sim.make_throw_params()
	p.speed_mps = 27.0
	p.spin_rps = 25.0
	p.launch_angle_rad = deg_to_rad(12.0)
	p.hyzer_angle_rad = deg_to_rad(8.0)

	var sim := Sim.new()
	sim.configure(disc, Sim.make_environment())
	var coarse := sim.simulate_full(p)
	sim.substep_dt = 1.0 / 3840.0
	var fine := sim.simulate_full(p)

	t.check("lands exactly on the ground plane", absf(coarse.landing_position.y) < 1e-9,
		"landing y = %s m" % Support.g(coarse.landing_position.y, 3))
	t.check("both runs land", coarse.landed and fine.landed)
	var d: float = absf(coarse.horizontal_distance_m - fine.horizontal_distance_m)
	# A whole unrefined substep would be ~10 cm; the truncation difference between
	# 1/240 and 1/3840 over a 100 m flight dominates what is left.
	t.check("landing distance agrees with a 16x finer run", d < 0.15,
		"|d| = %.4f m (coarse %.3f, fine %.3f)" % [d, coarse.horizontal_distance_m,
			fine.horizontal_distance_m])
	var dl: float = absf(coarse.lateral_m - fine.lateral_m)
	t.check("landing lateral agrees with a 16x finer run", dl < 0.20,
		"|d| = %.4f m" % dl)


## step() must produce the same physics regardless of how the caller chops up
## time, because the accumulator carries the remainder.
func _test_frame_rate_independence(t: Support, lib: Library) -> void:
	var disc := _drive_disc(lib)
	var p := Sim.make_throw_params()
	p.speed_mps = 24.0
	p.spin_rps = 22.0
	p.launch_angle_rad = deg_to_rad(10.0)

	var total := 2.0
	var positions: Array[Vector3] = []
	# 60 fps, 144 fps, and a deliberately jittery frame time.
	for pattern in [[1.0 / 60.0], [1.0 / 144.0], [0.004, 0.021, 0.009, 0.033, 0.012]]:
		var sim := Sim.new()
		sim.configure(disc, Sim.make_environment())
		sim.ground_height_m = -1.0e9
		sim.launch(p)
		var acc := 0.0
		var k := 0
		while acc < total - 1e-12:
			var d: float = minf(float(pattern[k % pattern.size()]), total - acc)
			sim.step(d)
			acc += d
			k += 1
		positions.append(sim.get_state().position)
	var worst: float = 0.0
	for i in range(1, positions.size()):
		worst = maxf(worst, positions[0].distance_to(positions[i]))
	# The residue is at most one un-run substep's worth of motion, and in practice
	# far less because the accumulator carries it forward.
	t.check("step() is frame-rate independent", worst < 1e-6,
		"max divergence after 2 s = %s m" % Support.g(worst, 3))

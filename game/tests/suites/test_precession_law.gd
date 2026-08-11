extends RefCounted

## Which precession law is correct, settled by measurement rather than argument.
##
## The flight integrator does not integrate rigid-body rotation. It applies a
## CLOSED FORM for the quasi-steady precession rate, because doing so removes the
## ~314 rad/s nutation mode and is what makes 240 Hz RK4 viable. Two closed forms
## are in circulation and they differ by a factor of ~2 for a disc:
##
##     A)  dn/dt = -M_perp / (I_zz * spin)
##     B)  dn/dt = -M_perp / ((I_zz - I_xy) * spin)     <- ~2x A for a disc
##
## B comes from writing Euler's equations in the SPINNING body frame and setting
## the transverse rate derivatives to zero. That step is invalid: during steady
## precession the transverse angular velocity is very nearly constant in SPACE,
## so in a frame spinning at 150 rad/s its components are not constant at all —
## they rotate at the spin rate. Carrying that term through cancels the I_xy
## contribution exactly and returns form A. Form A is also the textbook fast-top
## result, precession = torque / (spin-axis inertia * spin rate).
##
## Rather than rely on that argument, this test integrates the FULL Euler
## equations for an axisymmetric rigid body — body-frame angular velocity plus a
## rotation matrix, no quasi-steady assumption anywhere, no reference to either
## closed form — at a timestep that resolves nutation ~1000x per period, and
## measures how fast the symmetry axis actually moves under a constant torque.
##
## The sim ships form A multiplied by an explicit empirical DiscFlightSim.
## PRECESSION_GAIN of 2.0, which is numerically close to form B but is labelled
## for what it is: a stand-in for the spin-induced rolling moment the steady
## non-rotating CFD tables cannot contain. This test exists so that the 2.0 stays
## a measured, deliberate trade-off instead of quietly becoming folklore about
## what Euler's equations say — and so nobody re-derives form B and folds the
## factor into an inertia term, where it would silently vary per disc.

const Sim := preload("res://scripts/physics/disc_flight_sim.gd")
const Library := preload("res://scripts/physics/disc_library.gd")
const Support := preload("res://tests/test_support.gd")

# State layout: [0..8] rotation matrix body->world, row-major; [9..11] body-frame
# angular velocity. Doubles throughout — Godot's Basis is single precision and
# 10000 steps of it would swamp the effect being measured.
const _NS := 12


func run(t: Support, lib: Library) -> void:
	t.suite("precession law (raw Euler, no quasi-steady assumption)")
	_measure(t, lib)
	_gain_is_global(t, lib)
	_flight_sensitivity(t, lib)
	t.end_suite()


func _measure(t: Support, lib: Library) -> void:
	var disc := lib.get_index(0)
	var i_zz: float = disc.i_zz
	var i_xy: float = disc.i_xy
	var spin: float = 157.08          # rad/s, a normal 25 rev/s throw
	var torque: float = 0.06          # N m, the scale of a real pitching moment

	var nutation_period: float = TAU / ((i_zz / i_xy) * spin)
	var dt: float = 2.0e-5
	var horizon: float = 0.2
	var steps: int = int(round(horizon / dt))

	var y := PackedFloat64Array()
	y.resize(_NS)
	# identity rotation
	y[0] = 1.0; y[1] = 0.0; y[2] = 0.0
	y[3] = 0.0; y[4] = 1.0; y[5] = 0.0
	y[6] = 0.0; y[7] = 0.0; y[8] = 1.0
	y[9] = 0.0; y[10] = 0.0; y[11] = spin   # spinning about body +z

	var n_start := Vector3(y[2], y[5], y[8])
	for _i in steps:
		_rk4(y, dt, i_xy, i_zz, torque)
		_orthonormalise(y)
	var n_end := Vector3(y[2], y[5], y[8])

	# The axis rotates through an angle; for a unit vector |dn/dt| is that
	# angular rate. Measure the angle, not the chord.
	var cosang: float = clampf(n_start.dot(n_end), -1.0, 1.0)
	var measured: float = acos(cosang) / horizon

	var law_a: float = torque / (i_zz * spin)
	var law_b: float = torque / (absf(i_zz - i_xy) * spin)
	# The whole point of naming the gain: form B's implied gain is not exactly 2,
	# it is I_zz/(I_zz - I_xy), which varies across the roster.
	var ratio_a: float = measured / law_a
	var ratio_b: float = measured / law_b

	t.note("raw Euler: nutation period %.4f s resolved at %d steps/period; "
		% [nutation_period, int(nutation_period / dt)]
		+ "measured |dn/dt| = %s rad/s" % Support.g(measured, 5))
	t.check("raw Euler kinematics are -M/(I_zz*spin), i.e. gain 1.0",
		absf(ratio_a - 1.0) < 0.02,
		"measured/law = %.4f (law = %s rad/s)" % [ratio_a, Support.g(law_a, 5)])
	t.check("raw Euler is NOT -M/((I_zz-I_xy)*spin) — that form is not kinematics",
		absf(ratio_b - 1.0) > 0.2,
		"measured/law = %.4f — that form is %.2fx too large for a disc"
			% [ratio_b, law_b / law_a])

	# Same measurement at a different spin, to confirm the 1/spin scaling rather
	# than an accidental numerical coincidence at one operating point.
	var y2 := y.duplicate()
	y2[0] = 1.0; y2[1] = 0.0; y2[2] = 0.0
	y2[3] = 0.0; y2[4] = 1.0; y2[5] = 0.0
	y2[6] = 0.0; y2[7] = 0.0; y2[8] = 1.0
	y2[9] = 0.0; y2[10] = 0.0; y2[11] = spin * 2.0
	for _i in steps:
		_rk4(y2, dt, i_xy, i_zz, torque)
		_orthonormalise(y2)
	var n2 := Vector3(y2[2], y2[5], y2[8])
	var measured2: float = acos(clampf(n_start.dot(n2), -1.0, 1.0)) / horizon
	t.close("doubling the spin halves the precession rate", measured2 * 2.0,
		measured, 0.02 * measured, " rad/s")


func _orthonormalise(y: PackedFloat64Array) -> void:
	# Gram-Schmidt on the three rows; cheap and keeps the matrix a rotation over
	# tens of thousands of steps.
	var ax := Vector3(y[0], y[1], y[2])
	var ay := Vector3(y[3], y[4], y[5])
	ax = ax.normalized()
	ay = (ay - ax * ay.dot(ax)).normalized()
	var az: Vector3 = ax.cross(ay)
	y[0] = ax.x; y[1] = ax.y; y[2] = ax.z
	y[3] = ay.x; y[4] = ay.y; y[5] = ay.z
	y[6] = az.x; y[7] = az.y; y[8] = az.z


## dR/dt = R [w]x  and  I w' = M_body - w x (I w), with a constant WORLD torque
## along +x. Columns of R (i.e. y[i*3+2] etc.) are the body axes in world;
## here y is stored row-major so column 2 is (y[2], y[5], y[8]) = body +z in
## world = the symmetry axis.
func _derivs(y: PackedFloat64Array, dy: PackedFloat64Array, i_xy: float,
		i_zz: float, torque: float) -> void:
	var p: float = y[9]
	var q: float = y[10]
	var r: float = y[11]

	# dR/dt = R [w]x, row-major: row i of dR = row i of R times [w]x
	for row in 3:
		var a: float = y[row * 3 + 0]
		var b: float = y[row * 3 + 1]
		var c: float = y[row * 3 + 2]
		# (a,b,c) * [w]x  with [w]x = [[0,-r,q],[r,0,-p],[-q,p,0]]
		dy[row * 3 + 0] = b * r - c * q
		dy[row * 3 + 1] = -a * r + c * p
		dy[row * 3 + 2] = a * q - b * p

	# M_body = R^T * M_world, M_world = (torque, 0, 0). R^T column layout:
	# (R^T M)_j = sum_i R[i][j] * M[i]; with M only in world x, that is row 0.
	# Careful: R maps body->world, so world x is the FIRST ROW of R^T's product
	# -> M_body_j = R[0][j]... no: (R^T M)_j = sum_i R_ij M_i = R_0j * torque.
	var mx: float = y[0] * torque
	var my: float = y[1] * torque
	var mz: float = y[2] * torque

	# I w = (i_xy p, i_xy q, i_zz r); w x (I w)
	var hx: float = i_xy * p
	var hy: float = i_xy * q
	var hz: float = i_zz * r
	var cx: float = q * hz - r * hy
	var cy: float = r * hx - p * hz
	var cz: float = p * hy - q * hx

	dy[9] = (mx - cx) / i_xy
	dy[10] = (my - cy) / i_xy
	dy[11] = (mz - cz) / i_zz


# Hoisted out of _rk4: allocating five arrays per step dominated the runtime of a
# 10000-step integration.
var _k1 := PackedFloat64Array()
var _k2 := PackedFloat64Array()
var _k3 := PackedFloat64Array()
var _k4 := PackedFloat64Array()
var _tmp := PackedFloat64Array()


func _init() -> void:
	_k1.resize(_NS)
	_k2.resize(_NS)
	_k3.resize(_NS)
	_k4.resize(_NS)
	_tmp.resize(_NS)


func _rk4(y: PackedFloat64Array, dt: float, i_xy: float, i_zz: float,
		torque: float) -> void:
	var k1 := _k1
	var k2 := _k2
	var k3 := _k3
	var k4 := _k4
	var tmp := _tmp
	_derivs(y, k1, i_xy, i_zz, torque)
	for i in _NS:
		tmp[i] = y[i] + 0.5 * dt * k1[i]
	_derivs(tmp, k2, i_xy, i_zz, torque)
	for i in _NS:
		tmp[i] = y[i] + 0.5 * dt * k2[i]
	_derivs(tmp, k3, i_xy, i_zz, torque)
	for i in _NS:
		tmp[i] = y[i] + dt * k3[i]
	_derivs(tmp, k4, i_xy, i_zz, torque)
	for i in _NS:
		y[i] += (dt / 6.0) * (k1[i] + 2.0 * k2[i] + 2.0 * k3[i] + k4[i])


## What the choice is actually worth in flight, so the trade-off is visible.
## Reported, not asserted — this is the number the coordinator needs in order to
## decide, and it is exactly the ~2x the two laws differ by.
func _flight_sensitivity(t: Support, lib: Library) -> void:
	var disc := lib.get_disc("destroyer")
	if disc == null:
		disc = lib.get_index(0)
	var p := Sim.make_throw_params()
	p.speed_mps = 27.0
	p.spin_rps = 25.0
	p.launch_angle_rad = deg_to_rad(12.0)
	p.hyzer_angle_rad = deg_to_rad(8.0)
	p.launch_height_m = 1.4

	var out := ""
	for gain in [1.0, Sim.PRECESSION_GAIN]:
		var sim := Sim.new()
		sim.precession_gain = float(gain)
		sim.configure(disc, Sim.make_environment())
		var r := sim.simulate_full(p)
		out += "gain %.1f: %.1f m in %.2f s, maxR %+.1f, lands %+.1f, apex %.1f m   " % [
			gain, r.horizontal_distance_m, r.flight_time_s, r.max_right_m,
			r.lateral_m, r.max_height_m]
	t.note("what PRECESSION_GAIN is worth (%s, 27 m/s, 25 rev/s, 12 deg, 8 deg hyzer) — %s"
		% [disc.id, out.strip_edges()])
	t.note("PRECESSION_GAIN = %.1f is EMPIRICAL. Kinematics are 1.0 (measured above); "
		% Sim.PRECESSION_GAIN
		+ "the 2.0 stands in for C_Rr, the spin-induced rolling moment that "
		+ "steady-state RANS on a non-rotating disc structurally cannot produce.")


## CONTRACT v3: the gain must be one constant applied globally and identically.
## The failure mode this guards is someone folding it into `I_zz - I_xy`, which
## looks equivalent and is not: that ratio varies across the roster, so the gain
## would quietly become a per-disc fudge factor.
func _gain_is_global(t: Support, lib: Library) -> void:
	var wrong_default := PackedStringArray()
	var worst_implied_spread: float = 0.0
	var implied_min: float = INF
	var implied_max: float = -INF
	for i in lib.size():
		var d := lib.get_index(i)
		var sim := Sim.new()
		sim.configure(d, Sim.make_environment())
		if sim.precession_gain != Sim.PRECESSION_GAIN:
			wrong_default.append(d.id)
		var implied: float = d.i_zz / maxf(d.i_zz - d.i_xy, 1e-12)
		implied_min = minf(implied_min, implied)
		implied_max = maxf(implied_max, implied)
	worst_implied_spread = implied_max - implied_min
	t.check("every disc configures with the same PRECESSION_GAIN",
		wrong_default.is_empty(),
		"%d discs checked, gain = %.3f" % [lib.size(), Sim.PRECESSION_GAIN])
	t.note("if the gain had been folded into I_zz/(I_zz-I_xy) it would range "
		+ "%.4f..%.4f across the roster (%.2f%% spread) instead of being exactly %.1f"
		% [implied_min, implied_max, 100.0 * worst_implied_spread / implied_min,
			Sim.PRECESSION_GAIN])

	# And the gain must scale the attitude response linearly, on any disc.
	var scaled_ok := true
	var detail := ""
	for idx in [0, mini(6, lib.size() - 1), lib.size() - 1]:
		var d := lib.get_index(idx)
		var p := Sim.make_throw_params()
		p.speed_mps = 25.0
		p.spin_rps = 22.0
		p.launch_angle_rad = deg_to_rad(10.0)
		p.launch_height_m = 1.4
		var tilts: Array[float] = []
		for gain in [1.0, 2.0]:
			var sim := Sim.new()
			sim.precession_gain = float(gain)
			sim.configure(d, Sim.make_environment())
			sim.ground_height_m = -1.0e9
			sim.launch(p)
			for _i in 60:   # 0.25 s, short enough that the response is still linear
				sim.step(sim.substep_dt)
			var n: Vector3 = sim.get_state().orientation * Vector3(0.0, 1.0, 0.0)
			tilts.append(rad_to_deg(atan2(n.x, n.y)))
		var ratio: float = tilts[1] / tilts[0] if absf(tilts[0]) > 1e-9 else 0.0
		detail += "%s:%.3f " % [d.id, ratio]
		if absf(ratio - 2.0) > 0.02:
			scaled_ok = false
	t.check("doubling the gain doubles the early bank, on every disc tried",
		scaled_ok, "bank(gain 2)/bank(gain 1) = " + detail.strip_edges())

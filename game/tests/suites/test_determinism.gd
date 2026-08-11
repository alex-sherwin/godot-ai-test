extends RefCounted

## Determinism and state hygiene.
##
## The sim reuses preallocated buffers and caches, so the risk here is not
## randomness — there is none — but leakage between runs: a stale accumulator, a
## scratch array shared with the landing solver, `simulate_full` clobbering an
## interactive flight. Each of those shows up as "the same inputs gave a
## different answer", which is the one failure mode that makes a physics bug
## impossible to reproduce.

const DiscDef := preload("res://scripts/physics/disc_definition.gd")
const Library := preload("res://scripts/physics/disc_library.gd")
const Sim := preload("res://scripts/physics/disc_flight_sim.gd")
const Support := preload("res://tests/test_support.gd")


func run(t: Support, lib: Library) -> void:
	t.suite("determinism")
	_test_repeatable(t, lib)
	_test_fresh_instance_matches(t, lib)
	_test_simulate_full_does_not_disturb(t, lib)
	_test_relaunch_resets(t, lib)
	t.end_suite()


func _disc(lib: Library) -> DiscDef:
	for i in lib.size():
		var d := lib.get_index(i)
		if d.speed >= 9.0:
			return d
	return lib.get_index(0)


func _throw() -> Sim.ThrowParams:
	var p := Sim.make_throw_params()
	p.speed_mps = 27.0
	p.spin_rps = 25.0
	p.launch_angle_rad = deg_to_rad(12.0)
	p.hyzer_angle_rad = deg_to_rad(8.0)
	p.nose_angle_rad = deg_to_rad(2.0)
	p.launch_height_m = 1.4
	p.launch_heading_rad = deg_to_rad(15.0)
	return p


func _identical(a: PackedVector3Array, b: PackedVector3Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		# Bit-identical, not approximately equal.
		if a[i].x != b[i].x or a[i].y != b[i].y or a[i].z != b[i].z:
			return false
	return true


func _test_repeatable(t: Support, lib: Library) -> void:
	var sim := Sim.new()
	sim.configure(_disc(lib), Sim.make_environment())
	var runs: Array[Sim.FlightResult] = []
	for _i in 3:
		runs.append(sim.simulate_full(_throw()))
	var ok := true
	for i in range(1, runs.size()):
		if not _identical(runs[0].trajectory, runs[i].trajectory):
			ok = false
		if runs[0].distance_m != runs[i].distance_m:
			ok = false
		if runs[0].lateral_m != runs[i].lateral_m:
			ok = false
		if runs[0].flight_time_s != runs[i].flight_time_s:
			ok = false
	t.check("three runs on one sim instance are bit-identical", ok,
		"%d trajectory points, dist %.9f m" % [runs[0].trajectory.size(), runs[0].distance_m])


func _test_fresh_instance_matches(t: Support, lib: Library) -> void:
	var a := Sim.new()
	a.configure(_disc(lib), Sim.make_environment())
	var ra := a.simulate_full(_throw())
	# A fresh instance, and one that has already flown something else.
	var b := Sim.new()
	b.configure(_disc(lib), Sim.make_environment())
	var junk := _throw()
	junk.speed_mps = 9.0
	junk.hyzer_angle_rad = deg_to_rad(-40.0)
	b.simulate_full(junk)
	var rb := b.simulate_full(_throw())
	t.check("a used instance gives the same answer as a fresh one",
		_identical(ra.trajectory, rb.trajectory) and ra.distance_m == rb.distance_m,
		"dist %.9f vs %.9f" % [ra.distance_m, rb.distance_m])


## `simulate_full` must be usable for an instant preview while an interactive
## flight is mid-air, without perturbing it by a single bit.
func _test_simulate_full_does_not_disturb(t: Support, lib: Library) -> void:
	var control := Sim.new()
	control.configure(_disc(lib), Sim.make_environment())
	control.launch(_throw())
	for _i in 40:
		control.step(1.0 / 60.0)
	var want := control.get_state()

	var sim := Sim.new()
	sim.configure(_disc(lib), Sim.make_environment())
	sim.launch(_throw())
	for _i in 40:
		sim.step(1.0 / 60.0)
		# Interleave a full preview simulation with a different throw.
		var other := _throw()
		other.speed_mps = 18.0
		other.spin_rps = -12.0
		sim.simulate_full(other)
	var got := sim.get_state()

	t.check("simulate_full leaves the interactive state untouched",
		got.position == want.position and got.velocity == want.velocity
			and got.spin == want.spin and got.time == want.time,
		"pos delta %s m, t %.6f vs %.6f" % [Support.g(got.position.distance_to(want.position), 3),
			got.time, want.time])
	t.check("interleaved previews leave the trajectory untouched",
		_identical(sim.get_trajectory(), control.get_trajectory()),
		"%d vs %d points" % [sim.get_trajectory().size(), control.get_trajectory().size()])


func _test_relaunch_resets(t: Support, lib: Library) -> void:
	var sim := Sim.new()
	sim.configure(_disc(lib), Sim.make_environment())
	sim.launch(_throw())
	for _i in 30:
		sim.step(1.0 / 60.0)
	# Relaunching mid-flight must fully reset time, trajectory and accumulator.
	sim.launch(_throw())
	var s := sim.get_state()
	t.check("relaunch resets the clock", s.time == 0.0, "t = %.6f" % s.time)
	t.check("relaunch resets the trajectory", sim.get_trajectory().size() == 1,
		"%d points" % sim.get_trajectory().size())
	t.check("relaunch resets the flying flag", sim.is_flying())

	# And a flight started by relaunch must match one from a clean instance.
	var fresh := Sim.new()
	fresh.configure(_disc(lib), Sim.make_environment())
	fresh.launch(_throw())
	for _i in 120:
		sim.step(1.0 / 60.0)
		fresh.step(1.0 / 60.0)
	t.check("relaunched flight matches a clean one bit-for-bit",
		sim.get_state().position == fresh.get_state().position,
		"delta %s m" % Support.g(sim.get_state().position.distance_to(fresh.get_state().position), 3))

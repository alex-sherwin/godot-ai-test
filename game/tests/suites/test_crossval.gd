extends RefCounted

## Cross-validation against Track A's independent Python reference integrator.
##
## This is the highest-value test in the suite. Everything else checks that the
## GDScript is self-consistent; this checks that a completely separate
## implementation of the same physics — different language, different state
## vector (it integrates the normal directly, this integrates a quaternion),
## different author — lands the disc in the same place from the same table.
##
## Fixtures come from `python -m tools.aero.validate --dump`, which writes
## `tools/aero/validation/*.json`. They live outside res://, so they are read
## through the OS filesystem; that is fine because tests only ever run from
## source, never from an exported pack.
##
## TOLERANCE, and where it comes from. The two implementations are algebraically
## identical and both step RK4 at 1/240, so in exact arithmetic they agree to the
## last bit. Measured, they agree to about 1e-6 relative over a 113 m flight —
## roughly 0.1 mm — which is the level of Godot's single-precision Vector3 math
## against NumPy's doubles. The tolerances below sit ~100x above that, which is
## tight enough that a real model divergence cannot hide inside them.
##
## Worth recording, because it is the whole argument for having this test: an
## earlier revision of these two implementations disagreed by 0.6% (0.67 m over
## 111 m). That was NOT precision. The Python side was applying the empirical
## precession factor as `I_zz/(I_zz - I_xy)` while this side used a flat 2.0, and
## that ratio is 2.0074..2.0155 across the shipped roster — a 0.4-0.8%
## disc-dependent difference in precession gain, which is exactly the size of the
## trajectory gap it produced. Separating the gain from the inertia term on both
## sides (CONTRACT v3) collapsed the disagreement by four orders of magnitude.
## Two independent implementations are how that was found at all.

const DiscDef := preload("res://scripts/physics/disc_definition.gd")
const Library := preload("res://scripts/physics/disc_library.gd")
const Sim := preload("res://scripts/physics/disc_flight_sim.gd")
const Support := preload("res://tests/test_support.gd")

## Trajectory agreement, as a fraction of the distance flown.
const POS_REL_TOL := 1.0e-4
## Absolute floor so short flights are not held to an unreasonable absolute bound.
const POS_ABS_TOL := 0.01
## Disc normal is a unit vector; 2e-4 is ~0.011 degrees of attitude.
const NORMAL_TOL := 2.0e-4
const SPIN_REL_TOL := 1.0e-4

var _skipped_shapes := PackedStringArray()


func run(t: Support, lib: Library) -> void:
	t.suite("cross-validation vs the Python reference integrator")
	var dir_path := Support.repo_root().path_join("tools/aero/validation")
	if not DirAccess.dir_exists_absolute(dir_path):
		t.skip("cross-validation", "%s does not exist — run `python -m tools.aero.validate --dump`" % dir_path)
		t.end_suite()
		return
	var names := _fixture_names(dir_path)
	if names.is_empty():
		t.skip("cross-validation", "no throw fixtures in %s — run `python -m tools.aero.validate --dump`" % dir_path)
		t.end_suite()
		return
	if not lib.data_present():
		t.skip("cross-validation", "game/data is absent, so the fixtures reference discs we cannot load")
		t.end_suite()
		return

	var worst_rel: float = 0.0
	var worst_name := ""
	for name in names:
		var rel := _compare_one(t, lib, dir_path, name)
		if rel > worst_rel:
			worst_rel = rel
			worst_name = name
	t.note("worst relative trajectory disagreement across %d fixtures: %s (%s)" % [names.size(), Support.g(worst_rel, 3), worst_name])
	_compare_spin_sensitivity(t, lib, dir_path)
	_compare_hyzer_sweep(t, lib, dir_path)
	t.end_suite()


func _fixture_names(dir_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open(dir_path)
	if d == null:
		return out
	for f in d.get_files():
		if not f.ends_with(".json"):
			continue
		# Only per-throw fixtures belong in the row-by-row comparison. Track A also
		# dumps sweep summaries (spin_sensitivity, hyzer_sweep) and its own
		# shotshaper cross-check; those are handled separately or not at all, and
		# new ones must not break this loop.
		var probe: Variant = _read_json(dir_path.path_join(f))
		if not (probe is Dictionary):
			continue
		var pd: Dictionary = probe
		if not (pd.has("throw") and pd.has("samples")):
			_skipped_shapes.append(f)
			continue
		out.append(f)
	out.sort()
	return out


func _read_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	return JSON.parse_string(f.get_as_text())


func _vec(a: Variant) -> Vector3:
	var arr: Array = a
	return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))


## Returns the worst relative position disagreement for this fixture.
func _compare_one(t: Support, lib: Library, dir_path: String, file_name: String) -> float:
	var doc: Variant = _read_json(dir_path.path_join(file_name))
	if not (doc is Dictionary):
		t.check("%s parses" % file_name, false, "not a JSON object")
		return 0.0
	var d: Dictionary = doc
	var name := file_name.get_basename()
	var disc_id := String(d.get("disc", ""))
	var disc := lib.get_disc(disc_id)
	if disc == null:
		t.skip(name, "disc '%s' is not in the loaded roster" % disc_id)
		return 0.0

	var th: Dictionary = d.get("throw", {})
	var p := Sim.make_throw_params()
	p.speed_mps = float(th.get("speed_mps", 0.0))
	p.spin_rps = float(th.get("spin_rps", 0.0))
	p.nose_angle_rad = float(th.get("nose_angle_rad", 0.0))
	p.hyzer_angle_rad = float(th.get("hyzer_angle_rad", 0.0))
	p.launch_angle_rad = float(th.get("launch_angle_rad", 0.0))
	p.launch_height_m = float(th.get("launch_height_m", 1.4))
	p.launch_heading_rad = float(th.get("launch_heading_rad", 0.0))

	var envd: Dictionary = d.get("environment", {})
	var env := Sim.make_environment(float(envd.get("air_density", 1.225)),
		_vec(envd.get("wind", [0, 0, 0])), float(envd.get("gravity", 9.81)))

	var integ: Dictionary = d.get("integrator", {})
	var ref_dt := float(integ.get("dt", 1.0 / 240.0))

	var ref_samples: Array = d.get("samples", [])
	if ref_samples.size() < 2:
		t.check("%s has samples" % name, false)
		return 0.0
	# The reference samples every 6 substeps; match its grid so the comparison is
	# index-for-index and never has to interpolate.
	var ref_stride: float = float(ref_samples[1]["t"]) - float(ref_samples[0]["t"])

	var sim := Sim.new()
	sim.configure(disc, env)
	sim.substep_dt = ref_dt
	sim.sample_dt = ref_stride
	var r := sim.simulate_full(p)

	var n_cmp: int = mini(r.samples.size(), ref_samples.size()) - 1  # last row handled apart
	var worst_pos: float = 0.0
	var worst_norm: float = 0.0
	var worst_spin: float = 0.0
	var worst_alpha: float = 0.0
	var worst_t: float = 0.0
	var worst_at: float = 0.0
	for i in n_cmp:
		var a: Dictionary = r.samples[i]
		var b: Dictionary = ref_samples[i]
		var dt_err: float = absf(float(a["t"]) - float(b["t"]))
		worst_t = maxf(worst_t, dt_err)
		var dp: float = (a["pos"] as Vector3).distance_to(_vec(b["pos"]))
		if dp > worst_pos:
			worst_pos = dp
			worst_at = float(a["t"])
		worst_norm = maxf(worst_norm, (a["normal"] as Vector3).distance_to(_vec(b["normal"])))
		worst_spin = maxf(worst_spin, absf(float(a["spin"]) - float(b["spin"])))
		worst_alpha = maxf(worst_alpha,
			absf(rad_to_deg(float(a["alpha"])) - float(b["alpha_deg"])))

	var scale: float = maxf(r.horizontal_distance_m, 1.0)
	var rel: float = worst_pos / scale
	var launch_spin: float = absf(p.spin_rps * TAU)

	t.check("%s: sample grids line up" % name, worst_t < 1e-4,
		"max |dt| = %s s over %d samples" % [Support.g(worst_t, 3), n_cmp])
	t.check("%s: trajectory agrees" % name,
		worst_pos <= maxf(POS_ABS_TOL, POS_REL_TOL * scale),
		"max |dpos| = %.4f m at t=%.2f s over %.1f m flown (%s relative)" % [worst_pos, worst_at, r.horizontal_distance_m, Support.g(rel, 3)])
	t.check("%s: disc attitude agrees" % name, worst_norm <= NORMAL_TOL,
		"max |dn| = %s" % Support.g(worst_norm, 3))
	t.check("%s: spin agrees" % name,
		worst_spin <= SPIN_REL_TOL * maxf(launch_spin, 1.0),
		"max |dspin| = %s rad/s of %.1f" % [Support.g(worst_spin, 3), launch_spin])
	t.check("%s: angle of attack agrees" % name, worst_alpha < 0.02,
		"max |dalpha| = %.4f deg" % worst_alpha)

	# Summary metrics. The reference's `distance_m` is the horizontal distance
	# from the origin, which is our `horizontal_distance_m`.
	var res: Dictionary = d.get("result", {})
	t.close("%s: distance" % name, r.horizontal_distance_m,
		float(res.get("distance_m", 0.0)), maxf(0.02, 3.0e-4 * scale), " m")
	# Lateral gets the same absolute budget as distance rather than one scaled to
	# its own value: on an S-curve drive the landing lateral is the small residual
	# of a +-10 m swing, so a 0.5% error in the swing is a large fraction of the
	# residual. Judging it against its own magnitude would be demanding
	# better-than-double agreement out of float32 arithmetic.
	t.close("%s: lateral" % name, r.lateral_m, float(res.get("lateral_m", 0.0)),
		maxf(0.02, 3.0e-4 * scale), " m")
	t.close("%s: max height" % name, r.max_height_m,
		float(res.get("max_height_m", 0.0)), maxf(0.02, 3.0e-4 * scale), " m")
	t.close("%s: flight time" % name, r.flight_time_s,
		float(res.get("flight_time_s", 0.0)), 0.01, " s")
	t.close("%s: spin loss" % name, 1.0 - r.spin_retained,
		float(res.get("spin_loss_frac", 0.0)), 5.0e-4)
	return rel


## The reference also dumps a spin sweep. Reproducing its ORDERING is the real
## content — it is the CONTRACT §5 "more spin means less response" claim
## measured the same way in both implementations.
func _compare_spin_sensitivity(t: Support, lib: Library, dir_path: String) -> void:
	var path := dir_path.path_join("spin_sensitivity.json")
	if not FileAccess.file_exists(path):
		t.skip("spin sensitivity fixture", "not dumped")
		return
	var doc: Variant = _read_json(path)
	if not (doc is Dictionary):
		t.check("spin_sensitivity.json parses", false)
		return
	var d: Dictionary = doc
	var disc := lib.get_disc(String(d.get("disc", "")))
	if disc == null:
		t.skip("spin sensitivity fixture", "disc not in roster")
		return
	var speed := float(d.get("speed_mps", 27.0))
	var launch_deg := float(d.get("launch_angle_deg", 12.0))
	var rows: Array = d.get("rows", [])

	var sim := Sim.new()
	sim.configure(disc, Sim.make_environment())
	# The reference samples every 6 substeps. Match that: `tilt at t = 1 s` is read
	# off the first sample at or after 1 s, and at ~40 deg/s of bank rate a
	# half-sample offset is most of a degree of spurious disagreement.
	sim.sample_dt = 6.0 / 240.0
	var worst_tilt: float = 0.0
	var worst_tilt_rel: float = 0.0
	var worst_dist: float = 0.0
	for row in rows:
		var rr: Dictionary = row
		var p := Sim.make_throw_params()
		p.speed_mps = speed
		p.spin_rps = float(rr["spin_rps"])
		p.launch_angle_rad = deg_to_rad(launch_deg)
		p.launch_height_m = 1.4
		var res := sim.simulate_full(p)
		for probe in [[1.0, "tilt_at_1s_deg"], [2.0, "tilt_at_2s_deg"]]:
			var want: float = float(rr[probe[1]])
			var dtilt: float = absf(_tilt_at(res, float(probe[0])) - want)
			worst_tilt = maxf(worst_tilt, dtilt)
			worst_tilt_rel = maxf(worst_tilt_rel, dtilt / maxf(absf(want), 1.0))
		worst_dist = maxf(worst_dist,
			absf(res.horizontal_distance_m - float(rr["distance_m"])))
	# Judged relative to the tilt itself. These are bank angles up to 77 deg on
	# releases that turn all the way over, so an absolute degree budget would be
	# far stricter at the top of the sweep than at the bottom for no reason; the
	# float32 mechanism described at the top of this file is proportional.
	t.check("spin sweep tilt response matches the reference", worst_tilt_rel < 0.005,
		"max |dtilt| = %.4f deg (%.2f%% of the reference tilt) over %d spins"
			% [worst_tilt, 100.0 * worst_tilt_rel, rows.size()])
	t.check("spin sweep distances match the reference", worst_dist < 0.05,
		"max |ddist| = %.3f m" % worst_dist)


func _tilt_at(r: Sim.FlightResult, t_query: float) -> float:
	# The epsilon matters. Sample times are accumulated as repeated `t += 1/240`,
	# so the sample nominally at t = 1.0 can land at 0.99999999999. The reference
	# dump rounds its times to 5 dp, which snaps it to exactly 1.0; without the
	# epsilon this side would step past it and read the NEXT sample, 25 ms later.
	# At ~40 deg/s of bank rate that is a spurious degree of disagreement.
	for s in r.samples:
		if float(s["t"]) >= t_query - 1e-6:
			var n: Vector3 = s["normal"]
			return rad_to_deg(atan2(n.x, n.y))
	return NAN


## Track A also dumps a 24-release grid over launch and hyzer angle. It is the
## broadest cross-check available: the named throws all sit near nominal, whereas
## this sweep includes releases that turn over and roll, where two implementations
## have the most room to diverge.
func _compare_hyzer_sweep(t: Support, lib: Library, dir_path: String) -> void:
	var path := dir_path.path_join("hyzer_sweep.json")
	if not FileAccess.file_exists(path):
		t.skip("hyzer sweep fixture", "not dumped")
		return
	var doc: Variant = _read_json(path)
	if not (doc is Dictionary):
		t.check("hyzer_sweep.json parses", false)
		return
	var d: Dictionary = doc
	var disc := lib.get_disc(String(d.get("disc", "")))
	if disc == null:
		t.skip("hyzer sweep fixture", "disc not in roster")
		return
	var speed := float(d.get("speed_mps", 27.0))
	var spin := float(d.get("spin_rps", 25.0))
	var rows: Array = d.get("rows", [])

	var sim := Sim.new()
	sim.configure(disc, Sim.make_environment())
	var worst_dist: float = 0.0
	var worst_lat: float = 0.0
	var worst_row := ""
	for row in rows:
		var rr: Dictionary = row
		var p := Sim.make_throw_params()
		p.speed_mps = speed
		p.spin_rps = spin
		p.launch_angle_rad = deg_to_rad(float(rr["launch_deg"]))
		p.hyzer_angle_rad = deg_to_rad(float(rr["hyzer_deg"]))
		p.launch_height_m = 1.4
		var res := sim.simulate_full(p)
		var dd: float = absf(res.horizontal_distance_m - float(rr["distance_m"]))
		var dl: float = absf(res.lateral_m - float(rr["lateral_m"]))
		if dd > worst_dist:
			worst_dist = dd
			worst_row = "launch %.0f / hyzer %.0f deg" % [float(rr["launch_deg"]),
				float(rr["hyzer_deg"])]
		worst_lat = maxf(worst_lat, dl)
	# The fixture rounds to 0.1 m, so ~0.05 m of the budget is quantisation.
	t.check("hyzer sweep distances match the reference", worst_dist < 0.12,
		"max |ddist| = %.3f m over %d releases (worst at %s)" % [worst_dist,
			rows.size(), worst_row])
	t.check("hyzer sweep laterals match the reference", worst_lat < 0.12,
		"max |dlat| = %.3f m" % worst_lat)

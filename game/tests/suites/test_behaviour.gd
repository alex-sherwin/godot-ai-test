extends RefCounted

## CONTRACT §5 — the behaviour the model must reproduce.
##
## Two kinds of assertion live here and they are deliberately treated
## differently:
##
##   * QUALITATIVE / SIGN behaviours (turn before fade, RHFH mirroring, more spin
##     means less response, an understable disc turning over) are properties of
##     the INTEGRATOR and the sign conventions. They are hard failures.
##
##   * ABSOLUTE DISTANCES are properties of the coefficient DATA. Where the
##     shipped data and the §5 target disagree, this suite reports the number and
##     the disagreement rather than failing — failing would only create pressure
##     to tune coefficients until a fixture goes green, which is exactly how you
##     end up with a model that is right for the wrong reasons. The real check
##     that the integrator is correct is the cross-validation suite.

const DiscDef := preload("res://scripts/physics/disc_definition.gd")
const Library := preload("res://scripts/physics/disc_library.gd")
const Sim := preload("res://scripts/physics/disc_flight_sim.gd")
const Support := preload("res://tests/test_support.gd")
const Atmo := preload("res://scripts/physics/atmosphere.gd")
const AeroTable := preload("res://scripts/physics/aero_table.gd")


func run(t: Support, lib: Library) -> void:
	t.suite("CONTRACT §5 behaviour")
	_test_cm_sign_flip(t, lib)
	_test_driver(t, lib)
	_test_putter(t, lib)
	_test_spin_reduces_response(t, lib)
	_test_understable_turns_over(t, lib)
	_test_rhfh_mirrors(t, lib)
	_test_spin_loss(t, lib)
	_test_hyzer_sign(t, lib)
	_test_air_density(t, lib)
	t.end_suite()


## Pick a disc by flight numbers so the suite works on Track A's roster and on
## the built-in fallback alike.
func _pick(lib: Library, want_speed: float, want_turn: float, want_fade: float) -> DiscDef:
	var best: DiscDef = null
	var best_cost: float = INF
	for i in lib.size():
		var d := lib.get_index(i)
		var cost: float = (absf(d.speed - want_speed) * 1.0
			+ absf(d.turn - want_turn) * 3.0 + absf(d.fade - want_fade) * 3.0)
		if cost < best_cost:
			best_cost = cost
			best = d
	return best


func _driver(lib: Library) -> DiscDef:
	return _pick(lib, 12.0, -1.0, 3.0)


func _putter(lib: Library) -> DiscDef:
	return _pick(lib, 2.0, 0.0, 1.0)


func _understable(lib: Library) -> DiscDef:
	return _pick(lib, 9.0, -4.0, 1.0)


## The sign flip in CM(alpha) is the whole mechanism (CONTRACT §5): centre of
## pressure aft at low alpha -> CM < 0 -> right bank -> turn; forward at high
## alpha -> CM > 0 -> left bank -> fade.
func _test_cm_sign_flip(t: Support, lib: Library) -> void:
	var d := _driver(lib)
	var cm0: float = float(d.aero.sample(0.0)["cm"])
	var cm10: float = float(d.aero.sample(deg_to_rad(10.0))["cm"])
	t.check("driver CM(0) < 0 (turn)", cm0 < 0.0, "%s CM(0)=%.5f" % [d.id, cm0])
	t.check("driver CM(10 deg) > 0 (fade)", cm10 > 0.0, "%s CM(10)=%.5f" % [d.id, cm10])


func _throw(speed: float, spin: float, launch_deg: float, hyzer_deg: float) -> Sim.ThrowParams:
	var p := Sim.make_throw_params()
	p.speed_mps = speed
	p.spin_rps = spin
	p.launch_angle_rad = deg_to_rad(launch_deg)
	p.hyzer_angle_rad = deg_to_rad(hyzer_deg)
	p.nose_angle_rad = 0.0
	p.launch_height_m = 1.4
	return p


func _final_bank(r: Sim.FlightResult) -> float:
	if r.samples.is_empty():
		return 0.0
	return float(r.samples[-1]["bank_deg"])


## "A 12/5/-1/3 distance driver at ~27 m/s, ~25 rev/s, small hyzer -> 105-130 m,
## visible early right turn then a left fade finish."
func _test_driver(t: Support, lib: Library) -> void:
	var d := _driver(lib)
	var sim := Sim.new()
	sim.configure(d, Sim.make_environment())
	# The canonical drive, identical to Track A's `destroyer_power_drive` fixture,
	# so the two implementations are being judged on the same throw.
	var r := sim.simulate_full(_throw(27.0, 25.0, 13.0, 22.0))

	var detail := "%s: dist=%.1f m lat=%+.1f maxR=%+.1f maxL=%+.1f h=%.1f t=%.2f bank_f=%+.0f deg" % [
		d.id, r.horizontal_distance_m, r.lateral_m, r.max_right_m, r.max_left_m,
		r.max_height_m, r.flight_time_s, _final_bank(r)]
	t.check("driver flight completes", r.landed and not r.failed, detail)
	# Qualitative: right first, then back left. Hard failures.
	t.check("driver turns visibly right early", r.max_right_m >= 3.0,
		"max right excursion %.1f m" % r.max_right_m)
	t.check("driver fades back left at the end",
		r.lateral_m < r.max_right_m - 2.0 and _final_bank(r) < -5.0,
		"landed %.1f m right of a %.1f m peak, final bank %+.0f deg" % [
			r.lateral_m, r.max_right_m, _final_bank(r)])
	# Quantitative: a property of the coefficient data.
	if r.horizontal_distance_m >= 105.0 and r.horizontal_distance_m <= 130.0:
		t.check("driver distance in the §5 window 105-130 m", true,
			"%.1f m" % r.horizontal_distance_m)
	else:
		t.note("driver distance %.1f m is outside the §5 window 105-130 m (disc '%s', "
			% [r.horizontal_distance_m, d.id]
			+ "provenance '%s') — a coefficient-data property, not an integrator one" % d.aero_provenance)


## CONTRACT v2 §5: "A 2/3/0/1 putter at ~18 m/s -> 40-60 m, nearly straight with
## a gentle fade." (v1 said 13 m/s, which is a putting speed rather than a putter
## drive; the target was corrected, not the model.)
func _test_putter(t: Support, lib: Library) -> void:
	var d := _putter(lib)
	var sim := Sim.new()
	sim.configure(d, Sim.make_environment())
	# Same throw as Track A's `aviar_drive` fixture.
	var r := sim.simulate_full(_throw(18.0, 14.0, 10.0, 0.0))

	t.check("putter flight completes", r.landed and not r.failed,
		"%s: dist=%.1f m lat=%+.1f t=%.2f" % [d.id, r.horizontal_distance_m,
			r.lateral_m, r.flight_time_s])
	t.check("putter is nearly straight",
		absf(r.lateral_m) < 0.25 * maxf(r.horizontal_distance_m, 1.0),
		"lateral %.2f m over %.1f m" % [r.lateral_m, r.horizontal_distance_m])
	t.check("putter's small drift is a fade (left, for RHBH)", r.lateral_m <= 0.0,
		"lateral %+.2f m" % r.lateral_m)
	t.between("putter distance at 18 m/s is in the §5 window 40-60 m",
		r.horizontal_distance_m, 40.0, 60.0, " m")
	# Speed sweep, so the gap above is a measured curve rather than an assertion.
	var row := ""
	for u in [13.0, 15.0, 17.0, 18.0, 20.0, 22.0]:
		var rr := sim.simulate_full(_throw(float(u), 0.78 * float(u), 10.0, 0.0))
		row += "%.0f m/s:%.0f m  " % [u, rr.horizontal_distance_m]
	t.note("putter speed sweep — " + row.strip_edges())


## CONTRACT §5: "Omega = tau / (I_zz * omega)", so more spin must mean a slower
## attitude response — less turn AND less fade — and it must fall out of the
## model, not be special-cased.
##
## Measured on the disc's TILT at fixed times, not on landing lateral. Landing
## lateral is not monotonic in spin and should not be: a faster-spinning disc
## also stays flatter, so it stays airborne longer, so the residual bank has more
## time to push it sideways. Asserting on lateral would fail a correct model.
func _test_spin_reduces_response(t: Support, lib: Library) -> void:
	var d := _driver(lib)
	var sim := Sim.new()
	sim.configure(d, Sim.make_environment())
	var spins := [15.0, 20.0, 25.0, 30.0, 35.0]
	var tilt1: Array[float] = []
	var tilt2: Array[float] = []
	var lateral: Array[float] = []
	for rps in spins:
		var r := sim.simulate_full(_throw(27.0, float(rps), 12.0, 0.0))
		tilt1.append(_tilt_at(r, 1.0))
		tilt2.append(_tilt_at(r, 2.0))
		lateral.append(r.lateral_m)
	var mono1 := true
	var mono2 := true
	for i in range(1, spins.size()):
		if not (tilt1[i] < tilt1[i - 1]):
			mono1 = false
		if not (tilt2[i] < tilt2[i - 1]):
			mono2 = false
	var d1 := ""
	var d2 := ""
	for i in spins.size():
		d1 += "%.0f:%.1f " % [spins[i], tilt1[i]]
		d2 += "%.0f:%.1f " % [spins[i], tilt2[i]]
	t.check("more spin -> less tilt response at t=1 s", mono1, "deg " + d1.strip_edges())
	t.check("more spin -> less tilt response at t=2 s", mono2, "deg " + d2.strip_edges())
	var dl := ""
	for i in spins.size():
		dl += "%.0f:%+.1f " % [spins[i], lateral[i]]
	t.note("landing lateral vs spin (NOT expected to be monotonic) — m " + dl.strip_edges())


## Signed tilt of the disc normal away from vertical, positive = tilted right
## (anhyzer / turning). This is the direct precession response.
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


## "An understable disc (turn -4) thrown flat and fast should turn over and may roll."
func _test_understable_turns_over(t: Support, lib: Library) -> void:
	var d := _understable(lib)
	var sim := Sim.new()
	sim.configure(d, Sim.make_environment())
	# Same throw as Track A's `roadrunner_flat_fast` fixture.
	var r := sim.simulate_full(_throw(27.0, 24.0, 10.0, 0.0))
	t.check("understable disc turns over to the right",
		r.lateral_m > 5.0 and _final_bank(r) > 0.0,
		"%s: lat=%+.1f m maxR=%+.1f final bank %+.0f deg" % [d.id, r.lateral_m,
			r.max_right_m, _final_bank(r)])

	# The stability ordering itself, isolated from every other way two discs
	# differ. Same disc, same throw, same everything — only CM(alpha) is shifted
	# by a constant. A more negative CM must finish further right, monotonically.
	# Comparing two different roster discs would not test this: they also differ
	# in mass, area, inertia and CL/CD, so a failure would not localise.
	var base := _driver(lib)
	var tilts: Array[float] = []
	var laterals: Array[float] = []
	var offsets := [-0.02, -0.01, 0.0, 0.01, 0.02]
	for off in offsets:
		var variant := _with_cm_offset(base, float(off))
		var s2 := Sim.new()
		s2.configure(variant, Sim.make_environment())
		var rr := s2.simulate_full(_throw(25.0, 22.0, 10.0, 0.0))
		tilts.append(_tilt_at(rr, 1.5))
		laterals.append(rr.lateral_m)
	# Measured on the BANK at a fixed time. Landing lateral is not monotonic in
	# stability and should not be: a very understable disc turns over, rolls and
	# lands early, so it can travel less far right in total while banking further
	# right the whole way. Bank at a fixed time is the precession response itself.
	var mono := true
	for i in range(1, offsets.size()):
		if not (tilts[i] < tilts[i - 1]):
			mono = false
	var detail := ""
	var detail2 := ""
	for i in offsets.size():
		detail += "%+.2f:%+.1f " % [offsets[i], tilts[i]]
		detail2 += "%+.2f:%+.1f " % [offsets[i], laterals[i]]
	t.check("a more negative CM banks further right, monotonically", mono,
		"CM offset -> bank at t=1.5 s (deg): " + detail.strip_edges())
	t.note("CM offset -> landing lateral (m, NOT monotonic: the understable ones "
		+ "roll and land early): " + detail2.strip_edges())


## Copy of a disc with its whole CM curve shifted by a constant.
func _with_cm_offset(src: DiscDef, offset: float) -> DiscDef:
	var tab := AeroTable.new()
	tab.alpha_rad = src.aero.alpha_rad.duplicate()
	tab.cl = src.aero.cl.duplicate()
	tab.cd = src.aero.cd.duplicate()
	tab.cm = src.aero.cm.duplicate()
	for i in tab.cm.size():
		tab.cm[i] += offset
	tab.c_mq = src.aero.c_mq
	tab.c_rp = src.aero.c_rp
	tab.c_nr = src.aero.c_nr
	tab.finalize()
	var d := DiscDef.new()
	d.id = src.id + "_cm%+0.3f" % offset
	d.mass_kg = src.mass_kg
	d.diameter_m = src.diameter_m
	d.area_m2 = src.area_m2
	d.i_zz = src.i_zz
	d.i_xy = src.i_xy
	d.aero = tab
	return d


## "RHFH (negative spin) must curve the opposite way with no other change."
func _test_rhfh_mirrors(t: Support, lib: Library) -> void:
	var d := _driver(lib)
	var sim := Sim.new()
	sim.configure(d, Sim.make_environment())
	var bh := sim.simulate_full(_throw(27.0, 25.0, 13.0, 22.0))
	var fh := sim.simulate_full(_throw(27.0, -25.0, 13.0, -22.0))
	t.close("RHFH distance matches RHBH", fh.horizontal_distance_m,
		bh.horizontal_distance_m, 1e-4, " m")
	t.close("RHFH lateral is the exact mirror of RHBH", fh.lateral_m, -bh.lateral_m,
		1e-4, " m")
	t.close("RHFH height matches RHBH", fh.max_height_m, bh.max_height_m, 1e-4, " m")
	t.close("RHFH final bank is the exact mirror", _final_bank(fh), -_final_bank(bh),
		1e-3, " deg")


## Spin acts as a gain, not a driver: it should only drop 10-20% over a flight
## (CONTRACT §5). A wildly different number almost always means the spin-down
## moment has been assembled in a different form than the one the table's c_nr
## was calibrated against — a mistake worth ~2 orders of magnitude.
func _test_spin_loss(t: Support, lib: Library) -> void:
	var d := _driver(lib)
	var sim := Sim.new()
	sim.configure(d, Sim.make_environment())
	var r := sim.simulate_full(_throw(27.0, 25.0, 13.0, 22.0))
	var loss: float = 1.0 - r.spin_retained
	t.between("spin loss over a drive is 3-30%", loss * 100.0, 3.0, 30.0, " %")


## Positive hyzer must bend a RHBH throw LEFT relative to the same throw flat.
## This is the sign the CONTRACT §4 parenthetical gets backwards; both this
## implementation and the Python reference follow §5 instead.
func _test_hyzer_sign(t: Support, lib: Library) -> void:
	var d := _driver(lib)
	var sim := Sim.new()
	sim.configure(d, Sim.make_environment())
	var flat := sim.simulate_full(_throw(27.0, 25.0, 13.0, 0.0))
	var hyzer := sim.simulate_full(_throw(27.0, 25.0, 13.0, 20.0))
	var anhyzer := sim.simulate_full(_throw(27.0, 25.0, 13.0, -20.0))
	# Compared at a fixed time rather than at landing. Landing lateral is not
	# monotonic in release angle: a hard anhyzer turns over, rolls and lands early,
	# so it can end up LESS far right than a flat release despite banking further
	# right the whole way. Position at t = 1 s measures the bank, which is what
	# the hyzer sign actually controls.
	var t_probe := 1.0
	var lat_flat := _lateral_at(flat, t_probe)
	var lat_hyzer := _lateral_at(hyzer, t_probe)
	var lat_anhyzer := _lateral_at(anhyzer, t_probe)
	t.check("positive hyzer pushes left of flat", lat_hyzer < lat_flat,
		"at t=1 s: hyzer %+.2f m vs flat %+.2f m" % [lat_hyzer, lat_flat])
	t.check("negative hyzer (anhyzer) pushes right of flat", lat_anhyzer > lat_flat,
		"at t=1 s: anhyzer %+.2f m vs flat %+.2f m" % [lat_anhyzer, lat_flat])
	t.note("hyzer at landing (NOT monotonic — a hard anhyzer rolls and lands early): "
		+ "hyzer %+.1f, flat %+.1f, anhyzer %+.1f m" % [hyzer.lateral_m,
			flat.lateral_m, anhyzer.lateral_m])


func _lateral_at(r: Sim.FlightResult, t_query: float) -> float:
	for s in r.samples:
		if float(s["t"]) >= t_query - 1e-6:
			return (s["pos"] as Vector3).x
	return (r.samples[-1]["pos"] as Vector3).x if not r.samples.is_empty() else 0.0


## CONTRACT §6. Thinner air -> less lift and less drag; the classic altitude
## effect is a longer, flatter flight with less fade.
func _test_air_density(t: Support, lib: Library) -> void:
	var d := _driver(lib)
	var sim := Sim.new()
	var rho_sea := Atmo.air_density(0.0, 15.0)
	var rho_alt := Atmo.air_density(1600.0, 15.0)
	t.close("ISA sea level 15 C gives 1.225 kg/m^3", rho_sea, 1.225, 0.002, " kg/m^3")
	t.check("1600 m is thinner than sea level", rho_alt < rho_sea,
		"%.4f vs %.4f kg/m^3" % [rho_alt, rho_sea])

	sim.configure(d, Sim.make_environment(rho_sea))
	var sea := sim.simulate_full(_throw(27.0, 25.0, 13.0, 22.0))
	sim.configure(d, Sim.make_environment(rho_alt))
	var alt := sim.simulate_full(_throw(27.0, 25.0, 13.0, 22.0))
	# Every aerodynamic moment scales with rho, and the precession rate scales
	# with the moment, so thinner air must mean less attitude change per unit
	# time. Compared at a fixed time; landing lateral also folds in the longer
	# flight thin air produces, and is not monotonic in rho.
	var tilt_sea: float = absf(_tilt_at(sea, 1.5))
	var tilt_alt: float = absf(_tilt_at(alt, 1.5))
	t.check("thinner air slows the attitude response", tilt_alt < tilt_sea,
		"bank at t=1.5 s: %.2f deg at 1600 m vs %.2f deg at sea level" % [
			tilt_alt, tilt_sea])
	t.note("air density: sea level %.1f m / lat %+.1f vs 1600 m %.1f m / lat %+.1f" % [
		sea.horizontal_distance_m, sea.lateral_m, alt.horizontal_distance_m,
		alt.lateral_m])

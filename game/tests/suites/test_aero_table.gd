extends RefCounted

## Coefficient table: interpolation, clamping, grid validation, and a schema
## check on whatever Track A has actually shipped.

const AeroTable := preload("res://scripts/physics/aero_table.gd")
const DiscDef := preload("res://scripts/physics/disc_definition.gd")
const Library := preload("res://scripts/physics/disc_library.gd")
const Support := preload("res://tests/test_support.gd")


func run(t: Support, lib: Library) -> void:
	t.suite("aero table")
	_test_interpolation(t)
	_test_clamping(t)
	_test_nonuniform(t)
	_test_degenerate_grid(t)
	_test_shipped_tables(t, lib)
	t.end_suite()


func _make_linear_table(n: int, a0_deg: float, step_deg: float) -> AeroTable:
	var tab := AeroTable.new()
	tab.alpha_rad.resize(n)
	tab.cl.resize(n)
	tab.cd.resize(n)
	tab.cm.resize(n)
	for i in n:
		var a_deg: float = a0_deg + step_deg * float(i)
		tab.alpha_rad[i] = deg_to_rad(a_deg)
		# Linear in alpha, so linear interpolation must be exact everywhere.
		tab.cl[i] = 2.0 * a_deg + 1.0
		tab.cd[i] = -3.0 * a_deg + 7.0
		tab.cm[i] = 0.5 * a_deg - 2.0
	tab.finalize()
	return tab


func _test_interpolation(t: Support) -> void:
	var tab := _make_linear_table(361, -90.0, 0.5)
	t.check("uniform grid detected", tab.is_uniform())
	t.check("grid accepted", tab.is_grid_ok())
	var worst: float = 0.0
	# Sample off-node, including exactly between nodes where a broken index would
	# be most visible.
	for i in range(0, 3600):
		var a_deg: float = -89.5 + 0.049 * float(i)
		if a_deg > 89.5:
			break
		var s := tab.sample(deg_to_rad(a_deg))
		worst = maxf(worst, absf(float(s["cl"]) - (2.0 * a_deg + 1.0)))
		worst = maxf(worst, absf(float(s["cd"]) - (-3.0 * a_deg + 7.0)))
		worst = maxf(worst, absf(float(s["cm"]) - (0.5 * a_deg - 2.0)))
	t.check("linear data reproduced exactly", worst < 1e-9, "max err %s" % Support.g(worst, 3))


func _test_clamping(t: Support) -> void:
	var tab := _make_linear_table(181, -45.0, 0.5)
	var lo := tab.sample(deg_to_rad(-1000.0))
	var hi := tab.sample(deg_to_rad(1000.0))
	# CONTRACT §3: clamp, never extrapolate.
	t.close("clamps below range", float(lo["cl"]), 2.0 * -45.0 + 1.0, 1e-9)
	t.close("clamps above range", float(hi["cl"]), 2.0 * 45.0 + 1.0, 1e-9)
	t.close("clamps exactly at the edge", float(tab.sample(tab.alpha_min())["cm"]),
		0.5 * -45.0 - 2.0, 1e-9)


func _test_nonuniform(t: Support) -> void:
	# A non-uniform but ascending grid must still work, via binary search.
	var tab := AeroTable.new()
	var angles := [-90.0, -40.0, -12.0, -3.0, 0.0, 4.0, 11.0, 30.0, 90.0]
	var n: int = angles.size()
	tab.alpha_rad.resize(n)
	tab.cl.resize(n)
	tab.cd.resize(n)
	tab.cm.resize(n)
	for i in n:
		tab.alpha_rad[i] = deg_to_rad(float(angles[i]))
		tab.cl[i] = 2.0 * float(angles[i])
		tab.cd[i] = 1.0
		tab.cm[i] = 0.0
	tab.finalize()
	t.check("non-uniform grid flagged", not tab.is_uniform() and tab.is_grid_ok())
	var worst: float = 0.0
	for i in range(0, 500):
		var a_deg: float = -89.0 + 0.35 * float(i)
		if a_deg > 89.0:
			break
		worst = maxf(worst, absf(float(tab.sample(deg_to_rad(a_deg))["cl"]) - 2.0 * a_deg))
	t.check("binary-search path interpolates correctly", worst < 1e-9,
		"max err %s" % Support.g(worst, 3))
	# Repeated non-monotone queries must not confuse the locality cache.
	var probe := [80.0, -80.0, 5.0, -5.0, 60.0, -60.0, 0.5]
	worst = 0.0
	for a_deg in probe:
		worst = maxf(worst, absf(float(tab.sample(deg_to_rad(float(a_deg)))["cl"]) - 2.0 * float(a_deg)))
	t.check("locality cache survives random access", worst < 1e-9, "max err %s" % Support.g(worst, 3))


func _test_degenerate_grid(t: Support) -> void:
	# An all-zero alpha grid is the classic "forgot to fill the array" bug. It
	# must be rejected, not silently clamp every lookup to the last row.
	var tab := AeroTable.new()
	tab.alpha_rad.resize(8)
	tab.cl.resize(8)
	tab.cd.resize(8)
	tab.cm.resize(8)
	tab.finalize()
	t.check("degenerate grid rejected", not tab.is_grid_ok())
	var disc := DiscDef.builtin("reference_driver")
	disc.aero = tab
	t.check("disc with a bad table is invalid", not disc.is_valid())


func _test_shipped_tables(t: Support, lib: Library) -> void:
	if not lib.data_present():
		t.skip("shipped tables", "game/data not present; running on the built-in fallback")
		return
	var bad_grid := 0
	var bad_uniform := 0
	var non_finite := 0
	var wrong_range := 0
	var no_sign_flip := 0
	for i in lib.size():
		var d := lib.get_index(i)
		var tab := d.aero
		if not tab.is_grid_ok():
			bad_grid += 1
		if not tab.is_uniform():
			bad_uniform += 1
		if absf(rad_to_deg(tab.alpha_min())) < 45.0 or absf(rad_to_deg(tab.alpha_max())) < 45.0:
			wrong_range += 1
		for k in tab.size():
			if not (is_finite(tab.cl[k]) and is_finite(tab.cd[k]) and is_finite(tab.cm[k])):
				non_finite += 1
				break
		# CONTRACT §5: the turn/fade sign flip lives in CM(alpha). Every disc in
		# the roster must have CM < 0 at low alpha and CM > 0 at high alpha,
		# otherwise it cannot turn and fade at all.
		var cm_lo: float = float(tab.sample(0.0)["cm"])
		var cm_hi: float = float(tab.sample(deg_to_rad(10.0))["cm"])
		if not (cm_lo < 0.0 and cm_hi > 0.0):
			no_sign_flip += 1
			t.note("%s: CM(0)=%.5f CM(10deg)=%.5f — no turn/fade sign flip" % [d.id, cm_lo, cm_hi])
	t.check("all shipped grids valid", bad_grid == 0, "%d bad" % bad_grid)
	t.check("all shipped grids uniform (fast path)", bad_uniform == 0, "%d non-uniform" % bad_uniform)
	t.check("all shipped coefficients finite", non_finite == 0, "%d bad discs" % non_finite)
	t.check("all shipped grids span at least +-45 deg", wrong_range == 0, "%d too narrow" % wrong_range)
	t.check("every disc has a CM sign flip", no_sign_flip == 0,
		"%d of %d discs without one" % [no_sign_flip, lib.size()])
	# Inertia sanity: I_xy ~= I_zz/2 for a near-planar body (CONTRACT §2).
	var worst_ratio: float = 0.0
	for i in lib.size():
		var d := lib.get_index(i)
		worst_ratio = maxf(worst_ratio, absf(d.i_xy / d.i_zz - 0.5))
	t.check("I_xy/I_zz ~= 0.5 across the roster", worst_ratio < 0.06,
		"max deviation %.4f" % worst_ratio)

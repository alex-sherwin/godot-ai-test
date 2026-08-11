extends RefCounted

## Cross-check of the two GDScript geometry implementations against Track A's
## offline Python pipeline, over every disc in the shipped roster.
##
## There are three independent implementations of the CONTRACT §2 solid of
## revolution in this repo:
##
##   1. `tools/aero/geometry.py`         — Track A, numpy, 2001 radial stations.
##                                          Its output is what `discs.json` ships.
##   2. `scripts/ui/disc_geometry_calc.gd` — Track D's live designer readout,
##                                          401 stations, trapezoid rule.
##   3. `scripts/mesh/disc_mesh_builder.gd` — Track C's lathe, which integrates
##                                          the same solid by Green's theorem
##                                          over the traced contour.
##
## Two of them run on the user's screen and one produced the numbers the
## integrator uses. If they disagree, the disc being rendered is not the disc
## being simulated, and the designer's live numbers are decoration. This suite
## is the standing proof that they do not disagree — it was previously a
## one-off manual check whose figures went stale the moment Track A changed the
## nose-thickness inference.
##
## Preloaded, not referenced by `class_name`: this has to run under a bare
## `godot --headless --script` with no global class cache, exactly like the rest
## of the suite.

const Calc := preload("res://scripts/ui/disc_geometry_calc.gd")
const MeshBuilder := preload("res://scripts/mesh/disc_mesh_builder.gd")
const DISCS_JSON := "res://data/discs.json"

## Tolerances. These are agreement budgets between three different quadrature
## schemes on the same closed-form solid, not physical tolerances — anything
## above them means the *shapes* differ, not the arithmetic.
const TOL_REL := 0.005          ## 0.5% on the integrated moments
const TOL_SPEED_FIT := 1.6      ## rating points, rim-width fit residual
const TOL_PROFILE_M := 2.0e-5   ## 0.02 mm between the two cross-sections


func run(t: Object, _lib: Object) -> void:
	t.suite("geometry mirror (Track D / Track C vs Track A's shipped data)")
	var discs := _load_discs()
	if discs.is_empty():
		t.skip("roster", "%s missing or unparseable" % DISCS_JSON)
		t.end_suite()
		return

	_check_derived(t, discs)
	_check_lathe_inertia(t, discs)
	_check_density_band(t, discs)
	_check_speed_fit(t, discs)
	_check_profiles_agree(t, discs)
	t.end_suite()


func _load_discs() -> Array:
	if not FileAccess.file_exists(DISCS_JSON):
		return []
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(DISCS_JSON))
	if parsed is Dictionary and (parsed as Dictionary).has("discs"):
		parsed = (parsed as Dictionary)["discs"]
	return parsed if parsed is Array else []


# ---------------------------------------------------------------------------

## Track D's mirror vs the derived block Track A baked into `discs.json`.
func _check_derived(t: Object, discs: Array) -> void:
	# json key -> key in DiscGeometryCalc.derived()
	var fields := {
		"area_m2": "area_m2", "parting_ratio": "parting_ratio",
		"nose_ratio": "nose_ratio", "I_zz": "i_zz", "I_xy": "i_xy",
		"height_m": "height_m", "density_kg_m3": "density_kg_m3",
	}
	var worst := {}
	var worst_disc := {}
	for e: Dictionary in discs:
		var want: Dictionary = e.get("derived", {})
		if want.is_empty():
			continue
		var got: Dictionary = Calc.derived(e.get("geometry", {}))
		for jkey: String in fields:
			if not want.has(jkey):
				continue
			var a: float = float(want[jkey])
			var b: float = float(got[fields[jkey]])
			var rel: float = absf(b - a) / maxf(absf(a), 1e-12)
			if rel > float(worst.get(jkey, -1.0)):
				worst[jkey] = rel
				worst_disc[jkey] = str(e.get("id", "?"))
	for jkey: String in fields:
		if not worst.has(jkey):
			continue
		t.check("%s agrees with tools/aero over %d discs" % [jkey, discs.size()],
			float(worst[jkey]) <= TOL_REL,
			"worst %.4f%% (%s), budget %.2f%%" % [
				float(worst[jkey]) * 100.0, worst_disc[jkey], TOL_REL * 100.0])


## Track C's lathe, integrated by Green's theorem over the traced contour at
## the resolution `FlightApp.apply_geometry` actually uses (120 rows). This is
## the third implementation, and the one whose numbers replace `discs.json`'s
## the moment a designer slider moves — so if it disagreed, editing a disc would
## silently change the physics on top of changing the shape.
##
## It is exact on the polygon rather than a quadrature over a grid, so it is
## allowed a slightly wider budget than the two trapezoid implementations get
## against each other: the difference is Track A's own discretisation, not an
## error in this one.
func _check_lathe_inertia(t: Object, discs: Array) -> void:
	var worst := 0.0
	var worst_key := ""
	var worst_id := ""
	for e: Dictionary in discs:
		var r: Dictionary = MeshBuilder.verify_against(e, 1.0)
		for key: String in (r["errors"] as Dictionary):
			var err: float = float((r["errors"] as Dictionary)[key])
			if err > worst:
				worst = err
				worst_key = key
				worst_id = str(r["id"])
	t.check("mesh lathe mass properties agree with tools/aero over %d discs" % discs.size(),
		worst <= 0.01,
		"worst %.4f%% (%s / %s), budget 1.00%%" % [worst * 100.0, worst_id, worst_key])


## CONTRACT §7 / Track A's `PLASTIC_DENSITY_RANGE`. The UI checker and the
## offline pipeline must agree on what it will accept, or the designer flags
## discs the pipeline considers fine (or vice versa).
func _check_density_band(t: Object, discs: Array) -> void:
	var lo := 1e9
	var hi := -1e9
	var flagged: PackedStringArray = PackedStringArray()
	for e: Dictionary in discs:
		var d: Dictionary = Calc.derived(e.get("geometry", {}))
		var rho: float = float(d["density_kg_m3"])
		lo = minf(lo, rho)
		hi = maxf(hi, rho)
		for issue: Dictionary in Calc.check(e.get("geometry", {})):
			# `diameter_band` is expected on three shipped moulds: the Roc and
			# Buzzz are PDGA-published at 21.7 cm and the River at 21.5, above
			# the band a new design has to hit. Real certification figures, kept
			# unmodified — see tools/aero/roster.py.
			if str(issue.get("code", "")) == "diameter_band":
				continue
			flagged.append("%s: %s" % [str(e.get("id", "?")), str(issue["text"])])
	t.between("shipped densities inside PLASTIC_DENSITY_RANGE (min)", lo,
		Calc.PLASTIC_DENSITY_MIN, Calc.PLASTIC_DENSITY_MAX, " kg/m3")
	t.between("shipped densities inside PLASTIC_DENSITY_RANGE (max)", hi,
		Calc.PLASTIC_DENSITY_MIN, Calc.PLASTIC_DENSITY_MAX, " kg/m3")
	t.check("no shipped disc trips the designer's own checker", flagged.is_empty(),
		"" if flagged.is_empty() else str(flagged))


## `speed = 0.703 * rim_mm - 4.45` (CONTRACT §7: rim width and nothing else).
func _check_speed_fit(t: Object, discs: Array) -> void:
	var worst := 0.0
	var worst_id := ""
	var sum_sq := 0.0
	var n := 0
	for e: Dictionary in discs:
		var g: Dictionary = e.get("geometry", {})
		var fn: Dictionary = e.get("flight_numbers", {})
		if not fn.has("speed"):
			continue
		var predicted: float = Calc.speed_from_rim(float(g.get("rim_width_m", 0.0)))
		var residual: float = absf(predicted - float(fn["speed"]))
		sum_sq += residual * residual
		n += 1
		if residual > worst:
			worst = residual
			worst_id = str(e.get("id", "?"))
	t.check("rim-width speed fit residual within +-%.1f rating points" % TOL_SPEED_FIT,
		worst <= TOL_SPEED_FIT,
		"worst %.2f (%s), RMS %.2f over %d discs" % [worst, worst_id, sqrt(sum_sq / maxf(n, 1)), n])


## Item 4 from the integration list: the designer's "As rendered" overlay draws
## Track C's lathe profile on top of Track D's. They were built from different
## readings of `rim_thickness_m`; Track C has since ported Track A's
## `cross_section` outright, so the two curves must now be the same curve.
## Sampled as z_lo(r) / z_hi(r) because the two carry different point counts.
func _check_profiles_agree(t: Object, discs: Array) -> void:
	var worst := 0.0
	var worst_id := ""
	for e: Dictionary in discs:
		var g: Dictionary = e.get("geometry", {})
		var ui := Calc.outline(g, 241)
		var mesh := MeshBuilder.cross_section_polyline(g, 160)
		var d: float = _max_profile_gap(ui, mesh, float(g.get("diameter_m", 0.211)) * 0.5)
		if d > worst:
			worst = d
			worst_id = str(e.get("id", "?"))
	t.check("designer profile == rendered profile (\"As rendered\" overlay)",
		worst <= TOL_PROFILE_M,
		"worst %.4f mm (%s), budget %.4f mm" % [
			worst * 1000.0, worst_id, TOL_PROFILE_M * 1000.0])


## Largest vertical gap between two closed outlines, sampled on a common radial
## grid. Both are single closed loops in (r, z); the mesh one spans -R..R, so
## only its right half is used.
func _max_profile_gap(a: PackedVector2Array, b: PackedVector2Array, radius: float) -> float:
	var worst := 0.0
	# Stay inside the outer edge: at r = R the outline is a vertical face and
	# "the height at this radius" is a range, not a value.
	for i in range(1, 40):
		var r: float = radius * float(i) / 40.0
		var ea := _envelope(a, r)
		var eb := _envelope(b, r)
		if ea.x > 1e17 or eb.x > 1e17:
			continue
		worst = maxf(worst, maxf(absf(ea.x - eb.x), absf(ea.y - eb.y)))
	return worst


## (z_lo, z_hi) of a closed outline at radius r, by intersecting its edges with
## the vertical line at that radius. Returns a huge x if the line misses.
func _envelope(pts: PackedVector2Array, r: float) -> Vector2:
	var lo := 1e18
	var hi := -1e18
	var n := pts.size()
	for i in n:
		var p: Vector2 = pts[i]
		var q: Vector2 = pts[(i + 1) % n]
		var pr: float = absf(p.x)
		var qr: float = absf(q.x)
		if signf(p.x) * signf(q.x) < 0.0:
			continue  # spans the axis; not a meridional edge
		if minf(pr, qr) > r or maxf(pr, qr) < r:
			continue
		var f: float = 0.0 if is_equal_approx(qr, pr) else (r - pr) / (qr - pr)
		var z: float = p.y + (q.y - p.y) * clampf(f, 0.0, 1.0)
		lo = minf(lo, z)
		hi = maxf(hi, z)
	return Vector2(lo, hi) if hi > -1e17 else Vector2(1e18, 1e18)

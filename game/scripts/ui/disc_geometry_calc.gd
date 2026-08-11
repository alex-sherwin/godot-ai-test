class_name DiscGeometryCalc
extends RefCounted

## Derived quantities and legality checks for the CONTRACT §2 parameter set.
##
## This is a GDScript mirror of Track A's `tools/aero/geometry.py`: the same
## cross-section, the same mass integrals, the same convention that
## `parting_line_m` is measured from the *resting plane* (the disc sitting on
## its rim) rather than from the flight plate. Keeping the two in step is what
## lets the designer show live numbers without a round-trip through the offline
## pipeline — and any drift between them is a bug in one of the two.
##
## Everything here is SI. Degrees and millimetres live in the widgets, not here.

## Real flight plates run 1.5–2.0 mm. Not one of the eight parameters, so it is
## a constant here exactly as it is in Track A's module.
const PLATE_THICKNESS_M := 0.0018

## Radial stations for the quadrature. Track A uses 2001 for the baked data;
## 401 is plenty for a live readout (the difference on I_zz is < 1e-4 relative)
## and keeps a slider drag cheap.
const N_RADIAL := 401

const KEYS := [
	"diameter_m", "mass_kg", "rim_width_m", "rim_depth_m",
	"rim_thickness_m", "parting_line_m", "dome_height_m", "inner_rim_edge_m",
]

## PDGA technical standards for approved discs.
const PDGA_DIAMETER_MIN := 0.210
const PDGA_DIAMETER_MAX := 0.213
const PDGA_MASS_MAX := 0.200
const PDGA_RIM_WIDTH_MAX := 0.026
## Max weight is 8.3 g per cm of diameter, capped at 200 g — which is why a
## 21.1 cm mould tops out at 175.1 g and a 21.2 cm one at 176.0 g.
const PDGA_GRAMS_PER_CM := 8.3

enum Level { INFO, WARN, BAD }


static func has_all_keys(g: Dictionary) -> bool:
	for k in KEYS:
		if not g.has(k):
			return false
	return true


static func sanitize(g: Dictionary) -> Dictionary:
	## Fill any missing key from a mid-roster fairway driver so a partial
	## dictionary never produces NaN downstream.
	var out := {
		"diameter_m": 0.211, "mass_kg": 0.175, "rim_width_m": 0.017,
		"rim_depth_m": 0.011, "rim_thickness_m": 0.0055, "parting_line_m": 0.0045,
		"dome_height_m": 0.0022, "inner_rim_edge_m": 0.0885,
	}
	for k in KEYS:
		if g.has(k):
			var v: float = float(g[k])
			if is_finite(v):
				out[k] = v
	return out


# ------------------------------------------------------------ cross-section ---

## Meridional profile as a closed outline in (radius, height) metres: out along
## the top surface from the spin axis to the outer edge, then back along the
## underside. Track C's `DiscMeshBuilder` lathes the same curve; when it is
## available `DesignerPanel` asks it for the profile instead of using this, so
## the diagram is literally the mesh's own silhouette.
static func outline(g: Dictionary, n: int = 121) -> PackedVector2Array:
	var geo := sanitize(g)
	var r_outer: float = geo.diameter_m * 0.5
	var ri: float = clampf(geo.inner_rim_edge_m, 0.001, r_outer - 0.0005)
	var rim_height: float = geo.rim_depth_m + PLATE_THICKNESS_M
	var top_outer: float = geo.parting_line_m + 0.5 * geo.rim_thickness_m
	var bot_outer: float = geo.parting_line_m - 0.5 * geo.rim_thickness_m

	var top := PackedVector2Array()
	var bottom := PackedVector2Array()
	for i in range(n):
		var r: float = r_outer * float(i) / float(n - 1)
		var z_lo: float
		var z_hi: float
		if r < ri:
			var dome: float = geo.dome_height_m * (1.0 - pow(r / ri, 2.0))
			z_lo = geo.rim_depth_m
			z_hi = geo.rim_depth_m + PLATE_THICKNESS_M + dome
		else:
			var s: float = (r - ri) / maxf(r_outer - ri, 1e-9)
			z_hi = rim_height + (top_outer - rim_height) * s
			z_lo = maxf(bot_outer * s, 0.0)
		top.append(Vector2(r, z_hi))
		bottom.append(Vector2(r, z_lo))

	var out := PackedVector2Array()
	out.append_array(top)
	for i in range(bottom.size() - 1, -1, -1):
		out.append(bottom[i])
	return out


# ------------------------------------------------------------------ derived ---

## area_m2, parting_ratio, nose_ratio, I_zz, I_xy, height, implied density.
## The inertia integrals sweep the cross-section above as a solid of revolution
## with uniform density — a thin-rimmed putter and a wide-rimmed driver really
## do differ, so these are integrated rather than assumed.
static func derived(g: Dictionary) -> Dictionary:
	var geo := sanitize(g)
	var r_outer: float = geo.diameter_m * 0.5
	var ri: float = clampf(geo.inner_rim_edge_m, 0.001, r_outer - 0.0005)
	var rim_height: float = geo.rim_depth_m + PLATE_THICKNESS_M
	var top_outer: float = geo.parting_line_m + 0.5 * geo.rim_thickness_m
	var bot_outer: float = geo.parting_line_m - 0.5 * geo.rim_thickness_m

	var dr: float = r_outer / float(N_RADIAL - 1)
	var volume := 0.0
	var i_zz_v := 0.0
	var z_first := 0.0
	var z_second := 0.0

	var prev_dv := 0.0
	var prev_izz := 0.0
	var prev_z1 := 0.0
	var prev_z2 := 0.0
	for i in range(N_RADIAL):
		var r: float = dr * float(i)
		var z_lo: float
		var z_hi: float
		if r < ri:
			var dome: float = geo.dome_height_m * (1.0 - pow(r / ri, 2.0))
			z_lo = geo.rim_depth_m
			z_hi = geo.rim_depth_m + PLATE_THICKNESS_M + dome
		else:
			var s: float = (r - ri) / maxf(r_outer - ri, 1e-9)
			z_hi = rim_height + (top_outer - rim_height) * s
			z_lo = maxf(bot_outer * s, 0.0)
		var thickness: float = maxf(z_hi - z_lo, 0.0)
		var two_pi_r: float = TAU * r
		var dv: float = two_pi_r * thickness
		var izz: float = dv * r * r
		var z1: float = two_pi_r * 0.5 * (z_hi * z_hi - z_lo * z_lo)
		var z2: float = two_pi_r * (pow(z_hi, 3.0) - pow(z_lo, 3.0)) / 3.0
		if i > 0:
			volume += 0.5 * (dv + prev_dv) * dr
			i_zz_v += 0.5 * (izz + prev_izz) * dr
			z_first += 0.5 * (z1 + prev_z1) * dr
			z_second += 0.5 * (z2 + prev_z2) * dr
		prev_dv = dv
		prev_izz = izz
		prev_z1 = z1
		prev_z2 = z2

	var out := {
		"area_m2": PI * r_outer * r_outer,
		"parting_ratio": geo.parting_line_m / maxf(geo.rim_depth_m, 1e-9),
		"nose_ratio": geo.rim_thickness_m / maxf(geo.rim_depth_m, 1e-9),
		"height_m": geo.rim_depth_m + PLATE_THICKNESS_M + geo.dome_height_m,
		"volume_m3": volume,
		"valid": volume > 1e-9,
	}
	if volume <= 1e-9:
		out["i_zz"] = 0.0
		out["i_xy"] = 0.0
		out["density_kg_m3"] = 0.0
		out["com_z_m"] = 0.0
		return out

	var rho: float = geo.mass_kg / volume
	var i_zz: float = geo.mass_kg * i_zz_v / volume
	var z_cm: float = z_first / volume
	var axial: float = rho * z_second - geo.mass_kg * z_cm * z_cm
	out["i_zz"] = i_zz
	out["i_xy"] = 0.5 * i_zz + axial
	out["density_kg_m3"] = rho
	out["com_z_m"] = z_cm
	return out


# ---------------------------------------------------------- speed estimate ---

## Speed rating from rim width alone.
##
## Ordinary least squares over the 14 moulds in the shipped roster, using the
## PDGA-published rim thickness: `speed = 0.703 * rim_mm - 4.45`, R^2 = 0.95,
## residual spread about +-1 rating point. CONTRACT §7 quotes the same
## relationship at R^2 = 0.96 over 43 moulds — rim width, and nothing else,
## is what a speed rating measures.
##
## This is the ONLY flight number that can be read off the geometry directly.
## Turn and fade are set by CM(alpha), which reaches the geometry only through
## an n = 4 regression; the designer therefore shows those as model output, not
## as something computed here.
static func speed_from_rim(rim_width_m: float) -> float:
	return clampf(0.703 * (rim_width_m * 1000.0) - 4.45, 0.5, 16.0)


# ------------------------------------------------------------------ checks ---

## Returns [{level, text}] — PDGA legality first, then physical plausibility.
## Nothing here clamps: a design is allowed to be illegal, it is just told so.
static func check(g: Dictionary) -> Array:
	var geo := sanitize(g)
	var issues: Array = []
	var d: Dictionary = derived(geo)

	# --- PDGA technical standards -------------------------------------
	if geo.diameter_m < PDGA_DIAMETER_MIN - 1e-6 or geo.diameter_m > PDGA_DIAMETER_MAX + 1e-6:
		issues.append({
			"level": Level.WARN, "key": "diameter_m",
			"text": "Diameter %.1f cm is outside the PDGA-approved 21.0–21.3 cm band." % (geo.diameter_m * 100.0),
		})
	if geo.rim_width_m > PDGA_RIM_WIDTH_MAX + 1e-6:
		issues.append({
			"level": Level.WARN, "key": "rim_width_m",
			"text": "Rim width %.1f mm exceeds the PDGA maximum of 26 mm." % (geo.rim_width_m * 1000.0),
		})
	var max_mass_kg: float = minf(PDGA_MASS_MAX, PDGA_GRAMS_PER_CM * geo.diameter_m * 100.0 * 0.001)
	if geo.mass_kg > max_mass_kg + 1e-6:
		issues.append({
			"level": Level.WARN, "key": "mass_kg",
			"text": "Mass %.0f g is over the PDGA limit for this diameter (%.1f g — 8.3 g per cm of diameter, capped at 200 g)." % [
				geo.mass_kg * 1000.0, max_mass_kg * 1000.0],
		})

	# --- can this be a real solid? ------------------------------------
	if geo.parting_line_m >= geo.rim_depth_m:
		issues.append({
			"level": Level.BAD, "key": "parting_line_m",
			"text": "Parting line (%.1f mm) sits at or above the flight plate (%.1f mm). The widest point of a disc is inside the rim." % [
				geo.parting_line_m * 1000.0, geo.rim_depth_m * 1000.0],
		})
	if geo.rim_thickness_m > 2.0 * geo.parting_line_m + 1e-6:
		# The profile clamps the underside flat rather than inverting, so the
		# shape still draws — the parameter set is inconsistent, not fatal.
		issues.append({
			"level": Level.WARN, "key": "rim_thickness_m",
			"text": "A %.1f mm wing centred %.1f mm up would reach below the resting plane; the profile flattens it there instead." % [
				geo.rim_thickness_m * 1000.0, geo.parting_line_m * 1000.0],
		})
	var implied_inner: float = geo.diameter_m * 0.5 - geo.rim_width_m
	if absf(geo.inner_rim_edge_m - implied_inner) > 0.001:
		issues.append({
			"level": Level.BAD, "key": "inner_rim_edge_m",
			"text": "Inner rim edge should be radius − rim width = %.1f mm; it is %.1f mm." % [
				implied_inner * 1000.0, geo.inner_rim_edge_m * 1000.0],
		})

	# --- plausible as a manufactured object? --------------------------
	if bool(d.get("valid", false)):
		var rho: float = float(d["density_kg_m3"])
		if rho < 800.0 or rho > 1400.0:
			issues.append({
				"level": Level.WARN, "key": "mass_kg",
				"text": "Implied plastic density %.0f kg/m³ is outside the 800–1400 kg/m³ of real disc plastics — this shape and this mass do not belong to the same object." % rho,
			})
		var pr: float = float(d["parting_ratio"])
		if pr < 0.10 or pr > 0.95:
			issues.append({
				"level": Level.WARN, "key": "parting_line_m",
				"text": "Parting-line ratio %.2f is outside the 0.10–0.95 range seen on production moulds." % pr,
			})
	else:
		issues.append({
			"level": Level.BAD, "key": "",
			"text": "The cross-section encloses no volume — the disc has no material in it.",
		})
	return issues

class_name Provenance
extends RefCounted

## CONTRACT §7 in UI form.
##
## Four disc golf discs have genuinely measured aerodynamic coefficients. Every
## other disc in this simulator — and every disc a user designs — has
## coefficients constructed by mapping geometry and flight numbers onto those
## four. The whole point of this file is that the difference is never invisible.
##
## The vocabulary:
##   measured  — coefficients come from the Giljarhus et al. (2022) CFD dataset.
##   derived   — coefficients come from the n = 4 mapping. Plausible, not measured.
##   custom    — a user-designed shape. Always derived, and newly so.
##   fallback  — no coefficient data loaded at all; the panel is running on its
##               built-in placeholder roster.

const MEASURED := "measured"
const DERIVED := "derived"
const CUSTOM := "custom"
const FALLBACK := "fallback"

const CITATION := "Giljarhus, Kristiansen, Tutkun & Oggiano (2022), \"Aerodynamic characteristics of a golf disc\", Sports Engineering 25:24"


static func normalize(value: Variant) -> String:
	var s := str(value).strip_edges().to_lower()
	if s.begins_with(MEASURED):
		return MEASURED
	if s.begins_with(CUSTOM):
		return CUSTOM
	if s.contains(FALLBACK):
		return FALLBACK
	return DERIVED


static func short_label(kind: String) -> String:
	match kind:
		MEASURED: return "MEASURED"
		CUSTOM: return "CUSTOM · DERIVED"
		FALLBACK: return "NO DATA"
		_: return "DERIVED"


static func badge_variation(kind: String) -> String:
	return "BadgeMeasured" if kind == MEASURED else "BadgeDerived"


## One line, for a tooltip or a status strip.
static func one_liner(kind: String) -> String:
	match kind:
		MEASURED:
			return "Measured: coefficients are CFD on a 3D scan of this mould, from " + CITATION + "."
		CUSTOM:
			return "Custom design: coefficients are derived from your geometry through the same n = 4 mapping. Never measured."
		FALLBACK:
			return "No coefficient data is loaded — the panel is running on its built-in placeholder roster, which contains no aerodynamic tables."
		_:
			return "Derived: coefficients are inferred from geometry and flight numbers by a regression anchored on just 4 measured discs. Directionally right; not a measurement of this mould."


static func dot_color(kind: String) -> Color:
	match kind:
		MEASURED: return FlightLabTheme.OK_TEXT
		FALLBACK: return FlightLabTheme.WARN_TEXT
		_: return FlightLabTheme.TEXT_FAINT


## A compact badge for a roster row or the drawer header.
static func badge(kind: String) -> PanelContainer:
	return UiKit.badge(short_label(kind), badge_variation(kind), one_liner(kind))


## The long explanation. Deliberately blunt about how little n = 4 supports.
static func explanation() -> Array:
	return [
		["h", "Where the numbers come from"],
		["p", "This simulator flies a disc from aerodynamic coefficients — lift, drag and pitching moment as functions of angle of attack. For four discs those coefficients were measured. For everything else they are constructed."],

		["h2", "Measured — four discs"],
		["p", "Giljarhus, Kristiansen, Tutkun and Oggiano (2022), \"Aerodynamic characteristics of a golf disc\", Sports Engineering 25:24, ran CFD on 3D scans of four real disc golf discs and published the coefficient tables with the shotshaper library. Those four carry the MEASURED badge. One caveat even there: the fourth case (dd2) names no commercial mould upstream, so the disc it is paired with in this roster is an inference, not the paper's claim."],

		["h2", "Derived — everything else"],
		["p", "Every other disc's coefficients come from mapping its geometry and published flight numbers onto those four anchors. The fits the mapping rests on are:"],
		["code", "turn  ≈ 296.8 · CM(0°)  + 3.31     R² = 0.89, n = 4\nfade  ≈ 182.8 · CM(10°) − 4.22     R² = 0.91, n = 4"],
		["p", "Four points. That is enough to establish a direction and nowhere near enough to pin down a curve — an R² computed on four samples is barely constrained at all. Read a derived disc as \"plausibly in the right family\", not as a measurement of that mould. Two derived discs a rating point apart are not meaningfully distinguishable."],
		["p", "Glide is weaker still. The four measured discs are rated 5, 5, 5 and 3 for glide, so there is almost no variation to fit against; glide is effectively carried by the geometry model rather than by data."],

		["h2", "The exception: speed"],
		["p", "Speed rating tracks rim width, and nothing else, at R² = 0.96 across 43 moulds. That relationship is well determined and the designer computes it directly from your rim width."],

		["h2", "Custom designs"],
		["p", "A shape you invent has never been scanned or solved. Its coefficients are the same n = 4 mapping applied to your parameters, so a custom disc is always derived — and it is extrapolating further than a real mould does, because nothing anchors it to a disc anyone has thrown."],

		["h2", "What is exact"],
		["p", "Reference area, parting-line ratio, moments of inertia, implied plastic density and the cross-section itself follow from the eight geometry parameters by integration, with no fitting anywhere. Those are as accurate as the parameterisation is — which is a statement about the model, not about the data behind it."],

		["h2", "The precession gain is a fudge factor"],
		["p", "Turn and fade come from aerodynamic torque precessing a gyroscope. The kinematics of that are exact and the code proves them in CI: the precession rate is torque / (spin-axis inertia × spin rate). On top of that exact law the model applies a constant it did not derive:"],
		["code", "dn/dt = -PRECESSION_GAIN * M_perp / (I_zz * spin)\nPRECESSION_GAIN = 2.0    # empirical. The kinematics are 1.0."],
		["p", "At 1.0 — pure kinematics — flights are wrong in a consistent way: a distance driver hangs up for 9.4 s instead of 6, fade is about half of reality, and an understable disc never turns over. At 2.0 all four behavioural targets are met and the model reproduces the reference implementation's own example throw to 0.4%. So something real of about this size is missing, and the leading candidate is identified: the source CFD is steady-state on a NON-ROTATING disc, so it cannot contain any spin-dependent moment — in particular the spin-induced rolling moment, which is exactly a moment that would bank the disc. The 2.0 is a fudge factor with a plausible story, not a measurement."],

		["h2", "What this gets wrong: hyzer sensitivity"],
		["p", "Because that single gain doubles the whole precession response, it doubles the early turn as well as the late fade. Every disc in this roster rated turn −1 or lower therefore turns over and finishes right when released flat, including a 12-speed Destroyer, and needs 18–22° of hyzer to come back — far more than a real thrower uses. Discs rated turn 0 behave correctly from flat. The per-category release defaults compensate for this; they are not what a real thrower would use. It is a known defect, left visible rather than hidden."],

		["h2", "Damping is inert"],
		["p", "The pitch- and roll-damping coefficients are Hummel's 2003 fit to an Ultimate disc, used unchanged because no disc-golf measurement of either exists. Under this model's non-dimensionalisation they contribute about 0.1% of the static pitching moment, so they are effectively doing nothing. Spin-down was recalibrated and does matter."],
	]

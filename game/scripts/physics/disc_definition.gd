class_name DiscDefinition
extends RefCounted

# See the note in aero_table.gd: preloaded consts, not class_name identifiers,
# so the suite runs under a bare `godot --headless --script` with no import pass.
const AeroTable := preload("res://scripts/physics/aero_table.gd")
const DiscDef := preload("res://scripts/physics/disc_definition.gd")

## Everything the flight integrator needs to know about one disc: mass
## properties, reference area, and the aerodynamic coefficient table.
##
## Loading order (see DiscLibrary):
##   1. `game/data/discs.json` + `game/data/aero/<id>.json`  (Track A, authoritative)
##   2. the BUILT-IN FALLBACK roster below                    (this file)
##
## The fallback exists so that Track B's tests and Track C's scene can run
## before Track A's data pipeline lands. It is NOT measured data and must never
## be presented as such — every fallback disc carries
## `aero_provenance = "derived-fallback"` (CONTRACT §7).

const DEFAULT_MASS_KG := 0.175
const DEFAULT_DIAMETER_M := 0.211

var id: String = "unknown"
var name: String = "Unknown disc"
var category: String = "unknown"

# Flight numbers (marketing ratings, kept for UI + the fallback aero synthesis).
var speed: float = 7.0
var glide: float = 5.0
var turn: float = 0.0
var fade: float = 2.0

# CONTRACT §2 geometry.
var diameter_m: float = DEFAULT_DIAMETER_M
var mass_kg: float = DEFAULT_MASS_KG
var rim_width_m: float = 0.019
var rim_depth_m: float = 0.012
var rim_thickness_m: float = 0.014
var parting_line_m: float = 0.006
var dome_height_m: float = 0.004
var inner_rim_edge_m: float = 0.075

# CONTRACT §2 derived quantities. Populated by `_recompute_derived()` unless the
# data file supplies them explicitly (Track A owns the authoritative formulas;
# if it ships them we use them verbatim).
var area_m2: float = 0.0
var i_zz: float = 0.0
var i_xy: float = 0.0
var parting_ratio: float = 0.0

var aero: AeroTable = null
var aero_provenance: String = "derived"


func radius_m() -> float:
	return diameter_m * 0.5


## CONTRACT §2. area = PI r^2 (~0.0350 m^2 for d = 0.211) — explicitly NOT the
## 0.0568 m^2 Ultimate-frisbee figure, which inflates every force by ~62%.
##
## Inertia: a golf disc is rim-loaded, so I_zz / (m R^2) sits well above the 0.5
## of a uniform disc. The linear map below is calibrated to the CONTRACT §2
## reference point (I_zz ~= 0.00131 kg m^2 for a 175 g, 211 mm disc with a
## ~21 mm rim) and is a coarse parameterisation, not a derivation — Track A's
## data supersedes it whenever present.
##
## I_xy = I_zz / 2 is the perpendicular-axis theorem for a planar body; the
## disc's ~2 cm depth perturbs this by only a few percent, and it reproduces
## the CONTRACT §2 pair (0.00131 / 0.00066) exactly.
func _recompute_derived() -> void:
	var r := radius_m()
	area_m2 = PI * r * r
	var k: float = 0.55 + 0.65 * clampf(rim_width_m / maxf(r, 1e-6), 0.0, 0.45)
	i_zz = k * mass_kg * r * r
	i_xy = i_zz * 0.5
	parting_ratio = parting_line_m / maxf(rim_depth_m, 1e-6)


func is_valid() -> bool:
	return (aero != null and aero.size() >= 2 and aero.is_grid_ok() and mass_kg > 0.0
		and area_m2 > 0.0 and i_zz > 0.0 and i_xy > 0.0)


# ---------------------------------------------------------------------------
# Data loading (CONTRACT §3)
# ---------------------------------------------------------------------------

## Build from one entry of `discs.json`. `aero_table` is the already-parsed
## `aero/<id>.json` table, or null to fall back to synthesised coefficients.
static func from_dict(d: Dictionary, aero_table: AeroTable) -> DiscDef:
	var disc := DiscDef.new()
	disc.id = String(d.get("id", "unknown"))
	disc.name = String(d.get("name", disc.id))
	disc.category = String(d.get("category", "unknown"))

	var fn: Dictionary = d.get("flight_numbers", {})
	disc.speed = float(fn.get("speed", disc.speed))
	disc.glide = float(fn.get("glide", disc.glide))
	disc.turn = float(fn.get("turn", disc.turn))
	disc.fade = float(fn.get("fade", disc.fade))

	var g: Dictionary = d.get("geometry", {})
	disc.diameter_m = float(g.get("diameter_m", disc.diameter_m))
	disc.mass_kg = float(g.get("mass_kg", disc.mass_kg))
	disc.rim_width_m = float(g.get("rim_width_m", disc.rim_width_m))
	disc.rim_depth_m = float(g.get("rim_depth_m", disc.rim_depth_m))
	disc.rim_thickness_m = float(g.get("rim_thickness_m", disc.rim_thickness_m))
	disc.parting_line_m = float(g.get("parting_line_m", disc.parting_line_m))
	disc.dome_height_m = float(g.get("dome_height_m", disc.dome_height_m))
	disc.inner_rim_edge_m = float(g.get("inner_rim_edge_m", disc.inner_rim_edge_m))
	disc._recompute_derived()

	# Track A may ship the derived block; prefer it over our coarse model.
	var derived: Dictionary = d.get("derived", g)
	if derived.has("area_m2"):
		disc.area_m2 = float(derived["area_m2"])
	if derived.has("I_zz"):
		disc.i_zz = float(derived["I_zz"])
	elif derived.has("i_zz"):
		disc.i_zz = float(derived["i_zz"])
	if derived.has("I_xy"):
		disc.i_xy = float(derived["I_xy"])
	elif derived.has("i_xy"):
		disc.i_xy = float(derived["i_xy"])

	disc.aero_provenance = String(d.get("aero_provenance", "derived"))
	if aero_table != null:
		disc.aero = aero_table
	else:
		disc.aero = synth_aero_table(disc.speed, disc.glide, disc.turn, disc.fade)
		disc.aero_provenance = "derived-fallback"
	return disc


# ---------------------------------------------------------------------------
# Built-in fallback roster
# ---------------------------------------------------------------------------

const BUILTIN_IDS := ["reference_driver", "reference_fairway", "reference_putter",
	"reference_understable"]


static func builtin_ids() -> PackedStringArray:
	return PackedStringArray(BUILTIN_IDS)


## A small stand-in roster covering the CONTRACT §5 sanity targets.
## `aero_provenance` is "derived-fallback" for all of them.
static func builtin(disc_id: String) -> DiscDef:
	var d := Dictionary()
	match disc_id:
		"reference_driver":
			d = {
				"id": "reference_driver", "name": "Reference Distance Driver",
				"category": "distance_driver",
				"flight_numbers": {"speed": 12, "glide": 5, "turn": -1, "fade": 3},
				"geometry": {
					"diameter_m": 0.211, "mass_kg": 0.175, "rim_width_m": 0.023,
					"rim_depth_m": 0.012, "rim_thickness_m": 0.019,
					"parting_line_m": 0.0055, "dome_height_m": 0.003,
					"inner_rim_edge_m": 0.0825,
				},
			}
		"reference_fairway":
			d = {
				"id": "reference_fairway", "name": "Reference Fairway Driver",
				"category": "fairway_driver",
				"flight_numbers": {"speed": 7, "glide": 5, "turn": 0, "fade": 2},
				"geometry": {
					"diameter_m": 0.211, "mass_kg": 0.175, "rim_width_m": 0.019,
					"rim_depth_m": 0.013, "rim_thickness_m": 0.016,
					"parting_line_m": 0.0060, "dome_height_m": 0.004,
					"inner_rim_edge_m": 0.0865,
				},
			}
		"reference_putter":
			d = {
				"id": "reference_putter", "name": "Reference Putter",
				"category": "putter",
				"flight_numbers": {"speed": 2, "glide": 3, "turn": 0, "fade": 1},
				"geometry": {
					"diameter_m": 0.212, "mass_kg": 0.174, "rim_width_m": 0.011,
					"rim_depth_m": 0.015, "rim_thickness_m": 0.014,
					"parting_line_m": 0.0070, "dome_height_m": 0.005,
					"inner_rim_edge_m": 0.0950,
				},
			}
		"reference_understable":
			d = {
				"id": "reference_understable", "name": "Reference Understable Driver",
				"category": "distance_driver",
				"flight_numbers": {"speed": 9, "glide": 5, "turn": -4, "fade": 1},
				"geometry": {
					"diameter_m": 0.211, "mass_kg": 0.170, "rim_width_m": 0.020,
					"rim_depth_m": 0.012, "rim_thickness_m": 0.017,
					"parting_line_m": 0.0050, "dome_height_m": 0.004,
					"inner_rim_edge_m": 0.0855,
				},
			}
		_:
			return null
	var disc := from_dict(d, null)
	disc.aero_provenance = "derived-fallback"
	return disc


# ---------------------------------------------------------------------------
# Fallback coefficient synthesis
# ---------------------------------------------------------------------------

const _SYNTH_STEP_DEG := 0.5
const _SYNTH_MIN_DEG := -90.0
const _SYNTH_MAX_DEG := 90.0

## Synthesise a plausible CL/CD/CM(alpha) table from flight numbers.
##
## PROVENANCE (CONTRACT §7): this is NOT measured. The CM anchors come from the
## CONTRACT §7 regressions against the four Giljarhus et al. (2022) CFD discs:
##     turn ~= 296.8 * CM(0 deg) + 3.31     (R^2 = 0.89, n = 4)
##     fade ~= 182.8 * CM(10 deg) - 4.22    (R^2 = 0.91, n = 4)
## inverted to give CM at 0 deg and 10 deg, with a sin(a)cos(a) shape between and
## a stall roll-off outside. CL/CD use a thin-cambered-plate model whose
## magnitudes are in the range reported for disc-golf discs; the glide and speed
## dependencies are frankly underdetermined at n = 4 and are only there so the
## roster is not degenerate. Do not read precision into these numbers.
static func synth_aero_table(p_speed: float, p_glide: float, p_turn: float,
		p_fade: float) -> AeroTable:
	var t := AeroTable.new()
	var n: int = int(round((_SYNTH_MAX_DEG - _SYNTH_MIN_DEG) / _SYNTH_STEP_DEG)) + 1
	t.alpha_rad.resize(n)
	t.cl.resize(n)
	t.cd.resize(n)
	t.cm.resize(n)

	# Zero-alpha lift and drag. Glide raises CL0; a wider rim (higher speed
	# rating) lowers profile drag.
	var cl0: float = 0.085 + 0.013 * p_glide
	var cl_alpha: float = 2.5
	var cd0: float = 0.090 - 0.002 * p_speed
	var cd_k: float = 1.9
	var alpha0: float = -cl0 / cl_alpha  # zero-lift angle; drag minimum sits here

	# CM anchors from the CONTRACT §7 regressions.
	var cm0: float = (p_turn - 3.31) / 296.8
	var cm10: float = (p_fade + 4.22) / 182.8
	var s10: float = sin(deg_to_rad(10.0)) * cos(deg_to_rad(10.0))
	var cm_slope: float = (cm10 - cm0) / s10

	for i in n:
		var a_deg: float = _SYNTH_MIN_DEG + _SYNTH_STEP_DEG * float(i)
		var a: float = deg_to_rad(a_deg)
		t.alpha_rad[i] = a
		var sa: float = sin(a)
		var ca: float = cos(a)
		var aa: float = absf(a)

		# --- lift: linear-ish core, blended into a flat plate past stall
		var cl_core: float = cl0 + cl_alpha * sa * ca
		var cl_plate: float = sin(2.0 * a)
		var w_l: float = smoothstep(0.42, 0.80, aa)  # ~24 deg -> ~46 deg
		t.cl[i] = lerpf(cl_core, cl_plate, w_l)

		# --- drag: CD0 + induced (quadratic in sin(a - a0)), blended to bluff body
		var s_eff: float = sin(a - alpha0)
		var cd_core: float = cd0 + cd_k * s_eff * s_eff
		var cd_plate: float = 0.08 + 1.15 * sa * sa
		var w_d: float = smoothstep(0.35, 0.90, aa)
		t.cd[i] = lerpf(cd_core, cd_plate, w_d)

		# --- pitching moment: the sign flip that IS turn and fade (CONTRACT §5)
		var cm_core: float = cm0 + cm_slope * sa * ca
		# The centre of pressure migrates back toward the centre once the plate
		# stalls, so |CM| must roll off rather than grow without bound.
		var rolloff: float = lerpf(1.0, 0.35, smoothstep(0.50, 1.20, aa))
		t.cm[i] = cm_core * rolloff

	t.source = "derived-fallback:contract-s7-regression"
	t.finalize()
	return t

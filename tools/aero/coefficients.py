"""Geometry -> CL(alpha), CD(alpha), CM(alpha).

Method
------
**Shape-preserving affine mapping of a real measured CFD curve onto anchors
predicted from geometry.**

For every disc we

1. pick the nearest of the four measured CFD discs (Giljarhus et al. 2022) as a
   *base shape*, by distance in (turn, fade, speed) rating space;
2. compute two target anchors, ``CM(0 deg)`` and ``CM(10 deg)``, from the disc's
   geometry;
3. affine-map the base ``CM`` curve, ``CM' = a*CM + b``, so it passes through
   both anchors;
4. scale ``CL`` and ``CD`` by single geometry-driven factors.

Why affine rather than fitting a functional form: the measured curves carry real
non-linear behaviour — stall around 25-30 deg, the bluff-body plateau past 40
deg, the sign structure of ``CM`` through zero — that four data points cannot
possibly identify.  An affine map preserves all of it while letting geometry
drive where the disc sits within that family.  Because ``a > 0`` is enforced,
the map cannot reorder the curve or invent a ``CM`` sign change that is not in
the measured data.

Outside ``|alpha| > 30 deg`` the correction is smoothly tapered back to the
measured base curve and is gone entirely by ``|alpha| = 60 deg``.  Two reasons:
the affine offset would otherwise leave ``CM(+-90 deg) != 0``, which the
edge-on symmetry of a disc forbids; and the regressions that produce the
anchors were fitted on ``alpha`` in ``[0, 10]`` and have no authority at 60 deg.

Limits of the method — read before trusting a number out of it
--------------------------------------------------------------
* The two anchor regressions have **n = 4**.  ``R^2 = 0.89`` and ``0.91`` on four
  points is four points, not a validated model.
* Only **three** of the four CFD cases are tied to a named mould by the upstream
  data; the fourth (``dd2``) is matched on rating class only.
* The high-alpha wings of ``cd1`` and ``fd2`` are literally the same numbers —
  upstream copied them — so the apparent agreement between discs above 25 deg
  carries no information.
* **Glide is not recoverable from this dataset.**  Three of the four discs are
  rated glide 5 and one glide 3 — one contrast.  Peak ``CL/CD`` is 4.149 for the
  glide-3 disc against 4.151, 4.186 and 4.509 for the glide-5 discs: nominally
  in the right order, but 0.05% below the nearest one while the glide-5 discs
  are spread over 8.6% among *themselves*.  The glide -> ``CL`` scaling below is
  an author-chosen heuristic with no empirical support, deliberately kept small,
  and labelled as such everywhere it surfaces.
* The geometry -> anchor model is a **calibration, not a regression**.  Nobody
  publishes parting-line heights, so there is no dataset to regress against.
  Its slopes were chosen so that the roster's published flight numbers map back
  onto plausible manufacturable profiles; its *signs and relative magnitudes*
  come from the finding that parting-line ratio dominates both turn and fade.
  Do not quote an R^2 for it. There isn't one.
"""

from __future__ import annotations

import json
import math
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

import numpy as np
from scipy.interpolate import PchipInterpolator

from .geometry import DiscGeometry

REFERENCE_DIR = Path(__file__).resolve().parent / "reference"

# ---------------------------------------------------------------------------
# Flight-number <-> CM anchor regressions.
#
# Ordinary least squares of the four CFD discs' published commercial ratings
# against their CFD CM at the stated alpha. Both are reproduced from the cached
# reference data by test_coefficients.py, so if the data ever changes the test
# fails rather than these constants silently going stale.
#
#   turn = 296.87 * CM(0 deg)  + 3.314    R^2 = 0.890   n = 4
#   fade = 182.76 * CM(10 deg) - 4.221    R^2 = 0.908   n = 4
#
# n = 4. These are the best available and they are still four points.
# ---------------------------------------------------------------------------
TURN_SLOPE, TURN_INTERCEPT, TURN_R2 = 296.87, 3.314, 0.890
FADE_SLOPE, FADE_INTERCEPT, FADE_R2 = 182.76, -4.221, 0.908

# ---------------------------------------------------------------------------
# speed = f(rim width). CONTRACT §7 quotes R^2 = 0.96 over 43 discs; we do not
# have that dataset, so this is our own OLS fit over the 14 roster discs using
# PDGA-published rim widths and manufacturer speed ratings:
#
#   speed = 703.1 * rim_width_m - 4.453   R^2 = 0.948   n = 14
#
# Recomputed and asserted by test_coefficients.py against game/data/discs.json.
# ---------------------------------------------------------------------------
SPEED_PER_RIM_WIDTH, SPEED_INTERCEPT, SPEED_R2 = 703.1, -4.453, 0.948

# ---------------------------------------------------------------------------
# Geometry -> CM anchors. A CALIBRATION (see module docstring), expressed on two
# orthogonal combinations of the anchors:
#
#   cm_bar   = (CM(0) + CM(10)) / 2   overall stability -> parting-line ratio
#   cm_slope =  CM(10) - CM(0)        how fast the CoP marches forward -> the
#                                     axial bluntness of the rim wing
#
# Splitting it this way is what makes parting-line ratio move turn and fade
# *together*, which is the documented behaviour, while leaving one independent
# handle for the turn/fade split.
# ---------------------------------------------------------------------------
PARTING_RATIO_REF = 0.50
CM_BAR_REF = 0.0100
CM_BAR_PER_PARTING = 0.0333          # d(cm_bar)/d(parting_ratio)

BLUNTNESS_REF = 0.40                 # rim_thickness_m / rim_width_m
CM_SLOPE_REF = 0.0480
CM_SLOPE_PER_BLUNTNESS = 0.0688      # d(cm_slope)/d(bluntness)

# ---------------------------------------------------------------------------
# CD0 = f(rim width), OLS over the four CFD discs:
#   CD0 = -1.321 * rim_width_m + 0.0715    R^2 = 0.38   n = 4
# R^2 = 0.38 on n = 4 is barely a trend. It is applied because its direction
# (wider, sharper rim -> lower parasite drag) is not in doubt, and clamped hard
# so a putter extrapolated far outside the fitted 17-22 mm range cannot run
# away. Recomputed by test_coefficients.py.
# ---------------------------------------------------------------------------
CD0_PER_RIM_WIDTH, CD0_INTERCEPT, CD0_R2 = -1.321, 0.0715, 0.38
CD_SCALE_CLAMP = (0.80, 1.60)

# ---------------------------------------------------------------------------
# Glide -> CL. NOT FITTED. There is no glide signal in the measured data (see
# module docstring). This is a small author-chosen heuristic so that the glide
# rating does something rather than nothing; +-3.5% of CL per glide point off
# the roster mean, clamped at +-15%.
# ---------------------------------------------------------------------------
GLIDE_REF = 4.5
CL_PER_GLIDE_POINT = 0.035
CL_SCALE_CLAMP = (0.85, 1.15)
GLIDE_MODEL_IS_FITTED = False

# Where the geometry correction is trusted in full, and where it has faded back
# to the raw measured curve.
TAPER_FULL_DEG = 30.0
TAPER_ZERO_DEG = 60.0

# ---------------------------------------------------------------------------
# Damping (CONTRACT §3). No disc-golf-specific measurement of any of these
# exists, so they come from Hummel 2003's long-flight fit to an Ultimate disc.
#
# c_nr needs explaining. CONTRACT §4 requires the spin-down moment to carry the
# same 0.5*rho*A*V^2*d scaling as the other two moments — Hummel's published
# MATLAB omits the A*d factor, a widely-copied bug. But her *numeric* CNr was
# fitted to her own un-scaled dimensional form: dropped into
#
#     M_spin = q * A * d * c_nr * (spin * d / (2V))
#
# it produces roughly 0.2% spin loss over a drive, against the ~10-20% that is
# actually observed. The value and the equation are incompatible; keeping both
# unchanged would be self-consistent only on paper. We therefore ship a c_nr
# calibrated to that equation (measured spin loss is reported by validate.py),
# and keep Hummel's raw number alongside it so nothing is hidden.
# ---------------------------------------------------------------------------
DAMPING = {
    "c_mq": -0.0144,
    "c_rp": -0.0125,
    "c_nr": -3.0e-3,
}
DAMPING_PROVENANCE = {
    "source": "Hummel 2003 long-flight fit (Ultimate disc, not a golf disc)",
    "c_mq": "Hummel 2003, used unchanged",
    "c_rp": "Hummel 2003, used unchanged",
    "c_nr": (
        "RECALIBRATED. Hummel's published -3.41e-5 was fitted to a spin moment "
        "written without the A*d scaling. Under the CONTRACT §4 form "
        "M_spin = q*A*d*c_nr*(spin*d/2V) it gives ~0.2% spin loss over a drive; "
        "the observed figure is 10-20%. This value gives 11.7% over the "
        "CONTRACT §5 distance drive, and an initial decay rate of 2.8%/s at "
        "27 m/s / 157 rad/s -- which independently matches a turbulent "
        "skin-friction estimate over both disc faces (C_f ~ 0.005 gives "
        "2.4%/s). Re-checked after the §4 v2 precession correction shortened "
        "flight times; kept unchanged, because the first-principles estimate "
        "constrains it better than the round 15% figure does."
    ),
    "c_nr_hummel_2003_raw": -3.41e-5,
    "spin_moment_form": "M_spin = 0.5*rho*V^2*A*d * c_nr * (spin*d/(2*V))",
    "caveat": (
        "All three are Ultimate-disc numbers. No disc-golf-specific measurement "
        "of pitch damping, roll damping or spin-down exists in the literature."
    ),
}


# ---------------------------------------------------------------------------
# reference data access
# ---------------------------------------------------------------------------
@lru_cache(maxsize=1)
def load_cfd() -> dict:
    """Load the cached Giljarhus 2022 CFD tables."""
    path = REFERENCE_DIR / "giljarhus2022_cfd.json"
    if not path.exists():
        raise FileNotFoundError(
            f"{path} missing — run `python -m tools.aero.fetch_reference_data`"
        )
    return json.loads(path.read_text())


@lru_cache(maxsize=1)
def load_hummel() -> dict:
    return json.loads((REFERENCE_DIR / "hummel2003.json").read_text())


def measured_case(case: str) -> dict:
    return load_cfd()["discs"][case]


def _at(case: str, key: str, alpha_deg: float) -> float:
    d = measured_case(case)
    return float(d[key][d["alpha_deg"].index(alpha_deg)])


# ---------------------------------------------------------------------------
# flight numbers <-> anchors
# ---------------------------------------------------------------------------
def flight_numbers_from_cm(cm0: float, cm10: float) -> tuple[float, float]:
    """Forward regressions: CM anchors -> (turn, fade) ratings."""
    return TURN_SLOPE * cm0 + TURN_INTERCEPT, FADE_SLOPE * cm10 + FADE_INTERCEPT


def cm_anchors_from_flight(turn: float, fade: float) -> tuple[float, float]:
    """Inverse regressions: (turn, fade) ratings -> CM anchors."""
    return (turn - TURN_INTERCEPT) / TURN_SLOPE, (fade - FADE_INTERCEPT) / FADE_SLOPE


def predict_speed(rim_width_m: float) -> float:
    """Speed rating from rim width — the one geometry->rating link with real
    support (R^2 = 0.948 over 14 discs; the literature reports 0.96 over 43)."""
    return SPEED_PER_RIM_WIDTH * rim_width_m + SPEED_INTERCEPT


# ---------------------------------------------------------------------------
# geometry <-> anchors (calibration, both directions)
# ---------------------------------------------------------------------------
def cm_anchors_from_geometry(geom: DiscGeometry) -> tuple[float, float]:
    """Predict ``(CM(0 deg), CM(10 deg))`` from the disc profile.

    This is the forward direction the simulator uses: drag the parting line in
    the UI and the flight changes.
    """
    bluntness = geom.rim_thickness_m / geom.rim_width_m
    cm_bar = CM_BAR_REF + CM_BAR_PER_PARTING * (geom.parting_ratio - PARTING_RATIO_REF)
    cm_slope = CM_SLOPE_REF + CM_SLOPE_PER_BLUNTNESS * (bluntness - BLUNTNESS_REF)
    return cm_bar - 0.5 * cm_slope, cm_bar + 0.5 * cm_slope


def infer_shape_from_flight(
    turn: float, fade: float, rim_depth_m: float, rim_width_m: float
) -> tuple[float, float]:
    """Invert :func:`cm_anchors_from_geometry`: published ratings -> the two
    profile parameters nobody publishes.

    Returns ``(parting_line_m, rim_thickness_m)``.

    This is how the roster's ``parting_line_m`` and ``rim_thickness_m`` are
    obtained. They are **model output**, not measurements, and the emitted
    ``geometry_provenance`` says so for every disc.
    """
    cm0, cm10 = cm_anchors_from_flight(turn, fade)
    cm_bar, cm_slope = 0.5 * (cm0 + cm10), cm10 - cm0

    parting_ratio = PARTING_RATIO_REF + (cm_bar - CM_BAR_REF) / CM_BAR_PER_PARTING
    bluntness = BLUNTNESS_REF + (cm_slope - CM_SLOPE_REF) / CM_SLOPE_PER_BLUNTNESS

    parting_line_m = parting_ratio * rim_depth_m
    rim_thickness_m = bluntness * rim_width_m
    return parting_line_m, rim_thickness_m


# ---------------------------------------------------------------------------
# base-shape selection
# ---------------------------------------------------------------------------
def choose_base_case(speed: float, turn: float, fade: float) -> str:
    """Nearest measured CFD disc in rating space.

    Turn and fade are weighted an order of magnitude above speed: they set the
    shape of ``CM(alpha)``, which is what the affine map has to preserve, while
    speed only shifts the drag level, which is corrected separately.
    """
    best, best_d = None, math.inf
    for case, data in load_cfd()["discs"].items():
        fn = data["flight_numbers"]
        d = ((turn - fn["turn"]) ** 2
             + (fade - fn["fade"]) ** 2
             + 0.05 * (speed - fn["speed"]) ** 2)
        if d < best_d:
            best, best_d = case, d
    assert best is not None
    return best


# ---------------------------------------------------------------------------
# the model
# ---------------------------------------------------------------------------
def _taper(alpha_deg: np.ndarray) -> np.ndarray:
    """Smoothstep from 1 inside +-TAPER_FULL_DEG to 0 outside +-TAPER_ZERO_DEG."""
    a = np.abs(alpha_deg)
    t = np.clip((a - TAPER_FULL_DEG) / (TAPER_ZERO_DEG - TAPER_FULL_DEG), 0.0, 1.0)
    return 1.0 - t * t * (3.0 - 2.0 * t)


@dataclass(frozen=True)
class CoefficientSet:
    """CL/CD/CM sampled on a grid, plus everything needed to justify them."""

    alpha_deg: np.ndarray
    cl: np.ndarray
    cd: np.ndarray
    cm: np.ndarray
    base_case: str
    cm_gain: float
    cm_offset: float
    cl_scale: float
    cd_scale: float
    cm0: float
    cm10: float

    def recovered_flight_numbers(self) -> tuple[float, float]:
        """Read the anchors back off the finished curve and invert the
        regressions — the round-trip check ``test_bake`` asserts on."""
        f = PchipInterpolator(self.alpha_deg, self.cm)
        return flight_numbers_from_cm(float(f(0.0)), float(f(10.0)))


def build_coefficients(
    geom: DiscGeometry,
    *,
    glide: float,
    speed: float | None = None,
    base_case: str | None = None,
    alpha_grid_deg: np.ndarray | None = None,
) -> CoefficientSet:
    """Produce CL/CD/CM for ``geom`` on ``alpha_grid_deg`` (default 0.5 deg over
    [-90, 90], i.e. exactly the CONTRACT §3 bake grid).

    ``speed`` defaults to the geometry prediction from rim width; pass the
    published rating to select a base shape by the real number instead.
    """
    if alpha_grid_deg is None:
        alpha_grid_deg = np.arange(-90.0, 90.0 + 1e-9, 0.5)

    cm0_t, cm10_t = cm_anchors_from_geometry(geom)
    turn_t, fade_t = flight_numbers_from_cm(cm0_t, cm10_t)
    if speed is None:
        speed = predict_speed(geom.rim_width_m)
    case = base_case or choose_base_case(speed, turn_t, fade_t)

    base = measured_case(case)
    a_knots = np.asarray(base["alpha_deg"], float)
    cl_b = PchipInterpolator(a_knots, np.asarray(base["cl"], float))(alpha_grid_deg)
    cd_b = PchipInterpolator(a_knots, np.asarray(base["cd"], float))(alpha_grid_deg)
    cm_b = PchipInterpolator(a_knots, np.asarray(base["cm"], float))(alpha_grid_deg)

    # --- CM: affine map through both anchors --------------------------------
    cm0_b, cm10_b = _at(case, "cm", 0.0), _at(case, "cm", 10.0)
    span = cm10_b - cm0_b
    if abs(span) < 1e-6:
        raise ValueError(f"base case {case} has a degenerate CM(0)->CM(10) span")
    gain = (cm10_t - cm0_t) / span
    # A negative or vanishing gain would flip or flatten the measured curve and
    # fabricate stability behaviour. Clamp to a range that still spans every
    # commercial rating (turn -5..+1, fade 0..5) with room to spare.
    gain = float(np.clip(gain, 0.4, 2.5))
    offset = cm0_t - gain * cm0_b

    w = _taper(alpha_grid_deg)
    cm = cm_b + w * ((gain - 1.0) * cm_b + offset)

    # --- CD: parasite-drag level from rim width -----------------------------
    cd0_t = CD0_PER_RIM_WIDTH * geom.rim_width_m + CD0_INTERCEPT
    cd_scale = float(np.clip(cd0_t / _at(case, "cd", 0.0), *CD_SCALE_CLAMP))
    cd = cd_b * (1.0 + w * (cd_scale - 1.0))

    # --- CL: glide heuristic (NOT fitted — see module docstring) ------------
    cl_scale = float(np.clip(1.0 + CL_PER_GLIDE_POINT * (glide - GLIDE_REF), *CL_SCALE_CLAMP))
    cl = cl_b * (1.0 + w * (cl_scale - 1.0))

    return CoefficientSet(
        alpha_deg=alpha_grid_deg, cl=cl, cd=cd, cm=cm,
        base_case=case, cm_gain=gain, cm_offset=offset,
        cl_scale=cl_scale, cd_scale=cd_scale, cm0=cm0_t, cm10=cm10_t,
    )


def measured_coefficients(case: str, alpha_grid_deg: np.ndarray | None = None) -> CoefficientSet:
    """PCHIP-resample a measured CFD case with **no** modelling applied.

    Used for the four discs whose coefficients we actually have. The only
    processing is the resample onto the uniform grid.
    """
    if alpha_grid_deg is None:
        alpha_grid_deg = np.arange(-90.0, 90.0 + 1e-9, 0.5)
    base = measured_case(case)
    a_knots = np.asarray(base["alpha_deg"], float)
    return CoefficientSet(
        alpha_deg=alpha_grid_deg,
        cl=PchipInterpolator(a_knots, np.asarray(base["cl"], float))(alpha_grid_deg),
        cd=PchipInterpolator(a_knots, np.asarray(base["cd"], float))(alpha_grid_deg),
        cm=PchipInterpolator(a_knots, np.asarray(base["cm"], float))(alpha_grid_deg),
        base_case=case, cm_gain=1.0, cm_offset=0.0, cl_scale=1.0, cd_scale=1.0,
        cm0=_at(case, "cm", 0.0), cm10=_at(case, "cm", 10.0),
    )

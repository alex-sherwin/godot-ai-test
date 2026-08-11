"""Tests for the coefficient model.

Several of these re-derive the fitted constants from the cached reference data
rather than trusting the numbers written into ``coefficients.py``.  If the
reference cache is ever refetched and upstream has changed, these fail loudly
instead of the model silently drifting away from its own documentation.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from tools.aero import coefficients as C
from tools.aero.geometry import make_geometry
from tools.aero.roster import ROSTER

REPO_ROOT = Path(__file__).resolve().parents[2]
DISCS_JSON = REPO_ROOT / "game" / "data" / "discs.json"
CASES = ("cd1", "fd2", "cd5", "dd2")


def _ols(x, y):
    x, y = np.asarray(x, float), np.asarray(y, float)
    a = np.vstack([x, np.ones_like(x)]).T
    (m, b), *_ = np.linalg.lstsq(a, y, rcond=None)
    pred = m * x + b
    r2 = 1.0 - np.sum((y - pred) ** 2) / np.sum((y - y.mean()) ** 2)
    return float(m), float(b), float(r2)


def _cm_at(case, deg):
    d = C.measured_case(case)
    return d["cm"][d["alpha_deg"].index(deg)]


# ---------------------------------------------------------------------------
# the two anchor regressions, re-derived from the cached CFD data
# ---------------------------------------------------------------------------
def test_turn_regression_is_reproducible_from_reference_data():
    m, b, r2 = _ols([_cm_at(c, 0) for c in CASES],
                    [C.measured_case(c)["flight_numbers"]["turn"] for c in CASES])
    assert m == pytest.approx(C.TURN_SLOPE, rel=1e-3)
    assert b == pytest.approx(C.TURN_INTERCEPT, rel=1e-3)
    assert r2 == pytest.approx(C.TURN_R2, abs=2e-3)


def test_fade_regression_is_reproducible_from_reference_data():
    m, b, r2 = _ols([_cm_at(c, 10) for c in CASES],
                    [C.measured_case(c)["flight_numbers"]["fade"] for c in CASES])
    assert m == pytest.approx(C.FADE_SLOPE, rel=1e-3)
    assert b == pytest.approx(C.FADE_INTERCEPT, rel=1e-3)
    assert r2 == pytest.approx(C.FADE_R2, abs=2e-3)


def test_regressions_invert_exactly():
    for turn, fade in [(0, 4), (-4, 1), (-1, 3), (2, 0), (-5, 5)]:
        cm0, cm10 = C.cm_anchors_from_flight(turn, fade)
        t, f = C.flight_numbers_from_cm(cm0, cm10)
        assert t == pytest.approx(turn, abs=1e-9)
        assert f == pytest.approx(fade, abs=1e-9)


def test_regression_sample_size_is_four_and_stated_as_such():
    """CONTRACT §7. If a fifth measured disc ever appears this must be revisited."""
    assert len(C.load_cfd()["discs"]) == 4


# ---------------------------------------------------------------------------
# speed = f(rim width)
# ---------------------------------------------------------------------------
def test_speed_regression_matches_the_shipped_roster():
    m, b, r2 = _ols([e["pdga"]["rim_thickness_cm"] / 100.0 for e in ROSTER],
                    [e["flight_numbers"]["speed"] for e in ROSTER])
    assert m == pytest.approx(C.SPEED_PER_RIM_WIDTH, rel=2e-3)
    assert b == pytest.approx(C.SPEED_INTERCEPT, rel=2e-3)
    assert r2 == pytest.approx(C.SPEED_R2, abs=2e-3)
    assert r2 > 0.9, "rim width should explain most of the speed rating"


def test_wider_rim_predicts_higher_speed():
    widths = np.linspace(0.009, 0.026, 30)
    preds = np.array([C.predict_speed(w) for w in widths])
    assert np.all(np.diff(preds) > 0)
    assert C.predict_speed(0.009) < 3.0     # putter
    assert C.predict_speed(0.025) > 12.0    # 13-speed bomber


def test_predicted_speed_tracks_published_ratings():
    err = [abs(C.predict_speed(e["pdga"]["rim_thickness_cm"] / 100.0)
               - e["flight_numbers"]["speed"]) for e in ROSTER]
    assert max(err) < 1.3, f"worst speed prediction error {max(err):.2f}"


# ---------------------------------------------------------------------------
# CD0 = f(rim width) — the weak one, asserted weak on purpose
# ---------------------------------------------------------------------------
def test_cd0_regression_matches_and_is_honestly_labelled_weak():
    rim = {"cd1": 0.019, "fd2": 0.017, "cd5": 0.018, "dd2": 0.022}
    m, b, r2 = _ols([rim[c] for c in CASES],
                    [C.measured_case(c)["cd"][C.measured_case(c)["alpha_deg"].index(0)]
                     for c in CASES])
    assert m == pytest.approx(C.CD0_PER_RIM_WIDTH, rel=5e-3)
    assert b == pytest.approx(C.CD0_INTERCEPT, rel=5e-3)
    assert r2 == pytest.approx(C.CD0_R2, abs=0.02)
    assert r2 < 0.6, "this relation is weak and the module must not claim otherwise"


# ---------------------------------------------------------------------------
# glide: the thing we cannot do
# ---------------------------------------------------------------------------
def test_glide_is_not_recoverable_from_the_measured_data():
    """The justification for ``GLIDE_MODEL_IS_FITTED = False``, asserted.

    Three of the four CFD discs are rated glide 5 and one glide 3, so there is
    exactly one contrast to learn from.  Peak L/D is 4.149 (glide 3) against
    4.151 / 4.186 / 4.509 (glide 5).  The glide-3 disc is nominally lowest, but
    it sits 0.05% below the nearest glide-5 disc while the glide-5 discs are
    spread over 8.6% among themselves.  A one-point contrast buried an order of
    magnitude inside the within-group scatter is not a signal you can fit.
    """
    peaks = {}
    for case in CASES:
        d = C.measured_case(case)
        a = np.asarray(d["alpha_deg"], float)
        m = (a >= -5) & (a <= 20)
        peaks[case] = float(np.max(np.asarray(d["cl"])[m] / np.asarray(d["cd"])[m]))

    glides = {c: C.measured_case(c)["flight_numbers"]["glide"] for c in CASES}
    low = [peaks[c] for c in CASES if glides[c] == 3]
    high = sorted(peaks[c] for c in CASES if glides[c] == 5)
    assert len(low) == 1 and len(high) == 3

    between = (min(high) - low[0]) / low[0]
    within = (max(high) - min(high)) / min(high)
    assert between < 0.01, f"glide-3 to nearest glide-5 gap {between:.4f}"
    assert within > 10 * between, f"within-group spread {within:.4f} vs {between:.4f}"
    assert C.GLIDE_MODEL_IS_FITTED is False


def test_glide_scaling_is_small_and_bounded():
    for glide in range(1, 8):
        s = float(np.clip(1.0 + C.CL_PER_GLIDE_POINT * (glide - C.GLIDE_REF),
                          *C.CL_SCALE_CLAMP))
        assert 0.85 <= s <= 1.15


# ---------------------------------------------------------------------------
# geometry -> coefficients
# ---------------------------------------------------------------------------
def _geom(**over):
    kw = dict(diameter_m=0.211, mass_kg=0.175, rim_width_m=0.019,
              rim_depth_m=0.012, rim_thickness_m=0.0076, parting_line_m=0.006,
              dome_height_m=0.0002, inner_rim_edge_m=0.0855)
    kw.update(over)
    kw["inner_rim_edge_m"] = 0.5 * kw["diameter_m"] - kw["rim_width_m"]
    return make_geometry(**kw)


def test_higher_parting_line_makes_a_disc_more_overstable():
    """Monotone in the direction the literature reports: parting-line ratio
    drives both turn and fade, together."""
    prev_turn = prev_fade = None
    # Upper bound keeps the 7.6 mm wing under the flight plate.
    for parting in np.linspace(0.0035, 0.0098, 12):
        g = _geom(parting_line_m=float(parting))
        turn, fade = C.flight_numbers_from_cm(*C.cm_anchors_from_geometry(g))
        if prev_turn is not None:
            assert turn > prev_turn
            assert fade > prev_fade
        prev_turn, prev_fade = turn, fade


def test_more_negative_cm_at_zero_is_more_understable():
    lo = _geom(parting_line_m=0.0035)
    hi = _geom(parting_line_m=0.0098)
    cm0_lo, _ = C.cm_anchors_from_geometry(lo)
    cm0_hi, _ = C.cm_anchors_from_geometry(hi)
    assert cm0_lo < cm0_hi
    assert C.flight_numbers_from_cm(cm0_lo, 0)[0] < C.flight_numbers_from_cm(cm0_hi, 0)[0]


def test_blunter_nose_widens_the_turn_fade_split():
    thin = _geom(rim_thickness_m=0.0040)
    blunt = _geom(rim_thickness_m=0.0090)
    t_thin, f_thin = C.flight_numbers_from_cm(*C.cm_anchors_from_geometry(thin))
    t_blunt, f_blunt = C.flight_numbers_from_cm(*C.cm_anchors_from_geometry(blunt))
    assert f_blunt > f_thin      # more fade
    assert t_blunt < t_thin      # and more turn: a wider split at fixed cm_bar


def test_shape_inference_inverts_the_forward_model():
    for turn, fade in [(0, 1), (0, 4), (-4, 1), (-1, 3), (-2, 1), (-1, 2)]:
        for depth, width in [(0.011, 0.017), (0.015, 0.009), (0.012, 0.022)]:
            parting, nose = C.infer_shape_from_flight(turn, fade, depth, width)
            g = _geom(rim_depth_m=depth, rim_width_m=width,
                      parting_line_m=parting, rim_thickness_m=nose)
            t, f = C.flight_numbers_from_cm(*C.cm_anchors_from_geometry(g))
            assert t == pytest.approx(turn, abs=1e-6)
            assert f == pytest.approx(fade, abs=1e-6)


def test_inferred_profiles_are_manufacturable():
    """Every roster disc's inferred parting line and nose must be a real shape."""
    for e in ROSTER:
        fn, p = e["flight_numbers"], e["pdga"]
        depth, width = p["rim_depth_cm"] / 100.0, p["rim_thickness_cm"] / 100.0
        parting, nose = C.infer_shape_from_flight(fn["turn"], fn["fade"], depth, width)
        assert 0.0015 < parting < depth, f"{e['id']} parting {parting}"
        assert 0.003 < nose < 0.009, f"{e['id']} nose {nose}"
        assert 0.20 < parting / depth < 0.90, f"{e['id']} parting ratio"


# ---------------------------------------------------------------------------
# the affine map itself
# ---------------------------------------------------------------------------
def test_affine_map_hits_both_anchors_exactly():
    for e in ROSTER:
        fn, p = e["flight_numbers"], e["pdga"]
        parting, nose = C.infer_shape_from_flight(
            fn["turn"], fn["fade"], p["rim_depth_cm"] / 100.0, p["rim_thickness_cm"] / 100.0)
        g = _geom(diameter_m=p["diameter_cm"] / 100.0,
                  rim_width_m=p["rim_thickness_cm"] / 100.0,
                  rim_depth_m=p["rim_depth_cm"] / 100.0,
                  parting_line_m=parting, rim_thickness_m=nose)
        cs = C.build_coefficients(g, glide=fn["glide"], speed=fn["speed"])
        i0 = int(np.argmin(np.abs(cs.alpha_deg - 0.0)))
        i10 = int(np.argmin(np.abs(cs.alpha_deg - 10.0)))
        assert cs.cm[i0] == pytest.approx(cs.cm0, abs=1e-9)
        assert cs.cm[i10] == pytest.approx(cs.cm10, abs=1e-9)


def test_affine_gain_is_positive_so_the_curve_cannot_be_flipped():
    for e in ROSTER:
        fn, p = e["flight_numbers"], e["pdga"]
        parting, nose = C.infer_shape_from_flight(
            fn["turn"], fn["fade"], p["rim_depth_cm"] / 100.0, p["rim_thickness_cm"] / 100.0)
        g = _geom(diameter_m=p["diameter_cm"] / 100.0,
                  rim_width_m=p["rim_thickness_cm"] / 100.0,
                  rim_depth_m=p["rim_depth_cm"] / 100.0,
                  parting_line_m=parting, rim_thickness_m=nose)
        cs = C.build_coefficients(g, glide=fn["glide"], speed=fn["speed"])
        assert cs.cm_gain > 0.0


def test_correction_tapers_back_to_the_measured_curve_at_the_extremes():
    g = _geom(parting_line_m=0.0095)
    cs = C.build_coefficients(g, glide=5, speed=9, base_case="cd1")
    base = C.measured_coefficients("cd1", cs.alpha_deg)
    outer = np.abs(cs.alpha_deg) >= C.TAPER_ZERO_DEG
    assert np.allclose(cs.cm[outer], base.cm[outer], atol=1e-12)
    assert np.allclose(cs.cl[outer], base.cl[outer], atol=1e-12)
    assert np.allclose(cs.cd[outer], base.cd[outer], atol=1e-12)
    # ... and CM at edge-on stays essentially zero, as symmetry requires.
    assert abs(cs.cm[0]) < 0.01 and abs(cs.cm[-1]) < 0.01


def test_base_case_selection_prefers_the_nearest_measured_disc():
    assert C.choose_base_case(9, 0, 4) == "cd1"      # Firebird
    assert C.choose_base_case(7, 0, 2) == "fd2"      # Teebird
    assert C.choose_base_case(9, -4, 1) == "cd5"     # Roadrunner
    assert C.choose_base_case(12, -1, 3) == "dd2"
    assert C.choose_base_case(2, 0, 1) == "fd2"      # putter -> nearest is Teebird


def test_measured_coefficients_are_untouched_at_the_knots():
    for case in CASES:
        d = C.measured_case(case)
        cs = C.measured_coefficients(case)
        for a, cl, cd, cm in zip(d["alpha_deg"], d["cl"], d["cd"], d["cm"]):
            i = int(np.argmin(np.abs(cs.alpha_deg - a)))
            assert cs.cl[i] == pytest.approx(cl, abs=1e-12)
            assert cs.cd[i] == pytest.approx(cd, abs=1e-12)
            assert cs.cm[i] == pytest.approx(cm, abs=1e-12)


def test_cd_stays_positive_and_cl_slope_is_disc_golf_not_ultimate():
    for e in ROSTER:
        fn, p = e["flight_numbers"], e["pdga"]
        parting, nose = C.infer_shape_from_flight(
            fn["turn"], fn["fade"], p["rim_depth_cm"] / 100.0, p["rim_thickness_cm"] / 100.0)
        g = _geom(diameter_m=p["diameter_cm"] / 100.0,
                  rim_width_m=p["rim_thickness_cm"] / 100.0,
                  rim_depth_m=p["rim_depth_cm"] / 100.0,
                  parting_line_m=parting, rim_thickness_m=nose)
        cs = C.build_coefficients(g, glide=fn["glide"], speed=fn["speed"])
        assert (cs.cd > 0).all()
        m = (cs.alpha_deg >= -4) & (cs.alpha_deg <= 8)
        slope = np.polyfit(np.radians(cs.alpha_deg[m]), cs.cl[m], 1)[0]
        # Measured golf discs sit at 2.4-2.6 /rad; Hummel's Ultimate disc at 1.91.
        assert 2.0 < slope < 3.2, f"{e['id']} CL_alpha = {slope:.2f}/rad"
        assert abs(slope - 1.9124) > 0.3


def test_hummel_cl_cd_cm_are_not_used_anywhere():
    """Guard against someone reaching for the wrong dataset later."""
    src = (Path(__file__).parent / "coefficients.py").read_text()
    hum = C.load_hummel()["fitted_coefficients_ultimate_disc"]
    for key in ("CL0", "CLalpha", "CD0", "CDalpha", "CM0", "CMalpha"):
        assert f"{hum[key]}" not in src.replace("1.9124", "")  # the docstring mentions it


def test_damping_records_the_recalibration_of_c_nr():
    assert C.DAMPING["c_mq"] == C.load_hummel()["damping_long_flight_fit"]["CMq"]
    assert C.DAMPING["c_rp"] == C.load_hummel()["damping_long_flight_fit"]["CRp"]
    # c_nr is deliberately NOT Hummel's number, and says so.
    assert C.DAMPING["c_nr"] != C.load_hummel()["damping_long_flight_fit"]["CNr"]
    assert C.DAMPING_PROVENANCE["c_nr_hummel_2003_raw"] == -3.41e-5
    assert "RECALIBRATED" in C.DAMPING_PROVENANCE["c_nr"]


def test_shipped_roster_speed_prediction_field_is_consistent():
    doc = json.loads(DISCS_JSON.read_text())
    for entry in doc["discs"]:
        assert entry["speed_predicted_from_rim_width"] == pytest.approx(
            C.predict_speed(entry["geometry"]["rim_width_m"]), abs=0.01)

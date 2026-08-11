"""Tests for the baked data: interpolation behaviour, schema, and provenance."""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest
from scipy.interpolate import CubicSpline, PchipInterpolator

from tools.aero import bake as B
from tools.aero import coefficients as C
from tools.aero.roster import ROSTER, MEASURED_LINKS

REPO_ROOT = Path(__file__).resolve().parents[2]
DATA_DIR = REPO_ROOT / "game" / "data"
AERO_DIR = DATA_DIR / "aero"
CASES = ("cd1", "fd2", "cd5", "dd2")


@pytest.fixture(scope="module")
def discs():
    return json.loads((DATA_DIR / "discs.json").read_text())


@pytest.fixture(scope="module")
def tables():
    return {p.stem: json.loads(p.read_text()) for p in sorted(AERO_DIR.glob("*.json"))}


# ---------------------------------------------------------------------------
# PCHIP: the whole reason for the choice
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("key", ["cl", "cd", "cm"])
def test_pchip_never_overshoots_the_knot_envelope(case, key):
    """Shape preservation: between any two knots the interpolant must stay
    inside the interval they bound. This is what stops a resample from
    inventing an extremum that is not in the measured data."""
    d = C.measured_case(case)
    a = np.asarray(d["alpha_deg"], float)
    y = np.asarray(d[key], float)
    f = PchipInterpolator(a, y)
    for i in range(len(a) - 1):
        fine = np.linspace(a[i], a[i + 1], 41)
        vals = f(fine)
        lo, hi = min(y[i], y[i + 1]), max(y[i], y[i + 1])
        assert vals.min() >= lo - 1e-12
        assert vals.max() <= hi + 1e-12


@pytest.mark.parametrize("case", CASES)
def test_a_natural_cubic_spline_would_have_overshot(case):
    """The counterfactual, measured rather than asserted.

    A natural cubic spline through the same knots overshoots the local envelope,
    and on CM it does so near alpha = 0 where the sign of CM *is* the turn/fade
    behaviour. That would be fabricated stability, which is why the contract
    forbids it.
    """
    d = C.measured_case(case)
    a = np.asarray(d["alpha_deg"], float)
    cm = np.asarray(d["cm"], float)
    natural = CubicSpline(a, cm, bc_type="natural")
    fine = np.arange(-90.0, 90.0 + 1e-9, 0.5)

    worst = 0.0
    for i in range(len(a) - 1):
        seg = fine[(fine >= a[i]) & (fine <= a[i + 1])]
        if not len(seg):
            continue
        lo, hi = min(cm[i], cm[i + 1]), max(cm[i], cm[i + 1])
        v = natural(seg)
        worst = max(worst, float(np.max(np.maximum(lo - v, v - hi))))
    assert worst > 1e-4, "expected the natural spline to overshoot; it did not"

    # And PCHIP does not.
    pchip = PchipInterpolator(a, cm)
    for i in range(len(a) - 1):
        seg = fine[(fine >= a[i]) & (fine <= a[i + 1])]
        if not len(seg):
            continue
        lo, hi = min(cm[i], cm[i + 1]), max(cm[i], cm[i + 1])
        v = pchip(seg)
        assert v.min() >= lo - 1e-12 and v.max() <= hi + 1e-12


@pytest.mark.parametrize("case", CASES)
def test_pchip_does_not_add_cm_sign_changes(case):
    """A resample must not change how many times CM crosses zero."""
    d = C.measured_case(case)
    a = np.asarray(d["alpha_deg"], float)
    cm = np.asarray(d["cm"], float)
    fine = np.arange(-90.0, 90.0 + 1e-9, 0.5)
    resampled = PchipInterpolator(a, cm)(fine)

    def crossings(y):
        s = np.sign(y)
        s = s[s != 0]
        return int(np.sum(s[1:] != s[:-1]))

    assert crossings(resampled) == crossings(cm)


def test_shipped_tables_are_pchip_of_the_source(tables):
    """The measured tables must be exactly a PCHIP resample, nothing else."""
    grid = np.arange(-90.0, 90.0 + 1e-9, 0.5)
    for disc_id, link in MEASURED_LINKS.items():
        t = tables[disc_id]
        d = C.measured_case(link["case"])
        a = np.asarray(d["alpha_deg"], float)
        for key in ("cl", "cd", "cm"):
            want = PchipInterpolator(a, np.asarray(d[key], float))(grid)
            assert np.allclose(np.asarray(t[key]), want, atol=1e-6)


# ---------------------------------------------------------------------------
# CONTRACT §3 schema
# ---------------------------------------------------------------------------
def test_grid_is_uniform_half_degree_over_the_full_range(tables):
    assert tables, "no baked tables found"
    for name, t in tables.items():
        a = np.asarray(t["alpha_deg"], float)
        assert len(a) == 361, name
        assert a[0] == -90.0 and a[-1] == 90.0
        assert np.all(np.diff(a) > 0), f"{name} alpha_deg not strictly ascending"
        assert np.allclose(np.diff(a), 0.5)


def test_table_arrays_are_aligned_and_finite(tables):
    for name, t in tables.items():
        n = len(t["alpha_deg"])
        for key in ("cl", "cd", "cm"):
            assert len(t[key]) == n, f"{name}.{key}"
            assert np.all(np.isfinite(t[key]))


def test_required_schema_fields(tables):
    for name, t in tables.items():
        assert t["schema"] == 1
        assert t["id"] == name
        assert t["source"]
        assert t["aero_provenance"] in ("measured", "derived")
        for key in ("c_mq", "c_rp", "c_nr"):
            assert isinstance(t["damping"][key], float)


def test_damping_block_is_identical_across_tables(tables):
    blocks = {json.dumps({k: v for k, v in t["damping"].items() if k != "provenance"},
                         sort_keys=True) for t in tables.values()}
    assert len(blocks) == 1


def test_cd_is_positive_and_cl_cm_bounded(tables):
    for name, t in tables.items():
        assert min(t["cd"]) > 0.0, name
        assert max(np.abs(t["cl"])) < 2.5, name
        assert max(np.abs(t["cm"])) < 0.5, name


def test_cm_is_near_zero_edge_on(tables):
    """Symmetry: a disc presented edge-on has no pitching moment."""
    for name, t in tables.items():
        assert abs(t["cm"][0]) < 0.02, name
        assert abs(t["cm"][-1]) < 0.02, name


# ---------------------------------------------------------------------------
# roster
# ---------------------------------------------------------------------------
def test_roster_has_at_least_fourteen_real_discs(discs):
    assert len(discs["discs"]) >= 14


def test_roster_spans_the_categories(discs):
    cats = {d["category"] for d in discs["discs"]}
    for want in ("putter", "approach", "midrange", "fairway_driver",
                 "distance_driver", "control_driver"):
        assert want in cats


def test_roster_spans_manufacturers(discs):
    assert len({d["manufacturer"] for d in discs["discs"]}) >= 4


def test_required_discs_are_present_with_the_right_ratings(discs):
    want = {
        "aviar": (2, 3, 0, 1), "buzzz": (5, 4, -1, 1), "teebird": (7, 5, 0, 2),
        "leopard": (6, 5, -2, 1), "destroyer": (12, 5, -1, 3),
        "wraith": (11, 5, -1, 3), "firebird": (9, 3, 0, 4),
        "roadrunner": (9, 5, -4, 1), "boss": (13, 5, -1, 2),
    }
    got = {d["id"]: d["flight_numbers"] for d in discs["discs"]}
    for disc_id, (s, g, t, f) in want.items():
        assert disc_id in got, disc_id
        assert (got[disc_id]["speed"], got[disc_id]["glide"],
                got[disc_id]["turn"], got[disc_id]["fade"]) == (s, g, t, f)


def test_exactly_four_discs_are_marked_measured(discs):
    meas = [d for d in discs["discs"] if d["aero_provenance"] == "measured"]
    assert len(meas) == 4
    assert {d["id"] for d in meas} == set(MEASURED_LINKS)
    for d in meas:
        assert d["aero_source"].startswith("giljarhus2022:")
        assert d["measured_link"]["confidence"] in ("exact", "class_match")


def test_the_class_matched_disc_says_so(discs):
    """dd2 is not named upstream. The roster must not pretend otherwise."""
    dest = next(d for d in discs["discs"] if d["id"] == "destroyer")
    assert dest["measured_link"]["confidence"] == "class_match"
    assert "does not state" in dest["measured_link"]["note"]


def test_every_disc_points_at_an_existing_table(discs, tables):
    for d in discs["discs"]:
        assert d["aero"] in tables
        assert tables[d["aero"]]["aero_provenance"] == d["aero_provenance"]


def test_geometry_provenance_is_recorded_per_field(discs):
    for d in discs["discs"]:
        gp = d["geometry_provenance"]
        for field in d["geometry"]:
            assert field in gp, f"{d['id']} missing provenance for {field}"
        assert gp["parting_line_m"] == "inferred_from_flight_numbers"
        assert gp["rim_thickness_m"] == "inferred_from_flight_numbers"
        assert gp["mass_kg"] == "estimated_typical_throwing_weight"


def test_provenance_summary_declares_the_caveats(discs):
    ps = discs["provenance_summary"]
    assert ps["regression_n"] == 4
    joined = " ".join(ps["caveats"]).lower()
    assert "n = 4" in joined
    assert "glide" in joined
    assert "inferred" in joined


# ---------------------------------------------------------------------------
# round trip
# ---------------------------------------------------------------------------
def test_derived_discs_round_trip_their_published_flight_numbers(discs, tables):
    """Bake a disc from its ratings, read the anchors back off the finished
    table, invert the regressions, and land on the ratings you started with."""
    for d in discs["discs"]:
        if d["aero_provenance"] != "derived":
            continue
        anchors = tables[d["aero"]]["anchors"]
        assert anchors["turn_recovered"] == pytest.approx(d["flight_numbers"]["turn"], abs=0.05)
        assert anchors["fade_recovered"] == pytest.approx(d["flight_numbers"]["fade"], abs=0.05)


def test_measured_discs_show_the_real_regression_residual(discs, tables):
    """The measured discs use raw CFD data, so their round trip shows the n = 4
    regression error rather than a construction identity. Bound it, and make
    sure it is not silently zero — that would mean we had fitted them."""
    errs = []
    for disc_id in MEASURED_LINKS:
        d = next(x for x in discs["discs"] if x["id"] == disc_id)
        anchors = tables[d["aero"]]["anchors"]
        errs.append(abs(anchors["turn_recovered"] - d["flight_numbers"]["turn"]))
        errs.append(abs(anchors["fade_recovered"] - d["flight_numbers"]["fade"]))
    assert max(errs) < 1.0, f"worst regression residual {max(errs):.2f} rating points"
    assert max(errs) > 0.05, "a perfect round trip would mean these were fitted, not measured"


def test_stability_ordering_survives_the_bake(discs, tables):
    """More overstable published rating -> more positive CM(0) in the shipped
    table. If the bake ever inverted a sign this catches it."""
    rows = [(d["flight_numbers"]["turn"], tables[d["aero"]]["anchors"]["cm_at_0deg"])
            for d in discs["discs"] if d["aero_provenance"] == "derived"]
    rows.sort()
    cms = [c for _, c in rows]
    assert cms == sorted(cms)


def test_bake_is_reproducible(discs, tables):
    """A fresh bake must reproduce exactly what is committed."""
    assert B.bake(check_only=True) == 0

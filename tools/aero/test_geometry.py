"""Tests for the geometry parameterisation and the inertia integration."""

from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np
import pytest

from tools.aero import coefficients as C
from tools.aero.geometry import (
    DEFAULT_PLATE_THICKNESS_M,
    GeometryError,
    geometry_from_pdga,
    make_geometry,
)
from tools.aero.roster import ROSTER, by_id

REPO_ROOT = Path(__file__).resolve().parents[2]
DISCS_JSON = REPO_ROOT / "game" / "data" / "discs.json"


def _geom_for(disc_id: str):
    e = by_id(disc_id)
    fn, p = e["flight_numbers"], e["pdga"]
    parting, nose = C.infer_shape_from_flight(
        fn["turn"], fn["fade"], p["rim_depth_cm"] / 100.0, p["rim_thickness_cm"] / 100.0
    )
    return geometry_from_pdga(
        diameter_cm=p["diameter_cm"], height_cm=p["height_cm"],
        rim_depth_cm=p["rim_depth_cm"], rim_thickness_cm=p["rim_thickness_cm"],
        mass_kg=e["mass_kg"], parting_line_m=parting, nose_thickness_m=nose,
    )


# ---------------------------------------------------------------------------
# reference area — the correction CONTRACT §2 is emphatic about
# ---------------------------------------------------------------------------
def test_reference_area_is_disc_golf_not_ultimate():
    g = _geom_for("firebird")
    assert g.diameter_m == pytest.approx(0.211)
    assert g.area_m2 == pytest.approx(0.03497, abs=5e-5)
    # The Ultimate-frisbee figure that most references quote, and which would
    # inflate every aerodynamic force by ~62%.
    assert abs(g.area_m2 - 0.0568) > 0.02


# ---------------------------------------------------------------------------
# inertia against the scanned CFD discs
# ---------------------------------------------------------------------------
#: Specific moments of inertia (I / mass, m^2) computed by trimesh from the
#: scanned STL meshes, straight out of the upstream YAML. These are the only
#: independent measurements of disc golf disc inertia we have.
SCANNED = {
    "firebird": ("cd1", 3.759e-3, 7.485e-3),
    "teebird": ("fd2", 3.809e-3, 7.577e-3),
    "roadrunner": ("cd5", 3.829e-3, 7.616e-3),
    "destroyer": ("dd2", 3.755e-3, 7.465e-3),
}


@pytest.mark.parametrize("disc_id", sorted(SCANNED))
def test_inertia_matches_scanned_discs(disc_id):
    """The solid-of-revolution integral must reproduce the scanned meshes.

    Tolerance is 12%: three of the four land inside 1.1%, the Teebird lands at
    -9.6%. The mould that was scanned is not necessarily the mould the PDGA
    measured (the Teebird has been retooled repeatedly), so we assert a bound
    that catches a broken integral without pretending to millimetre agreement.
    """
    case, j_xy, j_z = SCANNED[disc_id]
    g = _geom_for(disc_id)
    assert g.I_zz / g.mass_kg == pytest.approx(j_z, rel=0.12)
    assert g.I_xy / g.mass_kg == pytest.approx(j_xy, rel=0.12)

    ref = C.measured_case(case)
    assert g.I_zz / g.mass_kg == pytest.approx(ref["J_z_m2"], rel=0.12)


def test_inertia_hits_the_contract_reference_values():
    """CONTRACT §2 quotes ~0.00131 and ~0.00066 kg m^2 for a 175 g golf disc."""
    g = _geom_for("destroyer")
    assert g.I_zz == pytest.approx(0.00131, rel=0.08)
    assert g.I_xy == pytest.approx(0.00066, rel=0.08)
    # And explicitly not the Ultimate values.
    assert g.I_zz < 0.0018 and g.I_xy < 0.0009


def test_thin_rim_putter_and_wide_rim_driver_genuinely_differ():
    """The whole point of integrating rather than hardcoding a constant."""
    putter, driver = _geom_for("aviar"), _geom_for("boss")
    assert putter.I_zz < driver.I_zz
    # Not a rounding-level difference.
    assert (driver.I_zz - putter.I_zz) / driver.I_zz > 0.10


def test_inertia_ratio_is_near_one_half():
    """For any flat solid of revolution I_xy ~ I_zz/2, slightly above."""
    for e in ROSTER:
        g = _geom_for(e["id"])
        ratio = g.I_xy / g.I_zz
        assert 0.50 <= ratio <= 0.56, f"{e['id']} I_xy/I_zz = {ratio}"


def test_inertia_quadrature_has_converged():
    g = _geom_for("destroyer")
    default = g._mass_integrals()
    fine = g._mass_integrals(n=16001)
    assert default["i_zz_v"] / default["volume"] == pytest.approx(
        fine["i_zz_v"] / fine["volume"], rel=1e-4)
    # The profile has slope discontinuities at the rim/plate join, so the
    # trapezoid rule converges at first order; 200 stations is visibly coarse.
    coarse = g._mass_integrals(n=201)
    assert abs(coarse["i_zz_v"] / coarse["volume"]
               - fine["i_zz_v"] / fine["volume"]) / (fine["i_zz_v"] / fine["volume"]) < 1e-3


# ---------------------------------------------------------------------------
# physical plausibility
# ---------------------------------------------------------------------------
def test_every_roster_disc_implies_real_plastic_density():
    """If the profile model were wrong the implied density would drift off."""
    for e in ROSTER:
        g = _geom_for(e["id"])
        assert 750.0 <= g.density_kg_m3 <= 1400.0, f"{e['id']}: {g.density_kg_m3}"


def test_cross_section_is_non_negative_and_closes():
    for e in ROSTER:
        g = _geom_for(e["id"])
        r, z_lo, z_hi = g.cross_section(801)
        assert (z_hi >= z_lo - 1e-12).all()
        assert (z_lo >= -1e-12).all()
        assert z_hi[0] == pytest.approx(g.rim_depth_m + DEFAULT_PLATE_THICKNESS_M
                                        + g.dome_height_m)
        assert (z_hi[-1] - z_lo[-1]) == pytest.approx(g.rim_thickness_m, abs=1e-9)


def test_derived_ratios():
    g = _geom_for("firebird")
    assert g.parting_ratio == pytest.approx(g.parting_line_m / g.rim_depth_m)
    assert g.nose_ratio == pytest.approx(g.rim_thickness_m / g.rim_depth_m)
    assert 0.10 < g.parting_ratio < 0.95


# ---------------------------------------------------------------------------
# validation
# ---------------------------------------------------------------------------
def _valid_kwargs():
    return dict(diameter_m=0.211, mass_kg=0.175, rim_width_m=0.022,
                rim_depth_m=0.012, rim_thickness_m=0.007, parting_line_m=0.006,
                dome_height_m=0.0002, inner_rim_edge_m=0.0835)


def test_valid_parameters_build():
    g = make_geometry(**_valid_kwargs())
    assert g.I_zz > 0 and g.I_xy > 0


@pytest.mark.parametrize("field,value", [
    ("diameter_m", 0.35),
    ("mass_kg", 0.400),
    ("rim_width_m", 0.001),
    ("rim_depth_m", 0.001),
])
def test_out_of_range_parameters_raise(field, value):
    kw = _valid_kwargs()
    kw[field] = value
    with pytest.raises(GeometryError):
        make_geometry(**kw)


def test_inconsistent_inner_rim_edge_raises():
    kw = _valid_kwargs()
    kw["inner_rim_edge_m"] = 0.070
    with pytest.raises(GeometryError):
        make_geometry(**kw)


def test_parting_line_above_flight_plate_raises():
    kw = _valid_kwargs()
    kw["parting_line_m"] = kw["rim_depth_m"] + 0.001
    with pytest.raises(GeometryError):
        make_geometry(**kw)


def test_missing_parameter_raises():
    kw = _valid_kwargs()
    del kw["dome_height_m"]
    with pytest.raises(GeometryError):
        make_geometry(**kw)


def test_low_parting_line_warns_rather_than_raises():
    kw = _valid_kwargs()
    kw["parting_line_m"] = 0.0015
    kw["rim_thickness_m"] = 0.008
    g = make_geometry(**kw)
    assert any("ground plane" in w for w in g.warnings)


# ---------------------------------------------------------------------------
# what actually shipped
# ---------------------------------------------------------------------------
def test_shipped_discs_json_geometry_round_trips():
    doc = json.loads(DISCS_JSON.read_text())
    for entry in doc["discs"]:
        g = make_geometry(**entry["geometry"])
        assert g.area_m2 == pytest.approx(entry["derived"]["area_m2"], rel=1e-4)
        assert g.I_zz == pytest.approx(entry["derived"]["I_zz"], rel=1e-3)
        assert g.I_xy == pytest.approx(entry["derived"]["I_xy"], rel=1e-3)
        assert g.parting_ratio == pytest.approx(entry["derived"]["parting_ratio"], abs=1e-3)


def test_shipped_geometry_matches_published_pdga_numbers():
    """Nothing in the published PDGA block may be quietly altered on the way in."""
    doc = json.loads(DISCS_JSON.read_text())
    for entry in doc["discs"]:
        p = entry["geometry_provenance"]["_pdga_record"]
        g = entry["geometry"]
        assert g["diameter_m"] == pytest.approx(p["diameter_cm"] / 100.0)
        assert g["rim_width_m"] == pytest.approx(p["rim_thickness_cm"] / 100.0)
        assert g["rim_depth_m"] == pytest.approx(p["rim_depth_cm"] / 100.0)
        assert g["inner_rim_edge_m"] == pytest.approx(
            0.5 * p["diameter_cm"] / 100.0 - p["rim_thickness_cm"] / 100.0)
        assert g["mass_kg"] * 1000.0 <= p["max_weight_g"] + 1e-9

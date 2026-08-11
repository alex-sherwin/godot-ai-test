"""Tests for the reference integrator, including the CONTRACT §5 sanity targets.

Where a target is not met, the test says so explicitly (``xfail(strict=True)``)
rather than being loosened until it passes. A model that hits one number by
tuning is worse than one that misses it honestly.
"""

from __future__ import annotations

import math

import numpy as np
import pytest

from tools.aero import validate as V


@pytest.fixture(scope="module")
def destroyer():
    return V.load_disc("destroyer")


def _throw(**kw):
    kw.setdefault("launch_height_m", 1.4)
    return V.ThrowParams(**kw)


# ---------------------------------------------------------------------------
# integrator mechanics
# ---------------------------------------------------------------------------
def test_ballistic_limit_matches_the_closed_form(destroyer):
    """Zero out the aerodynamics and the integrator must be a projectile."""
    table = V.AeroTable(
        alpha_deg=np.array([-90.0, 90.0]), cl=np.zeros(2), cd=np.zeros(2),
        cm=np.zeros(2), damping={"c_mq": 0.0, "c_rp": 0.0, "c_nr": 0.0})
    disc = V.DiscDefinition("ballistic", destroyer.mass_kg, destroyer.diameter_m,
                            destroyer.area_m2, destroyer.I_zz, destroyer.I_xy, table)
    u, ang, h = 20.0, math.radians(30.0), 1.4
    r = V.simulate(disc, _throw(speed_mps=u, spin_rps=20.0, launch_angle_rad=ang,
                                launch_height_m=h))
    vy = u * math.sin(ang)
    t = (vy + math.sqrt(vy * vy + 2 * 9.81 * h)) / 9.81
    assert r.flight_time_s == pytest.approx(t, rel=2e-3)
    assert r.distance_m == pytest.approx(u * math.cos(ang) * t, rel=2e-3)
    assert abs(r.lateral_m) < 1e-6


def test_ground_crossing_is_interpolated(destroyer):
    """A whole 1/240 substep at 25 m/s is 10 cm of landing error."""
    r = V.simulate(destroyer, _throw(**CANONICAL_DRIVE))
    assert r.landed
    assert abs(r.samples[-1]["pos"][1]) < 1e-3


def test_disc_normal_stays_a_unit_vector(destroyer):
    r = V.simulate(destroyer, _throw(**CANONICAL_DRIVE))
    for s in r.samples:
        # Samples round the normal to 6 dp on the way out.
        assert np.linalg.norm(s["normal"]) == pytest.approx(1.0, abs=1e-5)


def test_step_size_is_converged(destroyer):
    p = _throw(speed_mps=27.0, spin_rps=25.0, launch_angle_rad=math.radians(13.0),
               hyzer_angle_rad=math.radians(22.0))
    coarse = V.simulate(destroyer, p, dt=1.0 / 120.0)
    fine = V.simulate(destroyer, p, dt=1.0 / 960.0)
    assert coarse.distance_m == pytest.approx(fine.distance_m, rel=3e-3)
    assert coarse.lateral_m == pytest.approx(fine.lateral_m, abs=0.5)


def test_isa_density():
    assert V.air_density(0.0, 15.0) == pytest.approx(1.225, abs=2e-3)
    assert V.air_density(1600.0, 15.0) < 1.10   # Denver-ish, thinner air


def test_vanishing_air_density_converges_to_ballistic(destroyer):
    """The unambiguous density check. Thinner air is *not* simply "flies
    further" for a disc — less air means less lift as well as less drag, and the
    two do not cancel — so the honest assertion is the limit."""
    p = _throw(speed_mps=27.0, spin_rps=25.0, launch_angle_rad=math.radians(12.0))
    vy = 27.0 * math.sin(math.radians(12.0))
    t_ball = (vy + math.sqrt(vy * vy + 2 * 9.81 * 1.4)) / 9.81
    d_ball = 27.0 * math.cos(math.radians(12.0)) * t_ball
    # Not monotone at ordinary densities: halving rho lengthens the flight
    # before it shortens it, because lift falls off more slowly than the disc
    # sinks. The limit is what has to hold.
    prev = None
    for rho in (0.2, 0.05, 0.01, 0.002):
        r = V.simulate(destroyer, p, V.Environment(air_density=rho))
        err = abs(r.distance_m - d_ball)
        if prev is not None:
            assert err < prev, f"rho={rho}: {err:.2f} vs {prev:.2f}"
        prev = err
    assert prev < 1.0


def test_headwind_and_tailwind_behave_the_way_discs_actually_do(destroyer):
    """A headwind raises the relative airspeed: the disc turns over more and
    lands shorter. A tailwind lowers it: less lift, so the disc sits down and
    finishes more overstable. Both are the behaviour players describe, and both
    fall out of the model rather than being special-cased."""
    p = _throw(speed_mps=27.0, spin_rps=25.0, launch_angle_rad=math.radians(13.0),
               hyzer_angle_rad=math.radians(22.0))
    calm = V.simulate(destroyer, p, V.Environment())
    head = V.simulate(destroyer, p, V.Environment(wind=np.array([0.0, 0.0, 5.0])))
    tail = V.simulate(destroyer, p, V.Environment(wind=np.array([0.0, 0.0, -5.0])))

    assert head.distance_m < calm.distance_m
    assert head.max_right_m > calm.max_right_m      # headwind flips the disc over
    assert tail.max_height_m < calm.max_height_m    # tailwind kills the lift
    assert tail.lateral_m < calm.lateral_m          # and finishes harder left


# ---------------------------------------------------------------------------
# CONTRACT §5 sanity targets
# ---------------------------------------------------------------------------
CANONICAL_DRIVE = dict(speed_mps=27.0, spin_rps=25.0,
                       launch_angle_rad=math.radians(13.0),
                       hyzer_angle_rad=math.radians(22.0))


def test_distance_driver_hits_the_contract_distance_band(destroyer):
    """12/5/-1/3 at ~27 m/s, ~25 rev/s, small hyzer -> 105-130 m."""
    r = V.simulate(destroyer, _throw(**CANONICAL_DRIVE))
    assert 105.0 <= r.distance_m <= 130.0, f"{r.distance_m:.1f} m"


def test_distance_driver_turns_right_then_fades_left(destroyer):
    r = V.simulate(destroyer, _throw(**CANONICAL_DRIVE))
    assert r.max_right_m > 5.0, "no visible early right turn"
    assert r.lateral_m < r.max_right_m - 5.0, "no left fade finish"
    # And the sign flip lives in CM, not in spin decay.
    cms = [s["cm"] for s in r.samples]
    assert min(cms) < 0.0 < max(cms)


def test_the_distance_target_is_release_angle_sensitive():
    """Honesty guard on the test above: the §5 band is reachable across a range
    of releases, not at one lucky point, but it *is* sensitive — at 27 m/s a
    12-speed is understable, so the release is a hyzer-flip. If this ever drops
    to a single row, the single-throw test is measuring luck."""
    rows = V.hyzer_sweep("destroyer")
    hits = [r for r in rows if r["meets_contract_5"]]
    assert len(hits) >= 3, f"only {len(hits)} of {len(rows)} releases meet §5"
    assert 8.0 < min(r["hyzer_deg"] for r in hits) < 30.0


def test_rhfh_mirrors_rhbh(destroyer):
    """Negative spin must curve the other way with no other change."""
    bh = V.simulate(destroyer, _throw(**CANONICAL_DRIVE))
    fh = V.simulate(destroyer, _throw(**{**CANONICAL_DRIVE, "spin_rps": -25.0,
                                         "hyzer_angle_rad": math.radians(-22.0)}))
    assert fh.distance_m == pytest.approx(bh.distance_m, rel=1e-6)
    assert fh.lateral_m == pytest.approx(-bh.lateral_m, abs=1e-6)
    assert fh.flight_time_s == pytest.approx(bh.flight_time_s, rel=1e-6)


def test_more_spin_means_less_turn_and_less_fade():
    """CONTRACT §5: ``Omega = tau/(I_zz*omega)``, so the attitude response must
    fall monotonically with spin. Measured on the attitude, not on landing
    drift — see ``validate.spin_sensitivity`` for why those differ."""
    rows = V.spin_sensitivity("destroyer")
    for key in ("tilt_at_1s_deg", "tilt_at_2s_deg"):
        vals = [r[key] for r in rows]
        assert all(b < a for a, b in zip(vals, vals[1:])), f"{key}: {vals}"
    assert rows[0]["tilt_at_2s_deg"] > 2.0 * rows[-1]["tilt_at_2s_deg"]


def test_overstable_disc_never_turns_right():
    r = V.simulate(V.load_disc("firebird"),
                   _throw(speed_mps=25.0, spin_rps=23.0,
                          launch_angle_rad=math.radians(12.0),
                          hyzer_angle_rad=math.radians(5.0)))
    assert r.max_right_m < 1.0
    assert r.lateral_m < -10.0


def test_understable_disc_turns_over_and_stays_right():
    """CONTRACT §5: turn -4 thrown flat and fast should turn over and may roll."""
    r = V.simulate(V.load_disc("roadrunner"),
                   _throw(speed_mps=27.0, spin_rps=24.0,
                          launch_angle_rad=math.radians(10.0)))
    tilt = [math.degrees(math.atan2(s["normal"][0], s["normal"][1])) for s in r.samples]
    assert max(tilt) > 45.0, f"only reached {max(tilt):.0f} deg of tilt — did not turn over"
    assert tilt[-1] == pytest.approx(max(tilt), abs=2.0), "it must not stand back up"
    assert r.lateral_m > 8.0
    assert r.lateral_m == pytest.approx(r.max_right_m, abs=1.0), "it must not fade back"


#: In published-turn order: 0, 0, -1, -2, -4.
STABILITY_ORDER = ("firebird", "teebird", "buzzz", "leopard", "roadrunner")


def test_stability_ordering_shows_in_the_attitude_response():
    """Thrown identically, the roster must bank in published-turn order.

    Measured on disc tilt early in the flight rather than on landing drift.
    Once a disc turns fully over, drift saturates and stops ranking stability —
    at 22 m/s the Roadrunner (turn -4) flips sooner than the Leopard (turn -2),
    dumps sooner, and therefore lands *less* far right despite being the more
    understable disc. Tilt has no such degeneracy.
    """
    p = _throw(speed_mps=22.0, spin_rps=19.0, launch_angle_rad=math.radians(10.0))
    tilt = [V._tilt_deg_at(V.simulate(V.load_disc(d), p), 0.5) for d in STABILITY_ORDER]
    assert tilt == sorted(tilt), dict(zip(STABILITY_ORDER, [round(t, 2) for t in tilt]))
    assert tilt[-1] - tilt[0] > 5.0, "stability spread is too small to be meaningful"


def test_stability_ordering_also_shows_in_landing_drift_below_flip_speed():
    """Same ordering on where the disc actually lands, at a speed where none of
    them turns over."""
    p = _throw(speed_mps=18.0, spin_rps=16.0, launch_angle_rad=math.radians(10.0))
    lat = [V.simulate(V.load_disc(d), p).lateral_m for d in STABILITY_ORDER]
    for a, b in zip(lat, lat[1:]):
        assert b >= a - 0.1, dict(zip(STABILITY_ORDER, [round(x, 2) for x in lat]))
    assert lat[-1] - lat[0] > 4.0


def test_spin_decays_by_a_realistic_fraction(destroyer):
    """Hummel's published MATLAB drops the A*d factor and loses ~4%; the
    realistic figure over a full drive is 10-20%."""
    r = V.simulate(destroyer, _throw(**CANONICAL_DRIVE))
    assert 0.08 <= r.spin_loss_frac <= 0.22, f"{100 * r.spin_loss_frac:.1f}%"
    assert all(abs(a["spin"]) >= abs(b["spin"]) for a, b in
               zip(r.samples, r.samples[1:])), "spin must decay monotonically"


def test_putter_hits_the_contract_distance_band():
    """CONTRACT §5 v2: 2/3/0/1 putter at ~18 m/s -> 40-60 m.

    Met, but at 40.4 m it sits on the bottom edge of the band. Not tuned toward
    it: the model was unchanged by the target's correction, and the same throw
    at the superseded 13 m/s figure still returns ~20 m.
    """
    r = V.simulate(V.load_disc("aviar"),
                   _throw(speed_mps=18.0, spin_rps=14.0,
                          launch_angle_rad=math.radians(10.0)))
    assert 40.0 <= r.distance_m <= 60.0, f"{r.distance_m:.1f} m"


def test_putter_is_nearly_straight_with_a_gentle_fade():
    r = V.simulate(V.load_disc("aviar"),
                   _throw(speed_mps=18.0, spin_rps=14.0,
                          launch_angle_rad=math.radians(10.0)))
    assert abs(r.lateral_m) < 0.20 * r.distance_m
    assert r.lateral_m < 0.0, "should fade left for RHBH"


def test_putter_distance_rises_monotonically_with_release_speed():
    rows = V.putter_speed_sweep()
    assert all(b["distance_m"] > a["distance_m"] for a, b in zip(rows, rows[1:]))
    at13 = next(r for r in rows if r["speed_mps"] == 13.0)
    assert at13["distance_m"] < 30.0, (
        "the superseded 13 m/s target is still a ~20 m throw; if this ever "
        "passes 40 m without a modelling reason, something was tuned")


# ---------------------------------------------------------------------------
# cross-validation against shotshaper
# ---------------------------------------------------------------------------
def test_matches_the_published_reference_implementation():
    """Since CONTRACT §4 v2 we use shotshaper's precession law, so the whole
    integrator is checked against theirs, not just the parts around it."""
    cross = V.shotshaper_cross_check()
    for name, row in cross.items():
        ref, ours = row["shotshaper_published"], row["ours"]
        assert ours["distance_m"] == pytest.approx(ref["distance_m"], rel=0.05), name
        assert ours["flight_time_s"] == pytest.approx(ref["flight_time_s"], rel=0.10), name
        assert ours["max_height_m"] == pytest.approx(ref["max_height_m"], rel=0.10), name
    # On their own example throw the agreement is much tighter than that.
    paper = cross["paper_throw"]
    assert paper["ours"]["distance_m"] == pytest.approx(
        paper["shotshaper_published"]["distance_m"], rel=0.01)
    assert paper["ours"]["lateral_m"] == pytest.approx(
        paper["shotshaper_published"]["lateral_m"], abs=0.5)


def test_the_naive_gyroscopic_law_would_be_visibly_wrong():
    """Guard against the v1 precession law creeping back in. Dividing by I_zz
    instead of (I_zz - I_xy) halves the precession, which halves the fade: the
    flat drive nearly doubles in flight time and lands 26 m further right."""
    cross = V.shotshaper_cross_check()
    flat = cross["flat_27"]
    assert flat["ours_naive_gyroscopic"]["flight_time_s"] > 1.7 * flat["ours"]["flight_time_s"]
    assert flat["ours_naive_gyroscopic"]["lateral_m"] > flat["ours"]["lateral_m"] + 20.0


def test_precession_uses_i_zz_minus_i_xy(destroyer):
    """The correction factor for a flat disc is close to 2."""
    ratio = destroyer.I_zz / (destroyer.I_zz - destroyer.I_xy)
    assert 1.9 < ratio < 2.1


# ---------------------------------------------------------------------------
# the fixtures Track B diffs against
# ---------------------------------------------------------------------------
def test_reference_throws_all_land_and_serialise():
    import json

    out = V.run_reference_throws()
    assert len(out) >= 8
    for name, row in out.items():
        assert row["result"]["landed"], name
        assert len(row["samples"]) > 20
        json.dumps(row)  # must be JSON-serialisable for the dump
        s = row["samples"][0]
        assert set(s) >= {"t", "pos", "vel", "normal", "quat", "spin",
                          "alpha_deg", "cl", "cd", "cm"}


def test_quaternion_matches_the_normal():
    r = V.simulate(V.load_disc("teebird"),
                   _throw(speed_mps=23.0, spin_rps=20.0,
                          launch_angle_rad=math.radians(10.0),
                          hyzer_angle_rad=math.radians(3.0)))
    for s in r.samples[::20]:
        x, y, z, w = s["quat"]
        # Rotate +Y by the quaternion and compare with the stored normal.
        up = np.array([0.0, 1.0, 0.0])
        u = np.array([x, y, z])
        rot = (2.0 * np.dot(u, up) * u
               + (w * w - np.dot(u, u)) * up
               + 2.0 * w * np.cross(u, up))
        assert np.allclose(rot, s["normal"], atol=1e-5)

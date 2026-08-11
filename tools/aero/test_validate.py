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
    r = V.simulate(destroyer, _throw(speed_mps=27.0, spin_rps=25.0,
                                     launch_angle_rad=math.radians(12.0)))
    assert r.landed
    assert abs(r.samples[-1]["pos"][1]) < 1e-3


def test_disc_normal_stays_a_unit_vector(destroyer):
    r = V.simulate(destroyer, _throw(speed_mps=27.0, spin_rps=25.0,
                                     launch_angle_rad=math.radians(12.0)))
    for s in r.samples:
        # Samples round the normal to 6 dp on the way out.
        assert np.linalg.norm(s["normal"]) == pytest.approx(1.0, abs=1e-5)


def test_step_size_is_converged(destroyer):
    p = _throw(speed_mps=27.0, spin_rps=25.0, launch_angle_rad=math.radians(12.0),
               hyzer_angle_rad=math.radians(8.0))
    coarse = V.simulate(destroyer, p, dt=1.0 / 120.0)
    fine = V.simulate(destroyer, p, dt=1.0 / 960.0)
    assert coarse.distance_m == pytest.approx(fine.distance_m, rel=2e-3)
    assert coarse.lateral_m == pytest.approx(fine.lateral_m, abs=0.2)


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
    p = _throw(speed_mps=27.0, spin_rps=25.0, launch_angle_rad=math.radians(12.0),
               hyzer_angle_rad=math.radians(8.0))
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
def test_distance_driver_hits_the_contract_distance_band(destroyer):
    """12/5/-1/3 at ~27 m/s, ~25 rev/s, small hyzer -> 105-130 m."""
    r = V.simulate(destroyer, _throw(speed_mps=27.0, spin_rps=25.0,
                                     launch_angle_rad=math.radians(12.0),
                                     hyzer_angle_rad=math.radians(8.0)))
    assert 105.0 <= r.distance_m <= 130.0, f"{r.distance_m:.1f} m"


def test_distance_driver_turns_right_then_fades_left(destroyer):
    r = V.simulate(destroyer, _throw(speed_mps=27.0, spin_rps=25.0,
                                     launch_angle_rad=math.radians(12.0),
                                     hyzer_angle_rad=math.radians(8.0)))
    assert r.max_right_m > 5.0, "no visible early right turn"
    assert r.lateral_m < r.max_right_m - 4.0, "no left fade finish"
    # And the sign flip lives in CM, not in spin decay.
    cms = [s["cm"] for s in r.samples]
    assert min(cms) < 0.0 < max(cms)


def test_rhfh_mirrors_rhbh(destroyer):
    """Negative spin must curve the other way with no other change."""
    kw = dict(speed_mps=27.0, spin_rps=25.0, launch_angle_rad=math.radians(12.0),
              hyzer_angle_rad=math.radians(8.0))
    bh = V.simulate(destroyer, _throw(**kw))
    fh = V.simulate(destroyer, _throw(**{**kw, "spin_rps": -25.0,
                                         "hyzer_angle_rad": math.radians(-8.0)}))
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
    r = V.simulate(V.load_disc("roadrunner"),
                   _throw(speed_mps=25.0, spin_rps=22.0,
                          launch_angle_rad=math.radians(10.0)))
    assert r.lateral_m > 15.0, "an understable disc thrown flat and fast must turn over"
    assert r.lateral_m == pytest.approx(r.max_right_m, abs=1.0), "it must not fade back"


def test_stability_ordering_across_the_roster():
    """Thrown identically, the roster must land in published-turn order."""
    p = _throw(speed_mps=22.0, spin_rps=19.0, launch_angle_rad=math.radians(10.0))
    rows = []
    for disc_id in ("firebird", "teebird", "buzzz", "leopard", "roadrunner"):
        d = V.load_disc(disc_id)
        rows.append((d.table, V.simulate(d, p).lateral_m, disc_id))
    lat = [r[1] for r in rows]
    assert lat == sorted(lat), f"not in stability order: {[(r[2], round(r[1], 1)) for r in rows]}"


def test_spin_decays_by_a_realistic_fraction(destroyer):
    """Hummel's published MATLAB drops the A*d factor and loses ~4%; the
    realistic figure over a full drive is 10-20%."""
    r = V.simulate(destroyer, _throw(speed_mps=27.0, spin_rps=25.0,
                                     launch_angle_rad=math.radians(12.0),
                                     hyzer_angle_rad=math.radians(8.0)))
    assert 0.08 <= r.spin_loss_frac <= 0.22, f"{100 * r.spin_loss_frac:.1f}%"
    assert all(abs(a["spin"]) >= abs(b["spin"]) for a, b in
               zip(r.samples, r.samples[1:])), "spin must decay monotonically"


@pytest.mark.xfail(strict=True, reason=(
    "CONTRACT §5 asks for 40-60 m from a 2/3/0/1 putter at ~13 m/s. We get "
    "~21 m. 13 m/s is roughly a 10 m putt; the model needs ~18 m/s to reach the "
    "40-60 m band (see validate.putter_speed_sweep and game/data/README.md). "
    "Recorded as a miss rather than tuned away."))
def test_putter_hits_the_contract_distance_band():
    r = V.simulate(V.load_disc("aviar"),
                   _throw(speed_mps=13.0, spin_rps=10.0,
                          launch_angle_rad=math.radians(8.0)))
    assert 40.0 <= r.distance_m <= 60.0


def test_putter_is_nearly_straight_with_a_gentle_fade():
    """The shape of the putt is right even though the distance target is not."""
    r = V.simulate(V.load_disc("aviar"),
                   _throw(speed_mps=13.0, spin_rps=10.0,
                          launch_angle_rad=math.radians(8.0)))
    assert abs(r.lateral_m) < 0.15 * r.distance_m
    assert r.lateral_m < 0.0, "should fade left for RHBH"


def test_putter_reaches_the_band_at_realistic_putting_speed():
    rows = V.putter_speed_sweep()
    at18 = next(r for r in rows if r["speed_mps"] == 18.0)
    assert 40.0 <= at18["distance_m"] <= 60.0
    assert all(b["distance_m"] > a["distance_m"] for a, b in zip(rows, rows[1:]))


# ---------------------------------------------------------------------------
# cross-validation against shotshaper
# ---------------------------------------------------------------------------
def test_matches_shotshaper_when_the_precession_law_is_matched():
    """Everything except the precession constant is verified against the
    published reference implementation."""
    cross = V.shotshaper_cross_check()
    for name, row in cross.items():
        ref, ours = row["shotshaper_published"], row["ours_matched_precession"]
        assert ours["distance_m"] == pytest.approx(ref["distance_m"], rel=0.06), name
        assert ours["flight_time_s"] == pytest.approx(ref["flight_time_s"], rel=0.10), name
        assert ours["max_height_m"] == pytest.approx(ref["max_height_m"], rel=0.10), name


def test_euler_precession_is_half_of_shotshapers(destroyer):
    """The documented disagreement, asserted so nobody 'fixes' it by accident."""
    ratio = destroyer.I_zz / (destroyer.I_zz - destroyer.I_xy)
    assert 1.9 < ratio < 2.1


# ---------------------------------------------------------------------------
# the fixtures Track B diffs against
# ---------------------------------------------------------------------------
def test_reference_throws_all_land_and_serialise():
    import json

    out = V.run_reference_throws()
    assert len(out) >= 6
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

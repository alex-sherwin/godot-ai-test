#!/usr/bin/env python3
"""Reference 6-DOF flight integrator — the cross-validation oracle for Track B.

This is a Python implementation of exactly the physics CONTRACT §4/§5 specifies,
run against the same baked JSON tables the game loads.  Its job is to be the
thing the GDScript runtime is diffed against: identical disc, identical table,
identical throw, and the trajectories should agree to integration tolerance.

Run ``python -m tools.aero.validate --dump`` to write
``tools/aero/validation/*.json`` — named throws with full trajectories and
per-sample aerodynamic state, ready for Track B to compare row by row.

Model
-----
State is ten numbers: position, velocity, the unit normal of the non-spinning
disc frame, and a scalar spin rate.  The spin *phase* is deliberately absent —
the disc is axisymmetric so the phase angle never enters the equations of
motion, only its rate.  Dropping it removes the only stiff timescale (150 rad/s
of spin) and leaves the precession rate (~0.5 rad/s) as the fastest mode, which
is why fixed-step RK4 at 240 Hz is sufficient.

Because the disc is axisymmetric, the normal vector *is* the orientation as far
as the aerodynamics are concerned; a quaternion carrying an arbitrary phase
would add a redundant degree of freedom.  ``FlightResult.samples`` also emits a
quaternion (shortest rotation from +Y to the normal) so Track B can compare
against its ``DiscState.orientation`` directly.

Sign conventions (CONTRACT §1) — get these wrong and turn/fade invert
--------------------------------------------------------------------
* World frame Y-up, ``-Z`` downrange, ``+X`` to the thrower's right.
* ``spin > 0`` is RHBH: clockwise seen from above, so the **angular velocity
  vector points down**, along ``-normal``.  Hence ``L = -I_zz * spin * n``.
* Precession, CONTRACT §4 **v3**:

      dn/dt = -PRECESSION_GAIN * M_perp / (I_zz * spin)

  Two separate things, deliberately kept separate in the code.

  **The kinematics are the naive gyroscopic form** ``M/(I_zz*omega)``, and that
  form is exact.  It falls out of the Resal (non-spinning) frame directly:
  there ``dL/dt|frame = 0`` in steady precession and ``Omega x L`` carries no
  ``I_xy`` contribution, because the frame itself does not spin.  It also falls
  out of the body-fixed Euler equations, *provided* the steady-precession
  condition is written correctly.  The trap is setting ``omega_2_dot = 0`` in
  body axes: the disc spins at ~150 rad/s, so a transverse angular-velocity
  vector that is steady in space rotates backwards at the spin rate relative to
  those axes, giving ``omega_2_dot = -omega_3 * omega_1``, not zero.  With that
  substituted::

      I_xy*(-w3*w1) + (I_xy - I_zz)*w3*w1 = M_2
      w3*w1*[-I_xy + I_xy - I_zz]         = M_2
      -I_zz*w3*w1                         = M_2   ->   w1 = -M_2/(I_zz*w3)

  The ``I_xy`` terms cancel exactly.  Two independent derivations agree, so
  ``2M/(I_zz*omega)`` is **not** a kinematic result and must not be presented as
  one.

  **The factor of ~2 is an empirical calibration constant.**  It stands in for
  spin-dependent aerodynamics the source data cannot contain -- see
  ``PRECESSION_GAIN`` and the section below.  ``precession_gain_evidence()``
  measures the difference; ``validation/precession_gain_evidence.json`` ships it.

  The axial equation is unaffected either way: spin-down divides by ``I_zz``
  with no gain.

* Spin-down carries the full ``0.5*rho*V^2*A*d`` scaling, which Hummel's
  published MATLAB omits.  See ``coefficients.DAMPING_PROVENANCE``.
* ``hyzer_angle_rad``: positive banks the disc **left** for a RHBH throw, so a
  hyzer release finishes left.  CONTRACT §4 v2 confirms this; v1's parenthetical
  said the opposite and was wrong.

What ``PRECESSION_GAIN`` is standing in for
------------------------------------------
There is no spin-induced roll moment (``CRr``) in this model.  The Giljarhus CFD
is steady-state RANS on a **non-rotating** disc, so the dataset structurally
cannot contain *any* spin-dependent moment — an omission in the source data, not
a simplification we chose.  ``CRr`` in particular is precisely a moment that
would drive bank angle, which is what the gain is compensating for.

Transplanting Hummel's Ultimate-disc ``CRr = 0.00171`` was tried and rejected:
under her ``sqrt(d/g)`` non-dimensionalisation it produces a moment **2.25x
larger than the pitching moment** at launch, and neither sign gives a survivable
flight (the canonical drive collapses from 111.4 m to 41.8 m with ``+CRr`` and
to 20.5 m with ``-CRr``).  The number is not transferable to this frame.  Left
out, and recorded rather than fudged.

If ``CRr`` is ever measured on a *rotating* golf disc, it and
``PRECESSION_GAIN`` must be revisited **together**: adding one without reducing
the other would double-count the same physics.
"""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[2]
AERO_DIR = REPO_ROOT / "game" / "data" / "aero"
VALIDATION_DIR = Path(__file__).resolve().parent / "validation"

DT = 1.0 / 240.0
MAX_TIME_S = 30.0
# Below this the gyroscopic reduction is meaningless (precession -> infinity).
MIN_ABS_SPIN_RAD_S = 5.0

# EMPIRICAL, not derived. Kinematically this gain is 1.0: steady precession is
# exactly M/(I_zz*spin) (see the derivation in the module docstring and
# CONTRACT §4 v3). 2.0 compensates for spin-dependent aerodynamics absent from
# the source data: the Giljarhus CFD is steady-state RANS on a NON-ROTATING
# disc, so it structurally cannot contain CRr, the spin-induced rolling moment
# -- exactly a moment that would drive bank angle.
#   With 1.0: the driver flies 116 m in 9.4 s (a real drive of that distance
#             takes ~6 s), fade is roughly half of reality, and an understable
#             disc reaches only 23 deg of bank instead of turning over.
#   With 2.0: all four CONTRACT §5 targets are met and shotshaper's reference
#             throw is reproduced to within 0.6% on distance.
# If CRr is ever measured on a ROTATING golf disc, this and CRr must be
# revisited TOGETHER -- adding CRr without reducing this would double-count.
# One global constant. Never tuned per disc or per throw: if a disc needs its
# own value, its coefficient data is wrong, not the kinematics.
PRECESSION_GAIN = 2.0


# ---------------------------------------------------------------------------
# environment (CONTRACT §6)
# ---------------------------------------------------------------------------
def air_density(altitude_m: float = 0.0, temperature_c: float = 15.0) -> float:
    """ISA barometric density. Sea level at 15 C gives 1.225 kg/m^3."""
    p0, t0, lapse, g, r = 101325.0, 288.15, 0.0065, 9.80665, 287.058
    t_isa = t0 - lapse * altitude_m
    p = p0 * (t_isa / t0) ** (g / (lapse * r))
    return p / (r * (temperature_c + 273.15))


@dataclass
class Environment:
    air_density: float = 1.225
    wind: np.ndarray = field(default_factory=lambda: np.zeros(3))
    gravity: float = 9.81


@dataclass
class ThrowParams:
    speed_mps: float
    spin_rps: float                  # signed, + = RHBH
    nose_angle_rad: float = 0.0
    hyzer_angle_rad: float = 0.0     # + = hyzer = left bank for RHBH (see note)
    launch_angle_rad: float = 0.0
    launch_height_m: float = 1.4
    launch_heading_rad: float = 0.0  # 0 = straight downrange (-Z)


# ---------------------------------------------------------------------------
# disc + table
# ---------------------------------------------------------------------------
@dataclass
class AeroTable:
    """Baked CONTRACT §3 table. Lookup is plain linear interpolation on the fine
    grid — deliberately the same thing Track B does at runtime, so the oracle
    cannot be more accurate than the implementation it is checking."""

    alpha_deg: np.ndarray
    cl: np.ndarray
    cd: np.ndarray
    cm: np.ndarray
    damping: dict

    @classmethod
    def from_json(cls, path: Path) -> "AeroTable":
        d = json.loads(Path(path).read_text())
        return cls(
            alpha_deg=np.asarray(d["alpha_deg"], float),
            cl=np.asarray(d["cl"], float),
            cd=np.asarray(d["cd"], float),
            cm=np.asarray(d["cm"], float),
            damping=d["damping"],
        )

    def at(self, alpha_deg: float) -> tuple[float, float, float]:
        a = float(np.clip(alpha_deg, self.alpha_deg[0], self.alpha_deg[-1]))
        return (float(np.interp(a, self.alpha_deg, self.cl)),
                float(np.interp(a, self.alpha_deg, self.cd)),
                float(np.interp(a, self.alpha_deg, self.cm)))


@dataclass
class DiscDefinition:
    id: str
    mass_kg: float
    diameter_m: float
    area_m2: float
    I_zz: float
    I_xy: float
    table: AeroTable


def load_disc(disc_id: str, discs_json: Path | None = None) -> DiscDefinition:
    discs_json = discs_json or (REPO_ROOT / "game" / "data" / "discs.json")
    roster = json.loads(discs_json.read_text())["discs"]
    entry = next(d for d in roster if d["id"] == disc_id)
    g, dv = entry["geometry"], entry["derived"]
    return DiscDefinition(
        id=disc_id, mass_kg=g["mass_kg"], diameter_m=g["diameter_m"],
        area_m2=dv["area_m2"], I_zz=dv["I_zz"], I_xy=dv["I_xy"],
        table=AeroTable.from_json(AERO_DIR / f"{entry['aero']}.json"),
    )


# ---------------------------------------------------------------------------
# vector helpers
# ---------------------------------------------------------------------------
def _unit(v: np.ndarray) -> np.ndarray:
    n = float(np.linalg.norm(v))
    return v / n if n > 1e-12 else v


def _rotate(v: np.ndarray, axis: np.ndarray, angle: float) -> np.ndarray:
    """Rodrigues rotation."""
    k = _unit(axis)
    c, s = math.cos(angle), math.sin(angle)
    return v * c + np.cross(k, v) * s + k * float(np.dot(k, v)) * (1.0 - c)


def _quat_from_normal(n: np.ndarray) -> tuple[float, float, float, float]:
    """Shortest rotation taking +Y to ``n``, as (x, y, z, w) — Godot's order."""
    up = np.array([0.0, 1.0, 0.0])
    d = float(np.dot(up, n))
    if d > 1.0 - 1e-12:
        return (0.0, 0.0, 0.0, 1.0)
    if d < -1.0 + 1e-12:
        return (1.0, 0.0, 0.0, 0.0)
    ax = np.cross(up, n)
    w = math.sqrt((1.0 + d) * 2.0)
    q = ax / w
    return (float(q[0]), float(q[1]), float(q[2]), float(w * 0.5))


# ---------------------------------------------------------------------------
# dynamics
# ---------------------------------------------------------------------------
@dataclass
class _Aero:
    alpha_deg: float
    cl: float
    cd: float
    cm: float
    v_air: float


def _aero_state(disc: DiscDefinition, y: np.ndarray, env: Environment):
    pos, vel, n, spin = y[0:3], y[3:6], _unit(y[6:9]), y[9]
    v_air = vel - env.wind
    speed = float(np.linalg.norm(v_air))
    if speed < 1e-6:
        return None
    vhat = v_air / speed

    # alpha > 0 when the flow arrives from below the disc.
    sin_a = float(np.clip(-np.dot(vhat, n), -1.0, 1.0))
    alpha = math.asin(sin_a)
    cl, cd, cm = disc.table.at(math.degrees(alpha))

    # Lift acts along the component of the normal perpendicular to the airspeed.
    lift_dir = n - float(np.dot(n, vhat)) * vhat
    lift_dir = _unit(lift_dir) if np.linalg.norm(lift_dir) > 1e-9 else np.zeros(3)

    q = 0.5 * env.air_density * speed * speed
    qa = q * disc.area_m2
    force = qa * (cl * lift_dir - cd * vhat)
    return pos, vel, n, spin, vhat, speed, alpha, cl, cd, cm, q, qa, lift_dir, force


def _precess(m_vec: np.ndarray, n: np.ndarray, i_zz: float, spin: float,
             gain: float) -> np.ndarray:
    """``dn/dt`` produced by an applied moment.

    The **only** place ``PRECESSION_GAIN`` is applied. Everything outside this
    function is pure kinematics, so the empirical constant stays visible and
    cannot drift into the algebra.
    """
    m_perp = m_vec - float(np.dot(m_vec, n)) * n
    return -gain * m_perp / (i_zz * spin)


def _derivative(disc: DiscDefinition, y: np.ndarray, env: Environment,
                gain: float = PRECESSION_GAIN) -> np.ndarray:
    st = _aero_state(disc, y, env)
    dy = np.zeros(10)
    if st is None:
        dy[0:3] = y[3:6]
        dy[4] = -env.gravity
        return dy
    pos, vel, n, spin, vhat, speed, alpha, cl, cd, cm, q, qa, lift_dir, force = st

    dy[0:3] = vel
    dy[3:6] = force / disc.mass_kg + np.array([0.0, -env.gravity, 0.0])

    d = disc.diameter_m
    qad = qa * d
    nondim = d / (2.0 * speed)

    spin_eff = spin if abs(spin) >= MIN_ABS_SPIN_RAD_S else math.copysign(MIN_ABS_SPIN_RAD_S, spin or 1.0)

    # Pitch axis: rotating the normal about +j increases alpha (nose up), so a
    # positive CM is a nose-up moment, as CONTRACT §5 requires.
    j = np.cross(vhat, n)
    j = _unit(j) if np.linalg.norm(j) > 1e-9 else np.zeros(3)

    # Static pitching moment, then the rates it induces, then the damping those
    # rates produce. Two passes: the quasi-steady reduction makes the angular
    # rate a function of the moment, so the damping feedback is evaluated on the
    # undamped rate. The correction is ~0.1% of the static moment.
    m_static = qad * cm * j
    dn_static = _precess(m_static, n, disc.I_zz, spin_eff, gain)
    omega = np.cross(n, dn_static)

    c_mq = float(disc.table.damping["c_mq"])
    c_rp = float(disc.table.damping["c_rp"])
    c_nr = float(disc.table.damping["c_nr"])

    m_damp = (qad * c_rp * (float(np.dot(omega, vhat)) * nondim) * vhat
              + qad * c_mq * (float(np.dot(omega, j)) * nondim) * j)
    m_total = m_static + m_damp

    dy[6:9] = _precess(m_total, n, disc.I_zz, spin_eff, gain)
    # Spin-down, with the A*d scaling Hummel's published code drops.
    dy[9] = qad * c_nr * (spin * nondim) / disc.I_zz
    return dy


def _rk4(disc: DiscDefinition, y: np.ndarray, env: Environment, dt: float,
         gain: float = PRECESSION_GAIN) -> np.ndarray:
    k1 = _derivative(disc, y, env, gain)
    k2 = _derivative(disc, y + 0.5 * dt * k1, env, gain)
    k3 = _derivative(disc, y + 0.5 * dt * k2, env, gain)
    k4 = _derivative(disc, y + dt * k3, env, gain)
    out = y + (dt / 6.0) * (k1 + 2.0 * k2 + 2.0 * k3 + k4)
    out[6:9] = _unit(out[6:9])
    return out


# ---------------------------------------------------------------------------
# result
# ---------------------------------------------------------------------------
@dataclass
class FlightResult:
    samples: list[dict]
    distance_m: float
    downrange_m: float
    lateral_m: float
    max_right_m: float
    max_left_m: float
    max_height_m: float
    flight_time_s: float
    landed: bool
    spin_loss_frac: float
    final_bank_deg: float
    max_bank_deg: float
    min_bank_deg: float
    went_inverted: bool

    def trajectory(self) -> np.ndarray:
        return np.array([s["pos"] for s in self.samples])

    def summary(self) -> dict:
        return {k: v for k, v in self.__dict__.items() if k != "samples"}


def simulate(
    disc: DiscDefinition,
    p: ThrowParams,
    env: Environment | None = None,
    dt: float = DT,
    sample_every: int = 12,
    precession_gain: float = PRECESSION_GAIN,
) -> FlightResult:
    """Integrate a throw to landing.

    ``precession_gain`` exists only so the pure-kinematics case (1.0) can be
    measured for comparison. Production callers must leave it alone -- see the
    constant's comment.
    """
    env = env or Environment()

    # velocity: heading rotates -Z toward +X, then elevate.
    h, e = p.launch_heading_rad, p.launch_angle_rad
    fwd = np.array([math.sin(h), 0.0, -math.cos(h)])
    vdir = _unit(fwd * math.cos(e) + np.array([0.0, 1.0, 0.0]) * math.sin(e))
    vel = vdir * p.speed_mps

    right = _unit(np.cross(vdir, np.array([0.0, 1.0, 0.0])))
    n = _unit(np.cross(right, vdir))
    n = _rotate(n, right, p.nose_angle_rad)        # nose up -> alpha up
    n = _rotate(n, vdir, -p.hyzer_angle_rad)       # + hyzer -> left bank (see docstring)

    y = np.concatenate([[0.0, p.launch_height_m, 0.0], vel, n, [2.0 * math.pi * p.spin_rps]])
    y0_spin = y[9]

    samples: list[dict] = []
    t = 0.0
    landed = False
    step = 0

    def record(tt: float, yy: np.ndarray) -> None:
        st = _aero_state(disc, yy, env)
        nn = _unit(yy[6:9])
        if st is None:
            alpha = cl = cd = cm = 0.0
        else:
            alpha, cl, cd, cm = st[6], st[7], st[8], st[9]
        # Bank: signed angle of the normal away from vertical about the heading.
        bank = math.degrees(math.atan2(float(np.dot(nn, right)),
                                       float(np.dot(nn, np.array([0.0, 1.0, 0.0])))))
        samples.append({
            "t": round(tt, 5),
            "pos": [round(float(v), 5) for v in yy[0:3]],
            "vel": [round(float(v), 5) for v in yy[3:6]],
            "normal": [round(float(v), 6) for v in nn],
            "quat": [round(v, 6) for v in _quat_from_normal(nn)],
            "spin": round(float(yy[9]), 5),
            "alpha_deg": round(math.degrees(alpha), 4),
            "cl": round(cl, 6), "cd": round(cd, 6), "cm": round(cm, 6),
            "bank_deg": round(bank, 4),
        })

    record(t, y)
    while t < MAX_TIME_S:
        nxt = _rk4(disc, y, env, dt, precession_gain)
        if nxt[1] <= 0.0 < y[1]:
            # Interpolate the ground crossing inside the final substep: at 25 m/s
            # a whole 1/240 step is 10 cm of landing error.
            frac = y[1] / (y[1] - nxt[1])
            nxt = _rk4(disc, y, env, dt * max(frac, 1e-6), precession_gain)
            t += dt * frac
            y = nxt
            landed = True
            record(t, y)
            break
        y, t = nxt, t + dt
        step += 1
        if step % sample_every == 0:
            record(t, y)

    if not landed:
        record(t, y)

    pos = np.array([s["pos"] for s in samples])
    lat = pos[:, 0] * math.cos(h) - pos[:, 2] * math.sin(h) * 0.0  # heading 0 -> +X is lateral
    # General case: project onto the launch frame.
    fwd_h = np.array([math.sin(h), 0.0, -math.cos(h)])
    right_h = np.array([math.cos(h), 0.0, math.sin(h)])
    downrange = pos[:, 0] * fwd_h[0] + pos[:, 2] * fwd_h[2]
    lat = pos[:, 0] * right_h[0] + pos[:, 2] * right_h[2]

    banks = np.array([s["bank_deg"] for s in samples])
    normals = np.array([s["normal"] for s in samples])
    return FlightResult(
        samples=samples,
        distance_m=float(math.hypot(pos[-1, 0], pos[-1, 2])),
        downrange_m=float(downrange[-1]),
        lateral_m=float(lat[-1]),
        max_right_m=float(lat.max()),
        max_left_m=float(lat.min()),
        max_height_m=float(pos[:, 1].max()),
        flight_time_s=float(samples[-1]["t"]),
        landed=landed,
        spin_loss_frac=float(1.0 - samples[-1]["spin"] / y0_spin) if y0_spin else 0.0,
        final_bank_deg=float(banks[-1]),
        max_bank_deg=float(banks.max()),
        min_bank_deg=float(banks.min()),
        went_inverted=bool((normals[:, 1] < 0.0).any()),
    )


# ---------------------------------------------------------------------------
# named reference throws (the CONTRACT §5 sanity targets)
# ---------------------------------------------------------------------------
REFERENCE_THROWS: dict[str, dict] = {
    "destroyer_power_drive": {
        "disc": "destroyer",
        "target": "CONTRACT §5: 105-130 m, visible early right turn then a left fade finish",
        "throw": dict(speed_mps=27.0, spin_rps=25.0, launch_angle_rad=math.radians(13.0),
                      hyzer_angle_rad=math.radians(22.0), nose_angle_rad=0.0,
                      launch_height_m=1.4),
        "note": ("22 deg of hyzer, not the 8 deg this fixture used under the v1 "
                 "precession law. The measured dd2 data is more understable than "
                 "the Destroyer's published rating - the regression reads it as "
                 "turn -1.9, not -1 - so it needs more hyzer than a nominal "
                 "12/5/-1/3 disc. See wraith_power_drive for the derived case, "
                 "and validation/hyzer_sweep.json for the full sensitivity."),
    },
    "wraith_power_drive": {
        "disc": "wraith",
        "target": "a derived 11/5/-1/3 disc whose CM anchors sit exactly on the published ratings",
        "throw": dict(speed_mps=27.0, spin_rps=25.0, launch_angle_rad=math.radians(12.0),
                      hyzer_angle_rad=math.radians(15.0), nose_angle_rad=0.0,
                      launch_height_m=1.4),
    },
    "aviar_drive": {
        "disc": "aviar",
        "target": "CONTRACT §5 v2: 2/3/0/1 putter at ~18 m/s -> 40-60 m, nearly straight with a gentle fade",
        "throw": dict(speed_mps=18.0, spin_rps=14.0, launch_angle_rad=math.radians(10.0),
                      hyzer_angle_rad=0.0, nose_angle_rad=0.0, launch_height_m=1.4),
    },
    "aviar_putt": {
        "disc": "aviar",
        "target": "an actual putt (13 m/s) - not a §5 target, kept as a low-speed reference",
        "throw": dict(speed_mps=13.0, spin_rps=10.0, launch_angle_rad=math.radians(8.0),
                      hyzer_angle_rad=0.0, nose_angle_rad=0.0, launch_height_m=1.4),
    },
    "roadrunner_flat_fast": {
        "disc": "roadrunner",
        "target": "CONTRACT §5: understable (turn -4) thrown flat and fast should turn over and may roll",
        "throw": dict(speed_mps=27.0, spin_rps=24.0, launch_angle_rad=math.radians(10.0),
                      hyzer_angle_rad=0.0, nose_angle_rad=0.0, launch_height_m=1.4),
    },
    "firebird_overstable": {
        "disc": "firebird",
        "target": "overstable: strong left finish, shorter than the Destroyer",
        "throw": dict(speed_mps=25.0, spin_rps=23.0, launch_angle_rad=math.radians(12.0),
                      hyzer_angle_rad=math.radians(5.0), nose_angle_rad=0.0,
                      launch_height_m=1.4),
    },
    "teebird_fairway": {
        "disc": "teebird",
        "target": "straight fairway driver, gentle fade",
        "throw": dict(speed_mps=23.0, spin_rps=20.0, launch_angle_rad=math.radians(10.0),
                      hyzer_angle_rad=math.radians(3.0), nose_angle_rad=0.0,
                      launch_height_m=1.4),
    },
    "destroyer_rhfh": {
        "disc": "destroyer",
        "target": "the canonical drive with negative spin (RHFH) - must mirror exactly",
        "throw": dict(speed_mps=27.0, spin_rps=-25.0, launch_angle_rad=math.radians(13.0),
                      hyzer_angle_rad=math.radians(-22.0), nose_angle_rad=0.0,
                      launch_height_m=1.4),
    },
    "buzzz_midrange": {
        "disc": "buzzz",
        "target": "midrange, straight with a small fade",
        "throw": dict(speed_mps=20.0, spin_rps=17.0, launch_angle_rad=math.radians(9.0),
                      hyzer_angle_rad=0.0, nose_angle_rad=0.0, launch_height_m=1.4),
    },
}


def hyzer_sweep(disc_id: str = "destroyer") -> list[dict]:
    """Release angle sensitivity at fixed power.

    Published because the CONTRACT §5 distance target is genuinely sensitive to
    it: at 27 m/s a 12-speed is understable, so the release is a hyzer-flip and
    the amount of hyzer decides whether the disc flips early and runs right or
    flips late and fades back. Quoting a single throw without this table would
    overstate how well-determined the result is.
    """
    disc = load_disc(disc_id)
    rows = []
    for launch_deg in (11.0, 12.0, 13.0, 14.0):
        for hyzer_deg in (8.0, 12.0, 16.0, 18.0, 20.0, 22.0, 24.0, 26.0):
            r = simulate(disc, ThrowParams(
                speed_mps=27.0, spin_rps=25.0,
                launch_angle_rad=math.radians(launch_deg),
                hyzer_angle_rad=math.radians(hyzer_deg), launch_height_m=1.4))
            rows.append({
                "launch_deg": launch_deg, "hyzer_deg": hyzer_deg,
                "distance_m": round(r.distance_m, 1),
                "lateral_m": round(r.lateral_m, 1),
                "max_right_m": round(r.max_right_m, 1),
                "max_height_m": round(r.max_height_m, 1),
                "flight_time_s": round(r.flight_time_s, 2),
                "meets_contract_5": bool(105.0 <= r.distance_m <= 130.0
                                         and r.max_right_m > 5.0
                                         and r.lateral_m < r.max_right_m - 5.0),
            })
    return rows


def run_reference_throws() -> dict[str, dict]:
    out = {}
    for name, spec in REFERENCE_THROWS.items():
        disc = load_disc(spec["disc"])
        res = simulate(disc, ThrowParams(**spec["throw"]))
        out[name] = {
            "disc": spec["disc"],
            "target": spec["target"],
            "throw": {k: v for k, v in spec["throw"].items()},
            "environment": {"air_density": 1.225, "wind": [0, 0, 0], "gravity": 9.81},
            "integrator": {"method": "RK4", "dt": DT},
            "result": res.summary(),
            "samples": res.samples,
        }
    return out


def _tilt_deg_at(res: FlightResult, t: float) -> float:
    """Signed tilt of the disc normal away from vertical at time ``t``.

    Positive = tilted right (anhyzer / turning). This is the direct precession
    response and the right quantity for the spin test — unlike landing drift,
    which mixes in the fact that a faster-spinning disc also stays up longer.
    """
    for s in res.samples:
        if s["t"] >= t:
            n = s["normal"]
            return math.degrees(math.atan2(n[0], n[1]))
    return float("nan")


def spin_sensitivity(disc_id: str = "destroyer") -> list[dict]:
    """CONTRACT §5: ``Omega = tau / (I_zz * omega)``, so more spin must mean a
    slower attitude response — less turn and less fade — with nothing
    special-cased.

    Measured two ways, because they disagree and the difference is instructive:

    ``tilt_at_1s_deg`` / ``tilt_at_2s_deg``
        The attitude response itself. Strictly decreasing in spin, which is the
        physics §5 is describing.
    ``lateral_m``
        Where it actually lands. **Not** monotonic, because more spin also keeps
        the disc flat, which keeps it airborne longer, which gives the residual
        bank more time to push it sideways. Reporting only this number would
        make the model look wrong when it is not.
    """
    disc = load_disc(disc_id)
    rows = []
    for rps in (15.0, 20.0, 25.0, 30.0, 35.0):
        r = simulate(disc, ThrowParams(speed_mps=27.0, spin_rps=rps,
                                       launch_angle_rad=math.radians(12.0),
                                       hyzer_angle_rad=0.0, launch_height_m=1.4))
        rows.append({"spin_rps": rps,
                     "tilt_at_1s_deg": round(_tilt_deg_at(r, 1.0), 3),
                     "tilt_at_2s_deg": round(_tilt_deg_at(r, 2.0), 3),
                     "max_right_m": round(r.max_right_m, 2),
                     "lateral_m": round(r.lateral_m, 2),
                     "distance_m": round(r.distance_m, 2),
                     "flight_time_s": round(r.flight_time_s, 2)})
    return rows


def putter_speed_sweep() -> list[dict]:
    """CONTRACT §5 v2 asks for 40-60 m from a 2/3/0/1 putter at ~18 m/s.

    Met, but only just: 40.4 m sits on the bottom edge of the band. Published as
    a sweep so the margin is visible. (§5 v1 asked for the same band at 13 m/s,
    which the coordinator has since corrected — 13 m/s is a putting speed, not a
    putter drive. We did not tune toward the old figure and this sweep still
    reports it: 19.0 m.)
    """
    disc = load_disc("aviar")
    rows = []
    for u in (13.0, 15.0, 17.0, 18.0, 20.0, 22.0):
        r = simulate(disc, ThrowParams(speed_mps=u, spin_rps=max(10.0, 0.78 * u),
                                       launch_angle_rad=math.radians(10.0),
                                       launch_height_m=1.4))
        rows.append({"speed_mps": u, "distance_m": round(r.distance_m, 2),
                     "lateral_m": round(r.lateral_m, 2),
                     "flight_time_s": round(r.flight_time_s, 2)})
    return rows


# ---------------------------------------------------------------------------
# cross-check against shotshaper
# ---------------------------------------------------------------------------
#: Outputs of the upstream ``shotshaper`` integrator (commit c99e7a5), run in
#: this sandbox on its own dd2 table. Their frame has +y to the left, so their
#: lateral sign is the negative of ours.
SHOTSHAPER_REFERENCE = {
    "paper_throw": {
        "note": "the throw in shotshaper's examples/disc_golf_throw.py",
        "throw": dict(speed_mps=24.2, spin_rps=116.8 / (2 * math.pi),
                      launch_angle_rad=math.radians(15.5),
                      hyzer_angle_rad=math.radians(14.7), launch_height_m=1.3),
        "shotshaper": {"distance_m": 82.1, "flight_time_s": 6.87,
                       "max_height_m": 11.5, "lateral_m": -4.2},
    },
    "flat_27": {
        "note": "flat release, 27 m/s, 25 rev/s",
        "throw": dict(speed_mps=27.0, spin_rps=25.0,
                      launch_angle_rad=math.radians(12.0),
                      hyzer_angle_rad=0.0, launch_height_m=1.4),
        "shotshaper": {"distance_m": 75.0, "flight_time_s": 4.13,
                       "max_height_m": 8.9, "lateral_m": 24.9},
    },
}


def shotshaper_cross_check() -> dict:
    """Run our integrator against ``shotshaper``'s on the same disc and throws.

    ``ours`` uses the shipped ``PRECESSION_GAIN``; ``ours_kinematic_only``
    re-runs with the gain set to 1.0, i.e. pure gyroscopic kinematics with no
    empirical correction.

    The gap between those two columns **is** the evidence for the constant, so
    it is published rather than described: with 1.0 the flat drive nearly
    doubles in flight time and lands 26 m further right, and neither figure is
    reachable by any release angle. Keeping it in the fixtures means the
    constant can never quietly become folklore.
    """
    disc = load_disc("destroyer")
    out = {}
    for name, spec in SHOTSHAPER_REFERENCE.items():
        ours = simulate(disc, ThrowParams(**spec["throw"]))
        kin = simulate(disc, ThrowParams(**spec["throw"]), precession_gain=1.0)
        out[name] = {
            "note": spec["note"],
            "throw": spec["throw"],
            "precession_gain": PRECESSION_GAIN,
            "shotshaper_published": spec["shotshaper"],
            "ours": {
                "distance_m": round(ours.distance_m, 2),
                "flight_time_s": round(ours.flight_time_s, 2),
                "max_height_m": round(ours.max_height_m, 2),
                "lateral_m": round(ours.lateral_m, 2),
            },
            "ours_kinematic_only": {
                "_gain": 1.0,
                "distance_m": round(kin.distance_m, 2),
                "flight_time_s": round(kin.flight_time_s, 2),
                "max_height_m": round(kin.max_height_m, 2),
                "lateral_m": round(kin.lateral_m, 2),
            },
        }
    return out


def precession_gain_evidence() -> dict:
    """The §5 behavioural targets, measured at gain 1.0 and at the shipped gain.

    This is the whole justification for ``PRECESSION_GAIN`` in one table. If a
    future change to the coefficient data ever makes 1.0 sufficient, this is
    where it will show up.
    """
    rows = {}
    for gain in (1.0, PRECESSION_GAIN):
        drive = simulate(load_disc("destroyer"), ThrowParams(
            speed_mps=27.0, spin_rps=25.0, launch_angle_rad=math.radians(13.0),
            hyzer_angle_rad=math.radians(22.0), launch_height_m=1.4),
            precession_gain=gain)
        flat = simulate(load_disc("destroyer"), ThrowParams(
            speed_mps=27.0, spin_rps=25.0, launch_angle_rad=math.radians(12.0),
            launch_height_m=1.4), precession_gain=gain)
        rr = simulate(load_disc("roadrunner"), ThrowParams(
            speed_mps=27.0, spin_rps=24.0, launch_angle_rad=math.radians(10.0),
            launch_height_m=1.4), precession_gain=gain)
        tilt = max(math.degrees(math.atan2(s["normal"][0], s["normal"][1]))
                   for s in rr.samples)
        rows[f"gain_{gain:g}"] = {
            "precession_gain": gain,
            "canonical_drive_distance_m": round(drive.distance_m, 1),
            "canonical_drive_time_s": round(drive.flight_time_s, 2),
            "canonical_drive_fade_back_m": round(drive.max_right_m - drive.lateral_m, 1),
            "flat_drive_distance_m": round(flat.distance_m, 1),
            "flat_drive_time_s": round(flat.flight_time_s, 2),
            "understable_max_tilt_deg": round(tilt, 1),
        }
    rows["comment"] = (
        "Gain 1.0 is the exact kinematics. It is not a near miss: the driver "
        "hangs ~2x too long and the understable disc never turns over. The gap "
        "is the missing spin-dependent aerodynamics (CRr), which the "
        "non-rotating CFD source cannot contain."
    )
    return rows


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="reference integrator / validation oracle")
    ap.add_argument("--dump", action="store_true",
                    help="write tools/aero/validation/*.json for Track B to diff against")
    ap.add_argument("--disc", help="simulate a single disc and print the summary")
    args = ap.parse_args(argv)

    if args.disc:
        d = load_disc(args.disc)
        r = simulate(d, ThrowParams(speed_mps=27.0, spin_rps=25.0,
                                    launch_angle_rad=math.radians(12.0),
                                    hyzer_angle_rad=math.radians(8.0)))
        print(json.dumps(r.summary(), indent=1))
        return 0

    results = run_reference_throws()
    spin = spin_sensitivity()
    putt = putter_speed_sweep()
    cross = shotshaper_cross_check()
    hyzer = hyzer_sweep()
    gain_evidence = precession_gain_evidence()

    print(f"{'throw':26s} {'dist':>7s} {'lat':>7s} {'maxR':>7s} {'maxH':>6s} "
          f"{'time':>5s} {'spin-':>6s} {'bank':>7s}")
    for name, r in results.items():
        s = r["result"]
        print(f"{name:26s} {s['distance_m']:7.1f} {s['lateral_m']:7.1f} "
              f"{s['max_right_m']:7.1f} {s['max_height_m']:6.1f} "
              f"{s['flight_time_s']:5.2f} {100*s['spin_loss_frac']:5.1f}% "
              f"{s['final_bank_deg']:7.1f}")
    print("\nspin sensitivity (destroyer, flat, 27 m/s):")
    for row in spin:
        print("  " + json.dumps(row))
    print("\nputter speed sweep (aviar):")
    for row in putt:
        print("  " + json.dumps(row))
    print("\nhyzer sensitivity (destroyer, 27 m/s, 25 rev/s) - rows meeting CONTRACT §5:")
    for row in hyzer:
        if row["meets_contract_5"]:
            print("  " + json.dumps(row))
    print(f"\nprecession gain evidence (shipped gain = {PRECESSION_GAIN}):")
    for key, row in gain_evidence.items():
        if key != "comment":
            print("  " + json.dumps(row))
    print("\nshotshaper cross-check:")
    for name, row in cross.items():
        print(f"  {name}: shotshaper={row['shotshaper_published']}")
        print(f"    ours                  ={row['ours']}")
        print(f"    ours(kinematics only) ={row['ours_kinematic_only']}")

    if args.dump:
        VALIDATION_DIR.mkdir(parents=True, exist_ok=True)
        for name, r in results.items():
            (VALIDATION_DIR / f"{name}.json").write_text(json.dumps(r, indent=1) + "\n")
        (VALIDATION_DIR / "spin_sensitivity.json").write_text(
            json.dumps({"disc": "destroyer", "speed_mps": 27.0,
                        "launch_angle_deg": 12.0, "rows": spin,
                        "putter_speed_sweep": putt}, indent=1) + "\n")
        (VALIDATION_DIR / "precession_gain_evidence.json").write_text(
            json.dumps(gain_evidence, indent=1) + "\n")
        (VALIDATION_DIR / "hyzer_sweep.json").write_text(
            json.dumps({"disc": "destroyer", "speed_mps": 27.0, "spin_rps": 25.0,
                        "rows": hyzer}, indent=1) + "\n")
        (VALIDATION_DIR / "shotshaper_cross_check.json").write_text(
            json.dumps(cross, indent=1) + "\n")
        (VALIDATION_DIR / "README.md").write_text(
            "# Validation fixtures\n\n"
            "Generated by `python -m tools.aero.validate --dump`.\n\n"
            "Each file is one named throw: the disc, the throw parameters, the\n"
            "environment, the integrator settings, a summary, and the full\n"
            "per-sample trajectory (position, velocity, disc normal, quaternion,\n"
            "spin, angle of attack and the three coefficients actually used).\n\n"
            "Track B should reproduce these with `DiscFlightSim` using the same\n"
            "baked table from `game/data/aero/`. Sampling is every 12 substeps at\n"
            "dt = 1/240, i.e. 20 Hz.\n\n"
            "Sign conventions are CONTRACT §1. Note that `hyzer_angle_rad` is\n"
            "positive-is-left-bank for a RHBH throw, following CONTRACT §5\n"
            "(a right bank turns right); the parenthetical in §4 says the\n"
            "opposite and is believed to be an editorial slip.\n")
        print(f"\nwrote {len(results) + 5} files to {VALIDATION_DIR}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

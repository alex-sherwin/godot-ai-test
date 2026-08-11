"""Disc geometry parameterisation and derived quantities (CONTRACT §2).

A disc is described by eight numbers.  The rendered mesh (Track C) and the
aerodynamic coefficients (this package) both derive from exactly these, so
editing the profile is the same edit the aero model sees.

Parameter definitions
---------------------
All lengths in metres, measured with the disc resting upside-down-normal, i.e.
sitting on a table on its rim, ``z = 0`` at the resting plane and ``+z`` up
through the flight plate.

``diameter_m``       outer diameter.
``mass_kg``          throwing mass.
``rim_width_m``      radial width of the rim.  PDGA calls this *rim thickness*;
                     it is the primary driver of the speed rating.
``rim_depth_m``      depth of the rim cavity, i.e. height of the underside of
                     the flight plate above the resting plane.
``rim_thickness_m``  axial ("wing") thickness of the rim at the outer edge —
                     how blunt the nose is.  Not published by anyone.
``parting_line_m``   height **above the resting plane** of the parting line,
                     i.e. of the widest point of the outer rim.
``dome_height_m``    apex height of the flight plate above its rim-edge height.
``inner_rim_edge_m`` radius at which the rim meets the flight plate
                     (= PDGA inside rim diameter / 2).

.. note:: CONTRACT §2 words ``parting_line_m`` as "height of the parting line
   above the flight plate", which is ambiguous (it would make ``parting_ratio``
   sit near zero and go negative for low-parting-line discs).  We pin it down as
   *height above the resting plane*, the standard industry meaning, which puts
   ``parting_ratio = parting_line_m / rim_depth_m`` in ``(0, 1)`` and makes it
   the stability driver the literature describes.  Track C must build the mesh
   cross-section with the same convention.

Derived quantities
------------------
``area_m2``        PI * (d/2)^2.  ~0.0350 m^2 for d = 0.211.  **Not** the
                   0.0568 m^2 Ultimate-frisbee figure that most references use.
``parting_ratio``  parting_line_m / rim_depth_m.
``nose_ratio``     rim_thickness_m / rim_depth_m.
``I_zz``, ``I_xy`` moments of inertia, integrated over an actual solid of
                   revolution built from the cross-section — a thin-rimmed
                   putter and a wide-rimmed driver genuinely differ, so these
                   are not hardcoded constants.

Inertia model
-------------
The cross-section is swept about the spin axis.  Two regions:

* ``r < inner_rim_edge_m`` — the flight plate: a slab of thickness
  ``plate_thickness_m`` whose top follows a parabolic dome of height
  ``dome_height_m``, sitting on top of the rim cavity.
* ``r >= inner_rim_edge_m`` — the rim: material between ``z_lo(r)`` and
  ``z_hi(r)``, tapering from the full rim height at the inner edge to
  ``rim_thickness_m`` centred on ``parting_line_m`` at the outer edge.

Uniform density is assumed and set by ``mass_kg / volume``.  The implied density
is exposed as ``density_kg_m3`` and should land near 1000 kg/m^3 for real disc
plastic — if it does not, the parameter set is not describing a real disc, which
makes the model falsifiable rather than merely plausible.

Validated against the four scanned CFD discs, whose specific moments of inertia
were computed by trimesh from the real STL meshes (see
``test_geometry.py::test_inertia_matches_scanned_discs``).  Feeding this model
the PDGA-published profile of the matching mould reproduces the scanned I_zz to
-0.1% (Destroyer/dd2), +0.6% (Firebird/cd1), -1.0% (Roadrunner/cd5) and -9.6%
(Teebird/fd2).  The Teebird outlier is not obviously a model error: that mould
has been retooled several times and the scanned disc need not be the one the
PDGA measured.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field, asdict

import numpy as np

# Typical flight-plate thickness. Real disc golf flight plates run 1.5-2.0 mm.
# Not a free parameter of CONTRACT §2, so it is a module constant rather than a
# ninth field; overridable per-disc for the rare thick-plate mould.
DEFAULT_PLATE_THICKNESS_M = 0.0018

# Integration resolution for the solid of revolution. 2000 radial stations puts
# the quadrature error on I_zz below 1e-6 relative, far under the uncertainty in
# the geometry itself.
_N_RADIAL = 2001

#: Implied uniform density that a real disc golf mould can plausibly have.
#: Base polypropylene/polyethylene blends run 870-950 kg/m^3 and premium blends
#: with additives reach ~1050; the band is widened either side because this is a
#: *model* quantity, sensitive to the assumed rim taper, not a material spec.
#: The shipped roster spans 826-1107.
PLASTIC_DENSITY_RANGE = (800.0, 1200.0)

# CONTRACT §2 sanity ranges. Violations raise; near-violations are allowed but
# the caller can inspect `warnings`.
_LIMITS = {
    "diameter_m": (0.200, 0.220),
    "mass_kg": (0.120, 0.200),
    "rim_width_m": (0.006, 0.030),
    "rim_depth_m": (0.008, 0.030),
    "rim_thickness_m": (0.001, 0.020),
    "parting_line_m": (0.0005, 0.030),
    "dome_height_m": (0.0, 0.020),
    "inner_rim_edge_m": (0.050, 0.110),
}


class GeometryError(ValueError):
    """Raised when a parameter set cannot describe a physical disc."""


@dataclass(frozen=True)
class DiscGeometry:
    """CONTRACT §2 parameter set plus the derived quantities Track B consumes."""

    diameter_m: float
    mass_kg: float
    rim_width_m: float
    rim_depth_m: float
    rim_thickness_m: float
    parting_line_m: float
    dome_height_m: float
    inner_rim_edge_m: float
    plate_thickness_m: float = DEFAULT_PLATE_THICKNESS_M
    warnings: tuple[str, ...] = field(default=(), compare=False)

    # -- basic derived ---------------------------------------------------
    @property
    def radius_m(self) -> float:
        return 0.5 * self.diameter_m

    @property
    def area_m2(self) -> float:
        """Reference area for all aerodynamic coefficients (CONTRACT §2)."""
        return math.pi * self.radius_m ** 2

    @property
    def parting_ratio(self) -> float:
        return self.parting_line_m / self.rim_depth_m

    @property
    def nose_ratio(self) -> float:
        return self.rim_thickness_m / self.rim_depth_m

    @property
    def rim_height_m(self) -> float:
        """Total height of rim material at the inner edge."""
        return self.rim_depth_m + self.plate_thickness_m

    @property
    def height_m(self) -> float:
        """Overall disc height, comparable with the PDGA published figure."""
        return self.rim_depth_m + self.plate_thickness_m + self.dome_height_m

    # -- cross-section ---------------------------------------------------
    def cross_section(self, n: int = _N_RADIAL) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
        """Return ``(r, z_lo, z_hi)`` sampling the meridional cross-section.

        Track C's mesh generator should lathe exactly this profile so that the
        rendered disc and the aerodynamic model can never drift apart.
        """
        R = self.radius_m
        ri = self.inner_rim_edge_m
        r = np.linspace(0.0, R, n)

        z_lo = np.zeros_like(r)
        z_hi = np.zeros_like(r)

        plate = r < ri
        # Flight plate: underside at rim_depth, top domed.
        dome = self.dome_height_m * (1.0 - (r[plate] / ri) ** 2)
        z_lo[plate] = self.rim_depth_m
        z_hi[plate] = self.rim_depth_m + self.plate_thickness_m + dome

        # Rim: linear taper in the normalised radial coordinate. At r = ri the
        # rim spans the full [0, rim_height]; at r = R it collapses to a wing of
        # thickness rim_thickness_m centred on the parting line. On discs whose
        # parting line sits lower than half the wing thickness (very
        # understable moulds) the wing is pushed up so it rests on the ground
        # plane instead of extending below it; the thickness is preserved and
        # the parting line then sits low on a flat-bottomed wing, which is what
        # those moulds actually look like.
        rim = ~plate
        s = (r[rim] - ri) / max(R - ri, 1e-9)
        bot_outer = max(self.parting_line_m - 0.5 * self.rim_thickness_m, 0.0)
        top_outer = bot_outer + self.rim_thickness_m
        z_hi[rim] = self.rim_height_m + (top_outer - self.rim_height_m) * s
        z_lo[rim] = bot_outer * s
        return r, z_lo, z_hi

    # -- inertia ---------------------------------------------------------
    def _mass_integrals(self, n: int = _N_RADIAL) -> dict[str, float]:
        r, z_lo, z_hi = self.cross_section(n)
        t = np.maximum(z_hi - z_lo, 0.0)

        # dV = 2 pi r t dr ; dI_zz = r^2 dV ; second axial moment uses
        # integral(z^2 dz) = (z_hi^3 - z_lo^3)/3 over the local slab.
        two_pi_r = 2.0 * math.pi * r
        dV = two_pi_r * t
        vol = float(np.trapezoid(dV, r))
        if vol <= 0.0:
            raise GeometryError("cross-section encloses no volume")

        i_zz_v = float(np.trapezoid(dV * r ** 2, r))
        z_first = float(np.trapezoid(two_pi_r * 0.5 * (z_hi ** 2 - z_lo ** 2), r))
        z_second = float(np.trapezoid(two_pi_r * (z_hi ** 3 - z_lo ** 3) / 3.0, r))
        return {"volume": vol, "i_zz_v": i_zz_v, "z_first": z_first, "z_second": z_second}

    @property
    def density_kg_m3(self) -> float:
        return self.mass_kg / self._mass_integrals()["volume"]

    @property
    def centre_of_mass_z_m(self) -> float:
        m = self._mass_integrals()
        return m["z_first"] / m["volume"]

    @property
    def I_zz(self) -> float:
        """Spin-axis moment of inertia (kg m^2). ~0.00131 for a 175 g driver."""
        m = self._mass_integrals()
        return self.mass_kg * m["i_zz_v"] / m["volume"]

    @property
    def I_xy(self) -> float:
        """Transverse moment of inertia (kg m^2). ~0.00066 for a 175 g driver.

        For a solid of revolution ``I_xx = I_yy = I_zz/2 + integral(z'^2 dm)``
        about the centre of mass.
        """
        m = self._mass_integrals()
        rho = self.mass_kg / m["volume"]
        z_cm = m["z_first"] / m["volume"]
        axial = rho * m["z_second"] - self.mass_kg * z_cm ** 2
        return 0.5 * self.I_zz + axial

    # -- serialisation ---------------------------------------------------
    def params(self) -> dict[str, float]:
        """The eight CONTRACT §2 parameters, for `discs.json`."""
        d = asdict(self)
        d.pop("warnings", None)
        d.pop("plate_thickness_m", None)
        return {k: round(v, 6) for k, v in d.items()}

    def derived(self) -> dict[str, float]:
        return {
            "area_m2": round(self.area_m2, 7),
            "parting_ratio": round(self.parting_ratio, 4),
            "nose_ratio": round(self.nose_ratio, 4),
            "I_zz": round(self.I_zz, 8),
            "I_xy": round(self.I_xy, 8),
            "height_m": round(self.height_m, 5),
            "density_kg_m3": round(self.density_kg_m3, 1),
        }


def make_geometry(**kwargs) -> DiscGeometry:
    """Validate a parameter set and build a :class:`DiscGeometry`.

    Raises :class:`GeometryError` on anything that cannot be a real disc.
    Soft oddities -- an implied plastic density outside
    ``PLASTIC_DENSITY_RANGE`` -- are recorded in ``.warnings`` rather than
    raised, because a user dragging a slider in the UI should get feedback, not
    an exception.  Every shipped disc is required to be warning-free; see
    ``test_geometry.py::test_shipped_geometry_is_warning_free``.
    """
    missing = [k for k in _LIMITS if k not in kwargs]
    if missing:
        raise GeometryError(f"missing geometry parameters: {missing}")

    for key, (lo, hi) in _LIMITS.items():
        v = float(kwargs[key])
        if not (lo <= v <= hi):
            raise GeometryError(f"{key}={v!r} outside physical range [{lo}, {hi}]")

    radius = 0.5 * float(kwargs["diameter_m"])
    inner = float(kwargs["inner_rim_edge_m"])
    rim_w = float(kwargs["rim_width_m"])
    if abs((radius - inner) - rim_w) > 1e-3:
        raise GeometryError(
            f"inner_rim_edge_m ({inner}) must equal radius - rim_width_m "
            f"({radius - rim_w:.4f}); they disagree by "
            f"{abs((radius - inner) - rim_w) * 1000:.2f} mm"
        )
    if float(kwargs["parting_line_m"]) >= float(kwargs["rim_depth_m"]):
        raise GeometryError("parting_line_m must sit below the flight plate (< rim_depth_m)")

    geom = DiscGeometry(**{k: float(v) for k, v in kwargs.items()})

    # The rim wing must fit inside the rim envelope. Note that it is NOT
    # required to be centred on the parting line: real moulds are asymmetric
    # about it, and on very understable discs the parting line sits low on a
    # flat-bottomed wing. An earlier version rejected `rim_thickness_m >
    # 2*parting_line_m` on the mistaken assumption of symmetry; that rule was
    # wrong, not the Roadrunner it flagged.
    if geom.rim_thickness_m >= geom.rim_height_m:
        raise GeometryError(
            f"rim_thickness_m ({geom.rim_thickness_m * 1000:.1f} mm) is thicker "
            f"than the whole rim ({geom.rim_height_m * 1000:.1f} mm)"
        )
    wing_bottom = max(geom.parting_line_m - 0.5 * geom.rim_thickness_m, 0.0)
    if wing_bottom + geom.rim_thickness_m > geom.rim_height_m + 1e-9:
        raise GeometryError(
            "rim wing extends above the flight plate: wing top at "
            f"{(wing_bottom + geom.rim_thickness_m) * 1000:.1f} mm vs rim height "
            f"{geom.rim_height_m * 1000:.1f} mm"
        )

    warns: list[str] = []
    rho = geom.density_kg_m3
    lo, hi = PLASTIC_DENSITY_RANGE
    if not (lo <= rho <= hi):
        warns.append(
            f"implied plastic density {rho:.0f} kg/m^3 is outside the "
            f"{lo:.0f}-{hi:.0f} range of real disc golf plastics; the parameter "
            "set may not describe a manufacturable disc"
        )
    if geom.I_zz <= 0 or geom.I_xy <= 0:
        raise GeometryError("non-positive moment of inertia")
    if not (0.10 <= geom.parting_ratio <= 0.95):
        warns.append(f"parting_ratio {geom.parting_ratio:.2f} is outside the "
                     "0.10-0.95 range seen on production moulds")
    return DiscGeometry(**{**{k: float(v) for k, v in kwargs.items()},
                           "warnings": tuple(warns)})


def geometry_from_pdga(
    *,
    diameter_cm: float,
    height_cm: float,
    rim_depth_cm: float,
    rim_thickness_cm: float,
    mass_kg: float,
    parting_line_m: float,
    nose_thickness_m: float,
    plate_thickness_m: float = DEFAULT_PLATE_THICKNESS_M,
) -> DiscGeometry:
    """Build a geometry from the five figures the PDGA actually publishes.

    PDGA publishes diameter, height, rim depth, rim thickness (= our
    ``rim_width_m``) and inside rim diameter.  It does **not** publish the
    parting-line height or the axial thickness of the rim wing, so those two
    must be supplied by the caller — see ``coefficients.infer_shape_from_flight``
    for how the roster obtains them.
    """
    diameter_m = diameter_cm / 100.0
    rim_depth_m = rim_depth_cm / 100.0
    rim_width_m = rim_thickness_cm / 100.0
    dome_height_m = max(height_cm / 100.0 - rim_depth_m - plate_thickness_m, 0.0)
    return make_geometry(
        diameter_m=diameter_m,
        mass_kg=mass_kg,
        rim_width_m=rim_width_m,
        rim_depth_m=rim_depth_m,
        rim_thickness_m=nose_thickness_m,
        parting_line_m=parting_line_m,
        dome_height_m=dome_height_m,
        inner_rim_edge_m=0.5 * diameter_m - rim_width_m,
        plate_thickness_m=plate_thickness_m,
    )

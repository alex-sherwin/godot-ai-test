"""Offline aerodynamic data pipeline for the disc golf flight lab.

Pipeline stages
---------------
1. ``fetch_reference_data`` — pull the published reference datasets and cache
   them under ``tools/aero/reference/`` (committed, so the build is offline
   reproducible).
2. ``geometry``     — the disc geometry parameterisation (CONTRACT §2) and its
                      derived quantities, including moments of inertia from an
                      actual solid-of-revolution mass distribution.
3. ``coefficients`` — geometry -> CL/CD/CM(alpha) via shape-preserving affine
                      mapping of a measured CFD curve onto geometry-predicted
                      anchors.
4. ``bake``         — CLI. PCHIP-resample onto a uniform 0.5 deg grid and emit
                      the CONTRACT §3 JSON into ``game/data/aero/``.
5. ``validate``     — reference RK4 6-DOF integrator. Cross-validation oracle
                      for the GDScript runtime (Track B).

Provenance discipline (CONTRACT §7): every number this package emits is tagged
with where it came from. Measured means CFD or wind tunnel. Derived means our
model produced it. Nothing in between is claimed.
"""

__all__ = [
    "geometry",
    "coefficients",
    "bake",
    "validate",
    "reference_data",
    "roster",
]

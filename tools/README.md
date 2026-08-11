# `tools/` — offline aerodynamic data pipeline

Turns parametric disc geometry into the baked coefficient tables the game ships.
Runs offline; the game never runs any of this.

```bash
pip install -r tools/requirements.txt

python -m tools.aero.fetch_reference_data     # refresh the cached reference data
python -m tools.aero.bake                     # -> game/data/aero/*.json + discs.json
python -m tools.aero.validate --dump          # -> tools/aero/validation/*.json
python -m pytest tools/aero                   # 121 tests
```

Dependencies are numpy, scipy and pytest, pinned in `tools/requirements.txt`.
Reference-data fetching uses `git` and the standard library. Nothing else.

## Layout

```
tools/aero/
  fetch_reference_data.py   pulls the published datasets, caches them as JSON
  reference/                the cache — COMMITTED, so the bake works offline
  geometry.py               CONTRACT §2 parameters + solid-of-revolution inertia
  coefficients.py           geometry -> CL/CD/CM, the core model
  roster.py                 published facts for the 14 shipped discs
  bake.py                   CLI: emits the CONTRACT §3 JSON
  validate.py               reference RK4 6-DOF integrator (oracle for Track B)
  validation/               dumped reference trajectories
  test_*.py                 pytest suite
```

## The pipeline

**1. Fetch.** `fetch_reference_data.py` clones two repositories, parses them,
and writes normalised JSON into `reference/`. That directory is committed, so
the bake is reproducible with no network and CI never depends on a third-party
host. Re-running the fetch rewrites the cache; `--check` verifies it.

**2. Geometry.** Eight parameters describe a disc (CONTRACT §2). `geometry.py`
validates them, builds the meridional cross-section, and integrates the solid of
revolution for `I_zz` and `I_xy` — *not* hardcoded constants, because a
thin-rimmed putter and a wide-rimmed driver genuinely differ (Aviar
`I_zz = 1.09e-3 kg m^2`, Boss `1.25e-3`, a 13% spread). The integral is checked
against the four scanned CFD discs, whose specific inertias trimesh computed
from the real STL meshes: +0.3% (Roadrunner/cd5), +1.5% (Destroyer/dd2), +2.7%
(Firebird/cd1), -11.0% (Teebird/fd2, a mould that has been retooled repeatedly
— the disc that was scanned need not be the one the PDGA measured).

Assuming uniform density, the model also reports the *implied* plastic density.
It lands at 826–1107 kg/m³ across the roster, inside the documented 800–1200
band, which is real disc plastic. That makes the profile model falsifiable
rather than merely plausible — and it did falsify one: inferring nose thickness
as a fraction of rim width pushed three discs under 800 kg/m³ and gave a
13-speed the bluntest nose in the roster. Nose thickness is now inferred as an
absolute length. See `game/data/README.md`.

**3. Coefficients.** Shape-preserving affine mapping of a real measured CFD
curve onto anchors predicted from geometry. Documented in full in
`coefficients.py`'s module docstring and in `game/data/README.md`.

**4. Bake.** PCHIP-resample onto a uniform 0.5° grid over [-90°, 90°] and write
`game/data/aero/<id>.json`. PCHIP is shape-preserving; a natural cubic spline
overshoots between the unevenly-spaced measured stations, and an overshoot in
`CM` near α = 0 is a fabricated sign change — that is, fabricated turn or fade.
`test_bake.py` measures the overshoot a natural spline would produce and asserts
PCHIP produces none.

**5. Validate.** `validate.py` is a full RK4 6-DOF integrator implementing
CONTRACT §4/§5 against the same baked JSON the game loads. It exists to be the
oracle Track B's GDScript is diffed against. `--dump` writes named throws with
per-sample position, velocity, disc normal, quaternion, spin, α and the three
coefficients actually used, at 20 Hz.

Precession follows CONTRACT §4 **v3**, which keeps the derived part and the
fitted part visibly separate:

```
dn/dt = −PRECESSION_GAIN · M_perp / (I_zz · spin)
PRECESSION_GAIN = 2.0     # empirical. The kinematics are 1.0.
```

The kinematics are the naive gyroscopic form and it is exact — the `I_xy` terms
cancel, in the Resal frame and in the body-fixed Euler equations alike, once
steady precession is written as `ω̇₂ = −ω₃·ω₁` rather than `ω̇₂ = 0`. The factor
of 2 is **not** a kinematic result; it is a calibration constant standing in for
spin-dependent aerodynamics the source data cannot contain. It is declared once,
applied in one function (`_precess`), and never varies by disc or throw — three
tests enforce that. `game/data/README.md` has the derivation and the measured
evidence for the value; `validation/precession_gain_evidence.json` ships the
gain-1.0 comparison so it stays visible.

The axial equation is untouched: spin-down divides by `I_zz` with no gain.

One known upstream bug is avoided: Hummel's published MATLAB drops the `A·d`
factor from the spin-down moment. We include it — and, because her fitted `CNr`
was calibrated to the unscaled form, we recalibrate the coefficient rather than
ship a number that would give 0.2% spin loss where 10–20% is observed. See
`game/data/README.md`.

No spin-induced roll moment (`CRr`) is modelled. The CFD is steady-state RANS on
a *non-rotating* disc, so the source data cannot contain one — this is what
`PRECESSION_GAIN` is standing in for. Transplanting Hummel's Ultimate-disc value
was tried and rejected because it produces a moment 2.25× the pitching moment
and no survivable flight in either sign. The numbers are in
`game/data/README.md`. If `CRr` is ever measured on a rotating golf disc, it and
`PRECESSION_GAIN` must be revisited together or the same physics is
double-counted.

## Provenance discipline

Every number this pipeline emits carries a label. Measured means CFD or wind
tunnel. Derived means our model produced it. Inferred means we solved backwards
for a quantity nobody publishes. `game/data/README.md` documents which is which
for every field of every disc, including the things we tried to fit and could
not — glide, most notably.

If you extend this: an unlabelled number is a bug.

## Attribution and licensing of the reference data

`tools/aero/reference/` contains data fetched from third parties.
`reference/NOTICE.md` is the authoritative statement; in summary:

**Giljarhus et al. (2022) CFD tables** — the entire measured basis of this
project.

> Giljarhus, K.E.T., Kristiansen, T., Tutkun, M., Oggiano, L. (2022).
> *Aerodynamic characteristics of a golf disc.* Sports Engineering 25, 24.
> <https://doi.org/10.1007/s12283-022-00390-5>

Obtained from the authors' reference implementation,
<https://github.com/kegiljarhus/shotshaper>, which is licensed **GPL-3.0**. The
full upstream licence text is committed at
`tools/aero/reference/LICENSE-shotshaper.txt`, and the exact commit is recorded
in `reference/SOURCES.json`. We parsed their four YAML files and re-serialised
the same numbers with provenance metadata attached; the values are unchanged.
If you redistribute this repository you are redistributing that data — honour
the upstream licence and cite the paper.

**Hummel (2003) / Potts & Crowther (2002)** — damping coefficients and an
independent shape cross-check, from
<https://github.com/grebtsew/Discgolf>. Hummel measured an *Ultimate* disc; her
CL/CD/CM, inertias and reference area are **not** used anywhere in this
pipeline, and a test asserts they do not appear in the model source.

**PDGA equipment certification database** — published mould dimensions for the
roster, <https://www.pdga.com/technical-standards/equipment-certification/discs>.

## Interface notes for the other tracks

Two places where this pipeline had to pin down something the contract left
ambiguous or self-contradictory. Neither changes a data format; both change how
a number should be read.

* **`DiscGeometry.cross_section` is the canonical profile.** It returns
  `(r, z_lo, z_hi)` for the meridional section; lathing it is the definition of
  the disc's shape, and the inertia integrals are taken over exactly that
  profile. Track C should port or call it rather than reimplement the geometry,
  so the rendered disc and the aerodynamic model cannot drift apart. Treated as
  a stable interface: it will not change shape without a note here.

* **`parting_line_m`** — CONTRACT §2 words it as "height of the parting line
  above the flight plate", which would put `parting_ratio` near zero and make it
  negative for low-parting-line moulds. We use the standard industry meaning:
  height above the *resting plane* (the plane the disc sits on). That puts
  `parting_ratio = parting_line_m / rim_depth_m` in (0, 1) — 0.26 to 0.71 across
  the roster — and makes it the stability driver the literature describes.
  The wing is **not** centred on the parting line: real moulds are asymmetric
  about it, and on the Roadrunner it sits low on a flat-bottomed wing.

* **`rim_thickness_m` is the *axial* thickness of the rim wing** — how blunt the
  nose is — not the total rim height. It runs 3.5–8.0 mm across the roster and
  is always less than `rim_depth_m`. Total rim height is
  `rim_depth_m + plate thickness`, exposed as `DiscGeometry.rim_height_m`, and
  overall disc height as `DiscGeometry.height_m`. Track C read this field as
  total rim height and clamped it, which made it inert on every shipped disc;
  the coordinator has confirmed Track C adopts the definition above.

* **`hyzer_angle_rad` sign** — positive banks the disc **left** for a RHBH throw,
  so a hyzer release finishes left. CONTRACT §4 v2 confirms this; v1's
  parenthetical said the opposite and has been corrected. **Track B must match**
  or the validation fixtures will not line up.

* **The fixtures in `tools/aero/validation/` were regenerated for §4 v3.**
  Anything compared against a v1 or v2 dump is stale.

# `tools/` — offline aerodynamic data pipeline

Turns parametric disc geometry into the baked coefficient tables the game ships.
Runs offline; the game never runs any of this.

```bash
pip install -r tools/requirements.txt

python -m tools.aero.fetch_reference_data     # refresh the cached reference data
python -m tools.aero.bake                     # -> game/data/aero/*.json + discs.json
python -m tools.aero.validate --dump          # -> tools/aero/validation/*.json
python -m pytest tools/aero                   # the test suite
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
`I_zz = 1.07e-3 kg m^2`, Boss `1.31e-3`, an 18% spread). The integral is checked against the four
scanned CFD discs, whose specific inertias trimesh computed from the real STL
meshes: -0.1% (Destroyer/dd2), +0.6% (Firebird/cd1), -1.0% (Roadrunner/cd5),
-9.6% (Teebird/fd2, a mould that has been retooled repeatedly).

Assuming uniform density, the model also reports the *implied* plastic density.
It lands at 779–1128 kg/m³ across the roster, which is real disc plastic. That
makes the profile model falsifiable rather than merely plausible.

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

Two known upstream bugs are avoided, and both are called out in the code:

* Hummel's published MATLAB drops the `A·d` factor from the spin-down moment.
  We include it — and, because her fitted `CNr` was calibrated to the unscaled
  form, we recalibrate the coefficient rather than shipping a number that would
  give 0.2% spin loss where 10–20% is observed. See `game/data/README.md`.
* `shotshaper`'s precession law `−M/(ω(I_xy − I_z))` is off by a factor of ~2
  for a flat disc. We use the Euler-derived `−M/(I_zz·ω)` that CONTRACT §4
  mandates — and report, rather than hide, that their version matches their
  measured throws better than ours does.

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

* **`parting_line_m`** — CONTRACT §2 words it as "height of the parting line
  above the flight plate", which would put `parting_ratio` near zero and make it
  negative for low-parting-line moulds. We use the standard industry meaning:
  height above the *resting plane* (the plane the disc sits on). That puts
  `parting_ratio = parting_line_m / rim_depth_m` in (0, 1) — 0.26 to 0.71 across
  the roster — and makes it the stability driver the literature describes.
  **Track C must lathe the cross-section with this convention**; see
  `DiscGeometry.cross_section`, which returns the exact profile to sweep.

* **`hyzer_angle_rad` sign** — CONTRACT §4 annotates it "+ = hyzer (right edge
  down for RHBH)", which contradicts §5, where a right bank is what makes the
  disc *turn right*. Hyzer is the fade direction. `validate.py` implements §5:
  positive `hyzer_angle_rad` banks the disc **left** for a RHBH throw, so a
  hyzer release finishes left. **Track B should match this** or the validation
  fixtures will not line up.

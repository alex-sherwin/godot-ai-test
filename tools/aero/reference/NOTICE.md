# Reference data — provenance and licensing

Everything in this directory was fetched from a third party and cached here so
the aerodynamic bake is reproducible offline. Nothing here was authored by this
project. Regenerate with `python -m tools.aero.fetch_reference_data`.

## 1. `giljarhus2022_cfd.json` — the measured dataset

CFD coefficient tables for four real disc golf discs.

> Giljarhus, K.E.T., Kristiansen, T., Tutkun, M., Oggiano, L. (2022).
> *Aerodynamic characteristics of a golf disc.* Sports Engineering 25, 24.
> https://doi.org/10.1007/s12283-022-00390-5

Obtained from the authors' reference implementation,
<https://github.com/kegiljarhus/shotshaper> (`shotshaper/discs/*.yaml`), which
is licensed **GPL-3.0**. The full upstream licence text is kept alongside this
file as `LICENSE-shotshaper.txt`.

What we did with it: we parsed the four YAML files and re-serialised the same
numbers into `giljarhus2022_cfd.json` with provenance metadata attached. The
numbers are unchanged — no smoothing, no refitting, no reinterpretation. If you
redistribute this repository you are redistributing that data; honour the
upstream licence and cite the paper.

Two upstream quirks, preserved as-is and recorded here rather than silently
cleaned up:

* `fd2.yaml` and `cd1.yaml` share their `alpha <= -15` and `alpha >= 25` wings —
  the `fd2` header states the outer stations were copied from `cd1`. Only the
  `-10 .. 20` window is independently simulated for `fd2`.
* `fd2.yaml` carries an older, commented-out set of `-10 .. 20` values. We take
  the live (uncommented) values.

## 2. `hummel2003.json` — damping coefficients and a cross-check

Hummel, S.A. (2003), *Frisbee Flight Simulation and Throw Biomechanics*,
MSc thesis, UC Davis. The MATLAB implementation survives verbatim at
<https://github.com/grebtsew/Discgolf> (`Calculations/matlab_hummel_frisbee.m`),
which also carries the digitised Potts & Crowther (2002) wind tunnel tables.

**Hummel measured an Ultimate disc, not a golf disc.** Her fitted CL/CD/CM are
therefore *not* used anywhere in this pipeline: her `CLalpha = 1.9124 /rad`
against `2.44 - 2.59 /rad` measured by CFD for golf discs, and her reported
inertias (`I_zz = 0.002352`, `I_xy = 0.001219`) and reference area
(`A = 0.0568 m^2`) are all Ultimate-disc values that would inflate every force
by roughly 60% if applied to a golf disc.

What we *do* take from her: the three damping coefficients `CMq`, `CRp`, `CNr`,
because no disc-golf-specific measurement of them exists anywhere. This is
stated in the provenance of every baked table. See `game/data/README.md` for the
caveat on `CNr`, whose published numeric value is not compatible with the
non-dimensionalisation this project uses.

The Potts & Crowther tables are kept purely as an independent shape cross-check
(their disc is also not a golf disc).

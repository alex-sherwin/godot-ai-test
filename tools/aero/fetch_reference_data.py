#!/usr/bin/env python3
"""Fetch and cache the published reference datasets this pipeline is built on.

Two upstream sources, both fetched from GitHub:

1. ``kegiljarhus/shotshaper`` — the CFD coefficient tables from
   Giljarhus, Kristiansen, Tutkun & Oggiano, "Aerodynamic characteristics of a
   golf disc", *Sports Engineering* 25:24 (2022).
   Four real disc golf discs, scanned and run through CFD, 33 alpha stations of
   CL/CD/CM each.  This is the only measured disc-golf aerodynamic dataset that
   exists in the open literature, and everything else in this project is
   anchored to it.
   Upstream licence: **GPL-3.0**.  See ``reference/LICENSE-shotshaper.txt`` and
   ``reference/NOTICE.md``.

2. ``grebtsew/Discgolf`` — a verbatim copy of Hummel's 2003 MSc MATLAB model
   (an *Ultimate* disc, not a golf disc) which also carries the digitised
   Potts & Crowther (2002) wind tunnel tables.  We use it for exactly two
   things: the damping coefficients (CMq, CRp, CNr), for which no disc-golf
   specific measurement exists, and as an independent cross-check on CL/CD/CM
   shape.  We do **not** use Hummel's CL/CD/CM for golf discs — see NOTICE.md.

The fetched data is normalised into JSON under ``tools/aero/reference/`` and
**committed to the repository**, so the bake is reproducible with no network
and CI never depends on a third-party host.

Usage
-----
    python -m tools.aero.fetch_reference_data              # fetch + rewrite cache
    python -m tools.aero.fetch_reference_data --check      # verify cache only
"""

from __future__ import annotations

import argparse
import ast
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

REFERENCE_DIR = Path(__file__).resolve().parent / "reference"

SHOTSHAPER_REPO = "https://github.com/kegiljarhus/shotshaper"
SHOTSHAPER_DISCS = ("cd1", "fd2", "cd5", "dd2")

HUMMEL_REPO = "https://github.com/grebtsew/Discgolf"
HUMMEL_MATLAB = "Calculations/matlab_hummel_frisbee.m"

# Which real disc each CFD case was modelled on. The first three are stated in
# the upstream YAML headers; dd2 carries no such comment, so we record it as an
# unnamed distance driver rather than inventing an attribution.
CFD_DISC_IDENTITY = {
    "cd1": {
        "modelled_on": "Innova Firebird",
        "flight_numbers": {"speed": 9, "glide": 3, "turn": 0, "fade": 4},
        "identity_source": "stated in the upstream cd1.yaml header comment",
    },
    "fd2": {
        "modelled_on": "Innova Teebird",
        "flight_numbers": {"speed": 7, "glide": 5, "turn": 0, "fade": 2},
        "identity_source": "stated in the upstream fd2.yaml header comment",
    },
    "cd5": {
        "modelled_on": "Innova Roadrunner",
        "flight_numbers": {"speed": 9, "glide": 5, "turn": -4, "fade": 1},
        "identity_source": "stated in the upstream cd5.yaml header comment",
    },
    "dd2": {
        "modelled_on": None,
        "flight_numbers": {"speed": 12, "glide": 5, "turn": -1, "fade": 3},
        "identity_source": (
            "NOT stated upstream. dd2.yaml has no header comment naming a "
            "commercial disc. The flight numbers recorded here are the "
            "12/5/-1/3 distance-driver class the paper describes, not a "
            "manufacturer rating for a specific mould."
        ),
    },
}


# --------------------------------------------------------------------------
# fetching
# --------------------------------------------------------------------------
def _git_clone(repo_url: str, dest: Path) -> str | None:
    """Shallow-clone ``repo_url`` into ``dest``; return the commit SHA."""
    env = dict(os.environ, GIT_LFS_SKIP_SMUDGE="1", GIT_TERMINAL_PROMPT="0")
    try:
        subprocess.run(
            ["git", "clone", "--depth", "1", repo_url, str(dest)],
            check=True, capture_output=True, env=env, timeout=600,
        )
        sha = subprocess.run(
            ["git", "-C", str(dest), "rev-parse", "HEAD"],
            check=True, capture_output=True, text=True, env=env, timeout=60,
        ).stdout.strip()
        return sha
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as exc:
        print(f"  git clone failed for {repo_url}: {exc}", file=sys.stderr)
        return None


def _raw_get(repo_url: str, ref: str, path: str) -> str | None:
    """Fallback: fetch a single file over HTTPS from raw.githubusercontent.com."""
    slug = repo_url.rstrip("/").removeprefix("https://github.com/")
    url = f"https://raw.githubusercontent.com/{slug}/{ref}/{path}"
    try:
        with urllib.request.urlopen(url, timeout=60) as resp:
            return resp.read().decode("utf-8")
    except Exception as exc:  # noqa: BLE001 - any network failure is a fallback miss
        print(f"  raw fetch failed for {url}: {exc}", file=sys.stderr)
        return None


# --------------------------------------------------------------------------
# parsing
# --------------------------------------------------------------------------
def parse_disc_yaml(text: str) -> dict:
    """Parse one shotshaper disc YAML.

    Deliberately hand-rolled rather than pulling in PyYAML: the schema is four
    scalars and four numeric lists, the lists span multiple lines and carry
    interleaved ``#`` comments (upstream keeps superseded values commented out
    inline).  A dependency-free reader keeps ``tools/requirements.txt`` to
    numpy/scipy.
    """
    # Drop comments. No quoted strings in these files, so this is safe.
    stripped = "\n".join(line.split("#", 1)[0] for line in text.splitlines())

    out: dict[str, object] = {}
    for key in ("diameter", "J_xy", "J_z"):
        m = re.search(rf"^\s*{key}\s*:\s*([-+0-9.eE]+)\s*$", stripped, re.M)
        if not m:
            raise ValueError(f"missing scalar {key!r} in disc yaml")
        out[key] = float(m.group(1))

    for key in ("alpha", "Cd", "Cl", "Cm"):
        m = re.search(rf"^\s*{key}\s*:\s*(\[.*?\])", stripped, re.M | re.S)
        if not m:
            raise ValueError(f"missing list {key!r} in disc yaml")
        # Normalise bare-dot floats like ".5411498" that ast rejects after a comma.
        body = re.sub(r"(?<![\d.])\.(\d)", r"0.\1", m.group(1))
        values = ast.literal_eval(re.sub(r"\s+", " ", body))
        out[key] = [float(v) for v in values]

    n = len(out["alpha"])  # type: ignore[arg-type]
    for key in ("Cd", "Cl", "Cm"):
        if len(out[key]) != n:  # type: ignore[arg-type]
            raise ValueError(f"{key} has {len(out[key])} entries, expected {n}")  # type: ignore[arg-type]
    return out


def parse_hummel_matlab(text: str) -> dict:
    """Pull the fitted coefficients and the digitised Potts tables out of the
    Hummel 2003 MATLAB source."""

    def scalar(name: str) -> float:
        m = re.search(rf"^\s*{name}\s*=\s*([-+0-9.eE]+)\s*;", text, re.M)
        if not m:
            raise ValueError(f"missing scalar {name!r} in hummel matlab")
        return float(m.group(1))

    def table(name: str) -> list[list[float]]:
        m = re.search(rf"^\s*{name}\s*=\s*\[(.*?)\]\s*;", text, re.M | re.S)
        if not m:
            raise ValueError(f"missing table {name!r} in hummel matlab")
        rows = []
        for line in m.group(1).splitlines():
            line = line.split("%", 1)[0].strip()
            if not line:
                continue
            rows.append([float(tok) for tok in line.split()])
        return rows

    potts_cl = table("CL_data")
    potts_cd = table("CD_data")
    potts_cm = table("CM_data")

    return {
        "fitted_coefficients_ultimate_disc": {
            "CL0": scalar("CLo"), "CLalpha": scalar("CLa"),
            "CD0": scalar("CDo"), "CDalpha": scalar("CDa"),
            "CM0": scalar("CMo"), "CMalpha": scalar("CMa"),
            "CRr": scalar("CRr"),
            "_note": (
                "Fitted to an ULTIMATE disc, not a disc golf disc. CLalpha here "
                "is 1.91/rad; the Giljarhus CFD gives 2.44-2.59/rad for golf "
                "discs. Do not use these for golf disc CL/CD/CM."
            ),
        },
        "damping_long_flight_fit": {"CMq": -1.44e-02, "CRp": -1.25e-02, "CNr": -3.41e-05},
        "damping_short_flight_fit": {"CMq": -0.005, "CRp": -0.0055, "CNr": 7.1e-06},
        "inertia_ultimate_disc": {"I_zz": 0.002352, "I_xy": 0.001219},
        "potts_crowther_2002": {
            "_note": (
                "Digitised from Potts & Crowther (2002) wind tunnel data for a "
                "flying disc. Columns: [alpha_rad, coefficient, alpha_deg]. "
                "Used only as an independent shape cross-check."
            ),
            "cl": potts_cl, "cd": potts_cd, "cm": potts_cm,
        },
    }


# --------------------------------------------------------------------------
# driver
# --------------------------------------------------------------------------
NOTICE = """\
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
"""


def fetch(check_only: bool = False) -> int:
    REFERENCE_DIR.mkdir(parents=True, exist_ok=True)

    if check_only:
        missing = [
            name for name in (
                "giljarhus2022_cfd.json", "hummel2003.json",
                "SOURCES.json", "LICENSE-shotshaper.txt", "NOTICE.md",
            )
            if not (REFERENCE_DIR / name).exists()
        ]
        if missing:
            print(f"reference cache incomplete, missing: {missing}", file=sys.stderr)
            return 1
        data = json.loads((REFERENCE_DIR / "giljarhus2022_cfd.json").read_text())
        print(f"reference cache OK: {len(data['discs'])} CFD discs, "
              f"{len(data['discs']['cd1']['alpha_deg'])} alpha stations each")
        return 0

    sources = {
        "fetched_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "sources": [],
    }

    with tempfile.TemporaryDirectory() as tmp:
        # -- shotshaper ---------------------------------------------------
        ss_dir = Path(tmp) / "shotshaper"
        print(f"fetching {SHOTSHAPER_REPO} ...")
        ss_sha = _git_clone(SHOTSHAPER_REPO, ss_dir)

        discs: dict[str, dict] = {}
        for name in SHOTSHAPER_DISCS:
            rel = f"shotshaper/discs/{name}.yaml"
            text = (ss_dir / rel).read_text() if ss_sha else _raw_get(SHOTSHAPER_REPO, "main", rel)
            if text is None:
                print(f"  could not obtain {rel}", file=sys.stderr)
                return 2
            raw = parse_disc_yaml(text)
            identity = CFD_DISC_IDENTITY[name]
            discs[name] = {
                "case": name,
                "modelled_on": identity["modelled_on"],
                "identity_source": identity["identity_source"],
                "flight_numbers": identity["flight_numbers"],
                "diameter_m": raw["diameter"],
                # Upstream stores specific (per unit mass) moments of inertia,
                # computed from the scanned STL by trimesh: J = integral(r^2 dV)/V.
                # Multiply by mass to get kg m^2.
                "J_xy_m2": raw["J_xy"],
                "J_z_m2": raw["J_z"],
                "alpha_deg": raw["alpha"],
                "cl": raw["Cl"],
                "cd": raw["Cd"],
                "cm": raw["Cm"],
            }

        license_text = (
            (ss_dir / "LICENSE").read_text() if ss_sha
            else _raw_get(SHOTSHAPER_REPO, "main", "LICENSE")
        )
        if license_text is None:
            print("  could not obtain upstream LICENSE", file=sys.stderr)
            return 2
        (REFERENCE_DIR / "LICENSE-shotshaper.txt").write_text(license_text)

        (REFERENCE_DIR / "giljarhus2022_cfd.json").write_text(
            json.dumps(
                {
                    "schema": 1,
                    "citation": (
                        "Giljarhus, K.E.T., Kristiansen, T., Tutkun, M., Oggiano, L. "
                        "(2022). Aerodynamic characteristics of a golf disc. "
                        "Sports Engineering 25, 24. "
                        "https://doi.org/10.1007/s12283-022-00390-5"
                    ),
                    "obtained_from": f"{SHOTSHAPER_REPO} (shotshaper/discs/*.yaml)",
                    "upstream_license": "GPL-3.0 (see LICENSE-shotshaper.txt)",
                    "upstream_commit": ss_sha,
                    "measurement_method": "CFD on scanned real disc geometry",
                    "discs": discs,
                },
                indent=1,
            ) + "\n"
        )
        sources["sources"].append({
            "repo": SHOTSHAPER_REPO, "commit": ss_sha,
            "files": [f"shotshaper/discs/{n}.yaml" for n in SHOTSHAPER_DISCS] + ["LICENSE"],
            "license": "GPL-3.0",
            "used_for": "measured CL/CD/CM tables for four disc golf discs",
        })

        # -- Hummel / Potts ----------------------------------------------
        hu_dir = Path(tmp) / "discgolf"
        print(f"fetching {HUMMEL_REPO} ...")
        hu_sha = _git_clone(HUMMEL_REPO, hu_dir)
        text = (hu_dir / HUMMEL_MATLAB).read_text(errors="replace") if hu_sha \
            else _raw_get(HUMMEL_REPO, "master", HUMMEL_MATLAB)
        if text is None:
            print(f"  could not obtain {HUMMEL_MATLAB}", file=sys.stderr)
            return 2
        hummel = parse_hummel_matlab(text)
        hummel["citation"] = (
            "Hummel, S.A. (2003). Frisbee Flight Simulation and Throw "
            "Biomechanics. MSc thesis, University of California Davis."
        )
        hummel["obtained_from"] = f"{HUMMEL_REPO} ({HUMMEL_MATLAB})"
        hummel["upstream_commit"] = hu_sha
        hummel["schema"] = 1
        (REFERENCE_DIR / "hummel2003.json").write_text(json.dumps(hummel, indent=1) + "\n")
        sources["sources"].append({
            "repo": HUMMEL_REPO, "commit": hu_sha, "files": [HUMMEL_MATLAB],
            "license": "not stated upstream; verbatim copy of a 2003 MSc thesis appendix",
            "used_for": "damping coefficients CMq/CRp/CNr and the Potts & Crowther cross-check",
        })

    (REFERENCE_DIR / "SOURCES.json").write_text(json.dumps(sources, indent=1) + "\n")
    (REFERENCE_DIR / "NOTICE.md").write_text(NOTICE)
    print(f"wrote reference cache to {REFERENCE_DIR}")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true",
                    help="verify the committed cache instead of re-fetching")
    args = ap.parse_args(argv)
    return fetch(check_only=args.check)


if __name__ == "__main__":
    raise SystemExit(main())

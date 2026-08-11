#!/usr/bin/env python3
"""Bake the shipped aerodynamic data: ``game/data/aero/*.json`` + ``discs.json``.

Emits the CONTRACT §3 format: CL/CD/CM PCHIP-resampled onto a uniform 0.5 deg
grid over ``[-90, 90]`` (361 points), so the runtime can do plain linear
interpolation with negligible error.

**PCHIP, not natural cubic splines.**  A natural cubic spline through these
knots overshoots — the measured stations are unevenly spaced, with 10 deg gaps
in the wings meeting 2 deg spacing through the linear range.  An overshoot in
``CM`` near ``alpha = 0`` would introduce a sign change that is not in the data,
which is to say it would fabricate turn or fade behaviour.  PCHIP is
shape-preserving: it cannot introduce an extremum between two knots.
``test_bake.py`` asserts exactly that, and measures how badly a natural spline
would have misbehaved on the same knots.

Usage
-----
    python -m tools.aero.bake              # bake everything
    python -m tools.aero.bake --check      # rebake into memory, diff, report
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import date
from pathlib import Path

import numpy as np

from . import coefficients as C
from .geometry import geometry_from_pdga
from .roster import ROSTER, MEASURED_LINKS, PDGA_URL, check_pdga_consistency

REPO_ROOT = Path(__file__).resolve().parents[2]
DATA_DIR = REPO_ROOT / "game" / "data"
AERO_DIR = DATA_DIR / "aero"

ALPHA_GRID = np.arange(-90.0, 90.0 + 1e-9, 0.5)
SCHEMA = 1


def _round(a: np.ndarray, nd: int = 6) -> list[float]:
    return [round(float(v), nd) for v in a]


def _damping_block() -> dict:
    return {**C.DAMPING, "provenance": C.DAMPING_PROVENANCE}


def build_disc(entry: dict) -> tuple[dict, dict]:
    """Return ``(disc_roster_entry, aero_table)`` for one roster disc."""
    fn = entry["flight_numbers"]
    p = entry["pdga"]

    # The two profile parameters nobody publishes, inferred from the ratings.
    parting_line_m, nose_m = C.infer_shape_from_flight(
        fn["turn"], fn["fade"], p["rim_depth_cm"] / 100.0, p["rim_thickness_cm"] / 100.0
    )
    geom = geometry_from_pdga(
        diameter_cm=p["diameter_cm"], height_cm=p["height_cm"],
        rim_depth_cm=p["rim_depth_cm"], rim_thickness_cm=p["rim_thickness_cm"],
        mass_kg=entry["mass_kg"], parting_line_m=parting_line_m,
        nose_thickness_m=nose_m,
    )

    link = MEASURED_LINKS.get(entry["id"])
    if link is not None:
        provenance = "measured"
        aero_id = entry["id"]
        coeffs = C.measured_coefficients(link["case"], ALPHA_GRID)
        source = f"giljarhus2022:{link['case']}"
        source_note = link["note"]
    else:
        provenance = "derived"
        aero_id = entry["id"]
        coeffs = C.build_coefficients(geom, glide=fn["glide"], speed=fn["speed"],
                                      alpha_grid_deg=ALPHA_GRID)
        source = f"derived:affine({coeffs.base_case})"
        source_note = (
            f"CM affine-mapped from measured case {coeffs.base_case} "
            f"(gain {coeffs.cm_gain:.3f}, offset {coeffs.cm_offset:+.5f}) onto "
            f"anchors predicted from this disc's profile; CD scaled "
            f"{coeffs.cd_scale:.3f} from rim width; CL scaled "
            f"{coeffs.cl_scale:.3f} by the (unfitted) glide heuristic."
        )

    turn_rt, fade_rt = coeffs.recovered_flight_numbers()

    table = {
        "schema": SCHEMA,
        "id": aero_id,
        "source": source,
        "source_note": source_note,
        "aero_provenance": provenance,
        "alpha_deg": _round(coeffs.alpha_deg, 3),
        "cl": _round(coeffs.cl),
        "cd": _round(coeffs.cd),
        "cm": _round(coeffs.cm),
        "damping": _damping_block(),
        "anchors": {
            "cm_at_0deg": round(coeffs.cm0, 6),
            "cm_at_10deg": round(coeffs.cm10, 6),
            "turn_recovered": round(turn_rt, 3),
            "fade_recovered": round(fade_rt, 3),
            "turn_published": fn["turn"],
            "fade_published": fn["fade"],
        },
        "interpolation": "linear on this 0.5 deg grid (already PCHIP-resampled)",
        "generated": str(date.today()),
    }

    disc_entry = {
        "id": entry["id"],
        "name": entry["name"],
        "manufacturer": entry["manufacturer"],
        "category": entry["category"],
        "flight_numbers": fn,
        "geometry": geom.params(),
        "derived": geom.derived(),
        "aero": aero_id,
        "aero_provenance": provenance,
        "aero_source": source,
        "geometry_provenance": {
            "diameter_m": "pdga_published",
            "rim_width_m": "pdga_published",
            "rim_depth_m": "pdga_published",
            "inner_rim_edge_m": "pdga_published",
            "dome_height_m": "derived_from_pdga_height",
            "mass_kg": "estimated_typical_throwing_weight",
            "parting_line_m": "inferred_from_flight_numbers",
            "rim_thickness_m": "inferred_from_flight_numbers",
            "_pdga_record": entry["pdga"],
            "_pdga_source": PDGA_URL,
        },
        "speed_predicted_from_rim_width": round(C.predict_speed(geom.rim_width_m), 2),
    }
    if link is not None:
        disc_entry["measured_link"] = link
    if geom.warnings:
        disc_entry["geometry_warnings"] = list(geom.warnings)
    return disc_entry, table


def bake(check_only: bool = False) -> int:
    bad = check_pdga_consistency()
    warnings: list[str] = []
    if bad:
        warnings.append(
            "PDGA records whose inside-rim-diameter does not equal "
            "diameter - 2*rim_thickness (rounding in the published table): "
            + "; ".join(bad)
        )

    discs, tables = [], {}
    for entry in ROSTER:
        d, t = build_disc(entry)
        discs.append(d)
        tables[t["id"]] = t

    doc = {
        "schema": SCHEMA,
        "generated": str(date.today()),
        "generator": "tools/aero/bake.py",
        "provenance_summary": {
            "measured": sorted(d["id"] for d in discs if d["aero_provenance"] == "measured"),
            "derived": sorted(d["id"] for d in discs if d["aero_provenance"] == "derived"),
            "measured_means": (
                "CL/CD/CM come from CFD run on a scanned real disc "
                "(Giljarhus et al. 2022), resampled onto the shared grid and "
                "otherwise unmodified."
            ),
            "derived_means": (
                "CL/CD/CM are a measured curve affine-mapped onto anchors "
                "predicted from this disc's geometry. The shape is measured; "
                "where the disc sits within that family is modelled."
            ),
            "regression_n": 4,
            "caveats": [
                "The turn and fade regressions have n = 4. R^2 = 0.89 / 0.91 on "
                "four points is not a validated model.",
                "Glide is not recoverable from the measured data; the glide -> CL "
                "scaling is an unfitted heuristic (see game/data/README.md).",
                "parting_line_m and rim_thickness_m are inferred from flight "
                "numbers, not measured. No manufacturer publishes them.",
                "Damping coefficients are Ultimate-disc values (Hummel 2003); "
                "no disc-golf measurement exists.",
            ],
        },
        "discs": discs,
    }

    if check_only:
        existing = json.loads((DATA_DIR / "discs.json").read_text())
        same = existing.get("discs") == doc["discs"]
        print(f"discs.json up to date: {same}")
        for tid, t in tables.items():
            path = AERO_DIR / f"{tid}.json"
            if not path.exists():
                print(f"  MISSING {path}")
                same = False
                continue
            cur = json.loads(path.read_text())
            fresh = all(cur.get(k) == t[k] for k in ("alpha_deg", "cl", "cd", "cm"))
            if not fresh:
                print(f"  STALE {path}")
                same = False
        return 0 if same else 1

    AERO_DIR.mkdir(parents=True, exist_ok=True)
    for tid, t in tables.items():
        (AERO_DIR / f"{tid}.json").write_text(json.dumps(t, indent=1) + "\n")
    (DATA_DIR / "discs.json").write_text(json.dumps(doc, indent=1) + "\n")

    n_meas = len(doc["provenance_summary"]["measured"])
    print(f"baked {len(tables)} aero tables ({len(ALPHA_GRID)} alpha points each) "
          f"into {AERO_DIR}")
    print(f"wrote {DATA_DIR / 'discs.json'}: {len(discs)} discs "
          f"({n_meas} measured, {len(discs) - n_meas} derived)")
    for w in warnings:
        print(f"note: {w}", file=sys.stderr)

    print("\nround-trip (published -> geometry -> CM -> published):")
    print(f"  {'disc':12s} {'prov':9s} {'base':5s} {'turn':>12s} {'fade':>12s}")
    for d in discs:
        t = tables[d["aero"]]["anchors"]
        src = tables[d["aero"]]["source"]
        base = src.split("(")[-1].rstrip(")") if "(" in src else src.split(":")[-1]
        print(f"  {d['id']:12s} {d['aero_provenance']:9s} {base:5s} "
              f"{t['turn_published']:5.0f}->{t['turn_recovered']:6.2f} "
              f"{t['fade_published']:5.0f}->{t['fade_recovered']:6.2f}")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true",
                    help="verify the committed data matches a fresh bake")
    args = ap.parse_args(argv)
    return bake(check_only=args.check)


if __name__ == "__main__":
    raise SystemExit(main())

"""The shipped disc roster: published facts only.

Everything in this module is a *published* number — manufacturer flight ratings
and PDGA equipment-certification measurements — or an explicitly-flagged
estimate.  Nothing here is model output.  ``bake.py`` combines these facts with
``coefficients.py`` to produce ``game/data/discs.json``.

Sources
-------
* Flight numbers: manufacturer published ratings (Innova, Discraft,
  Latitude 64, Discmania).
* ``pdga`` block: the PDGA equipment certification database,
  <https://www.pdga.com/technical-standards/equipment-certification/discs>.
  The PDGA publishes, per approved mould: max weight, diameter, height, rim
  depth, rim thickness and inside rim diameter.  It publishes **nothing** about
  the parting-line height or the axial thickness of the rim wing.
  Retrieved 2026-08 via web search (pdga.com is not directly reachable from the
  build sandbox); every record was cross-checked with the identity
  ``inside rim diameter == diameter - 2 * rim thickness``, which all 14 satisfy.
* ``mass_kg``: **estimated** typical throwing weight, not a published figure.
  Real discs of a given mould ship across a weight range; we pick a
  representative value under the published maximum.

Honesty notes
-------------
* Three moulds (Roc, Buzzz, River) have published diameters of 21.7, 21.7 and
  21.5 cm, above the 21.0-21.3 cm band CONTRACT §2 calls typical.  Those are the
  real published measurements and they are kept unmodified rather than being
  trimmed to fit a comment.
* ``parting_line_m`` and ``rim_thickness_m`` (the nose) are **not published by
  anyone**.  They are inferred from the disc's flight numbers by
  ``coefficients.infer_shape_from_flight`` and are marked ``inferred`` in the
  emitted ``geometry_provenance``.  They are model output wearing the shape of a
  measurement, and the UI must not present them otherwise.
"""

from __future__ import annotations

PDGA_URL = "https://www.pdga.com/technical-standards/equipment-certification/discs"

#: Each entry: published flight ratings + the PDGA certification record.
#: ``pdga`` keys mirror the PDGA column names exactly (centimetres, grams).
ROSTER: list[dict] = [
    {
        "id": "aviar",
        "name": "Innova Aviar",
        "manufacturer": "Innova Champion Discs",
        "category": "putter",
        "flight_numbers": {"speed": 2, "glide": 3, "turn": 0, "fade": 1},
        "mass_kg": 0.175,
        "pdga": {
            "certification": "84-01", "approved": "1984-01-01", "max_weight_g": 176.0,
            "diameter_cm": 21.2, "height_cm": 2.0, "rim_depth_cm": 1.5,
            "rim_thickness_cm": 0.9, "inside_rim_diameter_cm": 19.4,
        },
    },
    {
        "id": "zone",
        "name": "Discraft Zone",
        "manufacturer": "Discraft",
        "category": "approach",
        "flight_numbers": {"speed": 4, "glide": 3, "turn": 0, "fade": 3},
        "mass_kg": 0.173,
        "pdga": {
            "certification": "08-18", "approved": "2008-05-28", "max_weight_g": 175.1,
            "diameter_cm": 21.1, "height_cm": 2.0, "rim_depth_cm": 1.3,
            "rim_thickness_cm": 1.2, "inside_rim_diameter_cm": 18.8,
        },
    },
    {
        "id": "roc",
        "name": "Innova Roc",
        "manufacturer": "Innova Champion Discs",
        "category": "midrange",
        "flight_numbers": {"speed": 4, "glide": 4, "turn": 0, "fade": 3},
        "mass_kg": 0.180,
        "pdga": {
            "certification": "87-05", "approved": "1987-01-01", "max_weight_g": 180.1,
            "diameter_cm": 21.7, "height_cm": 2.0, "rim_depth_cm": 1.3,
            "rim_thickness_cm": 1.2, "inside_rim_diameter_cm": 19.3,
        },
    },
    {
        "id": "buzzz",
        "name": "Discraft Buzzz",
        "manufacturer": "Discraft",
        "category": "midrange",
        "flight_numbers": {"speed": 5, "glide": 4, "turn": -1, "fade": 1},
        "mass_kg": 0.177,
        "pdga": {
            "certification": "03-30", "approved": "2003-09-30", "max_weight_g": 180.1,
            "diameter_cm": 21.7, "height_cm": 1.9, "rim_depth_cm": 1.3,
            "rim_thickness_cm": 1.2, "inside_rim_diameter_cm": 19.3,
        },
    },
    {
        "id": "leopard",
        "name": "Innova Leopard",
        "manufacturer": "Innova Champion Discs",
        "category": "fairway_driver",
        "flight_numbers": {"speed": 6, "glide": 5, "turn": -2, "fade": 1},
        "mass_kg": 0.175,
        "pdga": {
            "certification": "99-07", "approved": "1999-05-12", "max_weight_g": 176.0,
            "diameter_cm": 21.2, "height_cm": 1.6, "rim_depth_cm": 1.1,
            "rim_thickness_cm": 1.6, "inside_rim_diameter_cm": 18.0,
        },
    },
    {
        "id": "teebird",
        "name": "Innova Teebird",
        "manufacturer": "Innova Champion Discs",
        "category": "fairway_driver",
        "flight_numbers": {"speed": 7, "glide": 5, "turn": 0, "fade": 2},
        "mass_kg": 0.175,
        "pdga": {
            "certification": "99-06", "approved": "1999-05-03", "max_weight_g": 176.0,
            "diameter_cm": 21.2, "height_cm": 1.5, "rim_depth_cm": 1.1,
            "rim_thickness_cm": 1.7, "inside_rim_diameter_cm": 17.8,
        },
    },
    {
        "id": "fd",
        "name": "Discmania FD",
        "manufacturer": "Discmania",
        "category": "fairway_driver",
        "flight_numbers": {"speed": 7, "glide": 6, "turn": -1, "fade": 1},
        "mass_kg": 0.175,
        "pdga": {
            "certification": "11-41", "approved": "2011-11-13", "max_weight_g": 176.0,
            "diameter_cm": 21.2, "height_cm": 1.8, "rim_depth_cm": 1.1,
            "rim_thickness_cm": 1.8, "inside_rim_diameter_cm": 17.5,
        },
    },
    {
        "id": "river",
        "name": "Latitude 64 River",
        "manufacturer": "Latitude 64",
        "category": "fairway_driver",
        "flight_numbers": {"speed": 7, "glide": 7, "turn": -1, "fade": 1},
        "mass_kg": 0.174,
        "pdga": {
            "certification": "10-16", "approved": "2010-06-02", "max_weight_g": 178.5,
            "diameter_cm": 21.5, "height_cm": 1.9, "rim_depth_cm": 1.2,
            "rim_thickness_cm": 1.8, "inside_rim_diameter_cm": 17.8,
        },
    },
    {
        "id": "undertaker",
        "name": "Discraft Undertaker",
        "manufacturer": "Discraft",
        "category": "control_driver",
        "flight_numbers": {"speed": 9, "glide": 5, "turn": -1, "fade": 2},
        "mass_kg": 0.173,
        "pdga": {
            "certification": "16-31", "approved": "2016-04-06", "max_weight_g": 175.1,
            "diameter_cm": 21.1, "height_cm": 1.8, "rim_depth_cm": 1.1,
            "rim_thickness_cm": 1.9, "inside_rim_diameter_cm": 17.5,
        },
    },
    {
        "id": "firebird",
        "name": "Innova Firebird",
        "manufacturer": "Innova Champion Discs",
        "category": "control_driver",
        "flight_numbers": {"speed": 9, "glide": 3, "turn": 0, "fade": 4},
        "mass_kg": 0.175,
        "pdga": {
            "certification": "00-06", "approved": "2000-03-21", "max_weight_g": 175.1,
            "diameter_cm": 21.1, "height_cm": 1.4, "rim_depth_cm": 1.2,
            "rim_thickness_cm": 1.9, "inside_rim_diameter_cm": 17.3,
        },
    },
    {
        "id": "roadrunner",
        "name": "Innova Roadrunner",
        "manufacturer": "Innova Champion Discs",
        "category": "control_driver",
        "flight_numbers": {"speed": 9, "glide": 5, "turn": -4, "fade": 1},
        "mass_kg": 0.175,
        "pdga": {
            "certification": "05-16", "approved": "2005-08-27", "max_weight_g": 175.1,
            "diameter_cm": 21.1, "height_cm": 1.4, "rim_depth_cm": 1.2,
            "rim_thickness_cm": 1.8, "inside_rim_diameter_cm": 17.5,
        },
    },
    {
        "id": "wraith",
        "name": "Innova Wraith",
        "manufacturer": "Innova Champion Discs",
        "category": "distance_driver",
        "flight_numbers": {"speed": 11, "glide": 5, "turn": -1, "fade": 3},
        "mass_kg": 0.175,
        "pdga": {
            "certification": "05-15", "approved": "2005-08-15", "max_weight_g": 175.1,
            "diameter_cm": 21.1, "height_cm": 1.4, "rim_depth_cm": 1.2,
            "rim_thickness_cm": 2.1, "inside_rim_diameter_cm": 16.9,
        },
    },
    {
        "id": "destroyer",
        "name": "Innova Destroyer",
        "manufacturer": "Innova Champion Discs",
        "category": "distance_driver",
        "flight_numbers": {"speed": 12, "glide": 5, "turn": -1, "fade": 3},
        "mass_kg": 0.175,
        "pdga": {
            "certification": "07-38", "approved": "2007-06-26", "max_weight_g": 175.1,
            "diameter_cm": 21.1, "height_cm": 1.4, "rim_depth_cm": 1.2,
            "rim_thickness_cm": 2.2, "inside_rim_diameter_cm": 16.7,
        },
    },
    {
        "id": "boss",
        "name": "Innova Boss",
        "manufacturer": "Innova Champion Discs",
        "category": "distance_driver",
        "flight_numbers": {"speed": 13, "glide": 5, "turn": -1, "fade": 2},
        "mass_kg": 0.175,
        "pdga": {
            "certification": "08-28", "approved": "2008-08-26", "max_weight_g": 176.0,
            "diameter_cm": 21.2, "height_cm": 1.5, "rim_depth_cm": 1.2,
            "rim_thickness_cm": 2.5, "inside_rim_diameter_cm": 16.2,
        },
    },
]

#: Which roster entries are the four CFD cases, and how confident that link is.
#: ``exact`` means the upstream data file names the mould in its header comment.
#: ``class_match`` means the CFD case has no stated identity and we are matching
#: it on rating class alone — a weaker claim, surfaced in the UI copy.
MEASURED_LINKS: dict[str, dict] = {
    "firebird": {"case": "cd1", "confidence": "exact",
                 "note": "cd1.yaml header: 'Overstable control driver, modelled after an Innova Firebird'"},
    "teebird": {"case": "fd2", "confidence": "exact",
                "note": "fd2.yaml header: 'Stable fairway driver, modelled after an Innova Teebird'"},
    "roadrunner": {"case": "cd5", "confidence": "exact",
                   "note": "cd5.yaml header: 'Understable control driver, modelled after an Innova Roadrunner'"},
    "destroyer": {"case": "dd2", "confidence": "class_match",
                  "note": ("dd2.yaml names no mould. It is a 12/5/-1/3-class distance driver, "
                           "which is the Destroyer's class, but the paper does not state that "
                           "the scanned disc was a Destroyer. Treat the mapping as a class "
                           "match, not an identification.")},
}


def by_id(disc_id: str) -> dict:
    for entry in ROSTER:
        if entry["id"] == disc_id:
            return entry
    raise KeyError(disc_id)


def check_pdga_consistency() -> list[str]:
    """Return a list of PDGA records whose published numbers are internally
    inconsistent (``inside rim diameter != diameter - 2 * rim thickness``)."""
    bad = []
    for e in ROSTER:
        p = e["pdga"]
        expect = p["diameter_cm"] - 2.0 * p["rim_thickness_cm"]
        if abs(expect - p["inside_rim_diameter_cm"]) > 0.051:
            bad.append(f"{e['id']}: inside rim {p['inside_rim_diameter_cm']} "
                       f"!= {expect:.2f}")
    return bad

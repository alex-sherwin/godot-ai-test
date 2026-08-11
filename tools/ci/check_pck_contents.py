#!/usr/bin/env python3
"""Assert the exported ``.pck`` actually contains the program.

This is the last link in the chain: everything before it reasons about the
*source tree*, while this reads the artefact that is about to be uploaded to
Pages. It catches the export dropping something — a preset filter that stops
packing a directory, a resource the exporter silently skips.

**What it does not catch, stated plainly so nobody relies on it for that.**
This check enumerates what is on disk and looks for it in the pack, so if a
script was never committed in the first place, it is not on disk in a clean
checkout, it is not in the expected set, and this check passes. Measured, with
``scripts/physics/atmosphere.gd`` deleted from a scratch tree:

    godot --headless --export-release   -> exit 0, 39,513,091-byte wasm,
                                          605,044-byte pck, all size
                                          assertions pass
    check_pck_contents.py               -> exit 0  (!)
    check_scene_refs.py                 -> exit 1  (untracked / missing ref)
    tests/check_resources.gd            -> exit 1  ("main.tscn root node has
                                          no script attached")

That is the six-green-deploys failure, and the two checks that catch it are the
other two. The three are complementary; none of them is sufficient alone.

The pack's file index stores paths relative to ``res://`` — ``data/discs.json``,
not ``res://data/discs.json``. Scripts appear under the ``.gdc`` extension when
``script_export_mode`` is binary tokens (it is, see ``export_presets.cfg``), and
scenes appear as ``.godot/exported/<n>/export-<md5>-<name>.scn`` rather than
under their source path, so they are matched by the ``-<name>.scn`` suffix.

    python3 tools/ci/check_pck_contents.py web/public/game/index.pck
"""

from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PROJECT_DIR = REPO_ROOT / "game"


def expected_entries() -> list[tuple[str, str]]:
    """(kind, needle) for everything that must be in the pack."""
    out: list[tuple[str, str]] = []
    for path in sorted(PROJECT_DIR.rglob("*.gd")):
        rel = path.relative_to(PROJECT_DIR).as_posix()
        if rel.startswith(".godot/"):
            continue
        # `export_filter = all_resources`, so tests/ ships too. Left in the
        # check rather than excluded: if the preset ever stops packing a
        # directory, this is where it should be noticed.
        out.append(("script", rel[:-3] + ".gdc"))
    for path in sorted((PROJECT_DIR / "data").rglob("*.json")):
        out.append(("data", path.relative_to(PROJECT_DIR).as_posix()))
    for path in sorted((PROJECT_DIR / "scenes").rglob("*.tscn")):
        out.append(("scene", "-" + path.stem + ".scn"))
    return out


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    pck = Path(sys.argv[1])
    if not pck.is_file():
        print(f"FAIL — {pck} does not exist", file=sys.stderr)
        return 1
    blob = pck.read_bytes()

    entries = expected_entries()
    missing = [(kind, needle) for kind, needle in entries
               if blob.count(needle.encode()) == 0]

    counts: dict[str, int] = {}
    for kind, _ in entries:
        counts[kind] = counts.get(kind, 0) + 1
    print(f"{pck} — {len(blob):,} bytes")
    print("checked: " + ", ".join(f"{n} {k}s" for k, n in sorted(counts.items())))

    if missing:
        print("\nFAIL — the exported pack is missing project files:", file=sys.stderr)
        for kind, needle in missing:
            print(f"  - {kind}: {needle}", file=sys.stderr)
        print("\nThe export still exited 0. That is exactly the failure mode this "
              "check exists for.", file=sys.stderr)
        return 1
    print("OK — every shipped script, scene and data file is in the pack.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

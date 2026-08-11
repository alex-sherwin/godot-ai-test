#!/usr/bin/env python3
"""Assert that everything ``game/scenes/main.tscn`` needs is in the committed tree.

Why this exists
---------------
Six deploys of this project went green while the shipped build had no physics
core in it.  ``godot --headless --export-release`` returns **exit 0** with
scripts missing: the ``.pck`` is written, the ``.wasm`` is written, every size
assertion passes, and the failure only surfaces in a browser, where GDScript
resolves ``class_name`` at parse time and the scene dies on load.  A green
export is therefore not evidence that the export contains the program.

Neither is loading the scene back in Godot, incidentally: ``load()`` on a
script with an unresolved ``class_name`` dependency still returns a non-null
GDScript object and ``PackedScene.instantiate()`` still returns a node.  (The
companion check ``game/tests/check_resources.gd`` uses ``GDScript.reload()``,
which does report the parse error, so the two checks cover different halves.)

What this checks
----------------
Walks the transitive closure of ``game/scenes/main.tscn`` over three kinds of
edge, and requires every file it reaches to exist **and be tracked by git**:

1. ``[ext_resource path="res://..."]`` in ``.tscn`` / ``.tres``.
2. Any ``res://`` string literal in a reachable ``.gd`` — ``preload``,
   ``load``, ``ResourceLoader.exists``, a path constant, anything.
3. ``class_name`` edges: an identifier used in a reachable script that some
   script in the project declares via ``class_name``.  This is the edge that
   ``.tscn`` text does not mention at all and that broke the six deploys.

It also requires every ``.gd`` and ``.tscn`` under ``game/`` to be tracked,
reachable or not, so "forgot to ``git add``" is caught before it is pushed
rather than after it is deployed.

Exits non-zero with a specific list on any failure.  No Godot needed, so it
runs in a couple of hundred milliseconds and can gate a pull request.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PROJECT_DIR = REPO_ROOT / "game"  # res:// maps here
ROOT_SCENE = "res://scenes/main.tscn"

# `[ext_resource type="Script" path="res://scripts/app/flight_app.gd" id="1"]`
EXT_RESOURCE_RE = re.compile(r'\bpath\s*=\s*"(res://[^"]+)"')
# Any res:// string literal, wherever it appears.
RES_LITERAL_RE = re.compile(r'"(res://[^"]*)"')
# `class_name Foo` / `class_name Foo extends Bar`
CLASS_NAME_RE = re.compile(r"^\s*class_name\s+([A-Za-z_][A-Za-z0-9_]*)", re.MULTILINE)
IDENTIFIER_RE = re.compile(r"\b([A-Z][A-Za-z0-9_]*)\b")

RESOURCE_SUFFIXES = {".gd", ".tscn", ".tres", ".json", ".svg", ".png", ".cfg"}


def git_tracked() -> set[str]:
    out = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "ls-files"],
        check=True, capture_output=True, text=True,
    ).stdout
    return {line for line in out.splitlines() if line}


def res_to_rel(res_path: str) -> str:
    """`res://scripts/x.gd` -> `game/scripts/x.gd`, repo-relative."""
    return "game/" + res_path[len("res://"):]


def build_class_table(tracked: set[str]) -> dict[str, str]:
    """`class_name` -> res:// path, over every tracked script in the project."""
    table: dict[str, str] = {}
    for rel in sorted(tracked):
        if not rel.startswith("game/") or not rel.endswith(".gd"):
            continue
        text = (REPO_ROOT / rel).read_text(encoding="utf-8", errors="replace")
        for name in CLASS_NAME_RE.findall(text):
            table[name] = "res://" + rel[len("game/"):]
    return table


def refs_from(res_path: str, text: str, classes: dict[str, str]) -> set[str]:
    """Every res:// path this file depends on."""
    out: set[str] = set()
    if res_path.endswith((".tscn", ".tres")):
        out.update(EXT_RESOURCE_RE.findall(text))
    if res_path.endswith(".gd"):
        # Directory prefixes (`res://data/aero/`) are joined with a filename at
        # runtime; they are not files and are checked as directories instead.
        out.update(RES_LITERAL_RE.findall(text))
        # class_name edges. Over-matching an identifier only widens the set of
        # files required to exist, which is the safe direction to be wrong in.
        for ident in set(IDENTIFIER_RE.findall(text)):
            if ident in classes:
                out.add(classes[ident])
    return out


def walk(classes: dict[str, str]) -> tuple[set[str], list[str]]:
    """Transitive closure from the root scene. Returns (reached, problems)."""
    problems: list[str] = []
    reached: set[str] = set()
    queue = [ROOT_SCENE]
    while queue:
        res_path = queue.pop()
        if res_path in reached:
            continue
        reached.add(res_path)
        rel = res_to_rel(res_path)
        disk = REPO_ROOT / rel
        if res_path.endswith("/") or res_path == "res://":
            if not disk.is_dir():
                problems.append(f"{res_path} (directory) does not exist")
            continue
        if not disk.is_file():
            problems.append(f"{res_path} is referenced but does not exist on disk")
            continue
        if disk.suffix not in RESOURCE_SUFFIXES:
            continue
        if disk.suffix in {".gd", ".tscn", ".tres"}:
            text = disk.read_text(encoding="utf-8", errors="replace")
            queue.extend(refs_from(res_path, text, classes))
    return reached, problems


def main() -> int:
    tracked = git_tracked()
    classes = build_class_table(tracked)
    reached, problems = walk(classes)

    # 1. Everything reachable from the root scene must be committed.
    for res_path in sorted(reached):
        if res_path.endswith("/") or res_path == "res://":
            continue
        rel = res_to_rel(res_path)
        if not (REPO_ROOT / rel).is_file():
            continue  # already reported as missing
        if rel not in tracked:
            problems.append(
                f"{res_path} exists on disk but is NOT tracked by git — "
                "it would be absent from a clean checkout, and the export "
                "would still succeed"
            )

    # 2. Nothing in the project may be untracked, reachable or not.
    for path in sorted(PROJECT_DIR.rglob("*")):
        if not path.is_file() or path.suffix not in {".gd", ".tscn", ".tres"}:
            continue
        rel = path.relative_to(REPO_ROOT).as_posix()
        if rel.startswith("game/.godot/"):
            continue
        if rel not in tracked:
            problems.append(f"{rel} is untracked (add it or delete it)")

    scripts = sorted(p for p in reached if p.endswith(".gd"))
    scenes = sorted(p for p in reached if p.endswith(".tscn"))
    data = sorted(p for p in reached if p.endswith(".json"))
    print(f"root scene: {ROOT_SCENE}")
    print(f"reachable: {len(scripts)} scripts, {len(scenes)} scenes, {len(data)} data files")
    print(f"class_name table: {len(classes)} global classes in the committed tree")

    if problems:
        print("\nFAIL — the committed tree cannot build this scene:", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        return 1
    print("OK — every resource main.tscn reaches is present and committed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

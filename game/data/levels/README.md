# `game/data/levels` — the puzzle level schema

Ten portal-mode levels, plus `index.json`, which gives the menu order.

**Track P3 owns this schema. Track P2 consumes it.** `game/scripts/puzzle/level_data.gd`
is the normative definition — this file is the prose copy and the two are kept in
step by `game/tests/suites/test_puzzle.gd`.

The levels are generated, not hand-written: every number in an `expected` block
is a **measurement** taken from `tools/aero/validate.py`'s reference integrator
at `dt = 1/240` through a multi-room portal harness, and
`game/tests/suites/test_level_replay.gd` replays all ten through the real game
code and asserts the landings to ±0.5 m. Hand-editing a level file is fine —
hand-editing an `expected` block is how you get a green build that lies.

```
game/data/levels/
  index.json                 menu order
  01_crosswind_hall.json     ... 10_the_gauntlet.json
```

---

## Coordinate frames — the one thing to read before touching geometry

Every room authors its geometry in **its own local frame with the floor at
y = 0**: `bounds`, `portals[].center`, `surfaces[].rect`, `barriers[].box`,
`buttons[].center`, `tee.position` and `flag.position` are all room-local.

`rooms[].world_origin` translates that frame into the one shared world the
simulator and the renderer both use:

```
world = local + world_origin          # TRANSLATION ONLY, never a rotation
```

Three invariants, all re-checked at load:

1. **`world_origin.y == 0`.** `DiscFlightSim` has a single ground plane and every
   room floor is y = 0.
2. **The tee lands exactly on the world origin.** `DiscFlightSim.launch()` always
   starts the disc at `(0, release_height, 0)` and takes no tee parameter, so the
   level data is what moves, not the sim.
3. **Rooms do not overlap in world space**, so the renderer can draw them all at
   once.

A room may never be *rotated* into world space. Each room's wind is a world-frame
vector quoted in the room's own coordinates; rotating the room would leave the
wind pointing somewhere the level data does not describe. Rotation between rooms
is what the portals are for — and per `PORTAL_CONTRACT` §6 a wall-to-wall pair
that both use world-up is a pure yaw, which the flight dynamics are exactly
equivariant under, so such a portal is *physically free*. That is the fact the
first seven levels are built on.

---

## Top-level fields

| field | meaning |
|---|---|
| `schema` | 1 |
| `id` | matches the filename, without `.json` |
| `order` | menu order, 1..N, no gaps |
| `name`, `concept`, `hint` | `hint` is the one sentence shown to the player |
| `teaches` | free-form tags |
| `portal_disc_convention` | prose: who places which end. Stated per level because it changes the puzzle |
| `rooms` | see below |
| `portals` | authored portals; runtime ones are created by portal discs |
| `tee`, `flag` | `{room, position}`, room-local |
| `buttons` | trigger spheres armed by a disc passing through |
| `portal_discs` | the portal-opening discs this level grants |
| `allowed_discs` | `[{id, count}]`, ids from `discs.json`, `-1` = unlimited |
| `objective` | `{type, max_discs, requires_buttons, score}` |
| `medals` | `gold` / `silver` / `bronze`, each `{max_discs, max_flag_distance_m}` |
| `intended_solution` | the validated line. The CI gate replays it |
| `alternate_solutions` | other validated lines |
| `validation` | free-form: baselines, decoys, failure modes, design notes |

### `rooms[]`

```jsonc
{
  "id": "tee_chamber",
  "name": "Tee Chamber",
  "bounds": { "x": [-30, 30], "y": [0, 16], "z": [-20, 12] },   // room-local
  "world_origin": [0, 0, 4],                                     // local -> world
  "environment": {
    "altitude_m": 0,
    "temperature_c": 15,
    "air_density_override_kg_m3": 0.695,   // OPTIONAL, wins over altitude/temp
    "wind_mps": [0, 0, 0],                 // world frame, this room only
    "gravity_mps2": 9.81,
    "note": "free text for the room-info panel"
  },
  "surfaces": [ ... ],     // only where portalability or naming matters
  "barriers": [ ... ]      // solid slabs inside the room
}
```

The **floor is the ground plane** and is not a surface. The other five faces of
`bounds` are solid walls; a disc that strikes one stops dead and drops, which is
a real scoring outcome, not a retry.

### `rooms[].surfaces[]`

```jsonc
{ "id": "far_panel",
  "plane":  { "axis": "z", "value": -40 },
  "normal": "+z",                            // points INTO the room
  "rect":   { "x": [2, 28], "y": [2, 20] },  // the two non-plane axes; unstated
                                             // axes inherit the room's extent
  "portalable": true }
```

A surface names part of a wall. `portalable: true` is what a portal disc can open
a portal on; everything else is stone. A panel bounded on at least two sides by
stone — and, from Level 7 on, with a minimum height — is what turns a placement
into a throw.

### `rooms[].barriers[]`

```jsonc
{ "id": "gate",
  "box": { "x": [-50, 50], "y": [0, 22], "z": [-56, -54] },
  "starts_solid": true,
  "opened_by": ["key_a", "key_b"],   // ALL listed buttons required
  "opens_between_throws": true }     // never mid-flight
```

`opened_by: []` means permanent (Level 9's lintel). Barriers open **between
throws**, matching `PORTAL_CONTRACT` §7's rule for portals: a puzzle whose
geometry changes mid-flight cannot be planned.

### `portals[]`

```jsonc
{ "id": "p1a", "room": "tee_chamber",
  "center": [0, 6, -20],       // room-local, and FLUSH in one of the room's walls
  "facing": "+z",              // outward normal, points INTO the room
  "up": "+y",                  // world-up for every NON-inverting portal
  "width_m": 36, "height_m": 12,
  "link": "p1b",
  "inverting": false,          // true = DIVE portal
  "starts_open": true,
  "opened_by": ["some_button"] // optional
}
```

* **`inverting` is the authoritative flag.** The loader folds it into the portal's
  mounted up vector (`up -> -up`), so a dive portal is a frame mounted upside
  down — a proper rotation, never a reflection. Every consumer downstream reads
  `up` and does not branch on the flag.
* Setting it on **either** end makes the pair a dive pair.
* A non-inverting portal **must** use world-up, and the loader rejects one that
  does not. That is what keeps ordinary pairs pure-yaw and therefore free, and
  makes inversion opt-in rather than accidental.
* A portal is a **hole cut in the wall it is set in**, inset by the disc radius —
  exactly the rectangle `DiscFlightSim` fires its crossing event on. A disc whose
  centre passes within one radius of the rim hits stone, in the harness and in the
  engine alike.

### `buttons[]` and `portal_discs[]`

```jsonc
{ "id": "key_a", "room": "lock_hall", "center": [-2.9, 5.9, -32.1],
  "radius_m": 3.5, "unlocks": ["gate"] }

{ "id": "portal_a", "count": 1, "inverting": false,
  "opens_portal_id": "placed_a",   // the id the created portal takes
  "link": "exit_fixed",            // the end it pairs with
  "width_m": 10, "height_m": 8,    // clamped to fit inside the struck panel
  "note": "..." }
```

A button is armed by the flight **path**, tested per substep (0.11 m at 27 m/s),
not by the landing point. A portal disc is spent on throw whether or not it opens
anything, never scores, and its portal is clamped to fit inside the panel it
struck — which is why Level 10's impact at y = 4.88 opens a 14 × 12 portal
centred at y = 8.00.

An authored portal may `link` to a portal an unthrown portal disc will create.
Until it exists there is no link and no hole: the wall stays solid. That is a
state, not an error.

### `objective` and `medals`

`type` is one of `closest_to_flag`, `min_discs_then_closest`,
`buttons_then_flag`. `max_discs` is the hard budget for one attempt.

Medals are evaluated after every throw against `(discs_used, best_flag_distance,
buttons armed)`, and the best tier reached during the attempt is the one awarded
— so improving your distance with an extra disc can win silver without
retroactively costing you a gold you had already earned. Tiers must be **nested**
(gold's budget ≤ silver's ≤ bronze's, on both axes); CI checks it, because a
non-nested tier table means a threshold nobody can reach.

### `intended_solution[]` / `alternate_solutions[]`

```jsonc
{ "role": "score",             // "arm" | "place_portal_a" | "arm+place_portal_a"
  "disc": "roc",
  "speed_mps": 20, "spin_rps": 18,
  "nose_deg": 0, "hyzer_deg": 3, "launch_deg": 10, "heading_deg": 20,
  "release_height_m": 1.4,
  "expected": {                // MEASURED, dt = 1/240. Do not hand-edit.
    "room": "crosswind_hall",
    "landing": [-0.96, 0, -33.03],   // room-LOCAL
    "flag_distance_m": 0.963,
    "flight_time_s": 4.358,
    "outcome": "floor"               // "floor" | "wall" | "surface:<id>" | "barrier:<id>"
  } }
```

Alternate lines in the multi-throw levels are quoted **against the intended
placement / arming throw**, and both the CI gate and any "show me" button prefix
it automatically when the alternates do not supply their own.

---

## Provenance, and editing a level

These files were baked from the level-design pass's validated geometry: a script
applied the content edits, computed the layout, and re-measured every solution
through `tools/aero/validate.py`'s integrator wrapped in a multi-room portal
harness. That harness is a design-time artefact and is **not in this repo** —
what ships is the measurement it produced, and the gate that re-checks it against
the engine on every push.

So: to change a level's geometry, edit the file and then **delete the `expected`
blocks you invalidated and re-measure them from the gate's own output**, which
prints the engine's landing for every step. Do not adjust an `expected` number to
match a result you have not looked at; the whole value of these files is that
each one is a measurement somebody took on purpose.

Run the gate after any edit:

```bash
godot --headless --path game --script res://tests/run_puzzle_tests.gd
```

It prints the worst landing disagreement between the reference harness and the
engine across all ten levels. That number, not the pass line, is the thing to
watch: it is currently millimetres, and a jump to decimetres means something
changed even while the gate is still green.

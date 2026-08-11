# Disc Golf Flight Lab

An interactive disc golf flight simulator, built in Godot 4.7 and published to
GitHub Pages as a WebGL2 build.

**Live site:** https://alex-sherwin.github.io/godot-ai-test/

A disc in flight is a spinning, bevelled wing. It generates lift, it resists the
air, and because it is a gyroscope, the aerodynamic torque acting on it does not
tip it over — it precesses, turning the disc sideways instead. That is where
*turn* and *fade* actually come from. This models that behaviour directly rather
than replaying a canned curve: a fixed-step RK4 integrator runs at 240 Hz over
CL/CD/CM tables that come, for four discs, from published CFD.

**One build ships two modes.** They share the physics core, the disc roster, the
theme and the keyboard map, so shipping them separately would mean shipping the
40 MB engine twice. The mode is chosen on the query string before the engine
downloads — `game/index.html` for the sandbox, `game/index.html?mode=puzzle`
for the levels — which also makes each one a linkable URL.

**Flight Lab** — the sandbox. One open 200 m range. Pick one of 14 discs, set
the release, watch it fly, and read the numbers back. Or open the designer, edit
the eight parameters the disc's cross-section is lathed from, and watch the
mesh, the moments of inertia and the reference area move with them.

**Portal Puzzles** — ten sealed chambers linked by portals, each room with its
own air density, wind and gravity. Drag to aim; a ghost line predicts the throw
*inside the launch room only* and stops at the portal, because what the far room
does to the disc is the puzzle. You look through an aperture and see the
destination room live, from the transformed viewpoint — the same
`M = T_B · R_y(π) · T_A⁻¹` the simulator flies the disc through, applied to the
camera. Three levels are entered through a portal mounted upside down, which
turns the disc into an inverted wing and drops it out of the sky.

---

## What this is honest about

Read this before trusting a number. The short version is in the app itself,
behind the **?** button; the long version is in
[`game/data/README.md`](game/data/README.md).

**Four discs are measured. Ten are derived.** Real aerodynamic data exists for
exactly four disc golf discs — Giljarhus, Kristiansen, Tutkun & Oggiano,
*Aerodynamic characteristics of a golf disc*, Sports Engineering 25:24 (2022),
CFD on 3D scans of real moulds, published with
[`shotshaper`](https://github.com/kegiljarhus/shotshaper). Every other disc's
coefficients are constructed by mapping its geometry and published flight
numbers onto those four anchors, through a regression with **n = 4**:

```
turn ≈ 296.8 · CM(0°)  + 3.31     R² = 0.89, n = 4
fade ≈ 182.8 · CM(10°) − 4.22     R² = 0.91, n = 4
```

An R² computed on four points is barely constrained. Read a derived disc as
"plausibly in the right family", not as a measurement of that mould. Every disc
carries an `aero_provenance` field and the UI badges it on every screen it
appears on.

**`PRECESSION_GAIN = 2.0` is an empirical constant, not a derived one.** The
precession *kinematics* are exact and CI proves them: the rate is
`M / (I_zz · spin)`, and `tests/suites/test_precession_law.gd` measures it
against a raw Euler integration with no quasi-steady assumption. The factor of
2 sitting on top of that law is a calibration constant. It is there because at
1.0 the flights are wrong in a consistent way — a distance driver hangs for
9.4 s instead of ~6, fade is about half of reality, an understable disc never
turns over — and at 2.0 all four behavioural targets are met and the model
reproduces `shotshaper`'s own example throw to 0.4%. The leading explanation is
structural: the source CFD is steady-state RANS on a **non-rotating** disc, so
it cannot contain the spin-induced rolling moment `C_Rr`, which is exactly a
moment that would drive bank angle. In Track B's own words, it is *"a fudge
factor with a plausible story, not a measurement."*

**Glide is not fittable from n = 4, and ships flagged as such.** Three of the
four measured discs are rated glide 5 and one glide 3 — one contrast, buried an
order of magnitude inside the scatter among the glide-5 discs themselves. The
glide → CL scaling is an author-chosen heuristic;
`coefficients.GLIDE_MODEL_IS_FITTED` is `False` and a test asserts the lack of
separation that justifies it.

**Pitch and roll damping are effectively inert.** `c_mq` and `c_rp` are
Hummel's (2003) fit to an *Ultimate* disc, used unchanged because no disc-golf
measurement of either exists. Under this model's non-dimensionalisation they
contribute ~0.1% of the static pitching moment. Spin-down (`c_nr`) was
recalibrated for this equation and does matter — see `game/data/README.md`.

### What this model gets wrong

**It over-turns at low hyzer.** `PRECESSION_GAIN` is one scalar on the whole
precession response, so it doubles the early turn as well as the late fade.
Measured through the shipped physics at 27 m/s / 25 rev/s / 10° launch, every
roster disc rated turn −1 or lower turns over and finishes right from a flat
release:

| disc | flat (0° hyzer) | 9° hyzer | 22° hyzer |
| --- | --- | --- | --- |
| Destroyer 12/5/−1/3 | 70 m, **+17 m** | 79 m, **+20 m** | 114 m, +29 m |
| Wraith 11/5/−1/3 | 76 m, **+21 m** | 96 m, **+30 m** | 110 m, −10 m |
| Teebird 7/5/**0**/2 | 101 m, −12 m | 97 m, −27 m | 91 m, −31 m |
| Firebird 9/3/**0**/4 | 94 m, −15 m | 90 m, −25 m | 82 m, −26 m |

A real overstable 12-speed thrown flat and hard finishes **left**, not 17 m
right. The turn-0 discs are right; the turn−negative discs are not. The
per-category release defaults in `ThrowPanel.CATEGORY_PROFILE` were swept
against the shipped physics and compensate for this, which is why the distance
driver defaults to 22° of hyzer — more than a real thrower uses. This is
recorded as a defect rather than hidden: fixing it properly means measuring
`C_Rr` on a *rotating* golf disc, and `C_Rr` and `PRECESSION_GAIN` must then be
revisited **together**, because they are two descriptions of the same missing
physics.

**60 fps is unverified.** There is no GPU on the machine this was built and
tested on. llvmpipe gives 5–7 fps and SwiftShader 1–2, both pure CPU
rasterisation, and neither says anything about real hardware. What *is*
measured, by `tests/bench.gd` on this machine: the simulation costs
**~0.048 ms of CPU per 60 fps frame** (0.29% of a 16.7 ms budget), and the
browser build reports **~190 draw calls and ~30k primitives** per frame — which
is trivial for any integrated GPU of the last decade. So the framerate claim is
a reasonable expectation from the CPU cost and the draw-call count, and **not a
measurement**. Nobody has run this on real graphics hardware.

Portal Puzzles is measured in the same units and is no more expensive: **135–183
draw calls and 10k–18k primitives** across the ten levels with one or two portals
rendering live, against the same ~500–800 working ceiling that WebGL2's
validation layer imposes. A portal into a *room* costs about what a room costs,
and a room is one draw call — which is why rooms, and not the two-slot cap alone,
are what make the budget comfortable. The same "unverified on real hardware"
caveat applies, for the same reason.

**Three roster discs are outside the current PDGA diameter band.** The Roc and
Buzzz are published at 21.7 cm and the River at 21.5, against a 21.0–21.3 cm
standard. Those are the real certification figures and they ship unmodified;
the designer's checker says so in those words rather than calling an approved
disc illegal.

### What the portals do to the physics

Every caveat above applies to Portal Puzzles unchanged — it is the same
integrator, the same coefficient tables, the same four-measured-ten-derived
roster. The portals add three claims of their own, and all three are measured.

**A wall-to-wall portal does not perturb the flight, exactly.** The dynamics are
equivariant under rotations about world-up and only those, because gravity is
the only term that does not rotate with the state. A pure-yaw pair therefore
reproduces the rotated baseline to **1.88e-6 m** — the float32 content of the
authored `Transform3D`, and not improvable in the engine's own precision. (With
the 0.1 mm re-crossing nudge that `PORTAL_CONTRACT` §5 mandates in place, it is
~1e-4 m; the nudge is the whole of the difference, and the test zeroes it so it
measures the transform rather than asserting around a constant.) Level design
uses this: wall portals *always* take world-up as their up vector, so a
sideways hop through a wall costs the throw nothing and the only thing that
changes is which room's wind the disc is in.

**A dive portal costs 40–45% of the distance and collapses the flight to
2.5–2.9 s, whatever disc you throw.** Measured: Buzzz 96 m → 54 m and 6.92 s →
2.65 s; Teebird 100 m → 60 m with fade reversing sign; Destroyer 67 m → 55 m.
This is correct physics, not a bug and not a scripted effect:
`lift_dir = j × v̂` with `j = normalise(v̂ × n)`, so flipping the disc's normal
points lift **down**, and an inverted disc is an inverted wing. It is used
deliberately, as a mechanic, and it is telegraphed — orange aperture, scrolling
chevrons, a `DIVE` label, an orange badge on the level card and a panel that
states the numbers — because nothing about the geometry tells you a hole in a
wall will end your throw in under three seconds.

**The ten intended solutions are asserted in CI, to ±0.5 m.**
`tests/suites/test_level_replay.gd` replays every shipped level's
`intended_solution` through the real `PuzzleSession` and checks the landing
against the distance baked into the level file. Those distances are
measurements taken against the shipped integrator, not estimates, so this is a
physics regression test wearing level content as its fixture: change
`PRECESSION_GAIN`, a coefficient table, the portal transform, the per-room
environment split or the event locator, and it fails with the level and the
metre error printed. Without it a level can silently become unsolvable and
nobody finds out until a player cannot gold Level 9.

**The renderer's own caveats.** There is no oblique near-plane clipping in
Godot — no projection-matrix setter exists, `set_frustum()` cannot express one,
and the PRs that would have added it are closed. The three-part fallback
`PORTAL_CONTRACT` §8 specifies is what ships: a fitted perpendicular near plane,
a world-space `discard` on the disc and its crossing ghost, and rooms built with
single-sided inward-facing walls so a portal camera behind the exit wall does
not see it. The residue is a thin wedge at the aperture edge, visible only with
your eye nearly in the portal's plane. Depth is 1: a portal seen through a
portal is drawn flat, deliberately, because the cost of recursion is geometric.
At most two portals render at once.

---

## Repository layout

```
.
├── .github/
│   ├── actions/setup-godot/          composite action: editor + export templates
│   └── workflows/deploy-pages.yml    CI: test → export → bundle → deploy
├── game/                             Godot 4.7 project
│   ├── project.godot                 GL Compatibility renderer, 1280×720 base
│   ├── export_presets.cfg            "Web" preset (committed; see below)
│   ├── data/                         baked disc roster + coefficient tables
│   ├── scenes/boot.tscn              run/main_scene: picks the mode, hosts it
│   ├── scenes/main.tscn              Flight Lab
│   ├── scenes/ui/puzzle/**           Portal Puzzles
│   ├── scenes/portal/**              portal shaders + the two screenshot probes
│   ├── data/levels/**                the ten levels, with measured solutions
│   ├── scripts/key_bindings.gd       THE keyboard map (see below)
│   ├── scripts/physics/**            pure, node-free simulation core (+ portal_link)
│   ├── scripts/mesh/**               parametric disc lathe
│   ├── scripts/app/**                Flight Lab scene, cameras, trails, overlays
│   ├── scripts/portal/**             rooms, apertures, the SubViewport renderer
│   ├── scripts/puzzle/**             level model, world compiler, session, ghost
│   ├── scripts/ui/**                 the control panel (+ ui/puzzle/** for levels)
│   └── tests/                        headless suites + the resource check
├── tools/
│   ├── aero/                         offline coefficient pipeline (Python)
│   └── ci/                           source-tree and artefact guards
└── web/                              Vite landing page + static host
```

### The two halves

`game/` is the simulation. `web/` is a thin shell around it: a landing page that
explains the model and links to the exported build. They meet at exactly one
place — the Godot web export is written into `web/public/game/`, and Vite copies
`public/` into `dist/` **verbatim**. No hashing, no inlining, no rewriting.

That verbatim copy is load-bearing. Godot derives `index.wasm` and `index.pck`
at runtime from the basename of its own HTML file, so renaming or fingerprinting
those files breaks the build. CI asserts this with a `diff -r` between the export
and the bundle output.

---

## Keyboard bindings

Ownership is declared in one file, `game/scripts/key_bindings.gd`, and both
input handlers dispatch through it. They previously collided — the panel and the
scene each bound Space, C, V, R, H and the digit row in separate handlers, and
because Godot delivers unhandled input in reverse tree order the panel silently
won every one, leaving the scene's shortcuts as dead code that its own on-screen
hint still advertised. `tests/suites/test_key_bindings.gd` now fails the build if
the tables overlap, or if either handler grows a `KEY_*` the tables do not
declare.

With the control panel present (the normal case):

| key | action |
| --- | --- |
| `Space` / `Enter` | Throw |
| `R` | Reset the release parameters |
| `C` | Cycle the camera view |
| `V` | Toggle the force vectors |
| `T` | Clear the ghost trails |
| `H` | Show/hide the control drawer |
| `Esc` | Close the provenance overlay |
| `1`–`5` | **Panel tabs** — Throw, Discs, Design, Env, Flight |
| `W` | Cycle the wind preset (the only key the scene keeps) |

Digits switch tabs, not cameras. Cameras are the buttons in the action bar and
`C`.

Without the panel — if `scenes/ui/control_panel.tscn` fails to load — the scene
falls back to a built-in debug HUD and binds its own set (`KeyBindings.STANDALONE`),
where the digits *are* camera views. The two sets are never live at once.

---

## Running locally

You need **Node ≥ 20.19** (or ≥ 22.12), Python 3.11+ and the Godot 4.7.1 editor.

```bash
# One-time: installs Godot 4.7.1 + the single-threaded web export templates
# into ~/godot-bin and ~/.local/share/godot/export_templates/4.7.1.stable/
./scripts/dev-setup.sh
export PATH="$HOME/godot-bin:$PATH"

cd web
npm install
npm run export:game     # headless Godot export → web/public/game/
npm run dev             # http://localhost:5173/godot-ai-test/
```

### Tests

Everything below is what CI runs, in this order. All of it is fast.

```bash
# 1. Source-tree guard: every res:// resource main.tscn reaches, transitively
#    (including class_name edges), exists AND is tracked by git.
python3 tools/ci/check_scene_refs.py

# 2. The committed aero data still matches the pipeline that generates it.
python3 -m tools.aero.bake --check

# 3. Python suite — 121 tests, ~65 s.
python3 -m pytest tools/aero -q

# 4. Import once (populates the global script-class cache), then the three
#    engine-side checks.
godot --headless --path game --import
godot --headless --path game --script res://tests/check_resources.gd   # parse check, 74 scripts
godot --headless --path game --script res://tests/run_tests.gd         # 274 tests, ~10 s
godot --headless --path game --script res://tests/run_puzzle_tests.gd  # 331 tests, ~9 s

# 5. After an export: the pack actually contains the program.
python3 tools/ci/check_pck_contents.py web/public/game/index.pck
```

**Authoritative counts: 274 + 331 = 605 GDScript tests, plus 121 Python.** The
two GDScript runners are separate because they gate different things and are
owned by different parts of the project — `run_tests.gd` is physics, geometry,
determinism, the portal transform and the UI logic; `run_puzzle_tests.gd` is the
puzzle runtime plus the level replay gate. Both must pass before CI exports
anything. (Both print `physics suite: N passed`; the header is shared, the
numbers are not.)

### Looking at it

Neither suite can tell you whether the thing looks right, and on this project
every real visual defect was found by looking at a picture. Two harnesses exist
for that, both headless, both writing PNGs, both far faster than the
export-and-drive cycle that is the only real proof:

```bash
# The portal renderer alone: 7 camera stations over the hand-authored test pair,
# with draw-call counts and a colour-space calibration station. ~20 s.
xvfb-run -a godot --path game --rendering-driver opengl3 \
    res://scenes/portal/portal_probe.tscn -- --capture=/tmp/shots

# The real puzzle mode: every shipped level, any camera view, optionally
# throwing. Instances puzzle_mode.tscn and drives its public API, so what it
# photographs is the shipped scene.
xvfb-run -a godot --path game --rendering-driver opengl3 \
    res://scenes/portal/puzzle_probe.tscn -- --capture=/tmp/shots \
    --levels=08_the_drop --views=tee,level --arm-portal-disc
```

Software GL under Xvfb is **not** evidence the exported build works — only
Chromium against `web/public/game/` is. It is a truthful preview of framing and
shading, which is what the loop is usually about.

Other useful commands, all from `web/`:

| Command | What it does |
| --- | --- |
| `npm run export:game` | Headless Godot export into `public/game/` |
| `npm run dev` | Vite dev server at `/godot-ai-test/` |
| `npm run build` | Production bundle into `dist/` |
| `npm run build:all` | Export the game, then build the site |
| `npm run preview` | Serve `dist/` locally |

### Build outputs are not committed

`web/public/game/`, `web/dist/` and `game/.godot/` are gitignored. The export is
~40 MB (`index.wasm` alone is 39,513,091 bytes) and is regenerated by CI on every
push. Never commit it.

---

## Why the test gate exists

**Six deploys of this project went green while the shipped build had no physics
core in it.** That is the single most important fact about this repository's CI,
and everything in the `test` job is a response to it.

`godot --headless --export-release` returns **exit 0 with scripts missing**. It
writes the `.pck`, writes the `.wasm`, and every size assertion downstream
passes. GDScript resolves `class_name` at *parse* time, so the failure surfaces
only in a browser. A successful export is not evidence that the export contains
the program.

Loading the scene back in Godot is not evidence either, and this is the subtle
part. With a `class_name` dependency deleted:

```
load("res://scripts/app/flight_app.gd")   → a non-null GDScript
PackedScene.instantiate()                 → a Node
GDScript.reload()                         → 43  (ERR_PARSE_ERROR)   ← the only honest one
```

`tests/check_resources.gd` gates on `reload()`. Every check below was validated
by actually deleting `scripts/physics/atmosphere.gd` from a scratch copy of the
tree and running the whole pipeline against it:

| step | result with the physics dependency deleted |
| --- | --- |
| `godot --export-release` | **exit 0**, 39,513,091-byte wasm, 605,044-byte pck |
| "Assert export produced a usable build" | **passes** — everything is non-empty |
| `check_pck_contents.py` | **exit 0** — see below |
| `check_scene_refs.py` | exit 1 — untracked / missing reference |
| `check_resources.gd` | exit 1 — *"main.tscn root node has no script attached"* |
| `run_tests.gd` | exit 1 — the physics suites fail to compile |

The three guards are complementary and **none is sufficient alone**.
`tools/ci/check_scene_refs.py` walks the transitive closure of `main.tscn` —
through `.tscn` ext-resources, `res://` string literals **and `class_name`
edges** — and requires every file to exist and be tracked by git.
`tests/check_resources.gd` compiles everything. `tools/ci/check_pck_contents.py`
opens the exported pack and checks every script, scene and data file is in it —
which catches the *export* dropping something, but explicitly **not** a file
that was never committed, because such a file is not on disk in a clean
checkout either and so is never in the expected set. That is the one it misses,
and it is the historical one, which is why the other two exist.

### The runner used to hang, not fail

`tests/run_tests.gd` printed its pass count and then spun forever. Its termination
guard was `func _iteration()`, which is Godot **3**'s `MainLoop` virtual; Godot 4
renamed it to `_process` and never calls a method by the old name — no error, no
warning. So the suite completed, the `quit()` never ran, and a passing run read
as a CI timeout with no exit code. It was misdiagnosed once as a cold
script-class-cache problem and "fixed" by running `--import` first, which does
nothing for it. Both engine steps in CI are now wrapped in `timeout` and report
a hang (exit 124) differently from a failure, so the two can never be confused
again.

---

## Key build decisions

**Single-threaded export.** `variant/thread_support=false`. GitHub Pages cannot
send `Cross-Origin-Opener-Policy` / `Cross-Origin-Embedder-Policy` headers, so
`SharedArrayBuffer` is unavailable. A single-threaded Godot build never checks
for cross-origin isolation, which sidesteps the problem entirely — no
`coi-serviceworker` shim, no PWA. Both stay off. (Note that
`progressive_web_app/ensure_cross_origin_isolation_headers` is a no-op unless PWA
is also enabled, so don't half-enable it.)

**GL Compatibility renderer.** WebGL2 is what browsers give us, so `project.godot`
sets `rendering_method`, `rendering_method.mobile` **and** `rendering_method.web`
to `gl_compatibility`. The `.web` override matters: exporting a Forward+ project
to Web produces no warning and no error, and yields a build that only fails once
it reaches a browser.

**A guaranteed floor on the canvas.** `stretch/mode = canvas_items` with
`aspect = expand` and a 1280×720 base means the scale factor is
`min(win.x/1280, win.y/720)`, so the canvas-space viewport is never smaller than
1280×720 at any window size. `ControlPanel._layout()` relies on that and carries
no narrow-viewport branches; `tests/check_resources.gd` asserts the three project
settings that guarantee it, so changing the stretch policy fails CI rather than
silently breaking the layout.

**Full-page navigation, not an iframe.** The landing page links to
`${import.meta.env.BASE_URL}game/index.html`. Godot's default canvas resize
policy assumes it owns the whole window, and an iframe adds focus, keyboard,
fullscreen and pointer-lock friction for no benefit. A "← Back to overview" link
is injected into the game page through the export preset's `html/head_include`.

**`export_presets.cfg` is committed, and Godot owns its formatting.** Godot
rewrites and normalises this file on every export. Edit it, run one export, then
commit whatever Godot wrote — don't hand-maintain it.

**`export_path` is empty.** CI passes the destination explicitly. Never export
into a directory inside `game/`, or Godot will re-scan and import its own output
as project assets.

**`preload()` in anything headless.** `godot --headless --script` runs without
the global script-class cache, so `class_name` does not resolve there. Every
cross-file reference in `scripts/physics/**`, `game/tests/**` and the two shared
geometry modules (`scripts/mesh/disc_mesh_builder.gd`,
`scripts/ui/disc_geometry_calc.gd`) goes through `preload()` for that reason, and
all four are verified to compile with the cache deleted. The scene-tree scripts
(`flight_app.gd`, `control_panel.gd`, the UI panels) do use bare `class_name` and
**do not** compile without the cache — which is fine, because they only ever run
in the editor or in the exported build, where the cache is packed into the
`.pck`. It does mean they cannot be unit-tested by the bare-script suite, and
`tests/check_resources.gd` is run after `--import` for the same reason.

**No `.nojekyll`.** Artifact-based Pages deployments skip Jekyll entirely, and
`upload-pages-artifact` strips dotfiles anyway. Adding one is a no-op.

---

## How the deploy works

`.github/workflows/deploy-pages.yml` runs on every push to `main` and on manual
dispatch. All actions are pinned by commit SHA. Three jobs, `test → build →
deploy`, so nothing reaches Pages without passing the gate.

The Godot install is a local composite action, `.github/actions/setup-godot`,
shared by both engine jobs. The editor and the export templates are cached under
separate keys because only `build` needs the templates and the template archive
is 1.28 GB — `test` pulls the 76 MB editor and nothing else.

1. **test** — dependencies, the two source-tree guards, `bake --check`, pytest,
   `--import`, the parse check, the physics suite. ~2 minutes warm.
2. **build** — export, size assertions, the pack-contents check, `npm ci`,
   `configure-pages`, `npm run build -- --base=…`, then
   `diff -r web/public/game web/dist/game` to prove the export survived bundling.
   `base_path` has no trailing slash; Vite requires one, hence the appended `/`.
3. **deploy** — upload `web/dist` and publish.

### ⚠️ One manual step is required

**GitHub Pages must be switched to the Actions source before the first deploy can
succeed.** This cannot be automated — the default `GITHUB_TOKEN` has no
permission to change it.

> **Settings → Pages → Build and deployment → Source → "GitHub Actions"**

Until that is set, the `deploy` job fails with a permissions or "Pages not
enabled" error. It is a one-time change; re-run the workflow afterwards.

---

## Verified toolchain

| Component | Version |
| --- | --- |
| Godot | 4.7.1-stable (`a13da4feb`) |
| Export template | `web_nothreads_release` |
| Renderer | GL Compatibility (WebGL2) |
| Vite | 8.2.1 |
| Node (CI) | 22 |
| Python | 3.11+ (numpy 2.4.6, scipy 1.17.1, pytest 9.1.1) |

## Citations

* Giljarhus, K.E.T., Kristiansen, T., Tutkun, M., Oggiano, L. (2022).
  *Aerodynamic characteristics of a golf disc.* Sports Engineering 25, 24.
  <https://doi.org/10.1007/s12283-022-00390-5>
* `shotshaper` — <https://github.com/kegiljarhus/shotshaper>, GPL-3.0. The
  licence text and full attribution are in `tools/aero/reference/`.
* Hummel, S.A. (2003). *Frisbee Flight Simulation and Throw Biomechanics.*
  MSc thesis, UC Davis.
* PDGA equipment certification database —
  <https://www.pdga.com/technical-standards/equipment-certification/discs>

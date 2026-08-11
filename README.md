# Disc Golf Flight Lab

An interactive disc golf flight simulator, built in Godot 4.7 and published to
GitHub Pages as a WebGL2 build.

**Live site:** https://alex-sherwin.github.io/godot-ai-test/

A disc in flight is a spinning, bevelled wing. It generates lift, it resists the
air, and because it is a gyroscope, the aerodynamic torque acting on it does not
tip it over — it precesses, turning the disc sideways instead. That is where
*turn* and *fade* actually come from. Flight Lab models that behaviour directly
rather than replaying a canned curve: a fixed-step RK4 integrator runs at 240 Hz
over CL/CD/CM tables that come, for four discs, from published CFD.

Pick one of 14 discs, set the release, watch it fly, and read the numbers back.
Or open the designer, edit the eight parameters the disc's cross-section is
lathed from, and watch the mesh, the moments of inertia and the reference area
move with them.

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

**Three roster discs are outside the current PDGA diameter band.** The Roc and
Buzzz are published at 21.7 cm and the River at 21.5, against a 21.0–21.3 cm
standard. Those are the real certification figures and they ship unmodified;
the designer's checker says so in those words rather than calling an approved
disc illegal.

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
│   ├── scenes/main.tscn              run/main_scene
│   ├── scripts/key_bindings.gd       THE keyboard map (see below)
│   ├── scripts/physics/**            pure, node-free simulation core
│   ├── scripts/mesh/**               parametric disc lathe
│   ├── scripts/app/**                scene, cameras, trails, overlays
│   ├── scripts/ui/**                 the control panel
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

# 4. Import once (populates the global script-class cache), then the two
#    engine-side checks.
godot --headless --path game --import
godot --headless --path game --script res://tests/check_resources.gd   # parse check
godot --headless --path game --script res://tests/run_tests.gd         # 196 tests, ~6 s

# 5. After an export: the pack actually contains the program.
python3 tools/ci/check_pck_contents.py web/public/game/index.pck
```

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

`tests/run_tests.gd` printed `196 passed` and then spun forever. Its termination
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

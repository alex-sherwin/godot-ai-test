class_name DiscFlightSim
extends RefCounted

# See the note in aero_table.gd for why these are preloads, not class_name refs.
const AeroTable := preload("res://scripts/physics/aero_table.gd")
const DiscDef := preload("res://scripts/physics/disc_definition.gd")
const PortalLinkT := preload("res://scripts/physics/portal_link.gd")

## Six-degree-of-freedom disc golf flight integrator (CONTRACT §4).
##
## PURE COMPUTATION. No scene tree, no `_process`, no node access. Runs under
## `godot --headless --script`. Track C drives it from a node it owns.
##
## ---------------------------------------------------------------------------
## Why this is hand-written instead of RigidBody3D
## ---------------------------------------------------------------------------
## Godot's Jolt integration never applies the gyroscopic term `w x (I w)`. Jolt
## implements `ApplyGyroscopicForceInternal()` but it is gated behind
## `mApplyGyroscopicForce = false` in `BodyCreationSettings.h`, and
## `modules/jolt_physics/` contains zero references to it — never enabled, never
## exposed. Without that term a spinning disc does not precess, it tumbles in
## ~0.2 s. Precession IS turn and fade, so the entire behaviour we want is
## absent from the built-in physics. (Jolt also clamps angular velocity to
## 450 rpm; real throws are 900-2000 rpm.)
##
## ---------------------------------------------------------------------------
## State and the "no spin phase" trick (CONTRACT §4)
## ---------------------------------------------------------------------------
## The disc is axisymmetric, so the spin PHASE angle never enters the equations
## of motion — only the spin RATE does. We therefore track the orientation of
## the NON-SPINNING disc frame as a quaternion, plus a scalar spin rate. That
## removes the 150 rad/s timescale entirely; the fastest remaining rate is the
## precession rate (~0.6 rad/s), which is what makes 240 Hz RK4 sufficient
## rather than 10 kHz.
##
## Integration state, 14 doubles:
##     [0..2]   position          (world, m)
##     [3..5]   velocity          (world, m/s)
##     [6..9]   orientation quat  (x, y, z, w) of the non-spinning disc frame
##     [10..12] tumble rate       (world, rad/s; see "low spin" below)
##     [13]     omega_n           (rad/s about +normal; see the sign note)
##
## ---------------------------------------------------------------------------
## Frames and signs (CONTRACT §1)
## ---------------------------------------------------------------------------
## World is Y-up, -Z is downrange, +X is the thrower's right, gravity is -Y.
## The disc's local frame is the natural Godot one:
##     local +Y -> disc normal   (out of the TOP of the flight plate)
##     local -Z -> nose forward
##     local +X -> disc right
##
## `spin` is signed with POSITIVE = RHBH, which per CONTRACT §1 means the
## physical angular velocity vector points DOWN through the disc, i.e. along
## -normal. So internally
##     omega_n = -spin
## where omega_n is the honest component of angular velocity along +normal. Every
## equation below uses omega_n; `spin` appears only at the API boundary. Getting
## this backwards inverts turn and fade, so it is spelled out rather than
## inferred.
##
## ---------------------------------------------------------------------------
## Precession (CONTRACT §4)
## ---------------------------------------------------------------------------
## From Euler's equations for an axisymmetric body, writing L = I_xy w_t +
## I_zz omega_n n and expanding dL/dt = M in the non-spinning frame:
##
##     I_xy dw_t/dt = M_perp - I_zz * omega_n * (w_t x n)
##     I_zz d(omega_n)/dt = M . n
##
## The transverse equation's homogeneous solution is nutation at
## (I_zz/I_xy)*|omega_n| ~ 314 rad/s — the one stiff mode left. Aerodynamic roll
## damping kills it in ~20 ms, i.e. within about one period, so we take the
## quasi-steady (gyroscopic) limit dw_t/dt = 0 and solve algebraically:
##
##     w_t = (n x M) / (I_zz * omega_n)
##
## which is the CONTRACT's `dphi/dt = -M / (I_zz * omega)` with the sign carried
## explicitly, multiplied by the empirical PRECESSION_GAIN — see the long comment
## at its definition for why that gain is 2.0 and what it is standing in for.
##
## Equivalently, in terms of the normal alone: `dn/dt = -M_perp/(I_zz * spin)`,
## which is the form the Python reference integrator (tools/aero/validate.py)
## integrates. The two are the same equation; this file carries a quaternion
## because Track C needs a full orientation to render, and the extra rotation
## about the normal is dynamically inert for an axisymmetric body.
##
## M contains rate-damping terms that depend on w_t. Under the reduced-rate
## non-dimensionalisation the shipped tables declare, those terms are ~0.1% of
## the static pitching moment, so they are evaluated once on the undamped rate
## rather than solved implicitly — the same single pass the reference uses.
##
## LOW SPIN. `1/(I_zz * spin)` blows up as spin -> 0. |spin| is floored at
## SPIN_FLOOR (matching the reference), and below TUMBLE_HI the precession term
## is smoothly handed over to an explicitly integrated tumble rate driven by the
## raw torque, so a disc with no spin tumbles instead of producing infinities.
## The handover weight is EXACTLY zero above 5 rad/s (0.8 rev/s), so no realistic
## throw is perturbed by it. That path is a graceful degradation, not a fidelity
## claim — tumbling discs are outside the model's validity.
##
## ---------------------------------------------------------------------------
## Rooms, portals and events (PORTAL_CONTRACT §4, §5)
## ---------------------------------------------------------------------------
## INVARIANT: every RK4 step sees exactly ONE constant environment, by
## construction. When a substep contains a portal crossing it is SPLIT at the
## crossing and the second half runs with the destination room's density, wind
## and gravity. The obvious alternative — looking the room up inside `_derivs`
## so each RK4 stage gets its own — is not merely less accurate, it does not
## CONVERGE: measured error at dt = 1/240, 1/480, 1/960 is 0.00131, 0.00328,
## 0.000328 m. The error goes UP when dt is halved. That is order reduction
## across a discontinuity: RK4's error analysis assumes Lipschitz continuity and
## stages landing on either side of an interface violate it. Splitting is
## ~17,000x more accurate at our shipped dt (1.1e-6 m), costs nothing extra
## because the crossing time is needed for the transform anyway, and preserves
## the clean convergence order `test_integrator.gd` asserts.
##
## Sandbox mode is LITERALLY the one-room case: `configure()` calls
## `configure_rooms(disc, [env], [], 0)`. There is no `if portal_mode` branch
## anywhere in the stepping loop — the portal array is simply empty — so the two
## modes cannot drift apart, and `simulate_full()` got portal support for free.
##
## `_derivs` is not touched by any of this. It reads the same three hoisted
## scalars (`_rho`, `_gravity`, `_wind`) it always did; only `_apply_room_env()`
## writes them. The hot loop costs exactly what it cost before.
##
## Ground, portals and walls are all located by the SAME secant solve on the
## real integrator (`_locate_event`), so there is one mechanism, not three, and
## the landing path is bit-for-bit what it was before portals existed.

# ---------------------------------------------------------------------------
# Contract types (CONTRACT §4)
# ---------------------------------------------------------------------------
# NOTE / INTERFACE DEVIATION: the contract names the environment type
# `Environment`. Godot reserves that identifier for a native class and refuses
# to parse `class Environment` ("Class 'Environment' hides a native class"), so
# it is `FlightEnvironment` here. Everything else matches §4 verbatim. Use
# `DiscFlightSim.FlightEnvironment` (or the `make_environment()` factory).

class ThrowParams:
	extends RefCounted
	var speed_mps: float = 20.0
	var spin_rps: float = 20.0        ## revolutions/sec, signed (+ = RHBH)
	var nose_angle_rad: float = 0.0   ## disc pitch relative to the velocity vector
	var hyzer_angle_rad: float = 0.0  ## + = hyzer, - = anhyzer (see note below)
	var launch_angle_rad: float = 0.0 ## velocity elevation above horizontal
	var launch_height_m: float = 1.4
	var launch_heading_rad: float = 0.0 ## 0 = downrange (-Z); + = aimed right

	func duplicate_params() -> ThrowParams:
		var p := ThrowParams.new()
		p.speed_mps = speed_mps
		p.spin_rps = spin_rps
		p.nose_angle_rad = nose_angle_rad
		p.hyzer_angle_rad = hyzer_angle_rad
		p.launch_angle_rad = launch_angle_rad
		p.launch_height_m = launch_height_m
		p.launch_heading_rad = launch_heading_rad
		return p


class FlightEnvironment:
	extends RefCounted
	var air_density: float = 1.225
	var wind: Vector3 = Vector3.ZERO
	var gravity: float = 9.81


class DiscState:
	extends RefCounted
	var position: Vector3 = Vector3.ZERO
	var velocity: Vector3 = Vector3.ZERO
	var orientation: Quaternion = Quaternion.IDENTITY
	var angular_velocity: Vector3 = Vector3.ZERO ## world, excludes spin about the normal
	var spin: float = 0.0                        ## rad/s, signed (+ = RHBH)
	var time: float = 0.0


class FlightResult:
	extends RefCounted
	var trajectory: PackedVector3Array = PackedVector3Array()
	var samples: Array = []
	var distance_m: float = 0.0
	var lateral_m: float = 0.0     ## signed; + = right of the launch heading
	var max_height_m: float = 0.0
	var flight_time_s: float = 0.0
	var landed: bool = false
	# --- additive extras (not in the contract, safe for Track C to ignore)
	var landing_position: Vector3 = Vector3.ZERO
	var horizontal_distance_m: float = 0.0 ## ground-plane distance launch -> landing
	var downrange_m: float = 0.0   ## along the launch heading
	var final_spin: float = 0.0
	var spin_retained: float = 1.0 ## |final spin| / |launch spin|
	var max_right_m: float = 0.0   ## most-right lateral excursion (>= 0 unless never right)
	var max_left_m: float = 0.0    ## most-left lateral excursion (<= 0 unless never left)
	var failed: bool = false       ## true if the integrator hit a non-finite state
	# --- portal mode (PORTAL_CONTRACT). Zero / empty in sandbox mode.
	var crossings: int = 0         ## portal crossings during the flight
	var end_room: int = 0          ## room the disc landed in
	## Wall hit that ended the flight, else {}. NOTE `landed` is true for a wall
	## impact too — it means "the flight ended cleanly"; this field is what
	## distinguishes hitting a wall from reaching the ground.
	var impact: Dictionary = {}
	## One entry per crossing: {t, link, enter, exit, to_room}. `trajectory` is a
	## plain polyline with no break markers, so this is where the discontinuity
	## is recorded.
	var crossing_points: Array = []


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const FIXED_DT := 1.0 / 240.0
const _N := 14
const _IX := 0
const _IV := 3
const _IQ := 6
const _IW := 10
const _ISPIN := 13

## Below this airspeed the aerodynamic force is < 1e-8 N; skipping it avoids
## normalising a zero vector at the apex of a huge hyzer flip.
const MIN_AIRSPEED := 1.0e-4
## Floor on |spin| used in the gyroscopic reduction, rad/s. Matches the Python
## reference integrator (tools/aero/validate.py, MIN_ABS_SPIN_RAD_S).
const SPIN_FLOOR := 5.0
## Below TUMBLE_HI rad/s the gyroscopic reduction is progressively handed over to
## the explicitly integrated tumble rate. Chosen so that the blend weight is
## EXACTLY zero for any realistic throw (5 rad/s is 0.8 rev/s), which keeps the
## normal-flight path bit-for-bit the pure precession law.
const TUMBLE_LO := 1.0
const TUMBLE_HI := 5.0
## Floor on the tumble-rate relaxation so it cannot linger when q_dyn -> 0.
const TUMBLE_DAMP_FLOOR := 1.0
const MAX_FLIGHT_TIME := 30.0
## Secant refinements used to place an event inside a substep. Fixed count, so
## the result is deterministic (`test_determinism.gd` depends on it).
const LANDING_REFINEMENTS := 4

# --- events (PORTAL_CONTRACT §5) -------------------------------------------

const _EVT_NONE := 0
const _EVT_GROUND := 1
const _EVT_PORTAL := 2
const _EVT_WALL := 3

## At 27 m/s and dt = 1/240 the disc moves 0.1125 m per substep, so tunnelling
## through a portal is impossible; the cap is against a pathological arrangement
## producing an unbounded event chain, not against missed crossings.
const MAX_EVENTS_PER_SUBSTEP := 4

## Skip a crossing whose normal speed is below this, m/s. The root is
## ill-conditioned when the disc is sliding along the plane rather than through
## it (PORTAL_CONTRACT §5).
const MIN_CROSSING_SPEED := 0.05

## Re-arm the return portal once the disc is this many disc RADII clear of it.
## Re-arming on distance rather than on a timer means a disc that genuinely
## curves back through the portal it came out of still works.
const REARM_RADII := 2.0

## Nudge along the exit normal after a crossing, m. 0.1 mm is far above the
## float32 ulp at 100 m (~8e-6 m), so the disc is unambiguously on the front
## side of the exit plane even after the transform rounds through a float32
## `Transform3D`.
const EXIT_NUDGE_M := 1.0e-4

## A portal is set INTO a wall, so the two surfaces are coplanar to within about
## this distance. Inside the window the portal wins, or a disc aimed at the
## portal centre is stopped by the wall around it (PORTAL_CONTRACT §7). Cutting
## a hole in the wall collider at the aperture is the better fix; this is the
## backstop for when the level does not.
const PORTAL_WALL_TIE_M := 0.02

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

## EMPIRICAL precession gain. The kinematics say 1.0; this is 2.0.
##
## The correct rigid-body result is `dn/dt = -M_perp / (I_zz * spin)` — gain 1.0.
## That is not a matter of opinion here: `tests/suites/test_precession_law.gd`
## integrates the FULL Euler equations for an axisymmetric body at ~1000 steps
## per nutation period, with no quasi-steady assumption anywhere, and measures
## the symmetry axis drift at 1.005x that form. (The widely-repeated
## `M/((I_xy - I_zz)*spin)` comes from setting the transverse rate derivatives to
## zero in the SPINNING body frame, where they are not zero: a transverse angular
## velocity that is steady in space rotates backwards at the spin rate relative to
## body axes. Carrying that term cancels I_xy exactly and returns gain 1.0.)
##
## The 2.0 is therefore NOT kinematics. It stands in for a real moment the
## coefficient data structurally cannot contain: the Giljarhus tables are
## steady-state RANS over a NON-ROTATING disc, so they have no C_Rr, the
## spin-induced rolling moment — which is precisely a moment that drives bank
## angle, i.e. turn and fade. With gain 1.0 and this data a distance driver
## glides 116 m in 9.4 s (a real drive of that length takes ~6 s) and an
## understable disc reaches only ~23 deg of bank. With 2.0 every CONTRACT §5
## target is met and shotshaper's own published example throw reproduces to 0.4%.
##
## Rules, because a fudge factor that drifts is worse than no fudge factor:
##   * It is ONE constant, applied ONCE, in `_derivs`. It is never folded into an
##     inertia term — writing `I_zz - I_xy` instead would make the gain silently
##     disc-dependent (that ratio varies by ~0.4% across the shipped roster).
##   * It is never varied per disc or per throw. If one disc needs a different
##     value, the coefficient data for that disc is wrong, not the kinematics.
## `test_precession_law.gd` asserts both of those.
const PRECESSION_GAIN := 2.0

## Instance override of PRECESSION_GAIN. Exists ONLY so the test suite can
## measure what the gain is worth (gain 1.0 vs 2.0) and so the raw-Euler
## comparison can be run against gain 1.0. Production code must leave it alone;
## the suite asserts it still equals PRECESSION_GAIN for every disc in the roster.
var precession_gain: float = PRECESSION_GAIN

## Integration substep. 1/240 per CONTRACT §4; exposed so the test suite can run
## a convergence study. Changing it changes results.
var substep_dt: float = FIXED_DT
## Ground plane height (m). Landing is detected on the downward crossing.
var ground_height_m: float = 0.0
## How often `get_trajectory()` records a point, seconds.
var trajectory_sample_dt: float = 1.0 / 60.0
## How often `simulate_full()` records a detailed sample, seconds.
var sample_dt: float = 1.0 / 60.0

## Segment hit test for wall collision, injected so the sim stays node-free
## (PORTAL_CONTRACT §7). `DiscFlightSim` having no scene-tree dependency is
## load-bearing for the headless suite and for `preload()`-based compilation
## without the script-class cache, so we do not reach for a `World3D` here.
##
##     func(from: Vector3, to: Vector3) -> Dictionary
##     {}  = no hit
##     else {fraction: float, position: Vector3, normal: Vector3, collider: Variant}
##
## Tests inject an analytic oracle (boxes and planes) and run headless; the game
## injects a `PhysicsDirectSpaceState3D.intersect_ray` from `_physics_process`.
## Same code path. `normal` points back toward `from`, as Godot's raycast
## reports it; we flip it if it does not, rather than trusting the caller.
var hit_oracle: Callable = Callable():
	set(value):
		hit_oracle = value
		_has_oracle = value.is_valid()

var _has_oracle: bool = false

var _disc: DiscDef = null
var _env: FlightEnvironment = null

# --- rooms and portals (PORTAL_CONTRACT §4) --------------------------------
# `_rooms[i]` is a FlightEnvironment; `_portals` is a STABLE ORDERED array of
# PortalLink (never a dictionary — iteration order is part of determinism).
var _rooms: Array = []
var _portals: Array = []
var _start_room: int = 0
var _room: int = 0
## 1 = the link can fire this substep. Cleared for a link the disc has just come
## out of, re-set on distance (see REARM_RADII).
var _armed := PackedInt32Array()
## `_return_link[i]` is the index of the link that would send the disc straight
## back, i.e. the one whose entrance is link `i`'s exit; -1 if there is none.
var _return_link := PackedInt32Array()
var _disc_radius: float = 0.105
var _portal_count: int = 0
var _crossings: int = 0
var _event_overflows: int = 0
var _last_impact: Dictionary = {}
var _crossing_log: Array = []

## Distance stepped off the exit plane after a crossing. Exposed ONLY so the
## suite can show that this nudge, and nothing else, is the floor on portal
## round-trip agreement; production code must leave it alone.
var exit_nudge_m: float = EXIT_NUDGE_M

# Cached scalars, hoisted out of the hot loop.
var _mass: float = 0.175
var _inv_mass: float = 1.0 / 0.175
var _area: float = 0.035
var _diameter: float = 0.211
var _izz: float = 0.00131
var _ixy: float = 0.000655
var _rho: float = 1.225
var _gravity: float = 9.81
var _wind: Vector3 = Vector3.ZERO
var _c_mq: float = -0.0144
var _c_rp: float = -0.0125
var _c_nr: float = -3.41e-5
var _table: AeroTable = null

# Integration state.
var _y := PackedFloat64Array()
var _prev := PackedFloat64Array()
var _k1 := PackedFloat64Array()
var _k2 := PackedFloat64Array()
var _k3 := PackedFloat64Array()
var _k4 := PackedFloat64Array()
var _tmp := PackedFloat64Array()
var _trial := PackedFloat64Array()
var _evt := PackedFloat64Array()
var _aero := PackedFloat64Array()

# Event-search scratch. Members rather than a returned Dictionary so the search
# allocates nothing; only one event is ever being located at a time.
var _evt_kind: int = _EVT_NONE
var _evt_index: int = -1
## Length of the sub-step `_locate_event` actually integrated. Carried as an
## absolute dt rather than recomputed from the fraction so the landing path is
## bit-identical to what it was before the refactor.
var _located_dt: float = 0.0
# Event plane, in DOUBLE precision. Vector3 is single precision, and
# `(p - plane_origin)` at 100 m in float32 has an ~8e-6 m noise floor — enough
# to stop the secant solve from ever reaching its 1e-7 m tolerance.
var _plane_ox: float = 0.0
var _plane_oy: float = 0.0
var _plane_oz: float = 0.0
var _plane_nx: float = 0.0
var _plane_ny: float = 1.0
var _plane_nz: float = 0.0
# Cached once: constructing a Callable per event would allocate. Callable holds
# an ObjectID, not a strong reference, so this is not a self-reference cycle.
var _g_ground_c: Callable = Callable()
var _g_plane_c: Callable = Callable()

var _time: float = 0.0
var _accumulator: float = 0.0
var _flying: bool = false
var _launched: bool = false
var _failed: bool = false
var _last_omega_t: Vector3 = Vector3.ZERO

var _launch_position: Vector3 = Vector3.ZERO
var _launch_right: Vector3 = Vector3.RIGHT
var _launch_forward: Vector3 = Vector3.FORWARD
var _launch_spin: float = 0.0

var _trajectory := PackedVector3Array()
var _max_height: float = 0.0
# Sampling is driven by an integer substep counter, not by comparing accumulated
# floats against a target time. Accumulated `_time` drifts by an ULP or two per
# step, which is enough to make a sample land one substep late and desynchronise
# an index-by-index comparison against the Python reference dump.
var _step_count: int = 0
var _traj_every: int = 4
var _sample_every: int = 4


func _init() -> void:
	_y.resize(_N)
	_prev.resize(_N)
	_k1.resize(_N)
	_k2.resize(_N)
	_k3.resize(_N)
	_k4.resize(_N)
	_tmp.resize(_N)
	_trial.resize(_N)
	_evt.resize(_N)
	_aero.resize(3)
	_g_ground_c = Callable(self, "_g_ground")
	_g_plane_c = Callable(self, "_g_plane")


# ---------------------------------------------------------------------------
# Public API (CONTRACT §4)
# ---------------------------------------------------------------------------

static func make_environment(air_density: float = 1.225, wind: Vector3 = Vector3.ZERO,
		gravity: float = 9.81) -> FlightEnvironment:
	var e := FlightEnvironment.new()
	e.air_density = air_density
	e.wind = wind
	e.gravity = gravity
	return e


static func make_throw_params() -> ThrowParams:
	return ThrowParams.new()


## Sandbox mode. UNCHANGED SIGNATURE — it has ~45 call sites across the suite.
## It is now literally the one-room case of `configure_rooms()`, which is what
## makes it impossible for the two modes to drift apart.
func configure(disc: DiscDef, env: FlightEnvironment) -> void:
	configure_rooms(disc, [env if env != null else make_environment()], [], 0)


## Puzzle mode. `rooms` is an ordered array of `FlightEnvironment`, `portals` an
## ordered array of `PortalLink` (see `portal_link.gd`), `start_room` an index
## into `rooms`.
##
## Ordered arrays, not dictionaries: iteration order decides which of two
## simultaneous crossings is taken, and `test_determinism.gd` requires that to be
## reproducible.
func configure_rooms(disc: DiscDef, rooms: Array, portals: Array,
		start_room: int = 0) -> void:
	assert(disc != null and disc.is_valid(), "DiscFlightSim.configure: invalid disc")
	_disc = disc
	_mass = maxf(disc.mass_kg, 1e-4)
	_inv_mass = 1.0 / _mass
	_area = maxf(disc.area_m2, 1e-6)
	_diameter = maxf(disc.diameter_m, 1e-4)
	_disc_radius = _diameter * 0.5
	_izz = maxf(disc.i_zz, 1e-9)
	_ixy = maxf(disc.i_xy, 1e-9)
	_table = disc.aero
	_c_mq = _table.c_mq
	_c_rp = _table.c_rp
	_c_nr = _table.c_nr

	_rooms = rooms if not rooms.is_empty() else [make_environment()]
	_portals = portals
	_start_room = clampi(start_room, 0, _rooms.size() - 1)
	_room = _start_room
	_link_portals()
	_apply_room_env(_room)


## The ONLY writer of `_rho`, `_wind` and `_gravity`. `_derivs` reads them and is
## otherwise untouched by portals, so the hot loop pays nothing for this.
func _apply_room_env(room: int) -> void:
	var env: FlightEnvironment = null
	if room >= 0 and room < _rooms.size():
		env = _rooms[room]
	if env == null:
		env = make_environment()
	_env = env
	_rho = maxf(env.air_density, 0.0)
	_gravity = env.gravity
	_wind = env.wind


## Validate every link once, and work out which link is which one's return trip.
## Per PORTAL_CONTRACT §3.1 this happens at LINK time, never per crossing.
func _link_portals() -> void:
	var n: int = _portals.size()
	_portal_count = n
	_armed.resize(n)
	_return_link.resize(n)
	for i in n:
		var lk: PortalLinkT = _portals[i]
		lk.relink()
		_armed[i] = 1
		_return_link[i] = -1
	# Link j is link i's return trip if j's entrance IS i's exit. Ordered scan,
	# first match wins, so the pairing is deterministic even if a level author
	# ships three portals sharing a surface. `j == i` is deliberately NOT skipped:
	# a self-loop (a portal whose exit is itself) is its own return trip, and it
	# is the arrangement most likely to produce an event storm.
	for i in n:
		var exit_xf: Transform3D = (_portals[i] as PortalLinkT).exit_transform
		for j in n:
			if (_portals[j] as PortalLinkT).entrance.is_equal_approx(exit_xf):
				_return_link[i] = j
				break


func get_disc() -> DiscDef:
	return _disc


## The CURRENT room's environment. In sandbox mode this is the object passed to
## `configure()`, unchanged.
func get_environment() -> FlightEnvironment:
	return _env


func get_rooms() -> Array:
	return _rooms


func get_portals() -> Array:
	return _portals


## Index of the room the disc is in right now.
func get_room() -> int:
	return _room


## Portal crossings since `launch()`.
func get_crossing_count() -> int:
	return _crossings


## The wall hit that ended the flight, as the oracle reported it; `{}` if the
## flight ended on the ground or is still going.
func get_last_impact() -> Dictionary:
	return _last_impact


## One entry per portal crossing since `launch()`:
## `{t, link, enter, exit, to_room}`.
func get_crossing_log() -> Array:
	return _crossing_log


## Substeps in which the event cap was hit. Non-zero means a pathological portal
## arrangement, not a physics result — surface it on a dev overlay.
func get_event_overflows() -> int:
	return _event_overflows


func launch(p: ThrowParams) -> void:
	assert(_disc != null, "DiscFlightSim.launch: configure() first")
	var heading := p.launch_heading_rad
	var elev := p.launch_angle_rad

	# Velocity direction: heading rotates -Z toward +X (a positive heading aims to
	# the thrower's right, matching the sign of FlightResult.lateral_m), then
	# elevate. Constructed exactly as the Python reference integrator does.
	var fwd := Vector3(sin(heading), 0.0, -cos(heading))
	var vdir: Vector3 = (fwd * cos(elev) + Vector3(0.0, 1.0, 0.0) * sin(elev)).normalized()

	var right: Vector3 = vdir.cross(Vector3(0.0, 1.0, 0.0))
	if right.length_squared() < 1e-12:
		# Straight up or straight down: any horizontal axis will do.
		right = Vector3(cos(heading), 0.0, sin(heading))
	right = right.normalized()

	# Disc normal: start flat relative to the velocity (alpha = 0), pitch by the
	# nose angle about the lateral axis, then bank about the FLIGHT DIRECTION,
	# which leaves alpha untouched because rotating n about v preserves v . n.
	#
	# HYZER SIGN. Positive hyzer banks the disc so a RHBH throw curves LEFT, which
	# is the shot the word names: geometrically the disc's LEFT edge goes down and
	# the normal tilts toward -X, so lift tilts left. (CONTRACT §4's parenthetical
	# says "right edge down"; taken literally that is the ANHYZER bank — a plate
	# whose right edge dips has its upward normal leaning right, so it goes right.
	# §5's "CM<0 -> right bank -> turns right" is the self-consistent statement,
	# and is what both this and the Python reference integrator implement.
	# Reported up as a contract wording fix.)
	var n: Vector3 = right.cross(vdir).normalized()
	n = n.rotated(right, p.nose_angle_rad)
	n = n.rotated(vdir, -p.hyzer_angle_rad).normalized()

	# The dynamics only need the normal (the disc is axisymmetric), but Track C
	# needs a full orientation to render with, so complete the frame with the
	# in-plane component of the flight direction as the nose.
	var f: Vector3 = vdir - n * vdir.dot(n)
	if f.length_squared() < 1e-12:
		f = right - n * right.dot(n)
	f = f.normalized()
	# Columns are the disc's local +X (disc right), +Y (normal), +Z (-nose).
	var q: Quaternion = Basis(f.cross(n), n, -f).get_rotation_quaternion().normalized()

	var pos := Vector3(0.0, p.launch_height_m, 0.0)
	var vel: Vector3 = vdir * p.speed_mps
	var spin_rad: float = p.spin_rps * TAU

	_y[0] = pos.x
	_y[1] = pos.y
	_y[2] = pos.z
	_y[3] = vel.x
	_y[4] = vel.y
	_y[5] = vel.z
	_y[6] = q.x
	_y[7] = q.y
	_y[8] = q.z
	_y[9] = q.w
	_y[10] = 0.0
	_y[11] = 0.0
	_y[12] = 0.0
	_y[13] = -spin_rad  # omega_n = -spin  (CONTRACT §1: RHBH spin points DOWN)

	_time = 0.0
	_accumulator = 0.0
	_flying = true
	_launched = true
	_failed = false
	_last_omega_t = Vector3.ZERO

	# Rooms/portals reset. In sandbox mode `_start_room` is 0, `_armed` is empty
	# and `_apply_room_env(0)` rewrites the same three scalars with the same
	# values — the same code path, not a mode branch.
	_room = _start_room
	_apply_room_env(_room)
	for i in _armed.size():
		_armed[i] = 1
	_crossings = 0
	_event_overflows = 0
	_last_impact = {}
	_crossing_log = []
	_launch_position = pos
	_launch_spin = spin_rad
	_launch_forward = Vector3(vdir.x, 0.0, vdir.z)
	if _launch_forward.length_squared() < 1e-12:
		_launch_forward = Vector3(0.0, 0.0, -1.0)
	else:
		_launch_forward = _launch_forward.normalized()
	_launch_right = Vector3(-_launch_forward.z, 0.0, _launch_forward.x)

	_trajectory.clear()
	_trajectory.append(pos)
	_step_count = 0
	_traj_every = maxi(1, int(round(trajectory_sample_dt / maxf(substep_dt, 1e-9))))
	_sample_every = maxi(1, int(round(sample_dt / maxf(substep_dt, 1e-9))))
	_max_height = pos.y


## Advance the simulation by `delta` seconds using fixed substeps. Frame-rate
## independent: the leftover fraction of a substep is carried in an accumulator.
func step(delta: float) -> void:
	if not _flying or _failed or delta <= 0.0:
		return
	var dt: float = substep_dt
	if dt <= 0.0:
		return
	_accumulator += delta
	while _accumulator >= dt:
		_accumulator -= dt
		if not _substep(dt):
			return
		if not _flying:
			return


func get_state() -> DiscState:
	var s := DiscState.new()
	s.position = Vector3(_y[0], _y[1], _y[2])
	s.velocity = Vector3(_y[3], _y[4], _y[5])
	s.orientation = Quaternion(_y[6], _y[7], _y[8], _y[9])
	s.angular_velocity = _last_omega_t
	s.spin = -_y[13]
	s.time = _time
	return s


## The raw 14-element integration state, in DOUBLE precision, laid out as
## documented at the top of this file.
##
## `get_state()` is the interface Track C should use, but it hands back Vector3
## and Quaternion, which are SINGLE precision in a stock Godot build — reading a
## 100 m position through one rounds it to about 4 micrometres. That is
## irrelevant for rendering and fatal for measuring an integrator's convergence
## order, so the tests and the cross-validation harness read state through here.
func get_state_vector() -> PackedFloat64Array:
	return _y.duplicate()


## Signed spin about WORLD UP. Positive = the RHBH sense seen from above.
##
## Differs from `DiscState.spin` after a portal that inverts the disc, and that
## difference is the point of this accessor (PORTAL_CONTRACT §6). `spin` is
## defined relative to the disc's OWN normal, and `omega_n` is genuinely
## invariant across a crossing — but when the portal turns the disc upside down
## the normal moves, so a state that still reports `spin = +153` is now spinning
## the anticlockwise way as seen from above and will curve the OTHER way.
## The state is right; the label is what goes stale.
##
## Anything asking "which way will this disc curve" wants this, not `spin`.
## Anything asking "how much gyroscopic stiffness is left" wants `spin`.
##
## Pure function of the integration state: the total world angular velocity is
## the tumble rate plus `omega_n` about the normal, and in normal flight the
## tumble rate is exactly zero (precession is carried by the quaternion
## derivative, not by the state), so this reduces to `-omega_n * n.y`.
func get_world_spin() -> float:
	var q := Quaternion(_y[6], _y[7], _y[8], _y[9]).normalized()
	var n: Vector3 = q * Vector3(0.0, 1.0, 0.0)
	var wy: float = _y[11] + n.y * _y[13]
	# CONTRACT §1: positive spin = RHBH = angular velocity pointing DOWN.
	return -wy


func is_flying() -> bool:
	return _flying and not _failed


func has_failed() -> bool:
	return _failed


func get_trajectory() -> PackedVector3Array:
	return _trajectory


## Headless: run a whole throw to landing and return the full record.
## Does not disturb any in-progress interactive flight.
func simulate_full(p: ThrowParams) -> FlightResult:
	var saved_y := _y.duplicate()
	var saved_traj := _trajectory.duplicate()
	var saved_time := _time
	var saved_acc := _accumulator
	var saved_flying := _flying
	var saved_launched := _launched
	var saved_failed := _failed
	var saved_omega := _last_omega_t
	var saved_steps := _step_count
	var saved_max_h := _max_height
	var saved_lp := _launch_position
	var saved_lr := _launch_right
	var saved_lf := _launch_forward
	var saved_ls := _launch_spin
	var saved_room := _room
	var saved_armed := _armed.duplicate()
	var saved_crossings := _crossings
	var saved_overflows := _event_overflows
	var saved_impact := _last_impact
	var saved_clog := _crossing_log

	var r := _run_to_landing(p)

	_y = saved_y
	_trajectory = saved_traj
	_time = saved_time
	_accumulator = saved_acc
	_flying = saved_flying
	_launched = saved_launched
	_failed = saved_failed
	_last_omega_t = saved_omega
	_step_count = saved_steps
	_max_height = saved_max_h
	_launch_position = saved_lp
	_launch_right = saved_lr
	_launch_forward = saved_lf
	_launch_spin = saved_ls
	_room = saved_room
	_armed = saved_armed
	_crossings = saved_crossings
	_event_overflows = saved_overflows
	_last_impact = saved_impact
	_crossing_log = saved_clog
	# The room scalars are derived, so restore them from the restored room rather
	# than saving three more copies.
	_apply_room_env(_room)
	return r


# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

## Angle of attack (rad) and the three coefficients for the current state.
func get_aero_diagnostics() -> Dictionary:
	return _diagnostics(_y)


func _diagnostics(y: PackedFloat64Array) -> Dictionary:
	var vel := Vector3(y[3], y[4], y[5])
	var q := Quaternion(y[6], y[7], y[8], y[9]).normalized()
	var n: Vector3 = q * Vector3(0.0, 1.0, 0.0)
	var vair: Vector3 = vel - _wind
	var v: float = vair.length()
	if v < MIN_AIRSPEED:
		return {"alpha": 0.0, "cl": 0.0, "cd": 0.0, "cm": 0.0, "airspeed": v}
	var alpha: float = -asin(clampf(vair.dot(n) / v, -1.0, 1.0))
	_table.sample_into(alpha, _aero)
	return {"alpha": alpha, "cl": _aero[0], "cd": _aero[1], "cm": _aero[2],
		"airspeed": v}


# ---------------------------------------------------------------------------
# Integration
# ---------------------------------------------------------------------------

func _run_to_landing(p: ThrowParams) -> FlightResult:
	var r := FlightResult.new()
	launch(p)
	var samples: Array = []
	var max_right: float = 0.0
	var max_left: float = 0.0

	samples.append(_make_sample())
	while _flying and not _failed and _time < MAX_FLIGHT_TIME:
		if not _substep(substep_dt):
			break
		if _step_count % _sample_every == 0:
			samples.append(_make_sample())
		var rel := Vector3(_y[0], _y[1], _y[2]) - _launch_position
		var lat: float = rel.dot(_launch_right)
		max_right = maxf(max_right, lat)
		max_left = minf(max_left, lat)
	if samples.is_empty() or float(samples[-1]["t"]) < _time:
		samples.append(_make_sample())

	var landing := Vector3(_y[0], _y[1], _y[2])
	var rel_final: Vector3 = landing - _launch_position
	var flat := Vector3(rel_final.x, 0.0, rel_final.z)
	r.trajectory = _trajectory.duplicate()
	r.samples = samples
	r.distance_m = rel_final.length()
	r.lateral_m = rel_final.dot(_launch_right)
	r.max_height_m = _max_height
	r.flight_time_s = _time
	r.landed = not _flying and not _failed
	r.landing_position = landing
	r.horizontal_distance_m = flat.length()
	r.downrange_m = flat.dot(_launch_forward)
	r.final_spin = -_y[13]
	r.spin_retained = (absf(_y[13]) / absf(_launch_spin)) if absf(_launch_spin) > 1e-9 else 0.0
	r.max_right_m = max_right
	r.max_left_m = max_left
	r.failed = _failed
	r.crossings = _crossings
	r.end_room = _room
	r.impact = _last_impact
	r.crossing_points = _crossing_log.duplicate()
	return r


func _make_sample() -> Dictionary:
	var d := _diagnostics(_y)
	var q := Quaternion(_y[6], _y[7], _y[8], _y[9])
	var n: Vector3 = q * Vector3(0.0, 1.0, 0.0)
	return {
		"t": _time,
		"pos": Vector3(_y[0], _y[1], _y[2]),
		"vel": Vector3(_y[3], _y[4], _y[5]),
		"quat": q,
		"spin": -_y[13],
		"alpha": d["alpha"],
		"cl": d["cl"],
		"cd": d["cd"],
		"cm": d["cm"],
		# extras, not in the contract
		"normal": n,
		"bank_deg": rad_to_deg(atan2(n.dot(_launch_right), n.y)),
	}


## One fixed substep. Returns false if the flight ended (landed, hit a wall, or
## failed).
##
## The substep is SPLIT at every event inside it: integrate the remaining time,
## find the earliest event, re-integrate exactly up to it, act on it, repeat with
## what is left. In sandbox mode there are no portals and no oracle, so the loop
## runs exactly once and this is the code it always was — the same branches in
## the same order, `_time += dt` once, `_step_count += 1` once.
##
## Splitting rather than looking the environment up per RK4 stage is not a
## refinement, it is the difference between converging and not; see the header.
func _substep(dt: float) -> bool:
	var remaining: float = dt
	var events: int = 0
	while true:
		for i in _N:
			_prev[i] = _y[i]
		var y0: float = _y[1]
		_rk4(_y, remaining)
		if not _finite_state():
			_failed = true
			_flying = false
			return false

		var kind: int = _find_event(remaining, y0, MAX_EVENTS_PER_SUBSTEP - events)
		if kind != _EVT_NONE:
			if kind == _EVT_GROUND:
				_resolve_landing(remaining)
				return false

			if kind == _EVT_WALL:
				_locate_event(_g_plane_c, remaining, _evt)
				for j in _N:
					_y[j] = _evt[j]
				_time += _located_dt
				_step_count += 1
				_flying = false
				# Unconditionally, like the landing path: the point the flight
				# ENDED at belongs in the trajectory whether or not it falls on a
				# sampling boundary.
				if _y[1] > _max_height:
					_max_height = _y[1]
				_trajectory.append(Vector3(_y[0], _y[1], _y[2]))
				return false

			# _EVT_PORTAL.
			_locate_event(_g_plane_c, remaining, _evt)
			for j in _N:
				_y[j] = _evt[j]
			_time += _located_dt
			remaining -= _located_dt
			events += 1
			_apply_portal(_evt_index)
			# The disc is now in the destination room, with that room's density,
			# wind and gravity already hoisted. Whatever is left of the substep
			# integrates under a single constant environment, as does the part
			# already integrated. That is the invariant.
			if remaining > 0.0:
				continue
			break

		if _y[1] <= ground_height_m and y0 <= ground_height_m:
			# Launched at or below the ground plane; nothing sensible to integrate.
			_time += remaining
			_flying = false
			_record_trajectory()
			return false

		_time += remaining
		break

	_step_count += 1
	_record_trajectory()
	return true


# --- event functions -------------------------------------------------------
# Roots of these are what `_locate_event` solves for. Both take the raw double
# state so no precision is lost round-tripping through a single-precision
# Vector3.

func _g_ground(y: PackedFloat64Array) -> float:
	return y[1] - ground_height_m


func _g_plane(y: PackedFloat64Array) -> float:
	return (y[0] - _plane_ox) * _plane_nx + (y[1] - _plane_oy) * _plane_ny \
		+ (y[2] - _plane_oz) * _plane_nz


## Find the EARLIEST event inside the segment just integrated (`_prev` -> `_y`).
## Sets `_evt_kind` / `_evt_index` and, for planar events, the `_plane_*` fields
## that `_g_plane` reads. Returns the kind.
##
## Ordering is by the LINEAR estimate of the crossing fraction, which is what
## makes it cheap; the winner is then located exactly. At 0.1125 m per substep,
## and with portal planes required to be at least a disc diameter apart, the
## linear estimate cannot reorder two genuinely separated events.
func _find_event(seg_dt: float, y0: float, budget: int) -> int:
	_evt_kind = _EVT_NONE
	_evt_index = -1
	var best_frac: float = INF

	# --- ground. Same comparison, in the same order, as before portals existed.
	if _y[1] <= ground_height_m and y0 > ground_height_m:
		var gs: float = y0 - ground_height_m
		var ge: float = _y[1] - ground_height_m
		var den: float = gs - ge
		best_frac = 1.0 if absf(den) < 1e-12 else clampf(gs / den, 0.0, 1.0)
		_evt_kind = _EVT_GROUND

	if budget <= 0:
		if not _portals.is_empty() or _has_oracle:
			_event_overflows += 1
		return _evt_kind

	# --- portals. In sandbox mode `_portals` is empty and this loop does not
	# execute; it is the same code path, not an `if portal_mode` branch. Nothing
	# above it is computed speculatively either, so sandbox mode pays for the
	# loop bound and nothing else.
	for i in _portal_count:
		var lk: PortalLinkT = _portals[i]
		if _armed[i] == 0:
			# Re-arm on DISTANCE, not on a timer, so a disc that genuinely curves
			# back through the portal it came out of still works.
			if lk.signed_distance(_y[0], _y[1], _y[2]) > REARM_RADII * _disc_radius:
				_armed[i] = 1
			continue
		if not lk.enabled or lk.from_room != _room:
			continue
		var gs: float = lk.signed_distance(_prev[0], _prev[1], _prev[2])
		var ge: float = lk.signed_distance(_y[0], _y[1], _y[2])
		# STRICT sign change, and strictly positive on the entry side. A `>=`
		# here is what turns a disc resting on the plane into an event storm.
		if gs <= 0.0 or ge >= 0.0:
			continue
		var span: float = gs - ge
		# Grazing: the root is ill-conditioned when the disc is sliding along the
		# plane rather than through it.
		if span < MIN_CROSSING_SPEED * seg_dt:
			continue
		var f: float = clampf(gs / span, 0.0, 1.0)
		if f >= best_frac:
			continue
		# Aperture, INSET BY THE DISC RADIUS: a disc whose centre clears the rim
		# would otherwise scythe visibly through solid wall. Tested at the linear
		# estimate of the crossing point, which is within ~1 mm of the root —
		# three orders below the 0.105 m inset, so the decision is never in doubt.
		if not lk.aperture_contains(Vector3(
				_prev[0] + (_y[0] - _prev[0]) * f,
				_prev[1] + (_y[1] - _prev[1]) * f,
				_prev[2] + (_y[2] - _prev[2]) * f), _disc_radius):
			continue
		best_frac = f
		_evt_kind = _EVT_PORTAL
		_evt_index = i

	if _evt_kind == _EVT_PORTAL:
		var lk: PortalLinkT = _portals[_evt_index]
		_set_event_plane(lk.origin, lk.normal)

	# --- walls, via the injected oracle (PORTAL_CONTRACT §7).
	if _has_oracle:
		var p0 := Vector3(_prev[0], _prev[1], _prev[2])
		var p1 := Vector3(_y[0], _y[1], _y[2])
		var hit: Dictionary = hit_oracle.call(p0, p1)
		if not hit.is_empty():
			var f: float = clampf(float(hit.get("fraction", 1.0)), 0.0, 1.0)
			var seg_len: float = p0.distance_to(p1)
			# A portal is set INTO a wall, so on a near-tie the portal must win.
			var tie: float = 0.0
			if _evt_kind == _EVT_PORTAL:
				tie = (PORTAL_WALL_TIE_M / seg_len) if seg_len > 1e-9 else 1.0
			if f < best_frac - tie:
				var pos: Vector3 = hit.get("position", p0.lerp(p1, f))
				var nrm: Vector3 = hit.get("normal", Vector3.ZERO)
				if nrm.length_squared() < 1e-12:
					nrm = (p0 - p1).normalized()
				# The oracle should report the normal facing back toward `from`,
				# as Godot's raycast does. Fix it rather than trust it: a flipped
				# normal makes `_g_plane` have no sign change and the solve
				# silently returns the far end of the segment.
				if (p0 - pos).dot(nrm) < 0.0:
					nrm = -nrm
				best_frac = f
				_evt_kind = _EVT_WALL
				_evt_index = -1
				_last_impact = hit
				_set_event_plane(pos, nrm)

	return _evt_kind


func _set_event_plane(o: Vector3, n: Vector3) -> void:
	_plane_ox = o.x
	_plane_oy = o.y
	_plane_oz = o.z
	_plane_nx = n.x
	_plane_ny = n.y
	_plane_nz = n.z


## Locate the root of `g` inside a step of length `dt` starting from `_prev`, and
## write the state AT the root into `out`. Returns the fraction of `dt` used;
## `_located_dt` carries the same thing as an absolute time.
##
## CONTRACT §4: interpolate the ground crossing inside the final substep — a
## 1/240 step at 25 m/s is 10 cm of landing error otherwise. The same applies to
## a portal crossing, and to a wall.
##
## We do not interpolate the *output*; we re-integrate a shortened step, so the
## event state is a genuine solution of the ODE. The fraction starts from the
## linear estimate and is refined by secant iteration on the real integrator,
## which converges to well under a millimetre in 3-4 passes. The iteration count
## is FIXED, not tolerance-driven, because determinism matters more here than
## the last ulp.
##
## This is the one and only event locator: ground, portals and walls are all
## callers. Generalising the landing solver rather than writing a second
## mechanism is what lets CI prove the landing path did not move.
func _locate_event(g: Callable, dt: float, out: PackedFloat64Array) -> float:
	var g_start: float = g.call(_prev)
	var g_end: float = g.call(_y)
	var denom: float = g_start - g_end
	var frac: float = 1.0 if absf(denom) < 1e-12 else clampf(g_start / denom, 0.0, 1.0)

	var f_prev: float = 0.0
	var g_prev: float = g_start
	for j in _N:
		out[j] = _y[j]
	var best_dt: float = dt

	for _i in LANDING_REFINEMENTS:
		# NB: _rk4 uses _tmp as its stage buffer, so the trial state needs its own.
		for j in _N:
			_trial[j] = _prev[j]
		var sub: float = dt * frac
		_rk4(_trial, sub)
		var gv: float = g.call(_trial)
		for j in _N:
			out[j] = _trial[j]
		best_dt = sub
		if absf(gv) < 1e-7:
			break
		var dg: float = gv - g_prev
		if absf(dg) < 1e-14:
			break
		var next_frac: float = frac - gv * (frac - f_prev) / dg
		f_prev = frac
		g_prev = gv
		frac = clampf(next_frac, 0.0, 1.0)

	_located_dt = best_dt
	return best_dt / dt if dt > 0.0 else 0.0


func _resolve_landing(dt: float) -> void:
	_locate_event(_g_ground_c, dt, _evt)
	for j in _N:
		_y[j] = _evt[j]
	_y[1] = ground_height_m
	_time += _located_dt
	_step_count += 1
	_flying = false
	if _y[1] > _max_height:
		_max_height = _y[1]
	_trajectory.append(Vector3(_y[0], _y[1], _y[2]))


## Carry the state through portal link `i`. The disc is AT the entrance plane;
## `_y` holds the located crossing state.
##
## PORTAL_CONTRACT §2, and the last row is the interesting one:
##
##     position   y[0..2]    M * p            (full affine)
##     velocity   y[3..5]    M.basis * v      (basis only, no translation)
##     quaternion y[6..9]    R * q            (left-multiply)
##     tumble     y[10..12]  M.basis * w
##     omega_n    y[13]      UNCHANGED
##
## `omega_n` is INVARIANT: `w' . n' = (Rw) . (Rn) = w . n` under any proper
## rotation. Measured bit-identical across a crossing. Our state representation —
## a non-spinning-frame quaternion plus a scalar spin — is exactly the right one
## for portals, because the quantity that would be hardest to transform correctly
## needs no transform at all. `_last_omega_t` is a derived cache rewritten by the
## next `_derivs` call, so it is not transformed either.
##
## If a REFLECTION could ever reach here, `w' = R*w` would be wrong: angular
## velocity is a pseudovector and needs `w' = det(R) * (R*w)`, and turn and fade
## would silently invert. `PortalLink.relink()` rejects and repairs reflections
## precisely so this function never has to think about it.
##
## Arithmetic is done in doubles against `xform64` rather than through
## `Transform3D`, which is single precision — the whole point of the 14-double
## state is not to round a 100 m position to a float32 ulp, and doing it at every
## crossing would undo that.
func _apply_portal(i: int) -> void:
	var lk: PortalLinkT = _portals[i]
	var m: PackedFloat64Array = lk.xform64
	var im := PortalLinkT.XF_M
	var it := PortalLinkT.XF_T
	var iq := PortalLinkT.XF_Q
	var inm := PortalLinkT.XF_N

	var enter_pos := Vector3(_y[0], _y[1], _y[2])

	var px: float = _y[0]
	var py: float = _y[1]
	var pz: float = _y[2]
	_y[0] = m[im + 0] * px + m[im + 1] * py + m[im + 2] * pz + m[it + 0]
	_y[1] = m[im + 3] * px + m[im + 4] * py + m[im + 5] * pz + m[it + 1]
	_y[2] = m[im + 6] * px + m[im + 7] * py + m[im + 8] * pz + m[it + 2]

	var vx: float = _y[3]
	var vy: float = _y[4]
	var vz: float = _y[5]
	_y[3] = m[im + 0] * vx + m[im + 1] * vy + m[im + 2] * vz
	_y[4] = m[im + 3] * vx + m[im + 4] * vy + m[im + 5] * vz
	_y[5] = m[im + 6] * vx + m[im + 7] * vy + m[im + 8] * vz

	var wx: float = _y[10]
	var wy: float = _y[11]
	var wz: float = _y[12]
	_y[10] = m[im + 0] * wx + m[im + 1] * wy + m[im + 2] * wz
	_y[11] = m[im + 3] * wx + m[im + 4] * wy + m[im + 5] * wz
	_y[12] = m[im + 6] * wx + m[im + 7] * wy + m[im + 8] * wz

	# Hamilton product r * q, in doubles.
	var rx: float = m[iq + 0]
	var ry: float = m[iq + 1]
	var rz: float = m[iq + 2]
	var rw: float = m[iq + 3]
	var qx: float = _y[6]
	var qy: float = _y[7]
	var qz: float = _y[8]
	var qw: float = _y[9]
	var ox: float = rw * qx + rx * qw + ry * qz - rz * qy
	var oy: float = rw * qy - rx * qz + ry * qw + rz * qx
	var oz: float = rw * qz + rx * qy - ry * qx + rz * qw
	var ow: float = rw * qw - rx * qx - ry * qy - rz * qz
	var qn: float = sqrt(ox * ox + oy * oy + oz * oz + ow * ow)
	if qn > 1e-12:
		var inv: float = 1.0 / qn
		ox *= inv
		oy *= inv
		oz *= inv
		ow *= inv
	_y[6] = ox
	_y[7] = oy
	_y[8] = oz
	_y[9] = ow

	# y[13] (omega_n) is deliberately NOT touched. See the doc comment.

	# Re-crossing guard: step off the exit plane by 0.1 mm, so the very next
	# sign test is unambiguously on the front side.
	_y[0] += m[inm + 0] * exit_nudge_m
	_y[1] += m[inm + 1] * exit_nudge_m
	_y[2] += m[inm + 2] * exit_nudge_m

	_room = lk.to_room
	_apply_room_env(_room)

	# The path is DISCONTINUOUS here, and `get_trajectory()` is a plain polyline
	# with no break markers — so record the pair separately rather than pushing a
	# teleport segment into it and leaving Track P2 to guess.
	_crossing_log.append({
		"t": _time,
		"link": i,
		"enter": enter_pos,
		"exit": Vector3(_y[0], _y[1], _y[2]),
		"to_room": _room,
	})

	# Disarm the way back until the disc is clear of it. Belt and braces with the
	# nudge: the nudge handles the same substep, this handles the next few.
	var back: int = _return_link[i]
	if back >= 0:
		_armed[back] = 0
	_crossings += 1


func _record_trajectory() -> void:
	if _y[1] > _max_height:
		_max_height = _y[1]
	if _step_count % _traj_every == 0:
		_trajectory.append(Vector3(_y[0], _y[1], _y[2]))


func _finite_state() -> bool:
	for i in _N:
		var v: float = _y[i]
		if is_nan(v) or is_inf(v):
			return false
	# A quaternion that has collapsed to zero cannot be normalised.
	var qn: float = _y[6] * _y[6] + _y[7] * _y[7] + _y[8] * _y[8] + _y[9] * _y[9]
	return qn > 1e-12


func _rk4(y: PackedFloat64Array, dt: float) -> void:
	var h2: float = dt * 0.5
	var h6: float = dt / 6.0

	_derivs(y, _k1)
	for i in _N:
		_tmp[i] = y[i] + _k1[i] * h2
	_derivs(_tmp, _k2)
	for i in _N:
		_tmp[i] = y[i] + _k2[i] * h2
	_derivs(_tmp, _k3)
	for i in _N:
		_tmp[i] = y[i] + _k3[i] * dt
	_derivs(_tmp, _k4)
	for i in _N:
		y[i] += h6 * (_k1[i] + 2.0 * _k2[i] + 2.0 * _k3[i] + _k4[i])

	# Renormalise the quaternion every step (CONTRACT §4).
	var qn: float = sqrt(y[6] * y[6] + y[7] * y[7] + y[8] * y[8] + y[9] * y[9])
	if qn > 1e-12:
		var inv: float = 1.0 / qn
		y[6] *= inv
		y[7] *= inv
		y[8] *= inv
		y[9] *= inv


## Time derivative of the 14-element state. This is the hot loop: everything is
## typed, and nothing allocates.
func _derivs(y: PackedFloat64Array, dy: PackedFloat64Array) -> void:
	var vel := Vector3(y[3], y[4], y[5])
	var q := Quaternion(y[6], y[7], y[8], y[9]).normalized()
	var w_tumble := Vector3(y[10], y[11], y[12])
	var omega_n: float = y[13]

	var n: Vector3 = q * Vector3(0.0, 1.0, 0.0)

	# --- position. Copied straight out of the double state rather than through
	# `vel`: Godot's Vector3 is single precision, and round-tripping the velocity
	# through one puts a ~1e-6 m/s error into the single most exact term in the
	# whole system.
	dy[0] = y[3]
	dy[1] = y[4]
	dy[2] = y[5]

	var acc := Vector3.ZERO
	var omega_t: Vector3 = w_tumble
	var d_tumble := Vector3.ZERO
	var d_omega_n: float = 0.0

	# CONTRACT §6: aerodynamics use the AIRSPEED vector; gravity is world frame.
	var vair: Vector3 = vel - _wind
	var v: float = vair.length()
	if v > MIN_AIRSPEED and _rho > 0.0:
		var vhat: Vector3 = vair / v
		var vdotn: float = clampf(vhat.dot(n), -1.0, 1.0)
		var alpha: float = -asin(vdotn)

		_table.sample_into(alpha, _aero)
		var cl: float = _aero[0]
		var cd: float = _aero[1]
		var cm: float = _aero[2]

		var qdyn_a: float = 0.5 * _rho * v * v * _area

		# Lateral (pitch) axis. Rotating the normal about +j raises alpha, so a
		# positive CM is a nose-up moment, as CONTRACT §5 requires.
		var lat: Vector3 = vhat.cross(n)
		var latlen: float = lat.length()
		var j: Vector3
		var lift_dir := Vector3.ZERO
		if latlen > 1.0e-9:
			j = lat / latlen
			lift_dir = j.cross(vhat)  # == normalize(n - (n.vhat) vhat), unit already
		else:
			# alpha = +-90 deg: the flow is along the normal. Lift is zero there in
			# any sane table; pick a well-defined in-plane axis so the moments
			# still have a frame and nothing divides by zero.
			j = (q * Vector3(1.0, 0.0, 0.0)).normalized()

		acc += (lift_dir * (cl * qdyn_a) - vhat * (cd * qdyn_a)) * _inv_mass

		# --- moments. Every term, including spin-down, carries the same
		# 0.5*rho*A*v^2*d scaling (CONTRACT §4). Hummel's published MATLAB drops
		# A*d from the spin term (`Mspin = [0 0 CNr*omegaspin]`); that bug has
		# been copied widely and understates spin loss over a flight.
		#
		# The three rate derivatives multiply the REDUCED rate `rate*d/(2V)`, the
		# standard non-dimensionalisation. This is the form the shipped tables
		# declare (`damping.spin_moment_form`) and the one c_nr was recalibrated
		# against; it is also what the Python reference integrator uses, so the
		# two implementations are comparable term by term.
		#
		# HONEST CAVEAT: only c_nr was recalibrated for this form. c_mq and c_rp
		# are Hummel's published Ultimate-disc numbers, which were fitted against
		# RAW rates. Read as reduced rates they contribute ~0.1% of the static
		# pitching moment during a normal glide, i.e. they are effectively inert
		# except when damping fast wobble. Whether that is right is genuinely
		# unknown — no disc-golf pitch/roll damping measurement exists.
		var qad: float = qdyn_a * _diameter
		var nondim: float = _diameter / (2.0 * v)

		# Work in RHBH-positive spin here so the expressions match the reference
		# integrator line for line. omega_n is the component along +n, = -spin.
		var spin: float = -omega_n
		var spin_eff: float = spin
		if absf(spin_eff) < SPIN_FLOOR:
			spin_eff = SPIN_FLOOR if spin_eff >= 0.0 else -SPIN_FLOOR
		# The one and only place PRECESSION_GAIN is applied.
		var gyro_gain: float = -precession_gain / (_izz * spin_eff)

		# Static pitching moment, the precession it drives, then the damping that
		# precession produces. One pass: the damping feedback on itself is ~0.1%
		# of a term that is itself ~0.1%, so iterating buys nothing.
		var m_static: Vector3 = j * (qad * cm)
		var dn_static: Vector3 = (m_static - n * m_static.dot(n)) * gyro_gain
		var omega_static: Vector3 = n.cross(dn_static)
		var m_damp: Vector3 = vhat * (qad * _c_rp * omega_static.dot(vhat) * nondim) \
			+ j * (qad * _c_mq * omega_static.dot(j) * nondim)
		var m_total: Vector3 = m_static + m_damp
		var m_perp: Vector3 = m_total - n * m_total.dot(n)

		var dn: Vector3 = m_perp * gyro_gain
		var w_prec: Vector3 = n.cross(dn)

		# Spin-down about the normal.
		d_omega_n = qad * _c_nr * omega_n * nondim / _izz

		# Low-spin fallback: hand the transverse motion over to a torque-driven
		# tumble rate as the gyroscopic stiffening disappears. w_low is EXACTLY
		# zero above TUMBLE_HI (5 rad/s = 0.8 rev/s), so this term does not
		# perturb any realistic throw at all.
		var w_low: float = 1.0 - smoothstep(TUMBLE_LO, TUMBLE_HI, absf(omega_n))
		omega_t = w_prec * (1.0 - w_low) + w_tumble
		if w_low > 0.0 or w_tumble.length_squared() > 0.0:
			var damp: float = qad * absf(_c_rp) * nondim / _ixy + TUMBLE_DAMP_FLOOR
			d_tumble = m_perp * (w_low / _ixy) - w_tumble * damp
		else:
			d_tumble = Vector3.ZERO

	# --- velocity. Gravity is added here as a double rather than seeded into
	# `acc`: Godot's Vector3 is single precision, so routing g through it would
	# bake a ~4e-7 relative error into the one term that is otherwise exact, and
	# the zero-density ballistic test would no longer be a clean check of the
	# integrator.
	dy[3] = acc.x
	dy[4] = acc.y - _gravity
	dy[5] = acc.z

	# --- orientation: qdot = 0.5 * (omega, 0) (x) q   for a WORLD-frame omega.
	var wq := Quaternion(omega_t.x, omega_t.y, omega_t.z, 0.0) * q
	dy[6] = 0.5 * wq.x
	dy[7] = 0.5 * wq.y
	dy[8] = 0.5 * wq.z
	dy[9] = 0.5 * wq.w

	dy[10] = d_tumble.x
	dy[11] = d_tumble.y
	dy[12] = d_tumble.z
	dy[13] = d_omega_n

	_last_omega_t = omega_t

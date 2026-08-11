class_name PortalLink
extends RefCounted

# Cross-file/self references go through preloaded consts rather than the global
# `class_name` identifiers — see the note at the top of aero_table.gd. CI runs
# the suite as a bare `godot --headless --script`, which never populates the
# global script-class cache.
const PortalLinkT := preload("res://scripts/physics/portal_link.gd")

## One DIRECTED portal hop: cross the entrance aperture from the front and you
## come out of the exit portal's front face (PORTAL_CONTRACT §1).
##
## PURE MATH. No scene tree, no node access, no `_process`. `DiscFlightSim`'s
## headless property is load-bearing for the test suite and for `preload()`-based
## compilation without the script-class cache, and this file is part of the sim,
## so it inherits the same rule. Track P2 owns the *nodes* that author these; it
## hands us plain `Transform3D`s.
##
## ---------------------------------------------------------------------------
## Convention: local +Z is the surface normal
## ---------------------------------------------------------------------------
## A portal's LOCAL +Z points out of the face you enter from. This is the
## convention both mature open-source implementations use, and it is the
## OPPOSITE of Godot's `Node3D` "forward" (which is -Z). Two consequences:
##
##   * `look_at()` is the wrong tool for building one. It orients -Z, and it
##     ERRORS OUT returning identity when the up vector is parallel to the look
##     direction — i.e. exactly the floor/ceiling case. Use
##     `transform_from_surface_hit()`, which builds the basis by hand.
##   * A portal node authored in the editor must be rotated so its +Z (blue
##     gizmo axis) faces out of the wall, not into it.
##
## ---------------------------------------------------------------------------
## The transform
## ---------------------------------------------------------------------------
##     M = T_B * R_y(PI) * T_A^-1
##
## `R_y(PI)` is 180 degrees about the portal's LOCAL +Y (up). It converts
## "moving into A" into "moving out of B" while preserving the sense of up. It
## is a ROTATION, not a mirror, which is what keeps `det(M) = +1`.
##
## ---------------------------------------------------------------------------
## Handedness (PORTAL_CONTRACT §3) — why the guard below is not paranoia
## ---------------------------------------------------------------------------
## `det(M) = det(T_B) * det(R_y(PI)) * det(T_A)^-1 = +1` for any RIGID portal
## pair, at any orientation, including runtime-placed ones. A reflection cannot
## arise by accident. Two things let one in, both silent:
##
##   1. Negative scale on a portal node (`scale.x = -1` to "mirror" it).
##   2. Building the flip as a planar mirror `I - 2*n*n^T` instead of a rotation.
##      This is the likelier mistake, because portal rendering and mirror
##      rendering look alike.
##
## `Basis.get_rotation_quaternion()` silently negates all three axes when
## `det < 0`, returning a rotation that differs from the input by a point
## inversion. VERIFIED against 4.7.1: `Basis(Vector3(-1,0,0), Vector3(0,1,0),
## Vector3(0,0,1)).get_rotation_quaternion()` returns `(1, 0, 0, 0)` — a 180
## degree rotation about X — and prints NO error, not even in the editor binary.
## The one guard in the engine lives in `get_quaternion()` behind
## `#ifdef MATH_CHECKS`, which is defined only under `DEBUG_ENABLED`. We export
## with `web_nothreads_release`, so it is compiled out of the shipped build.
## That is the same failure class as the six-deploys-without-physics incident:
## fine locally, garbage only in the browser.
##
## Hence: validate at LINK time (not per crossing), with a real runtime check —
## `assert()` is stripped from release GDScript too — repair rather than crash,
## and never call `get_rotation_quaternion()` on an unvalidated basis.
##
## MEASURED CORRECTION to PORTAL_CONTRACT §3.1, which says to validate
## "`det(M)` and `is_conformal()`". `is_conformal()` returns TRUE for a pure
## reflection (verified above: det = -1, `is_conformal()` = true). It tests for
## angle preservation, which a mirror satisfies. It is a useful check for shear
## and non-uniform scale, but it CANNOT detect the failure §3 is about. The
## determinant sign is the load-bearing test; treat `is_conformal()` as the
## secondary one.

## Half-extents of a portal aperture when none is given, metres.
const DEFAULT_HALF_WIDTH := 0.75
const DEFAULT_HALF_HEIGHT := 1.0

## Lift off the surface when building a portal from a raycast hit. Compatibility
## has 24-bit depth and no reverse-Z, so it needs a more generous offset than a
## desktop renderer would (PORTAL_CONTRACT §7).
const SURFACE_LIFT_M := 1.0e-3

## Below this length, the world-up vector projected into the portal plane is too
## short to normalise safely and we switch to the fallback. 0.1 is ~6 degrees
## from vertical — deliberately BEFORE the numerics go bad, not at the exact
## singularity (PORTAL_CONTRACT §7).
const UP_DEGENERATE := 0.1

## `xform64` layout. `Transform3D` and `Quaternion` are single precision in a
## stock Godot build; the integrator state is 14 doubles. Promoting M ONCE here
## and doing the crossing arithmetic in doubles keeps a 100 m position from
## being rounded to a float32 ulp (~8e-6 m) at every crossing. The float32
## content of M itself is a property of the authored transform and is not
## something we can improve on.
const XF_M := 0    ## [0..8]   M.basis, ROW major: element (r, c) at 3*r + c
const XF_T := 9    ## [9..11]  M.origin
const XF_Q := 12   ## [12..15] rotation quaternion of M.basis, (x, y, z, w)
const XF_N := 16   ## [16..18] exit portal world normal (unit)
const XF_SIZE := 19

# --- authored inputs -------------------------------------------------------

## World transform of the portal you enter. Local +Z is its outward normal.
var entrance := Transform3D.IDENTITY
## World transform of the portal you leave by. Local +Z is its outward normal.
var exit_transform := Transform3D.IDENTITY
## Room index the ENTRANCE lives in. Only links whose `from_room` is the disc's
## current room are tested, so two rooms may reuse the same coordinates.
var from_room: int = 0
## Room index the disc is in after crossing. Selects the `FlightEnvironment`.
var to_room: int = 0
## Aperture half-extents in the entrance portal's local X / Y, metres.
var half_width: float = DEFAULT_HALF_WIDTH
var half_height: float = DEFAULT_HALF_HEIGHT
## Cleared to disable the link without removing it from the array (which would
## change iteration order, and iteration order is part of determinism).
var enabled: bool = true

# --- derived, rebuilt ONLY by relink() -------------------------------------

## M = T_B * R_y(PI) * T_A^-1.
var transform := Transform3D.IDENTITY
## Rotation quaternion of `transform.basis`. Only ever read after validation.
var rotation := Quaternion.IDENTITY
var origin := Vector3.ZERO           ## entrance origin, world
var normal := Vector3(0.0, 0.0, 1.0) ## entrance +Z, world, unit
var exit_origin := Vector3.ZERO
var exit_normal := Vector3(0.0, 0.0, 1.0)
var determinant: float = 1.0
## False if the pair could not be used as authored. Still safe to step through:
## the basis has been repaired to the nearest proper rotation.
var valid: bool = true
## True if the guard had to repair the basis. Surface this on a dev overlay.
var repaired: bool = false
## Human-readable reasons, for a dev overlay. Empty when `valid`.
var warnings := PackedStringArray()

var xform64 := PackedFloat64Array()

var _entrance_inv := Transform3D.IDENTITY
# Entrance plane in DOUBLE precision, promoted once from the float32 transform.
var _ox: float = 0.0
var _oy: float = 0.0
var _oz: float = 0.0
var _nx: float = 0.0
var _ny: float = 0.0
var _nz: float = 1.0


func _init() -> void:
	xform64.resize(XF_SIZE)
	relink()


# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

## One directed hop. Prefer `make_pair()` — a portal you can only go one way
## through is almost always an authoring mistake.
static func make(entrance_xf: Transform3D, exit_xf: Transform3D, from_r: int = 0,
		to_r: int = 0, half_w: float = DEFAULT_HALF_WIDTH,
		half_h: float = DEFAULT_HALF_HEIGHT) -> PortalLinkT:
	var lk := PortalLinkT.new()
	lk.entrance = entrance_xf
	lk.exit_transform = exit_xf
	lk.from_room = from_r
	lk.to_room = to_r
	lk.half_width = half_w
	lk.half_height = half_h
	lk.relink()
	return lk


## Both directions of one portal pair, in a fixed order: `[a -> b, b -> a]`.
## `DiscFlightSim` pairs them up by matching transforms, so passing this array
## straight to `configure_rooms()` gives correct re-crossing suppression.
static func make_pair(a: Transform3D, b: Transform3D, room_a: int = 0,
		room_b: int = 0, half_w: float = DEFAULT_HALF_WIDTH,
		half_h: float = DEFAULT_HALF_HEIGHT) -> Array:
	return [
		make(a, b, room_a, room_b, half_w, half_h),
		make(b, a, room_b, room_a, half_w, half_h),
	]


## Build a portal transform from a surface hit: `+Z = n`, `+X = up x n`, lifted
## off the surface by `SURFACE_LIFT_M` to avoid z-fighting.
##
## The up vector is WORLD-UP PROJECTED ONTO THE PLANE. That choice is
## gameplay-visible, not cosmetic (PORTAL_CONTRACT §6): two wall portals that
## both use world-up differ by a pure YAW, and the flight dynamics are exactly
## equivariant under yaw — so a wall-to-wall pair leaves the flight unchanged,
## merely rotated and moved. Any other net rotation changes the flight, because
## gravity is the one term that does not rotate with the state. An INVERTING
## pair is a disc-killer and it is correct physics: `lift_dir = j x vhat` with
## `j = normalise(vhat x n)`, so flipping `n` points lift DOWN. Unlike Portal we
## cannot re-upright the traveller — the disc's orientation IS its physics state.
##
## `hint` is used only for floor/ceiling faces, where world-up is parallel to
## the normal and the projection degenerates. Pass the disc's horizontal travel
## direction; a fixed deterministic axis is the last resort.
static func transform_from_surface_hit(p: Vector3, n: Vector3,
		hint: Vector3 = Vector3.ZERO) -> Transform3D:
	var nn: Vector3 = n
	if not nn.is_finite() or nn.length_squared() < 1e-12:
		nn = Vector3(0.0, 0.0, 1.0)
	nn = nn.normalized()

	var up: Vector3 = Vector3.UP - nn * Vector3.UP.dot(nn)
	if up.length() < UP_DEGENERATE:
		up = hint - nn * hint.dot(nn)
	if up.length() < UP_DEGENERATE:
		# Deterministic last resorts, tried in a fixed order so a floor portal
		# placed twice at the same spot gets the same basis both times.
		up = Vector3(0.0, 0.0, -1.0) - nn * Vector3(0.0, 0.0, -1.0).dot(nn)
	if up.length() < UP_DEGENERATE:
		up = Vector3(1.0, 0.0, 0.0) - nn * Vector3(1.0, 0.0, 0.0).dot(nn)
	up = up.normalized()

	# Columns are local +X, +Y, +Z. `right = up x n` makes the triple
	# right-handed: right x up = (up x n) x up = n. det = +1 by construction.
	var right: Vector3 = up.cross(nn).normalized()
	up = nn.cross(right).normalized()
	return Transform3D(Basis(right, up, nn), p + nn * SURFACE_LIFT_M)


# ---------------------------------------------------------------------------
# Linking and validation
# ---------------------------------------------------------------------------

## Rebuild and revalidate `M`. Call after changing `entrance` / `exit_transform`.
##
## This is the ONLY place `M` is computed. Everything else reads the cache, so a
## portal cannot go stale mid-flight — which is also why PORTAL_CONTRACT §7 makes
## portals immutable while a disc is airborne.
func relink() -> void:
	warnings.clear()
	valid = true
	repaired = false

	_check_portal_basis("entrance", entrance.basis)
	_check_portal_basis("exit", exit_transform.basis)

	# PORTAL_CONTRACT §1: M = T_B * R_y(PI) * T_A^-1.
	#
	# SUBTLETY, and getting it backwards is a silent bug. `Transform3D.rotated()`
	# PRE-multiplies (it is a rotation in the global frame);
	# `Transform3D.rotated_local()` post-multiplies. VERIFIED against 4.7.1.
	# Here the argument acts on the OUTPUT of `T_A^-1`, which is A's own local
	# frame — so `Vector3.UP` below means THE PORTAL'S +Y, not the world's. That
	# is what makes the flip preserve the sense of up regardless of how the
	# portal is mounted.
	var m: Transform3D = exit_transform * entrance.affine_inverse().rotated(Vector3.UP, PI)

	determinant = m.basis.determinant()
	var bad_det: bool = not is_finite(determinant) or determinant <= 0.0
	# `is_conformal()` is the SECONDARY check: it is true for a pure reflection
	# (measured), so it catches shear and non-uniform scale but not handedness.
	var bad_shape: bool = not m.basis.is_conformal()
	if bad_det or bad_shape:
		if bad_det:
			_fail("det(M) = %f, expected +1 — a reflecting portal returns garbage from get_rotation_quaternion() with no error in a release build" % determinant)
		if bad_shape:
			_fail("M is not conformal — the portal transforms carry shear or non-uniform scale")
		m = Transform3D(_repair_basis(m.basis), m.origin)
		determinant = m.basis.determinant()
		repaired = true

	transform = m
	# Only now, on a basis known to be a proper rotation (PORTAL_CONTRACT §3.4).
	rotation = m.basis.get_rotation_quaternion().normalized()

	origin = entrance.origin
	normal = _axis_or(entrance.basis.z, Vector3(0.0, 0.0, 1.0))
	exit_origin = exit_transform.origin
	exit_normal = _axis_or(exit_transform.basis.z, Vector3(0.0, 0.0, 1.0))
	_entrance_inv = entrance.affine_inverse()

	_ox = origin.x
	_oy = origin.y
	_oz = origin.z
	_nx = normal.x
	_ny = normal.y
	_nz = normal.z

	var b: Basis = m.basis
	# Row major: element (r, c) is component r of column c.
	xform64[XF_M + 0] = b.x.x
	xform64[XF_M + 1] = b.y.x
	xform64[XF_M + 2] = b.z.x
	xform64[XF_M + 3] = b.x.y
	xform64[XF_M + 4] = b.y.y
	xform64[XF_M + 5] = b.z.y
	xform64[XF_M + 6] = b.x.z
	xform64[XF_M + 7] = b.y.z
	xform64[XF_M + 8] = b.z.z
	xform64[XF_T + 0] = m.origin.x
	xform64[XF_T + 1] = m.origin.y
	xform64[XF_T + 2] = m.origin.z
	xform64[XF_Q + 0] = rotation.x
	xform64[XF_Q + 1] = rotation.y
	xform64[XF_Q + 2] = rotation.z
	xform64[XF_Q + 3] = rotation.w
	xform64[XF_N + 0] = exit_normal.x
	xform64[XF_N + 1] = exit_normal.y
	xform64[XF_N + 2] = exit_normal.z

	if half_width <= 0.0 or half_height <= 0.0:
		_fail("aperture half-extents must be positive (got %.4f x %.4f)"
			% [half_width, half_height])


func _fail(msg: String) -> void:
	valid = false
	warnings.append(msg)
	# A REAL runtime check, not `assert()` — asserts are stripped from release
	# GDScript, which is exactly the build where this matters. Warn and repair;
	# never crash a player's browser (PORTAL_CONTRACT §3.2, §3.3).
	push_warning("PortalLink: %s" % msg)


func _check_portal_basis(which: String, b: Basis) -> void:
	var d: float = b.determinant()
	if not is_finite(d) or d <= 0.0:
		_fail("%s portal has det = %f — negative scale on a portal node mirrors it, which we reject rather than support" % [which, d])
	elif not b.is_conformal():
		_fail("%s portal basis is not conformal (shear or non-uniform scale)" % which)


## Nearest proper rotation to a broken basis. `orthonormalized()` is Gram-Schmidt
## and PRESERVES the determinant sign (verified: orthonormalising a reflection
## still gives det = -1), so a reflection has to be undone explicitly. We flip
## local +X, leaving +Y (up) and +Z (the normal) intact — those two are the
## gameplay-meaningful axes, and the exit orientation is what decides whether the
## disc emerges upright or inverted.
func _repair_basis(b: Basis) -> Basis:
	var r: Basis = b.orthonormalized()
	if not is_finite(r.determinant()) or absf(r.determinant()) < 1e-6:
		return Basis.IDENTITY
	if r.determinant() < 0.0:
		r = Basis(-r.x, r.y, r.z)
	return r


static func _axis_or(v: Vector3, fallback: Vector3) -> Vector3:
	if not v.is_finite() or v.length_squared() < 1e-12:
		return fallback
	return v.normalized()


# ---------------------------------------------------------------------------
# Queries used by the integrator
# ---------------------------------------------------------------------------

## Signed distance from the entrance plane; positive on the side you enter from.
## Double precision on purpose — the integrator state is doubles, and this is the
## event function whose root we solve for.
func signed_distance(x: float, y: float, z: float) -> float:
	return (x - _ox) * _nx + (y - _oy) * _ny + (z - _oz) * _nz


func signed_distance_v(p: Vector3) -> float:
	return signed_distance(p.x, p.y, p.z)


## Is a world point inside the aperture, with the rectangle shrunk by `inset`?
##
## `inset` is the disc RADIUS. Without it, a disc whose CENTRE clears the rim
## visibly scythes through solid wall (PORTAL_CONTRACT §5). The centre is also
## the only crossing point that makes the event a single well-defined root and
## keeps `omega_n` invariance exact.
func aperture_contains(p: Vector3, inset: float = 0.0) -> bool:
	var l: Vector3 = _entrance_inv * p
	return absf(l.x) <= maxf(half_width - inset, 0.0) \
		and absf(l.y) <= maxf(half_height - inset, 0.0)


## Distance between the two portal PLANES, used to reject a pair placed so close
## that a disc could cross both inside one substep (PORTAL_CONTRACT §7).
func plane_separation() -> float:
	return absf((exit_origin - origin).dot(normal))


func describe() -> String:
	return "PortalLink(room %d -> %d, det=%.6f%s%s)" % [from_room, to_room,
		determinant, "" if valid else ", INVALID", ", REPAIRED" if repaired else ""]

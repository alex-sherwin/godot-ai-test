class_name DiscMeshBuilder
extends RefCounted

## Parametric disc-golf disc: a solid of revolution generated from exactly the
## CONTRACT §2 geometry parameters, so the shape the user edits is the shape the
## aero model is handed.
##
## PURE. No scene tree, no node access — everything here runs under
## `godot --headless --script`. The only engine types touched are the resource
## types it returns (ArrayMesh / StandardMaterial3D / ImageTexture).
##
## ---------------------------------------------------------------------------
## The cross-section is Track A's, ported
## ---------------------------------------------------------------------------
## `tools/aero/geometry.py::DiscGeometry.cross_section` is the authority: it is
## the exact meridional profile Track A sweeps to integrate `I_zz` and `I_xy`.
## This is a line-for-line port of it, because if the lathe here and the
## integration there disagreed about the solid, the disc you can see and the
## disc that is being simulated would be different objects.
##
## Track A returns the section as (r, z_lo, z_hi) over r in [0, R]. Traced as a
## single closed loop from the dome apex, outward over the top, down the outer
## face, back under the rim and in along the plate underside, with y = 0 at the
## RESTING PLANE (the surface the disc sits on):
##
##            dome apex
##          .-----_____                                    1 flight plate + dome
##         /           `-----_____                         2 rim top ramp
##        |                        `-----.  top_outer
##   rh - +                               |               3 outer face; the
##        |   (rim cavity, open below)    |   parting        parting line is its
##        |                          ____/  bot_outer        midpoint
##   rd - +----------------._____----'                      4 rim underside ramp
##        |               |                                 5 cavity wall
##  y = 0 +---------------+                                 6 plate underside
##        r=0            r=ri                       r=R
##
##   rh = rim_depth_m + plate_thickness_m            (rim height at r = ri)
##   bot_outer = max(parting_line_m - rim_thickness_m/2, 0)
##   top_outer = bot_outer + rim_thickness_m
##   plate top: rh + dome_height_m * (1 - (r/ri)^2)   for r < ri
##   rim, s = (r - ri)/(R - ri):
##       z_hi = rh + (top_outer - rh) * s ,  z_lo = bot_outer * s
##
## Straight ramps rather than curves is Track A's model, and it is reproduced
## verbatim — no fillets, no smoothing of the solid — so the volume, the
## moments and the silhouette are identical to what the aero model integrates.
## `verify_against(disc_entry)` re-integrates I_zz / I_xy from the traced
## polyline and checks them against the values `discs.json` ships, which is what
## makes the "same object" claim testable rather than asserted.
##
## ---------------------------------------------------------------------------
## Parameter meanings (CONTRACT §2 v2, matching tools/aero/geometry.py)
## ---------------------------------------------------------------------------
##   diameter_m         outer diameter. NOT clamped to the PDGA 0.210-0.213
##                      band: Roc and Buzzz really are 0.217 m and River 0.215.
##   rim_width_m        radial width of the rim. Drives the speed rating; the
##                      profile itself is positioned by inner_rim_edge_m, and
##                      Track A's roster always has ri = R - rim_width.
##   rim_depth_m        cavity depth = height of the plate underside.
##   rim_thickness_m    AXIAL thickness of the wing at the outer edge — how
##                      blunt the nose is. 2.5-6 mm across the real roster.
##   parting_line_m     height of the widest point above the RESTING PLANE
##                      (CONTRACT §2 v2; v1 said "above the flight plate",
##                      which made parting_ratio go negative).
##   dome_height_m      apex height of the plate above its rim-edge height.
##   inner_rim_edge_m   radius where the rim meets the flight plate.
##
## plate_thickness_m is not one of the eight; Track A treats it as a module
## constant (1.8 mm) with a per-disc override, and so does this.
##
## ---------------------------------------------------------------------------
## Winding
## ---------------------------------------------------------------------------
## Godot uses CLOCKWISE winding for front faces, so a front-facing triangle has
## `cross(v1-v0, v2-v0)` pointing AWAY from the outward normal. The convention
## is pinned by `verify_winding()`, which any headless script can assert on.

# ---------------------------------------------------------------------------
# Geometry (CONTRACT §2)
# ---------------------------------------------------------------------------

const GEOMETRY_KEYS := ["diameter_m", "mass_kg", "rim_width_m", "rim_depth_m",
	"rim_thickness_m", "parting_line_m", "dome_height_m", "inner_rim_edge_m"]

## The Teebird's published figures, from Track A's roster.
const DEFAULT_GEOMETRY := {
	"diameter_m": 0.212,
	"mass_kg": 0.175,
	"rim_width_m": 0.017,
	"rim_depth_m": 0.011,
	"rim_thickness_m": 0.006109,
	"parting_line_m": 0.005975,
	"dome_height_m": 0.0022,
	"inner_rim_edge_m": 0.089,
}

## Flight-plate thickness. Not one of the eight CONTRACT §2 parameters; Track A
## carries it as a module constant with a per-disc override
## (`tools/aero/geometry.py::DEFAULT_PLATE_THICKNESS_M`), and this matches.
const DEFAULT_PLATE_THICKNESS_M := 0.0018
const MIN_PLATE_M := 0.0006
const MAX_PLATE_M := 0.010
## Junction tangent change beyond which the profile creases instead of smoothing.
const CREASE_RAD := 0.70  # ~40 degrees

## Default tessellation. 64 x ~40 is the budget the designer sliders rebuild at.
const DEFAULT_RADIAL_SEGMENTS := 64
const DEFAULT_PROFILE_SAMPLES := 40

# Surface indices of the returned ArrayMesh.
const SURFACE_PLATE := 0  ## top of the flight plate; carries the spin pattern
const SURFACE_BODY := 1   ## shoulder, rim, underside


## One traced cross-section: parallel arrays, one entry per profile row.
## `r`/`y` are metres, `nr`/`ny` the outward normal in the (r, y) half-plane,
## `v` the per-surface V texture coordinate, `surf` the target surface index.
class Profile:
	extends RefCounted
	var r := PackedFloat32Array()
	var y := PackedFloat32Array()
	var nr := PackedFloat32Array()
	var ny := PackedFloat32Array()
	var v := PackedFloat32Array()
	var surf := PackedInt32Array()
	var radius: float = 0.0      ## outer radius, m
	var height: float = 0.0      ## total height, m
	var parting_y: float = 0.0   ## height of the widest point above the resting plane

	func size() -> int:
		return r.size()


# ---------------------------------------------------------------------------
# Instance API (cached; this is what the live designer sliders drive)
# ---------------------------------------------------------------------------

var radial_segments: int = DEFAULT_RADIAL_SEGMENTS
var profile_samples: int = DEFAULT_PROFILE_SAMPLES
## Shift the mesh so its local origin sits on the parting line — the disc's
## aerodynamic mid-plane — rather than on the resting plane.
var origin_at_parting_line: bool = true

var _geom: Dictionary = {}
var _norm: Dictionary = {}
var _mesh: ArrayMesh = null
var _profile: Profile = null
var _dirty: bool = true
var _build_count: int = 0
var _last_build_usec: int = 0


func _init(geometry: Dictionary = {}) -> void:
	set_geometry(geometry if not geometry.is_empty() else DEFAULT_GEOMETRY)


## Returns true if anything actually changed (and therefore a rebuild is due).
## Cheap enough to call on every slider frame.
func set_geometry(geometry: Dictionary) -> bool:
	var n := normalize_geometry(geometry)
	if not _norm.is_empty() and _dicts_match(n, _norm):
		return false
	_geom = geometry.duplicate()
	_norm = n
	_dirty = true
	return true


func get_geometry() -> Dictionary:
	return _norm.duplicate()


func set_resolution(radial: int, profile: int) -> void:
	radial = clampi(radial, 8, 256)
	profile = clampi(profile, 12, 200)
	if radial == radial_segments and profile == profile_samples:
		return
	radial_segments = radial
	profile_samples = profile
	_dirty = true


## Rebuilds only when the geometry or resolution changed.
func get_mesh() -> ArrayMesh:
	if _dirty or _mesh == null:
		var t0 := Time.get_ticks_usec()
		_profile = trace_profile(_norm, profile_samples)
		_mesh = _revolve(_profile, radial_segments,
			-_profile.parting_y if origin_at_parting_line else 0.0)
		_last_build_usec = Time.get_ticks_usec() - t0
		_build_count += 1
		_dirty = false
	return _mesh


func get_profile() -> Profile:
	if _dirty or _profile == null:
		get_mesh()
	return _profile


## Half cross-section as (r, y) metres, y from the resting plane. This is the
## same polyline the mesh is revolved from, so a UI diagram drawn from it is
## literally the geometry the sim sees.
func get_profile_polyline() -> PackedVector2Array:
	var p := get_profile()
	var out := PackedVector2Array()
	out.resize(p.size())
	for i in p.size():
		out[i] = Vector2(p.r[i], p.y[i])
	return out


## Full mirrored cross-section, x in [-R, +R], y from the resting plane. Drawn
## left-to-right it traces the top surface across the disc and back along the
## underside, i.e. a closed outline ready for `Polygon2D` / `draw_polyline`.
func get_cross_section() -> PackedVector2Array:
	return cross_section_polyline(_norm, profile_samples)


func last_build_usec() -> int:
	return _last_build_usec


func build_count() -> int:
	return _build_count


# ---------------------------------------------------------------------------
# Static API
# ---------------------------------------------------------------------------

## Fill in defaults, coerce to float, and widen or narrow only as far as is
## needed to keep the shell non-degenerate. Also returns the same derived
## quantities Track A publishes, so a UI can label a diagram without re-deriving
## them.
##
## The bounds here are deliberately WIDER than Track A's `_LIMITS`. Track A
## validates published moulds and raises on anything that cannot be a real disc;
## this has to keep rendering while somebody drags a slider, so it clamps
## silently and never rejects. In particular `diameter_m` is NOT clamped to the
## PDGA 0.210-0.213 band — Roc and Buzzz ship at 0.217 m and River at 0.215 m,
## and those are real certified figures.
static func normalize_geometry(g: Dictionary) -> Dictionary:
	var out := {}
	for k in GEOMETRY_KEYS:
		out[k] = float(g.get(k, DEFAULT_GEOMETRY[k]))

	var diameter: float = clampf(out["diameter_m"], 0.12, 0.32)
	var radius: float = diameter * 0.5
	var rim_width: float = clampf(out["rim_width_m"], 0.003, 0.48 * radius)
	var rim_depth: float = clampf(out["rim_depth_m"], 0.003, 0.05)
	var plate: float = clampf(float(g.get("plate_thickness_m", DEFAULT_PLATE_THICKNESS_M)),
		MIN_PLATE_M, MAX_PLATE_M)
	# Axial thickness of the wing at the outer edge.
	var nose: float = clampf(out["rim_thickness_m"], 0.0004, 0.030)
	# Height of the widest point above the resting plane (CONTRACT §2 v2).
	var parting: float = clampf(out["parting_line_m"], 0.0002, 0.030)
	var dome: float = clampf(out["dome_height_m"], 0.0, 0.025)
	# Track A positions the whole profile from inner_rim_edge_m and never reads
	# rim_width_m, so it is taken verbatim; its roster always has ri = R - rim_width.
	# Only when it is absent is it derived.
	var shoulder: float = clampf(
		float(g.get("inner_rim_edge_m", radius - rim_width)),
		0.30 * radius, radius - 0.002)

	var rim_height: float = rim_depth + plate
	# tools/aero/geometry.py: a wing whose parting line sits lower than half its
	# thickness is pushed up to rest on the ground plane rather than dipping
	# below it. Thickness is preserved; the parting line then sits low on a
	# flat-bottomed wing, which is what those moulds actually look like.
	var bot_outer: float = maxf(parting - 0.5 * nose, 0.0)

	out["diameter_m"] = diameter
	out["rim_width_m"] = rim_width
	out["rim_depth_m"] = rim_depth
	out["rim_thickness_m"] = nose
	out["parting_line_m"] = parting
	out["dome_height_m"] = dome
	out["inner_rim_edge_m"] = shoulder
	out["mass_kg"] = clampf(out["mass_kg"], 0.05, 0.40)
	# Derived — same names and definitions as Track A's `DiscGeometry`.
	out["plate_thickness_m"] = plate
	out["radius_m"] = radius
	out["rim_height_m"] = rim_height
	out["bot_outer_m"] = bot_outer
	out["top_outer_m"] = bot_outer + nose
	out["area_m2"] = PI * radius * radius
	out["parting_ratio"] = parting / maxf(rim_depth, 1e-9)
	out["nose_ratio"] = nose / maxf(rim_depth, 1e-9)
	out["height_m"] = rim_height + dome
	return out


## Pull the CONTRACT §2 block off anything that exposes those properties —
## a DiscDefinition, or a plain Dictionary from `discs.json`.
static func geometry_from(source: Variant) -> Dictionary:
	var out := {}
	if source is Dictionary:
		var d: Dictionary = source
		if d.has("geometry") and d["geometry"] is Dictionary:
			d = d["geometry"]
		for k in GEOMETRY_KEYS:
			out[k] = float(d.get(k, DEFAULT_GEOMETRY[k]))
		return out
	if source == null:
		return DEFAULT_GEOMETRY.duplicate()
	for k in GEOMETRY_KEYS:
		var val: Variant = source.get(k)
		out[k] = float(val) if val != null else float(DEFAULT_GEOMETRY[k])
	return out


static func build_mesh(geometry: Dictionary,
		radial: int = DEFAULT_RADIAL_SEGMENTS,
		profile: int = DEFAULT_PROFILE_SAMPLES,
		center_on_parting_line: bool = true) -> ArrayMesh:
	var norm := normalize_geometry(geometry)
	var prof := trace_profile(norm, profile)
	return _revolve(prof, radial, -prof.parting_y if center_on_parting_line else 0.0)


static func cross_section_polyline(geometry: Dictionary,
		samples: int = DEFAULT_PROFILE_SAMPLES) -> PackedVector2Array:
	var prof := trace_profile(normalize_geometry(geometry), samples)
	var n := prof.size()
	var out := PackedVector2Array()
	out.resize(n * 2)
	# Right half traced in order, then the left half traced backwards, so the
	# result is a single closed outline.
	for i in n:
		out[i] = Vector2(prof.r[i], prof.y[i])
	for i in n:
		var j: int = n - 1 - i
		out[n + i] = Vector2(-prof.r[j], prof.y[j])
	return out


# ---------------------------------------------------------------------------
# Profile tracing
# ---------------------------------------------------------------------------

## Trace the closed cross-section — a direct port of
## `tools/aero/geometry.py::DiscGeometry.cross_section`, walked as a loop
## instead of as (r, z_lo, z_hi) columns. `samples` is the approximate total row
## count; only the dome is actually curved, so most of it goes there.
static func trace_profile(norm: Dictionary, samples: int) -> Profile:
	var radius: float = norm["radius_m"]
	var rim_depth: float = norm["rim_depth_m"]
	var rim_height: float = norm["rim_height_m"]
	var dome: float = norm["dome_height_m"]
	var shoulder: float = norm["inner_rim_edge_m"]
	var bot_outer: float = norm["bot_outer_m"]
	var top_outer: float = norm["top_outer_m"]

	var scale: float = clampf(float(samples) / float(DEFAULT_PROFILE_SAMPLES), 0.3, 5.0)
	var n_dome: int = maxi(4, int(round(16.0 * scale)))
	# Straight ramps need only enough rows to keep the lathe's radial facets
	# from being long and thin; the surface is exactly conical.
	var n_ramp: int = maxi(2, int(round(5.0 * scale)))

	# Every segment emits BOTH endpoints, so each junction appears as a
	# coincident pair of points carrying the two segments' tangents. The merge
	# pass in `_finish_profile` then decides smooth-or-crease with the exact
	# tangents on each side.
	var pts := PackedVector2Array()
	var tans := PackedVector2Array()

	# --- 1. flight plate + dome, r: 0 -> ri --------------------------------
	#     z_hi = rim_height + dome * (1 - (r/ri)^2)
	for i in n_dome + 1:
		var t: float = float(i) / float(n_dome)
		pts.append(Vector2(shoulder * t, rim_height + dome * (1.0 - t * t)))
		tans.append(Vector2(shoulder, -2.0 * dome * t))
	# The flight-plate top is its own surface; it ends on this row.
	var plate_end: int = pts.size() - 1

	# --- 2. rim top ramp, (ri, rim_height) -> (R, top_outer) ---------------
	_append_line(pts, tans, Vector2(shoulder, rim_height),
		Vector2(radius, top_outer), n_ramp)

	# --- 3. outer face; the parting line is its midpoint by construction ---
	_append_line(pts, tans, Vector2(radius, top_outer),
		Vector2(radius, bot_outer), 2)

	# --- 4. rim underside ramp, (R, bot_outer) -> (ri, 0) ------------------
	_append_line(pts, tans, Vector2(radius, bot_outer), Vector2(shoulder, 0.0), n_ramp)

	# --- 5. cavity wall, (ri, 0) -> (ri, rim_depth) ------------------------
	_append_line(pts, tans, Vector2(shoulder, 0.0), Vector2(shoulder, rim_depth), 2)

	# --- 6. flight plate underside, r: ri -> 0 (flat) ----------------------
	_append_line(pts, tans, Vector2(shoulder, rim_depth), Vector2(0.0, rim_depth), 2)

	return _finish_profile(pts, tans, plate_end, norm)


## Sample a straight segment, emitting both endpoints and a constant tangent.
static func _append_line(pts: PackedVector2Array, tans: PackedVector2Array,
		a: Vector2, b: Vector2, n: int) -> void:
	var d: Vector2 = b - a
	if d.length_squared() < 1e-18:
		d = Vector2(1.0, 0.0)
	for i in n + 1:
		pts.append(a.lerp(b, float(i) / float(n)))
		tans.append(d)


## Turn the traced points into rows: outward normals, junction merging (smooth)
## or crease duplication (sharp), per-surface V coordinates.
##
## Junctions arrive as coincident point PAIRS, one from each segment. Merging
## them with the mean of the two tangents is the weld: the resulting normal is
## shared by both segments and identical on every column of the revolution,
## including the duplicated wrap seam.
static func _finish_profile(pts: PackedVector2Array, tans: PackedVector2Array,
		plate_end: int, norm: Dictionary) -> Profile:
	var n := pts.size()
	var prof := Profile.new()
	prof.radius = norm["radius_m"]
	prof.height = norm["height_m"]
	prof.parting_y = norm["parting_line_m"]

	# Normalised tangents; the outward normal of a profile traced top-centre ->
	# outward -> under -> back to the axis is (-dy, dr).
	var dirs := PackedVector2Array()
	dirs.resize(n)
	for i in n:
		var d: Vector2 = tans[i]
		if d.length_squared() < 1e-16:
			d = Vector2(1.0, 0.0)
		dirs[i] = d.normalized()

	var shoulder_r: float = maxf(float(norm["inner_rim_edge_m"]), 1e-5)
	var crease_cos: float = cos(CREASE_RAD)

	var rows_r := PackedFloat32Array()
	var rows_y := PackedFloat32Array()
	var rows_nr := PackedFloat32Array()
	var rows_ny := PackedFloat32Array()
	var rows_surf := PackedInt32Array()

	var i: int = 0
	while i < n:
		var p: Vector2 = pts[i]
		var surface: int = SURFACE_PLATE if i <= plate_end else SURFACE_BODY
		var paired: bool = i + 1 < n and pts[i + 1].distance_squared_to(p) < 1e-14
		if not paired:
			var d: Vector2 = dirs[i]
			rows_r.append(p.x); rows_y.append(p.y)
			rows_nr.append(-d.y); rows_ny.append(d.x)
			rows_surf.append(surface)
			i += 1
			continue
		var d_in: Vector2 = dirs[i]
		var d_out: Vector2 = dirs[i + 1]
		# The plate/body boundary always splits so the two surfaces can carry
		# independent UVs, even where the profile is perfectly smooth.
		var split: bool = d_in.dot(d_out) < crease_cos or i == plate_end
		if split:
			rows_r.append(p.x); rows_y.append(p.y)
			rows_nr.append(-d_in.y); rows_ny.append(d_in.x)
			rows_surf.append(surface)
			rows_r.append(p.x); rows_y.append(p.y)
			rows_nr.append(-d_out.y); rows_ny.append(d_out.x)
			rows_surf.append(SURFACE_PLATE if i + 1 <= plate_end else SURFACE_BODY)
		else:
			var d: Vector2 = (d_in + d_out).normalized()
			rows_r.append(p.x); rows_y.append(p.y)
			rows_nr.append(-d.y); rows_ny.append(d.x)
			rows_surf.append(surface)
		i += 2

	var m := rows_r.size()
	prof.r = rows_r
	prof.y = rows_y
	prof.nr = rows_nr
	prof.ny = rows_ny
	prof.surf = rows_surf
	prof.v.resize(m)

	# V coordinates. The plate is mapped radially (v = r / shoulder) so a radial
	# pattern lands square on it; the body is mapped by arclength.
	var body_len: float = 0.0
	var lens := PackedFloat32Array()
	lens.resize(m)
	var prev := Vector2(rows_r[0], rows_y[0])
	for k in m:
		var cur := Vector2(rows_r[k], rows_y[k])
		if rows_surf[k] == SURFACE_BODY:
			body_len += cur.distance_to(prev)
		lens[k] = body_len
		prev = cur
	var inv_body: float = 1.0 / maxf(body_len, 1e-6)
	for k in m:
		if rows_surf[k] == SURFACE_PLATE:
			prof.v[k] = clampf(rows_r[k] / shoulder_r, 0.0, 1.0)
		else:
			prof.v[k] = clampf(lens[k] * inv_body, 0.0, 1.0)
	return prof


# ---------------------------------------------------------------------------
# Revolution
# ---------------------------------------------------------------------------

## Revolve a traced profile around +Y. Normals are analytic, so the wrap seam is
## exact rather than approximately averaged: the duplicated u = 1 column carries
## bit-identical normals to the u = 0 column.
static func _revolve(prof: Profile, radial: int, y_offset: float) -> ArrayMesh:
	radial = maxi(radial, 8)
	var cols: int = radial + 1
	var rows: int = prof.size()
	var mesh := ArrayMesh.new()

	var cosv := PackedFloat32Array()
	var sinv := PackedFloat32Array()
	cosv.resize(cols)
	sinv.resize(cols)
	for j in cols:
		var a: float = TAU * float(j) / float(radial)
		cosv[j] = cos(a)
		sinv[j] = sin(a)

	for surface in [SURFACE_PLATE, SURFACE_BODY]:
		# Contiguous row range for this surface.
		var lo: int = -1
		var hi: int = -1
		for i in rows:
			if prof.surf[i] == surface:
				if lo < 0:
					lo = i
				hi = i
		if lo < 0 or hi <= lo:
			continue
		var nrows: int = hi - lo + 1
		var vcount: int = nrows * cols

		var verts := PackedVector3Array()
		var norms := PackedVector3Array()
		var uvs := PackedVector2Array()
		verts.resize(vcount)
		norms.resize(vcount)
		uvs.resize(vcount)

		var k: int = 0
		for i in range(lo, hi + 1):
			var r: float = prof.r[i]
			var yy: float = prof.y[i] + y_offset
			var nr: float = prof.nr[i]
			var ny: float = prof.ny[i]
			var vv: float = prof.v[i]
			for j in cols:
				var c: float = cosv[j]
				var s: float = sinv[j]
				verts[k] = Vector3(r * c, yy, r * s)
				norms[k] = Vector3(nr * c, ny, nr * s)
				uvs[k] = Vector2(float(j) / float(radial), vv)
				k += 1

		# Godot front faces are CLOCKWISE: (i,j) -> (i+1,j) -> (i,j+1) is the
		# outward-facing order for this parameterisation. Rings that collapse to
		# the axis, and the zero-height quads at a crease, are skipped.
		var idx := PackedInt32Array()
		idx.resize((nrows - 1) * radial * 6)
		var w: int = 0
		for i in nrows - 1:
			var ra: float = prof.r[lo + i]
			var rb: float = prof.r[lo + i + 1]
			var ya: float = prof.y[lo + i]
			var yb: float = prof.y[lo + i + 1]
			if absf(ra - rb) < 1e-9 and absf(ya - yb) < 1e-9:
				continue  # crease duplicate: zero-area band
			var row0: int = i * cols
			var row1: int = row0 + cols
			var degenerate_a: bool = ra < 1e-9
			var degenerate_b: bool = rb < 1e-9
			for j in radial:
				var v00: int = row0 + j
				var v01: int = row0 + j + 1
				var v10: int = row1 + j
				var v11: int = row1 + j + 1
				if not degenerate_a:
					idx[w] = v00; idx[w + 1] = v11; idx[w + 2] = v01
					w += 3
				if not degenerate_b:
					idx[w] = v00; idx[w + 1] = v10; idx[w + 2] = v11
					w += 3
		idx.resize(w)
		if w == 0:
			continue

		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = norms
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_INDEX] = idx
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# ---------------------------------------------------------------------------
# Mass properties — the proof that this lathe and Track A integrate one solid
# ---------------------------------------------------------------------------

## Volume, density and the moments of inertia of the solid this builder lathes,
## computed from the traced polyline itself rather than from a parallel formula.
##
## For a region A in the (r, y) half-plane revolved about +Y, Green's theorem
## turns every moment into a boundary integral:
##
##     integral_A r^m y^n dA  =  contour_integral  r^(m+1) y^n / (m+1)  dy
##
## so V = 2pi*I(1,0), I_zz/rho = 2pi*I(3,0), and the axial first and second
## moments are 2pi*I(1,1) and 2pi*I(1,2). Each edge is integrated with 4-point
## Gauss-Legendre, exact to degree 7 where the integrands reach degree 6. The
## naming matches `tools/aero/geometry.py::_mass_integrals` so the two can be
## compared line by line.
static func integrate_inertia(geometry: Dictionary,
		samples: int = DEFAULT_PROFILE_SAMPLES) -> Dictionary:
	var norm := normalize_geometry(geometry)
	var prof := trace_profile(norm, samples)
	var n := prof.size()
	var mass: float = float(norm["mass_kg"])

	var i10: float = _contour_moment(prof, 1, 0)
	var sign: float = 1.0 if i10 >= 0.0 else -1.0
	var vol: float = TAU * i10 * sign
	if vol <= 1e-12:
		return {"volume_m3": 0.0, "density_kg_m3": 0.0, "i_zz": 0.0, "i_xy": 0.0,
			"com_y_m": 0.0, "area_m2": float(norm["area_m2"]),
			"height_m": float(norm["height_m"])}
	var i_zz_v: float = TAU * _contour_moment(prof, 3, 0) * sign
	var z_first: float = TAU * _contour_moment(prof, 1, 1) * sign
	var z_second: float = TAU * _contour_moment(prof, 1, 2) * sign

	var rho: float = mass / vol
	var z_cm: float = z_first / vol
	var i_zz: float = mass * i_zz_v / vol
	# Perpendicular-axis theorem for a solid of revolution, about the centre of
	# mass: I_xx = I_yy = I_zz/2 + integral(z'^2 dm).
	var i_xy: float = 0.5 * i_zz + (rho * z_second - mass * z_cm * z_cm)
	return {
		"volume_m3": vol,
		"density_kg_m3": rho,
		"i_zz": i_zz,
		"i_xy": i_xy,
		"com_y_m": z_cm,
		"area_m2": float(norm["area_m2"]),
		"height_m": float(norm["height_m"]),
		"parting_ratio": float(norm["parting_ratio"]),
	}


## 4-point Gauss-Legendre nodes/weights on [0, 1].
const _GL_T := [0.0694318442029737, 0.3300094782075719,
	0.6699905217924281, 0.9305681557970263]
const _GL_W := [0.1739274225687269, 0.3260725774312731,
	0.3260725774312731, 0.1739274225687269]


static func _contour_moment(prof: Profile, m: int, n: int) -> float:
	var count := prof.size()
	if count < 3:
		return 0.0
	var total: float = 0.0
	var inv_m: float = 1.0 / float(m + 1)
	for i in count:
		var j: int = (i + 1) % count   # closes the loop along the r = 0 axis
		var r0: float = prof.r[i]
		var y0: float = prof.y[i]
		var dr: float = prof.r[j] - r0
		var dy: float = prof.y[j] - y0
		if absf(dy) < 1e-15:
			continue                    # dy = 0 contributes nothing
		var acc: float = 0.0
		for k in 4:
			var t: float = _GL_T[k]
			acc += _GL_W[k] * pow(r0 + dr * t, float(m + 1)) * pow(y0 + dy * t, float(n))
		total += acc * dy * inv_m
	return total


## Compare this lathe's mass properties against the `derived` block Track A
## ships in `discs.json`. Returns per-field relative errors; `ok` is true when
## every one is within `tol`. This is the check that keeps the rendered disc and
## the simulated disc the same object.
static func verify_against(entry: Dictionary, tol: float = 0.02) -> Dictionary:
	var geom: Dictionary = entry.get("geometry", entry)
	var want: Dictionary = entry.get("derived", {})
	var got := integrate_inertia(geom, 120)
	var out := {"id": entry.get("id", "?"), "ok": true, "errors": {}, "got": got}
	var pairs := {"I_zz": "i_zz", "I_xy": "i_xy", "area_m2": "area_m2",
		"height_m": "height_m", "density_kg_m3": "density_kg_m3",
		"parting_ratio": "parting_ratio"}
	for key in pairs:
		if not want.has(key):
			continue
		var expected: float = float(want[key])
		var actual: float = float(got[pairs[key]])
		var err: float = absf(actual - expected) / maxf(absf(expected), 1e-12)
		out["errors"][key] = err
		if err > tol:
			out["ok"] = false
	return out


# ---------------------------------------------------------------------------
# Materials
# ---------------------------------------------------------------------------

## Flight-plate top. Carries the procedural stamp so rotation is visible in
## flight; without it a solid of revolution looks motionless no matter how fast
## it spins.
static func make_plate_material(base: Color, accent: Color = Color(0, 0, 0, 0)) -> StandardMaterial3D:
	if accent.a <= 0.0:
		accent = base.lightened(0.35)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color.WHITE
	m.albedo_texture = make_plate_texture(base, accent)
	m.roughness = 0.42
	m.metallic = 0.0
	m.metallic_specular = 0.45
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return m


## Rim, shoulder and underside: plain plastic, no pattern.
static func make_body_material(base: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = base
	m.roughness = 0.38
	m.metallic = 0.0
	m.metallic_specular = 0.5
	return m


## Procedural stamp: `wedges` spokes plus two concentric bands, drawn straight
## into the plate's (u = angle, v = radius) UV space. No texture assets.
static func make_plate_texture(base: Color, accent: Color, wedges: int = 6,
		width: int = 128, height: int = 64) -> ImageTexture:
	var img := Image.create_empty(width, height, true, Image.FORMAT_RGB8)
	var dark: Color = base.darkened(0.28)
	for py in height:
		var v: float = (float(py) + 0.5) / float(height)   # 0 centre -> 1 rim
		for px in width:
			var u: float = (float(px) + 0.5) / float(width)
			var c: Color = base
			# Spokes, faded out at the hub so they converge cleanly.
			var w: float = fposmod(u * float(wedges), 1.0)
			var spoke: float = smoothstep(0.02, 0.10, w) * (1.0 - smoothstep(0.44, 0.50, w))
			c = c.lerp(accent, spoke * clampf((v - 0.16) / 0.20, 0.0, 1.0) * 0.85)
			# Two concentric bands.
			var ring_a: float = 1.0 - smoothstep(0.0, 0.035, absf(v - 0.60))
			var ring_b: float = 1.0 - smoothstep(0.0, 0.028, absf(v - 0.93))
			c = c.lerp(dark, maxf(ring_a, ring_b) * 0.7)
			# Hub.
			c = c.lerp(dark, 1.0 - smoothstep(0.10, 0.15, v))
			# Very slight radial shading so the dome reads even when unlit.
			c = c.darkened(0.06 * v)
			img.set_pixel(px, py, c)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


# ---------------------------------------------------------------------------
# Self-check
# ---------------------------------------------------------------------------

## Confirms the emitted winding agrees with the engine's own idea of a front
## face, by comparing analytic normals against `SurfaceTool.generate_normals()`.
## Returns a report dictionary; `ok` is what a headless test should assert.
static func verify_winding() -> Dictionary:
	var mesh := build_mesh(DEFAULT_GEOMETRY, 24, 28, false)
	var report := {"ok": false, "surfaces": mesh.get_surface_count(), "agree": 0, "total": 0}
	var agree: int = 0
	var total: int = 0
	for s in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(s)
		var st := SurfaceTool.new()
		st.create_from(mesh, s)
		var mine: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		st.deindex()
		var stripped := SurfaceTool.new()
		stripped.begin(Mesh.PRIMITIVE_TRIANGLES)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for i in idx.size():
			stripped.add_vertex(verts[idx[i]])
		stripped.generate_normals()
		var gen: Array = stripped.commit_to_arrays()
		var gnorm: PackedVector3Array = gen[Mesh.ARRAY_NORMAL]
		for i in idx.size():
			var a: Vector3 = mine[idx[i]]
			var b: Vector3 = gnorm[i]
			if b.length_squared() < 1e-9:
				continue
			total += 1
			if a.dot(b) > 0.0:
				agree += 1
	report["agree"] = agree
	report["total"] = total
	report["ok"] = total > 0 and float(agree) / float(total) > 0.97
	return report


static func _dicts_match(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for k in a:
		if not b.has(k):
			return false
		if absf(float(a[k]) - float(b[k])) > 1e-9:
			return false
	return true

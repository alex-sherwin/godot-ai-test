class_name WindVisualizer
extends Node3D

## Honest wind: everything here is driven by the actual `wind` vector handed to
## the physics core, so if the streamers drift downrange the disc really is
## getting a tailwind. Three readouts, because one is not enough:
##
##   * drifting streamers through the flight volume — direction, and through
##     their speed, length and density, magnitude
##   * a windsock by the tee, which droops toward vertical as the wind drops to
##     nothing rather than pretending there is a breeze
##   * a ground arrow and a numeric label, for the cases where you need the
##     actual number
##
## The sock, the arrow and the label are the *instruments*; set
## `instruments = false` before adding the node and you get the streamers on
## their own. That is what puzzle mode wants: one of these per room, each
## carrying that room's own air, so the crosswind you are about to throw into is
## visible THROUGH THE PORTAL before you throw. A windsock in every chamber
## would be eight draw calls of clutter saying what the conditions panel already
## says in words.
##
## CPUParticles3D rather than GPUParticles3D: CPU particles are a MultiMesh
## under the hood and are guaranteed in the Compatibility renderer. One draw
## call per volume, whatever the particle count.
##
## ---------------------------------------------------------------------------
## THE BUG THIS SHAPE EXISTS TO PREVENT
## ---------------------------------------------------------------------------
## `emitting = false` does not unspawn what `preprocess` already seeded, and in
## dead air a seeded particle has zero velocity — so the first version of this
## hung ~15 motionless pale sticks in an 84 x 18 x 210 m box centred 9 m up and
## they read, correctly, as a rendering defect: white streaks floating in the
## sky above the treeline, attached to nothing. Two structural fixes, not one
## patch:
##
##   1. THERE IS NO CRAWLING STATE, NEVER MIND A STILL ONE. Below
##      `STREAMER_MIN_WIND` — a whole metre a second, not an epsilon, because a
##      streamer moving at 0.2 m/s is the same defect at a slower frame rate —
##      the streamers either switch to a slow ambient drift
##      (`ambient_when_calm`, what the outdoor Flight Lab uses; real open air is
##      never perfectly still) or are not emitted at all (what a sealed puzzle
##      chamber uses, because a calm room next to a windy one is the whole point
##      of the level and shimmer in both would blunt it).
##   2. THE VOLUME IS BOUNDED AND ANCHORED. The emission box is oriented to the
##      wind and shortened downwind by exactly the distance a particle travels
##      in its lifetime, so the swept volume is the configured box and not one
##      box-length past it. The default box hugs the ground along the flight
##      corridor — under the treeline, where the wind is something the player is
##      throwing through — rather than sitting in empty sky.

## m/s below which the instruments say "calm" and the ground arrow hides.
const MIN_WIND := 0.15
## m/s below which the STREAMERS have nothing to say. Higher than `MIN_WIND` on
## purpose and this is the second half of the fix: a streamer given a true
## 0.2 m/s wind crosses barely one metre in its whole lifetime, which is a
## motionless white stick with a technically non-zero velocity — the same defect
## wearing a disguise. Under a metre a second there is no motion to draw, so we
## draw still air instead, and the instruments still report the number.
const STREAMER_MIN_WIND := 1.0
const SOCK_POS := Vector3(-15.0, 0.0, -8.0)

## Flight Lab default volume: the throwing corridor, starting at the tee and
## running past the far gate, from just above the grass to a little over the
## canopy. Deliberately NOT the whole 1.5 km ground plane and not the full 18 m
## of sky the first version used — density is finite, so a volume four times too
## big just puts every streamer 150 m away where it is three pixels long. Trees
## top out near 12 m and the lane is 44 m wide inside a treeline at +/-50 m, so
## every streamer here has world geometry behind it.
const DEFAULT_VOLUME_CENTER := Vector3(0.0, 3.7, -52.0)
const DEFAULT_VOLUME_EXTENTS := Vector3(26.0, 3.3, 58.0)

## Streamers fade out between these distances from the camera. Perspective is
## why this is needed and not a nicety: a box of uniform density puts most of
## its contents far away, where every streak is a two-pixel scratch ABOVE the
## horizon with nothing but sky behind it — which is exactly the "floating,
## attached to nothing" reading the first version earned. Fading the far half
## out leaves the streamers that overlap grass, lane markings and treeline, and
## those are the ones that read as air moving through the range.
##
## This is an OUTDOOR fix, and puzzle mode turns it off (`configure_fade(0, 0)`).
## A room's streamers always have one of its own walls behind them, so they can
## never read as sky — and the level-overview camera sits a level-radius back,
## which is past any distance sensible here: the fade would delete exactly the
## view that is meant to show you all three rooms' air at once.
const FADE_START_M := 62.0
const FADE_END_M := 155.0

## Lifetime bounds, seconds. The upper bound is also how long a direction change
## takes to flush through, which is why it is short: dragging the wind slider
## has to look like the air turning, not like the old air refusing to leave.
const MIN_LIFETIME := 1.2
const MAX_LIFETIME := 6.0

## Per-particle spawn-speed jitter, so a bank of streamers does not march in
## lockstep. The MAX end is what the volume is sized against — see the sweep
## calculation in `_apply_streamers`.
const VELOCITY_JITTER_MIN := 0.86
const VELOCITY_JITTER_MAX := 1.16

## Streamer count at 6 m/s in a corridor-sized volume, and how weakly it follows
## the volume. Sub-linear on purpose: a 220,000 m³ hall does not want four times
## the streamers of a 60,000 m³ one, it wants a bit more, because what the eye
## reads is streaks per unit of SCREEN, not per cubic metre. One draw call
## either way — the pool size is a look decision, not a budget one.
const AMOUNT_AT_6MPS := 180.0
const REFERENCE_VOLUME := 60000.0
const VOLUME_EXPONENT := 0.4
const MIN_AMOUNT := 70
const MAX_AMOUNT := 300

## Calm-air drift: slow, short, dim, and biased upward so it reads as air
## standing still rather than as a light breeze. Only used when
## `ambient_when_calm` is on.
const AMBIENT_SPEED := 0.85
const AMBIENT_SPREAD := 62.0
const AMBIENT_LENGTH := 1.2
const AMBIENT_ALPHA := 0.17

## Build the sock, the ground arrow and the numeric label. Set before the node
## enters the tree.
var instruments: bool = true
## Show a slow ambient drift instead of nothing when the wind is below
## `STREAMER_MIN_WIND`. Outdoors: yes. Sealed room: no.
var ambient_when_calm: bool = true

var _particles: CPUParticles3D = null
var _streak: BoxMesh = null
var _streak_mat: StandardMaterial3D = null
var _ramp: Gradient = null
var _sock_pivot: Node3D = null
var _arrow: Node3D = null
var _label: Label3D = null

var _wind := Vector3.ZERO
var _drift_hint := Vector3(0.0, 0.0, -1.0)
var _volume_center: Vector3 = DEFAULT_VOLUME_CENTER
var _volume_extents: Vector3 = DEFAULT_VOLUME_EXTENTS
var _fade_start: float = FADE_START_M
var _fade_end: float = FADE_END_M
## `amount` reallocates the particle pool, so it is quantised: a wind slider
## drag must not re-seed the volume sixty times a second.
var _amount_bucket: int = -1


func _ready() -> void:
	_build_particles()
	if instruments:
		_build_sock()
	set_wind(_wind)


## The box the streamers live in, in this node's own space. Puzzle mode passes
## the room's interior; the Flight Lab keeps the default corridor. Safe to call
## before or after the node enters the tree.
func configure_volume(center: Vector3, extents: Vector3) -> void:
	_volume_center = center
	var e: Vector3 = extents.abs()
	_volume_extents = Vector3(maxf(e.x, 0.5), maxf(e.y, 0.5), maxf(e.z, 0.5))
	_amount_bucket = -1
	if _particles != null:
		set_wind(_wind)


## Distance fade, metres from the camera. Pass `(0, 0)` to switch it off — see
## `FADE_START_M`.
func configure_fade(start_m: float, end_m: float) -> void:
	_fade_start = start_m
	_fade_end = end_m
	if _streak_mat != null:
		_apply_fade()


func _apply_fade() -> void:
	if _fade_start <= 0.0 or _fade_end <= _fade_start:
		_streak_mat.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_DISABLED
		return
	# Godot reverses the fade when max < min: fully opaque up to the start
	# distance, gone by the end distance.
	_streak_mat.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_PIXEL_ALPHA
	_streak_mat.distance_fade_max_distance = _fade_start
	_streak_mat.distance_fade_min_distance = _fade_end


func set_wind(w: Vector3) -> void:
	_wind = w
	var speed: float = w.length()
	var still: bool = speed < STREAMER_MIN_WIND
	var dir: Vector3 = _drift_hint if speed < MIN_WIND else w / speed
	if speed >= MIN_WIND:
		_drift_hint = dir

	_apply_streamers(dir, speed, still)
	_apply_instruments(dir, speed, speed < MIN_WIND, w)


func get_wind() -> Vector3:
	return _wind


# ============================================================== streamers ===

## One code path for wind and for calm air; only the numbers differ, and one of
## those numbers is never zero. See the class comment.
func _apply_streamers(dir: Vector3, speed: float, still: bool) -> void:
	if _particles == null:
		return
	if still and not ambient_when_calm:
		# Nothing to show and nothing left showing: `emitting = false` alone
		# would leave the preprocessed batch on screen for a full lifetime, and
		# in dead air that batch does not move.
		_particles.emitting = false
		_particles.visible = false
		_amount_bucket = -1
		return

	var flow: Vector3 = dir
	var flow_speed: float = speed
	var length: float = 0.0
	var alpha: float = 0.0
	var spread: float = 0.0
	var amount: int = 0
	var ctr: Vector3 = _volume_center
	var ext: Vector3 = _volume_extents

	if still:
		# Rising, wandering, and slow enough that the label's "calm" is not
		# contradicted — but never still. Confined to the lower part of the
		# volume as well: a mote you can see against the grass reads as air, and
		# the same mote against bare sky reads as the defect this replaced.
		flow = (dir * 0.55 + Vector3.UP).normalized()
		flow_speed = AMBIENT_SPEED
		length = AMBIENT_LENGTH
		alpha = AMBIENT_ALPHA
		spread = AMBIENT_SPREAD
		amount = clampi(int(_pool(1.0) * 0.45), 30, 110)
		ctr = _volume_center - Vector3(0.0, _volume_extents.y * 0.35, 0.0)
		ext = Vector3(_volume_extents.x, _volume_extents.y * 0.55, _volume_extents.z)
	else:
		# Longer, denser, brighter and faster with the wind, so 12 m/s cannot be
		# mistaken for 3 m/s in a still frame OR in motion.
		length = clampf(1.4 + speed * 0.62, 2.0, 9.0)
		alpha = clampf(0.20 + speed * 0.029, 0.20, 0.55)
		# Nearly parallel. Steady wind IS parallel, and every degree of spread is
		# also lateral drift out through a room's side wall over a 50 m sweep.
		spread = 2.0
		amount = clampi(int(_pool(clampf(0.60 + speed * 0.068, 0.60, 1.55))),
			MIN_AMOUNT, MAX_AMOUNT)

	# ---- volume, oriented to the flow -------------------------------------
	var frame: Basis = _frame_for(flow)
	var f: Vector3 = frame.z
	var ed: float = ext.dot(f.abs())
	var eu: float = ext.dot(frame.x.abs())
	var ev: float = ext.dot(frame.y.abs())

	# Sized off the FASTEST particle, not the average: the spawn velocity spread
	# is +/-15%, and budgeting for the mean would let the quick sixth of the pool
	# out through the downwind wall.
	var vmax: float = maxf(flow_speed * VELOCITY_JITTER_MAX, 0.05)
	var life: float = clampf(2.0 * ed / vmax, MIN_LIFETIME, MAX_LIFETIME)
	# Travel is capped at the volume's own depth, and the emission slab is
	# shortened by half of it at each end, so the swept region is exactly the
	# configured box. This is what keeps room streamers inside their room and
	# range streamers off the skyline.
	var travel: float = minf(vmax * life, 2.0 * ed)
	life = maxf(travel / vmax, 0.2)
	var slab: float = maxf(ed - travel * 0.5, ed * 0.08)

	_particles.transform = Transform3D(frame, ctr - f * travel * 0.5)
	_particles.emission_box_extents = Vector3(eu, ev, slab)
	_particles.direction = Vector3(0.0, 0.0, 1.0)   # local +Z is the flow
	_particles.spread = spread
	_particles.initial_velocity_min = flow_speed * VELOCITY_JITTER_MIN
	_particles.initial_velocity_max = flow_speed * VELOCITY_JITTER_MAX
	_particles.lifetime = life
	_particles.preprocess = life

	if _streak != null:
		_streak.size = Vector3(0.105, length, 0.105)
	if _streak_mat != null:
		_streak_mat.albedo_color = Color(0.84, 0.92, 1.0, alpha)

	var was_visible: bool = _particles.visible
	_particles.visible = true
	# `amount` reallocates and re-seeds, so only touch it when the bucket moves.
	var bucket: int = amount / 12
	if bucket != _amount_bucket:
		_amount_bucket = bucket
		_particles.amount = amount
		_particles.restart()
	elif not was_visible or not _particles.emitting:
		_particles.restart()
	_particles.emitting = true


func _pool(speed_factor: float) -> float:
	var v: float = 8.0 * _volume_extents.x * _volume_extents.y * _volume_extents.z
	var vf: float = clampf(pow(v / REFERENCE_VOLUME, VOLUME_EXPONENT), 0.55, 1.75)
	return AMOUNT_AT_6MPS * speed_factor * vf


## Right-handed frame whose +Z is `d`. Matches the convention the portal code
## uses for the same job, and never degenerates: straight up gets the fallback.
static func _frame_for(d: Vector3) -> Basis:
	var f: Vector3 = d.normalized()
	if f.length_squared() < 0.5:
		f = Vector3(0.0, 0.0, -1.0)
	var hint: Vector3 = Vector3.UP if absf(f.y) < 0.95 else Vector3.RIGHT
	var r: Vector3 = hint.cross(f).normalized()
	var u: Vector3 = f.cross(r).normalized()
	return Basis(r, u, f)


# ============================================================ instruments ===

func _apply_instruments(dir: Vector3, speed: float, calm: bool, w: Vector3) -> void:
	if _sock_pivot != null:
		# A real sock hangs under its own weight and only lifts as the wind
		# picks up; ~5 m/s is roughly full extension.
		var droop: Vector3 = dir * speed + Vector3(0.0, -4.0, 0.0)
		if calm:
			droop = Vector3(0.0, -4.0, 0.0)
		_sock_pivot.quaternion = Quaternion(Vector3.UP, droop.normalized())

	if _arrow != null:
		_arrow.visible = not calm
		if not calm:
			var flat := Vector3(dir.x, 0.0, dir.z)
			if flat.length_squared() < 1e-6:
				flat = Vector3(0.0, 0.0, -1.0)
			_arrow.quaternion = Quaternion(Vector3.UP, flat.normalized())

	if _label != null:
		if calm:
			_label.text = "WIND  calm"
		else:
			# Downrange / crosswind split is what a thrower actually wants: -Z is
			# downrange, +X is to the thrower's right (CONTRACT §1).
			var along: float = -w.z
			var cross: float = w.x
			_label.text = "WIND %.1f m/s\n%+.1f down-range  %+.1f cross" % [speed, along, cross]


# ---------------------------------------------------------------------------

func _build_particles() -> void:
	var p := CPUParticles3D.new()
	p.name = "Streamers"
	p.amount = MIN_AMOUNT
	p.lifetime = 4.0
	p.local_coords = false
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.gravity = Vector3.ZERO
	p.damping_min = 0.0
	p.damping_max = 0.0
	p.particle_flag_align_y = true   # streaks lie along their own velocity
	p.scale_amount_min = 0.75
	p.scale_amount_max = 1.30
	# Layer 1 is the portal renderer's LAYER_WORLD: streamers must be visible in
	# a portal view, because seeing the room's air through the aperture is the
	# entire point of building them per room.
	p.layers = 1
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	_streak = BoxMesh.new()
	_streak.size = Vector3(0.105, 3.0, 0.105)
	_streak_mat = StandardMaterial3D.new()
	_streak_mat.albedo_color = Color(0.84, 0.92, 1.0, 0.30)
	_streak_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_streak_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_streak_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_streak_mat.disable_receive_shadows = true
	# The per-particle colour rides in the MultiMesh colour array; without this
	# the lifetime fade below is simply discarded and every streak pops in and
	# out at full strength.
	_streak_mat.vertex_color_use_as_albedo = true
	_apply_fade()
	_streak.material = _streak_mat
	p.mesh = _streak

	# Fade in and out at the ends of the lifetime, so a streamer never appears
	# or vanishes as a hard edge — that hard edge is what made the old ones read
	# as debris rather than as air.
	_ramp = Gradient.new()
	_ramp.set_color(0, Color(1, 1, 1, 0))
	_ramp.set_color(1, Color(1, 1, 1, 0))
	_ramp.add_point(0.18, Color(1, 1, 1, 1))
	_ramp.add_point(0.82, Color(1, 1, 1, 1))
	p.color_ramp = _ramp

	add_child(p)
	_particles = p


func _build_sock() -> void:
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.80, 0.82, 0.85)
	metal.roughness = 0.6

	var pole := MeshInstance3D.new()
	var pm := CylinderMesh.new()
	pm.top_radius = 0.05
	pm.bottom_radius = 0.07
	pm.height = 4.2
	pm.radial_segments = 8
	pole.mesh = pm
	pole.position = SOCK_POS + Vector3(0.0, 2.1, 0.0)
	pole.material_override = metal
	add_child(pole)

	var pivot := Node3D.new()
	pivot.position = SOCK_POS + Vector3(0.0, 4.2, 0.0)
	add_child(pivot)
	_sock_pivot = pivot

	# Two bands so rotation is visible, cone opening upwind.
	var sock_mat_a := StandardMaterial3D.new()
	sock_mat_a.albedo_color = Color(0.95, 0.42, 0.18)
	sock_mat_a.cull_mode = BaseMaterial3D.CULL_DISABLED
	sock_mat_a.roughness = 0.85
	var sock_mat_b := StandardMaterial3D.new()
	sock_mat_b.albedo_color = Color(0.96, 0.95, 0.92)
	sock_mat_b.cull_mode = BaseMaterial3D.CULL_DISABLED
	sock_mat_b.roughness = 0.85

	var seg_len := 0.55
	for i in 4:
		var seg := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.bottom_radius = lerpf(0.34, 0.20, float(i) / 4.0)
		cm.top_radius = lerpf(0.34, 0.20, float(i + 1) / 4.0)
		cm.height = seg_len
		cm.radial_segments = 10
		cm.rings = 1
		seg.mesh = cm
		seg.position = Vector3(0.0, seg_len * (float(i) + 0.5), 0.0)
		seg.material_override = sock_mat_a if i % 2 == 0 else sock_mat_b
		pivot.add_child(seg)

	# Ground arrow + numeric readout beside the sock.
	var arrow := Node3D.new()
	arrow.position = SOCK_POS + Vector3(0.0, 0.06, 0.0)
	add_child(arrow)
	_arrow = arrow

	var arrow_mat := StandardMaterial3D.new()
	arrow_mat.albedo_color = Color(0.98, 0.86, 0.35, 0.9)
	arrow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	arrow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	arrow_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var shaft := MeshInstance3D.new()
	var sb := BoxMesh.new()
	sb.size = Vector3(0.30, 0.02, 1.0)
	shaft.mesh = sb
	# The arrow node's +Y is rotated onto the wind direction, so the mesh must
	# extend along +Y before rotation.
	shaft.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	shaft.position = Vector3(0.0, 0.5, 0.0)
	shaft.material_override = arrow_mat
	arrow.add_child(shaft)

	var head := MeshInstance3D.new()
	var hm := CylinderMesh.new()
	hm.top_radius = 0.0
	hm.bottom_radius = 0.42
	hm.height = 0.9
	hm.radial_segments = 4
	hm.rings = 1
	head.mesh = hm
	head.position = Vector3(0.0, 1.45, 0.0)
	head.material_override = arrow_mat
	arrow.add_child(head)

	var l := Label3D.new()
	l.position = SOCK_POS + Vector3(0.0, 5.4, 0.0)
	l.modulate = Color(0.98, 0.90, 0.55)
	l.outline_modulate = Color(0.02, 0.04, 0.07, 0.9)
	l.outline_size = 12
	l.font_size = 64
	l.pixel_size = 0.55 / 64.0
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.double_sided = true
	add_child(l)
	_label = l

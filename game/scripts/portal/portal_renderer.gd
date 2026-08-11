class_name PortalRenderer
extends Node3D

## Draws at most `SLOTS` portals per frame, at depth 1, on GL Compatibility.
##
## ---------------------------------------------------------------------------
## What this does NOT do, and why
## ---------------------------------------------------------------------------
## **No oblique near-plane clipping.** Godot has no way to express it: there is
## no projection-matrix setter on Camera3D or RenderingServer, `set_frustum()`
## is an off-axis shear and cannot represent a sheared near plane, and the three
## PRs that would have added it are closed or blocked. `PROJECTION_MATRIX` is
## writable from a `vertex()` shader and does reach the GLES3 code generator,
## but Godot's near plane is `z = +w` rather than the textbook `z = -w`, so
## Lengyel's formula needs a sign adaptation that cannot be verified without a
## GPU. Shipping an unverifiable projection-matrix hack into a browser-only
## renderer is exactly the class of thing this repository has been burned by.
##
## Instead, the three-part fallback of PORTAL_CONTRACT §8:
##
##   (a) a dynamic PERPENDICULAR near plane, fitted so that no corner of the
##       exit aperture is ever clipped (`_fit_near`);
##   (b) a world-space plane `discard` on the objects room construction cannot
##       help with — the disc and its ghost (`portal_clip.gdshader`);
##   (c) rooms built so the problem mostly does not arise: single-sided walls,
##       so the wall the exit portal is set into is invisible from the outside,
##       where the portal camera sits (`PortalRoom`).
##
## (c) is doing most of the work. (a) removes anything standing in the room
## between the exit portal and the camera. The residue — a thin wedge near the
## aperture edge at grazing angles — is what an oblique plane would have fixed
## and is visible only when the player's eye is nearly in the portal's plane.
##
## ---------------------------------------------------------------------------
## Budget
## ---------------------------------------------------------------------------
## The sandbox baseline is ~190 draw calls; WebGL2 puts every one of them
## through the browser's validation layer, so the working ceiling is ~500-800.
## Two portals is the budget. `SLOTS` is not a tuning knob to raise casually.
##
## ---------------------------------------------------------------------------
## Pooling
## ---------------------------------------------------------------------------
## SubViewports are allocated once, in `_ready`, and never again. Idle cost is
## texture memory only (~2 MiB per slot at 1024x576 RGBA8). The reason is not
## allocation cost: it is that a cold shader compile in a browser is a
## multi-hundred-millisecond freeze, and one that happens the first time the
## player looks at a portal is a freeze at the worst possible moment. Every slot
## is warm-rendered during `warm_frames`, which the loading screen covers.

const SLOTS := 2

## Fraction of the main viewport's resolution each portal renders at. The portal
## shader samples by SCREEN_UV, so this is a free quality/cost dial with no UV
## maths attached.
const RESOLUTION_SCALE := 0.75
const MAX_TEXTURE_HEIGHT := 720

## Nothing beyond this is worth a whole render pass.
##
## A VAR, not a const, and set by the scene that owns the renderer. 110 m is
## right for the hand-authored test pair, whose rooms are 30 m long; the puzzle
## levels are up to 290 m across and their overview camera sits 250 m back, at
## which range a 36 m portal is still 8 degrees of view and reads as a dead grey
## rectangle if it is culled. The `SLOTS` cap is what bounds the cost, so
## raising this buys the far view at no extra worst case.
@export var max_render_distance: float = 110.0
## Never let the fitted near plane collapse; 24-bit depth with no reverse-Z
## (Compatibility) does not tolerate a near of 1e-4.
const MIN_NEAR := 0.05
## Pull the fitted plane back by this much so float error at the aperture rim
## cannot nibble a pixel off the edge of the view.
const NEAR_SLACK := 0.02

## Frames of forced full-rate rendering after `_ready`. Compiles the portal
## surface shader, the clip shader and every room material while the loading
## screen is still up.
@export var warm_frames: int = 8
@export var enabled: bool = true

var main_camera: Camera3D = null
## Per-room Environment, indexed by `Portal.room_index`. A portal camera renders
## the destination room's air, not the source room's — different fog and ambient
## is what makes two boxes read as two places.
var room_environments: Array[Environment] = []

var portals: Array[Portal] = []

var _viewports: Array[SubViewport] = []
var _cameras: Array[Camera3D] = []
var _slot_portal: Array[Portal] = []
var _warm_left: int = 0
var _last_size := Vector2i.ZERO
var _active_count: int = 0
var _focus_point := Vector3.INF
var _focus_active: bool = false


func _ready() -> void:
	for i in SLOTS:
		var vp := SubViewport.new()
		vp.name = "PortalViewport%d" % i
		# MEASURED, and a trap: SubViewport.msaa_3d defaults to DISABLED and
		# does NOT inherit the project's `anti_aliasing/quality/msaa_3d`. Left
		# alone you get a jagged portal inside a smooth frame, which reads as a
		# rendering bug rather than as a portal.
		vp.msaa_3d = Viewport.MSAA_4X
		# The portal must render the same world, not a fresh empty one.
		vp.own_world_3d = false
		vp.transparent_bg = false
		vp.handle_input_locally = false
		vp.audio_listener_enable_3d = false
		vp.positional_shadow_atlas_size = 1024
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		vp.disable_3d = true
		vp.size = Vector2i(512, 288)
		add_child(vp)

		var cam := Camera3D.new()
		cam.name = "PortalCamera%d" % i
		cam.current = true
		# A portal camera must never see a live aperture, or a portal renders
		# itself; it sees the flat stand-in on layer 3 instead.
		cam.cull_mask = Portal.LAYER_WORLD | Portal.LAYER_PORTAL_FLAT
		vp.add_child(cam)

		_viewports.append(vp)
		_cameras.append(cam)
		_slot_portal.append(null)

	_warm_left = warm_frames


## Wire the scene's own camera in. Also fixes its cull mask: the main camera
## must see live apertures (layer 2) and must NOT see the flat stand-ins
## (layer 3).
func attach_main_camera(cam: Camera3D) -> void:
	main_camera = cam
	if cam != null:
		cam.cull_mask = (cam.cull_mask | Portal.LAYER_PORTAL_LIVE) \
			& ~Portal.LAYER_PORTAL_FLAT


func register(p: Portal) -> void:
	if p != null and not portals.has(p):
		portals.append(p)


func clear_portals() -> void:
	for i in SLOTS:
		_release_slot(i)
	portals.clear()


## Gameplay hint: where the disc is. Portals near it are rendered in preference
## to portals that merely happen to be on screen, and the update mode stays
## ALWAYS while it is approaching. `UPDATE_WHEN_VISIBLE` is the obvious choice
## here and is the wrong one — it has a restart latency that shows up as a
## one-frame flicker exactly as the disc arrives.
func set_focus(point: Vector3) -> void:
	_focus_point = point
	_focus_active = true


func clear_focus() -> void:
	_focus_active = false


func is_warm() -> bool:
	return _warm_left <= 0


func active_portal_count() -> int:
	return _active_count


func debug_stats() -> Dictionary:
	return {
		"active": _active_count,
		"registered": portals.size(),
		"draw_calls": int(Performance.get_monitor(
			Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"primitives": int(Performance.get_monitor(
			Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"viewport": _viewports[0].size if not _viewports.is_empty() else Vector2i.ZERO,
		"warm": is_warm(),
	}


# ---------------------------------------------------------------------------
# Per-frame
# ---------------------------------------------------------------------------

func _process(_delta: float) -> void:
	if not enabled or main_camera == null:
		# Disabling must actually stop the work, not just stop choosing: a slot
		# left in UPDATE_ALWAYS keeps rendering a full scene pass nobody sees.
		if _active_count != 0:
			for i in SLOTS:
				_release_slot(i)
			_active_count = 0
		return
	_resize_if_needed()

	var chosen := _select()
	_assign_slots(chosen)

	for i in SLOTS:
		var p: Portal = _slot_portal[i]
		if p == null:
			continue
		_drive_slot(i, p)

	_active_count = chosen.size()
	if _warm_left > 0:
		_warm_left -= 1


## SubViewport aspect must match the main viewport's exactly, or the SCREEN_UV
## lookup shears. Height is scaled and clamped; width is then derived from the
## real aspect rather than scaled independently.
func _resize_if_needed() -> void:
	var size := get_viewport().get_visible_rect().size
	var isize := Vector2i(maxi(int(size.x), 2), maxi(int(size.y), 2))
	if isize == _last_size:
		return
	_last_size = isize
	var h := clampi(int(round(float(isize.y) * RESOLUTION_SCALE)), 64, MAX_TEXTURE_HEIGHT)
	var w := maxi(64, int(round(float(isize.x) * float(h) / float(isize.y))))
	for vp: SubViewport in _viewports:
		vp.size = Vector2i(w, h)


## Frustum + facing + distance cull, then the best `SLOTS` by apparent size.
func _select() -> Array[Portal]:
	var out: Array[Portal] = []
	if portals.is_empty():
		return out
	# Warm-up ignores culling on purpose: EVERY pooled slot must be rendered at
	# least once behind the loading screen, whether or not the player happens to
	# be looking at two portals when the level starts. A cold shader compile in
	# a browser is a multi-hundred-millisecond freeze, and the first time you
	# look at a portal is the worst possible moment to take one.
	if _warm_left > 0:
		for p: Portal in portals:
			if p != null and is_instance_valid(p) and p.peer != null:
				out.append(p)
			if out.size() >= SLOTS:
				break
		return out

	var cam_pos := main_camera.global_position
	var frustum := main_camera.get_frustum()
	var scored: Array = []

	for p: Portal in portals:
		if p == null or not is_instance_valid(p) or p.peer == null or not p.visible:
			continue
		# You cannot see through the back of a portal.
		if not p.is_in_front(cam_pos):
			continue
		var to := p.global_position - cam_pos
		var dist := to.length()
		if dist > max_render_distance:
			continue
		var pts := p.corners()
		if not _corners_in_frustum(frustum, pts):
			continue
		# Apparent solid angle: area over distance squared. Warming still
		# selects, so the first frames render whatever is nearest.
		var score := (p.width * p.height) / maxf(dist * dist, 0.25)
		if _focus_active:
			var fd := p.global_position.distance_to(_focus_point)
			# A disc bearing down on a portal outranks a bigger one behind you.
			score += 40.0 / maxf(fd * fd, 1.0)
		scored.append({"p": p, "s": score})

	scored.sort_custom(func(a, b): return a["s"] > b["s"])
	for i in mini(SLOTS, scored.size()):
		out.append(scored[i]["p"])
	return out


## Conservative: cull only when every corner is outside the SAME plane. A portal
## bigger than the screen has all four corners outside four different planes and
## must still be drawn, which the naive "any corner inside" test gets wrong.
##
## `Camera3D.get_frustum()` hands back planes whose normals point OUT of the
## frustum, so `distance_to(v) <= 0` means "inside". Verified behaviourally
## against the probe's camera stations: 0 portals looking away, 1 at a grazing
## edge, 2 head-on. Get the sign backwards and the failure is not subtle — you
## cull everything, always, or nothing, ever.
static func _corners_in_frustum(frustum: Array[Plane], pts: PackedVector3Array) -> bool:
	for plane: Plane in frustum:
		var all_out := true
		for v: Vector3 in pts:
			if plane.distance_to(v) <= 0.0:
				all_out = false
				break
		if all_out:
			return false
	return true


## Sticky assignment: a portal that keeps its slot keeps its warm texture and
## its shader variant, so nothing flickers when the second portal changes.
func _assign_slots(chosen: Array[Portal]) -> void:
	for i in SLOTS:
		var p: Portal = _slot_portal[i]
		if p != null and not chosen.has(p):
			_release_slot(i)
	for p: Portal in chosen:
		if _slot_portal.has(p):
			continue
		for i in SLOTS:
			if _slot_portal[i] == null:
				_take_slot(i, p)
				break


func _take_slot(i: int, p: Portal) -> void:
	_slot_portal[i] = p
	var vp: SubViewport = _viewports[i]
	vp.disable_3d = false
	# UPDATE_ALWAYS, not UPDATE_WHEN_VISIBLE. Two reasons: WHEN_VISIBLE has a
	# restart latency that flickers, and godot#86258 reports SubViewport
	# textures rendering BLACK in exported builds under anything but Always.
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	p.set_live_texture(vp.get_texture())


func _release_slot(i: int) -> void:
	var p: Portal = _slot_portal[i]
	if p != null and is_instance_valid(p):
		p.set_live(false)
	_slot_portal[i] = null
	var vp: SubViewport = _viewports[i]
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	# Idle slots cost texture memory and nothing else.
	vp.disable_3d = true


func _drive_slot(i: int, p: Portal) -> void:
	var cam: Camera3D = _cameras[i]
	var peer := p.peer
	if peer == null:
		_release_slot(i)
		return

	# THE one place a pair transform is applied for rendering. Physics uses the
	# same `to_peer`, cached at link time, so the picture and the flight cannot
	# disagree.
	cam.global_transform = p.to_peer * main_camera.global_transform

	cam.fov = main_camera.fov
	cam.keep_aspect = main_camera.keep_aspect
	cam.far = main_camera.far
	cam.near = _fit_near(cam, peer)
	cam.environment = _environment_for(peer.room_index)


## Dynamic perpendicular near plane, fitted to the four corners of the EXIT
## aperture: the largest near distance that still cannot clip any corner.
##
## This is the honest substitute for an oblique plane. It removes everything
## standing between the portal camera and the exit portal — which, combined with
## single-sided room walls, is the whole of the visible problem in practice.
static func _fit_near(cam: Camera3D, peer: Portal) -> float:
	var origin := cam.global_position
	var forward := -cam.global_transform.basis.z.normalized()
	var nearest := INF
	for v: Vector3 in peer.corners():
		nearest = minf(nearest, forward.dot(v - origin))
	if not is_finite(nearest):
		return MIN_NEAR
	return clampf(nearest - NEAR_SLACK, MIN_NEAR, maxf(cam.far * 0.5, MIN_NEAR))


func _environment_for(room: int) -> Environment:
	if room >= 0 and room < room_environments.size():
		return room_environments[room]
	return null

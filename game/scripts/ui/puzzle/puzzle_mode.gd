class_name PuzzleModeApp
extends Node3D

## Portal Puzzles: the mode controller. It owns the level library, one
## `PuzzleSession`, one `PuzzleGhost`, the 3D preview and the UI, and it is the
## only place those five talk to each other.
##
## ---------------------------------------------------------------------------
## The division with Track P3
## ---------------------------------------------------------------------------
## P3 owns `scripts/puzzle/**`: the level model, the world, the session, the
## ghost predictor and the progress store. Not one line of gameplay arithmetic
## lives in `scripts/ui/puzzle/**`. This file translates in both directions —
## a `throw_requested` signal becomes `session.begin_throw()`, and
## `session.progress()` becomes what the HUD says — and nothing more.
##
## ---------------------------------------------------------------------------
## The throw loop
## ---------------------------------------------------------------------------
##   aim    the drag writes `PuzzleAimController`; `PuzzleGhost.request()` is
##          told about it on every change and decides for itself when to
##          integrate (it debounces and rate-limits, so a drag costs one
##          prediction, not sixty)
##   throw  `session.begin_throw()`, then `session.advance()` from
##          `_physics_process` — the flight is stepped by the session at its own
##          fixed dt, and the camera follows the disc the session reports
##   land   the flown path stays on screen as a trail, the HUD updates from
##          `session.progress()`, and the results screen appears when the
##          attempt is over
##
## Stepping the flight in `_physics_process` and not `_process` is not a style
## choice: `PuzzleSession.advance()` consumes whole substeps of a fixed-dt
## integrator, and driving that from a variable frame time makes the flight
## frame-rate dependent.

signal sandbox_requested()

const T := preload("res://scripts/ui/flight_lab_theme.gd")
const Facts := preload("res://scripts/ui/puzzle/level_facts.gd")
const LevelDataT := preload("res://scripts/puzzle/level_data.gd")
const LevelLibraryT := preload("res://scripts/puzzle/level_library.gd")
const SessionT := preload("res://scripts/puzzle/puzzle_session.gd")
const GhostT := preload("res://scripts/puzzle/ghost_predictor.gd")
const ProgressT := preload("res://scripts/puzzle/progress_store.gd")
const DiscLibraryT := preload("res://scripts/physics/disc_library.gd")

## Flight playback runs a little faster than the flight did. A puzzle is a retry
## loop and Level 10's scoring throw is 11 s long; 1.6x keeps the shape of the
## flight readable without making the loop feel like waiting. The *simulation*
## is untouched — this only scales how much simulated time one real second
## advances.
const PLAYBACK_RATE := 1.6

var levels: PuzzleLevelLibrary = null
var session: PuzzleSession = null
var ghost: PuzzleGhost = null
var progress: PuzzleProgress = null
var preview: PuzzleLevelPreview = null
var ui: PuzzleUi = null
var aim: PuzzleAimController = null

var _discs: DiscLibrary = null
var _level: PuzzleLevelData = null
var _level_index: int = 0
var _view: String = "tee"
var _flying: bool = false
var _throw_index: int = -1
var _last_ghost_kind: String = ""
## One stage diagnostic per level; see `_report_stage`.
var _stage_reported: bool = false


func _ready() -> void:
	print("[PuzzleMode] renderer=%s" % ProjectSettings.get_setting(
		"rendering/renderer/rendering_method"))
	_discs = DiscLibraryT.load_default()
	levels = LevelLibraryT.load_default()
	for e in levels.load_errors:
		push_warning("PuzzleMode: %s" % e)
	progress = ProgressT.load_default()
	session = SessionT.new()
	ghost = GhostT.new()

	aim = PuzzleAimController.new()
	aim.changed.connect(_on_aim_changed)

	preview = PuzzleLevelPreview.new()
	add_child(preview)

	ui = PuzzleUi.new(aim)
	add_child(ui)
	ui.throw_requested.connect(_on_throw)
	ui.retry_requested.connect(_on_retry)
	ui.level_requested.connect(load_level_by_id)
	ui.camera_view_changed.connect(set_view)
	ui.ghost_toggled.connect(_on_ghost_toggled)
	ui.disc_changed.connect(_on_disc_changed)
	ui.portal_disc_toggled.connect(func(_id: String) -> void: _request_ghost())
	ui.sandbox_requested.connect(func() -> void: sandbox_requested.emit())
	ui.overlay.aim_dragged.connect(_request_ghost)
	ui.overlay.drag_finished.connect(_request_ghost)
	ui.results.next_level_requested.connect(_on_next_level)
	ui.overlay.camera = preview.camera

	_refresh_level_list()
	if levels.size() == 0:
		var why := "\n".join(levels.load_errors) if not levels.load_errors.is_empty() \
			else "res://data/levels/ is empty."
		ui.level_select.set_notice("No levels loaded. " + why)
		ui.set_status("No level data.")
		ui.open_level_select()
		return
	# `?level=<id>` makes a level a linkable URL. An unknown id starts at the
	# first level rather than at an error, for the same reason an unknown `mode`
	# opens the sandbox: a mistyped link should still give you a game.
	var wanted := ModeBoot.requested_level()
	var start := 0
	for i in levels.size():
		if (levels.get_index(i) as PuzzleLevelData).id == wanted:
			start = i
			break
	load_level_index(start)
	print("[PuzzleMode] ready. levels=%d discs=%d" % [levels.size(), _discs.size()])


func _refresh_level_list() -> void:
	var medals: Dictionary = {}
	for lv in levels.levels:
		var level: PuzzleLevelData = lv
		medals[level.id] = progress.medal_of(level.id)
	ui.level_select.set_levels(levels.levels, medals)


# ============================================================ level loading ===

func load_level_by_id(level_id: String) -> void:
	for i in levels.size():
		if (levels.get_index(i) as PuzzleLevelData).id == level_id:
			load_level_index(i)
			return


func load_level_index(i: int) -> void:
	var level: PuzzleLevelData = levels.get_index(i)
	if level == null:
		return
	_level_index = i
	_level = level
	_flying = false
	_throw_index = -1
	_stage_reported = false

	session.start(level, _discs)
	for e in session.start_errors:
		push_warning("PuzzleMode: %s" % e)
	ghost.setup(session.world, _discs)

	preview.build(level, session.world)
	preview.clear_flight_paths()
	preview.hide_disc()

	# Heading zero is world -Z and nothing else. `DiscFlightSim.launch()` builds
	# the velocity as `(sin h, 0, -cos h)` in WORLD axes, so the aim clamp, the
	# reticle and the camera are all measured from -Z.
	#
	# It is tempting to point them at the flag instead, and that is wrong: rooms
	# are laid out side by side in one shared world (`world_origin`, translation
	# only), so the flag's world position can be 130 m to the *right* of the tee
	# even though it is straight downrange through the portal. Aiming anything at
	# it swings the whole frame sideways. Measured on Level 1: flag world
	# (130, 0, 16) against a tee at the origin.
	aim.set_tee(level.tee_world(), Vector3(0, 0, -1))
	# The reticle is drawn on the LAUNCH room's floor and nowhere else. Without
	# this it is a marker on an infinite ground plane, and at full power on
	# Level 1 it sits 115 m past the tee room's far wall — in the gap between
	# rooms, pointing at nothing.
	var tee_room: PuzzleLevelData.RoomData = level.get_room(level.tee_room)
	if tee_room != null:
		aim.set_bounds(tee_room.world_min(), tee_room.world_max())
	else:
		aim.clear_bounds()

	var ids := level.allowed_disc_ids()
	aim.apply_category(_category_of(ids[0] if not ids.is_empty() else ""), true)

	ui.set_level(level, _discs)
	ui.overlay.flag_position = level.flag_world()
	ui.overlay.in_flight = false
	ui.set_throw_enabled(true)
	ui.results.visible = false
	ui.level_select.visible = false
	_refresh_hud()
	set_view("tee")
	_predict_now()
	# One line per level, in the shape the sandbox's boot diagnostics take. It is
	# what a browser run has to show for the layout to be checkable at all: with
	# no DOM to query, the console is the only place the geometry can be asserted
	# from outside the engine.
	print("[PuzzleMode] level %s  tee=%s flag=%s  rooms=%d portals=%d dive=%s" % [
		level.id, str(level.tee_world()), str(level.flag_world()),
		level.rooms.size(), level.portals.size(), str(Facts.has_dive_portal(level))])


func _category_of(disc_id: String) -> String:
	if _discs == null or disc_id.is_empty():
		return ""
	var disc: DiscDefinition = _discs.get_disc(disc_id)
	return disc.category if disc != null else ""


func _on_disc_changed(disc_id: String) -> void:
	aim.apply_category(_category_of(disc_id), false)
	_predict_now()


func _on_next_level() -> void:
	ui.results.visible = false
	if _level_index + 1 < levels.size():
		load_level_index(_level_index + 1)
	else:
		ui.open_level_select()


func _on_retry() -> void:
	if _level == null:
		return
	session.restart()
	ghost.sync(session.world)
	preview.build(_level, session.world)
	preview.clear_flight_paths()
	preview.hide_disc()
	_flying = false
	_throw_index = -1
	ui.results.visible = false
	ui.overlay.in_flight = false
	ui.set_throw_enabled(true)
	ui.set_status("Level reset — %d disc%s." % [_level.max_discs,
		"" if _level.max_discs == 1 else "s"])
	_refresh_hud()
	set_view("tee")
	_predict_now()


# ================================================================= throwing ===

func _on_throw() -> void:
	if _flying or _level == null:
		return
	var disc_id := ui.current_disc_id()
	var portal_disc := ui.current_portal_disc_id()
	var problem := session.throw_error(disc_id, portal_disc)
	if not problem.is_empty():
		# The session says why in the language of the rules; passing it straight
		# through beats inventing a second vocabulary for the same refusals.
		ui.set_status("Cannot throw: %s." % problem)
		return

	session.begin_throw(disc_id, aim.build_params(), portal_disc)
	_throw_index = session.throws.size() - 1
	_flying = true
	ui.overlay.in_flight = true
	ui.set_throw_enabled(false)
	ui.set_status("%s away — %s" % [_disc_name(disc_id), aim.summary()])
	set_view("follow")
	_refresh_hud()


func _physics_process(delta: float) -> void:
	if not _flying:
		return
	if session.advance(delta * PLAYBACK_RATE):
		var state := session.flight_state()
		preview.show_disc(state.position)
		# Two hints to the portal renderer, both about the disc: which portals
		# are worth a render pass (the two slots go to the ones it is bearing
		# down on, not merely the biggest on screen), and where to put the
		# crossing ghost so the disc does not pop as it goes through.
		preview.stage.set_focus(state.position)
		preview.stage.track_disc(Transform3D(Basis.IDENTITY, state.position), true)
		if _view == "follow":
			preview.view_follow(state.position, aim.reticle_position() - aim.tee_position)
		return
	_land()


func _process(delta: float) -> void:
	_report_stage()
	if _flying or _level == null:
		return
	# The predictor decides when to integrate; this only gives it a clock.
	if ghost.update(delta):
		_push_ghost()


## One line, once per level, as soon as the portal renderer has warmed and is
## actually drawing something. It is the puzzle-mode counterpart of
## `[FlightApp] ready.` and it exists for the same reason: a headless browser
## driving the shipped build has no DOM inside the canvas, so the console is the
## only place a claim about the 3D scene can be checked from outside the engine.
##
## `portal_rect` is the payload that matters. godot#86258 reports SubViewport
## textures rendering BLACK in *exported* builds — fine in the editor, broken in
## the browser, which is exactly the failure mode that shipped six green deploys
## of this project with no physics in them. Printing the aperture's screen
## rectangle lets the driver sample those pixels and assert that the portal
## shows a room rather than a black hole.
func _report_stage() -> void:
	if _stage_reported or _level == null or preview == null or preview.stage == null:
		return
	var renderer := preview.stage.renderer
	if renderer == null or not renderer.is_warm() or renderer.active_portal_count() <= 0:
		return
	var rect: Dictionary = preview.stage.live_portal_rect()
	if rect.is_empty():
		return
	_stage_reported = true
	var s: Dictionary = preview.stage.stats()
	print("[PuzzleMode] stage level=%s rooms=%d portals=%d live=%d draw_calls=%d prims=%d problems=%d" % [
		_level.id, int(s["rooms"]), int(s["portals"]), int(s["active"]),
		int(s["draw_calls"]), int(s["primitives"]), int(s["problems"])])
	print("[PuzzleMode] portal_rect id=%s kind=%d x=%d y=%d w=%d h=%d" % [
		str(rect["id"]), int(rect["kind"]), int(rect["x"]), int(rect["y"]),
		int(rect["w"]), int(rect["h"])])


func _land() -> void:
	_flying = false
	ui.overlay.in_flight = false
	preview.hide_disc()
	preview.stage.clear_focus()
	preview.stage.track_disc(Transform3D.IDENTITY, false)

	var record: PuzzleSession.ThrowRecord = session.throws[_throw_index] \
		if _throw_index >= 0 and _throw_index < session.throws.size() else null
	if record == null:
		return

	# The one line a headless browser can read a THROW off, and the puzzle-mode
	# counterpart of `[FlightApp] landed ...`. Everything else about an attempt
	# goes to the HUD, which is inside the canvas and therefore invisible to a
	# driver — so before this, a browser could prove the level loaded and the
	# portal rendered but not that a throw completed. Same shape as the sandbox's
	# line on purpose: one grep serves both modes.
	print("[PuzzleMode] landed level=%s disc=%s outcome=%s room=%d flag=%s t=%.2f s crossings=%d medal=%s" % [
		_level.id, record.disc_id, record.outcome, record.end_room,
		("%.2f m" % record.flag_distance_m) if record.flag_distance_m < INF else "none",
		record.flight_time_s, record.crossings,
		session.best_medal if session.best_medal != "" else "none"])

	preview.add_flight_path(record.trajectory, T.ACCENT)
	# A portal disc changes the geometry, and a barrier can open between throws,
	# so the dynamic pass is rebuilt rather than assumed unchanged.
	preview.rebuild_dynamic()
	ghost.sync(session.world)
	_refresh_hud()

	var medal := session.medal_now()
	if not medal.is_empty() or record.flag_distance_m < INF:
		progress.record_attempt(_level.id, medal, record.flag_distance_m,
			session.discs_used, record.flag_distance_m < INF)
		progress.save()
		_refresh_level_list()
		ui.level_select.set_current(_level.id)

	if session.attempt_over():
		ui.results.show_outcome(_level, _outcome(record), _level_index + 1 < levels.size())
		ui.set_throw_enabled(session.discs_remaining() > 0)
		# The camera selector reads "Level", but the framing is the landing with
		# the modal accounted for. Pressing C from here cycles to the plain views.
		set_view("level")
		preview.view_landing(record.landing_world)
	else:
		ui.set_throw_enabled(true)
		ui.set_status("%s  %d disc%s left." % [_landing_line(record),
			session.discs_remaining(), "" if session.discs_remaining() == 1 else "s"])
		set_view("tee")
	_predict_now()


## `ThrowRecord` flattened into the dictionary the results screen renders. The
## screen is deliberately given plain data rather than the record object, so it
## can be driven by a test without a session.
func _outcome(record: PuzzleSession.ThrowRecord) -> Dictionary:
	return {
		"disc": record.disc_id,
		"disc_name": _disc_name(record.disc_id),
		"room": record.end_room,
		# The attempt's score, not this throw's: a placement or button throw
		# legitimately never reaches the flag room, and the medal is scored on
		# the best landing of the attempt.
		"reached_flag_room": session.best_flag_distance_m < INF,
		"flag_distance_m": session.best_flag_distance_m,
		"flight_time_s": record.flight_time_s,
		"crossings": record.crossings,
		"discs_used": session.discs_used,
		"discs_remaining": session.discs_remaining(),
		"buttons_ok": session.medal_now() != "" or _level.requires_buttons.is_empty()
			or _all_required_armed(),
		"buttons_hit": record.buttons_armed,
		"medal": session.best_medal,
		"outcome": record.outcome,
		"struck_id": record.struck_id,
		"placed_portal_id": record.placed_portal_id,
	}


func _all_required_armed() -> bool:
	var armed := session.buttons_armed()
	for b in _level.requires_buttons:
		if not armed.has(b):
			return false
	return true


func _landing_line(record: PuzzleSession.ThrowRecord) -> String:
	if not record.placed_portal_id.is_empty():
		return "Portal `%s` opened." % record.placed_portal_id
	if record.outcome == "wall":
		return "Stopped against %s." % ("a wall" if record.struck_id.is_empty() else record.struck_id)
	if record.outcome == "barrier":
		return "Stopped against a locked barrier."
	if record.flag_distance_m < INF:
		return "Landed %.2f m from the flag." % record.flag_distance_m
	return "Landed in %s." % Facts.room_name(_level, record.end_room)


func _disc_name(disc_id: String) -> String:
	var disc: DiscDefinition = _discs.get_disc(disc_id) if _discs != null else null
	return disc.name if disc != null else disc_id.capitalize()


# =================================================================== ghost ===

func _on_aim_changed() -> void:
	if ui != null:
		ui.advanced.refresh()
	_request_ghost()


func _on_ghost_toggled(enabled: bool) -> void:
	ghost.enabled = enabled
	if enabled:
		_predict_now()
	else:
		ui.overlay.ghost_points = PackedVector3Array()
		ui.overlay.ghost_end_kind = ""
		ui.overlay.ghost_end_label = ""


## Free — it stores the request and returns. `ghost.update()` decides when to
## integrate.
func _request_ghost() -> void:
	if _level == null or _flying or not ghost.enabled:
		return
	var disc_id := ui.current_disc_id()
	if not disc_id.is_empty():
		ghost.request(disc_id, aim.build_params())


## Skip the throttle: entering a level or changing disc with a stale line on
## screen reads as a stutter.
func _predict_now() -> void:
	if _level == null or not ghost.enabled:
		return
	var disc_id := ui.current_disc_id()
	if disc_id.is_empty():
		return
	ghost.predict_now(disc_id, aim.build_params())
	_push_ghost()


## Copy the predictor's result onto the overlay, and work out what the marker at
## the end should say. The predictor reports *what* it stopped against; only this
## layer knows whether that portal is the one that will drop the disc out of the
## sky.
func _push_ghost() -> void:
	var overlay := ui.overlay
	overlay.ghost_points = ghost.trajectory
	overlay.ghost_end_kind = ghost.end_kind
	overlay.ghost_end_position = ghost.end_position
	overlay.ghost_end_dive = false
	overlay.ghost_end_label = ""
	overlay.ghost_end_portalable = false
	match ghost.end_kind:
		"portal":
			var dive := Facts.portal_dives(_level, _level.get_portal(ghost.end_id))
			overlay.ghost_end_dive = dive
			overlay.ghost_end_label = "DIVE PORTAL — 40-45% shorter beyond this" if dive \
				else "PORTAL — the prediction stops here"
		"wall":
			# A portalable panel is not "stone". Saying so is the difference
			# between a player who knows their one portal disc is aimed at a
			# legal surface and a player who finds out by spending it.
			overlay.ghost_end_portalable = ghost.end_portalable
			# Kept short on purpose. `PuzzleAimOverlay._draw_tag` only keeps a
			# plate inside the CANVAS, not clear of the HUD panels, and the
			# ghost's terminus is routinely two thirds of the way across the
			# screen — measured at 1280x720, where a 42-character label slid
			# under the room-conditions panel and lost its last four words.
			if ghost.end_portalable:
				overlay.ghost_end_label = "PORTALABLE — portal opens here" \
					if _portal_disc_armed() else "PORTALABLE — arm a portal disc"
			else:
				overlay.ghost_end_label = "WALL — this line hits stone"
		"barrier":
			overlay.ghost_end_label = "BARRIER — still locked"
		"truncated":
			overlay.ghost_end_label = "preview ends"
		"failed":
			overlay.ghost_end_label = "no prediction"
	_push_portal_prediction()
	if ghost.end_kind != _last_ghost_kind:
		_last_ghost_kind = ghost.end_kind
		print("[PuzzleMode] ghost %s at %s (%d pts, %.1f ms) dive=%s portalable=%s" % [
			ghost.end_kind, str(ghost.end_position), ghost.trajectory.size(),
			ghost.compute_ms, str(overlay.ghost_end_dive), str(ghost.end_portalable)])


func _portal_disc_armed() -> bool:
	return ui != null and not ui.current_portal_disc_id().is_empty()


## Show the rectangle the armed portal disc would actually open, at the current
## aim. Only when a portal disc is armed AND the line ends on a portalable
## panel — a rectangle drawn for a throw that cannot place a portal is worse
## than none, because it promises something the throw will not do.
func _push_portal_prediction() -> void:
	var show: bool = _portal_disc_armed() and ghost.end_kind == "wall" \
		and ghost.end_portalable and not ghost.end_id.is_empty()
	preview.predicted_portal_surface = ghost.end_id if show else ""
	preview.predicted_portal_disc = ui.current_portal_disc_id() if show else ""
	preview.predicted_portal_impact = ghost.end_position
	preview.refresh_prediction()


# ==================================================================== state ===

func _refresh_hud() -> void:
	if _level == null:
		return
	var p := session.progress()
	ui.hud.set_discs(int(p["discs_remaining"]), int(p["max_discs"]))
	ui.hud.set_best_distance(float(p["best_flag_distance_m"]))
	var armed: PackedStringArray = p["buttons_armed"]
	ui.hud.set_buttons(armed.size(), _level.requires_buttons.size())
	ui.hud.set_medal(str(p["best_medal"]))
	ui.hud.set_current_room(session.flight_room() if _flying else _level.tee_room)
	ui.hud.set_progress(_status_word(p), true)
	preview.set_buttons_armed(armed)
	ui.set_portal_disc_available(int(p["portal_discs_remaining"]) > 0)


static func _status_word(p: Dictionary) -> String:
	if bool(p["flying"]):
		return "In flight"
	if bool(p["attempt_over"]):
		return "Attempt over"
	if int(p["discs_used"]) == 0:
		return "Ready"
	return "Throw %d" % (int(p["discs_used"]) + 1)


# =================================================================== camera ===

func set_view(view: String) -> void:
	_view = view
	ui.set_camera_view(view)
	match view:
		"top":
			preview.view_top()
		"level":
			preview.view_level()
		"follow":
			if not _flying:
				preview.view_tee(aim.reticle_position() - aim.tee_position)
		_:
			preview.view_tee(aim.reticle_position() - aim.tee_position)

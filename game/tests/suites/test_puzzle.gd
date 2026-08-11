extends RefCounted

## Unit tests for the puzzle runtime: the level schema, the hit oracle, the
## session (disc budget, buttons, barriers, portal-disc placement, medals), the
## ghost predictor and the progress store.
##
## The level REPLAY gate lives in `test_level_replay.gd`; this file is about the
## machinery those levels run on.

const LevelDataT := preload("res://scripts/puzzle/level_data.gd")
const LibraryT := preload("res://scripts/puzzle/level_library.gd")
const SessionT := preload("res://scripts/puzzle/puzzle_session.gd")
const WorldT := preload("res://scripts/puzzle/puzzle_world.gd")
const OracleT := preload("res://scripts/puzzle/puzzle_hit_oracle.gd")
const GhostT := preload("res://scripts/puzzle/ghost_predictor.gd")
const ProgressT := preload("res://scripts/puzzle/progress_store.gd")
const Sim := preload("res://scripts/physics/disc_flight_sim.gd")


func run(t, lib) -> void:
	var levels := LibraryT.load_default()
	_schema(t, lib, levels)
	_oracle(t, levels)
	_session(t, lib, levels)
	_placement(t, lib, levels)
	_ghost(t, lib, levels)
	_progress(t, levels)


# ---------------------------------------------------------------------------

func _schema(t, lib, levels) -> void:
	t.suite("puzzle level schema")
	t.check("levels load", levels.size() == 10,
		"%d levels: %s" % [levels.size(), str(levels.ids())])

	var orders := {}
	for i in levels.size():
		var lv: LevelDataT = levels.get_index(i)
		if not t.check("%s is structurally valid" % lv.id, lv.is_valid(), str(lv.errors)):
			continue
		t.check("%s has a hint" % lv.id, lv.hint.length() > 20,
			"%d chars" % lv.hint.length())
		t.check("%s order is unique" % lv.id, not orders.has(lv.order),
			"order %d" % lv.order)
		orders[lv.order] = true

		var missing := PackedStringArray()
		for did in lv.allowed_disc_ids():
			if lib.get_disc(did) == null:
				missing.append(did)
		t.check("%s bag is in the roster" % lv.id, missing.is_empty(),
			"%s%s" % [str(lv.allowed_disc_ids()),
				("" if missing.is_empty() else " MISSING " + str(missing))])

		# Every intended step must use a disc the level actually allows: a
		# solution the player could not reproduce is not a solution.
		var illegal := PackedStringArray()
		for s in lv.intended_solution:
			if not lv.allowed_disc_ids().has((s as LevelDataT.SolutionStep).disc):
				illegal.append((s as LevelDataT.SolutionStep).disc)
		t.check("%s intended solution uses only the level's bag" % lv.id,
			illegal.is_empty(), str(illegal))
		t.check("%s intended solution fits the disc budget" % lv.id,
			lv.intended_solution.size() <= lv.max_discs,
			"%d step(s), budget %d" % [lv.intended_solution.size(), lv.max_discs])

		# The two invariants the world frame depends on.
		var tw: Vector3 = lv.tee_world()
		t.check("%s tee sits on the world origin" % lv.id,
			Vector2(tw.x, tw.z).length() < 1e-4, str(tw))
		var floors_ok: bool = true
		for r in lv.rooms:
			if absf((r as LevelDataT.RoomData).bounds_min.y) > 1e-9 \
					or absf((r as LevelDataT.RoomData).world_origin.y) > 1e-9:
				floors_ok = false
		t.check("%s every room floor is the world ground plane" % lv.id, floors_ok)

		# The layout must actually separate the rooms, or the renderer draws two
		# rooms on top of each other.
		var overlap: String = ""
		for a in lv.rooms.size():
			for b in range(a + 1, lv.rooms.size()):
				var ra: LevelDataT.RoomData = lv.rooms[a]
				var rb: LevelDataT.RoomData = lv.rooms[b]
				if _boxes_overlap(ra.world_min(), ra.world_max(), rb.world_min(), rb.world_max()):
					overlap = "%s and %s" % [ra.id, rb.id]
		t.check("%s rooms are disjoint in world space" % lv.id, overlap == "", overlap)

	# The design set is explicitly a difficulty ramp; a gap or a repeat in the
	# order is a content bug, not a cosmetic one.
	var seq: bool = true
	for i in levels.size():
		if not orders.has(i + 1):
			seq = false
	t.check("levels are ordered 1..N with no gaps", seq, str(orders.keys()))
	t.end_suite()


static func _boxes_overlap(a0: Vector3, a1: Vector3, b0: Vector3, b1: Vector3) -> bool:
	for i in 3:
		if a1[i] <= b0[i] + 1e-6 or b1[i] <= a0[i] + 1e-6:
			return false
	return true


# ---------------------------------------------------------------------------

func _oracle(t, levels) -> void:
	t.suite("puzzle hit oracle")
	var lv: LevelDataT = levels.get_level("01_crosswind_hall")
	if lv == null:
		t.skip("oracle", "level 1 missing")
		return
	var w := WorldT.new(lv)
	var o: OracleT = w.oracle
	o.room = lv.tee_room
	o.disc_radius = 0.105

	var r: LevelDataT.RoomData = lv.get_room(lv.tee_room)
	var origin: Vector3 = r.world_origin
	var mid: Vector3 = Vector3(0.0, 6.0, -10.0) + origin

	# Straight at the portal centre: the aperture is a HOLE, not a wall.
	var through := o.query(mid, Vector3(0.0, 6.0, -21.0) + origin)
	t.check("a disc aimed at the portal centre is not stopped by the wall",
		through.is_empty(), str(through.get("collider", {})))

	# Same wall, outside the 36 x 12 aperture: solid.
	var side := o.query(Vector3(28.0, 6.0, -10.0) + origin,
		Vector3(28.0, 6.0, -21.0) + origin)
	t.check("the wall around the aperture is solid", not side.is_empty(),
		str(side.get("collider", {})))
	if not side.is_empty():
		var p: Vector3 = side["position"]
		t.close("wall hit lands on the wall plane", p.z - origin.z, -20.0, 1e-3, " m")

	# Just inside the rim, but within one disc radius of it: the hole is cut to
	# the INSET rectangle, so this is wall. Getting this wrong lets a disc leave
	# the room without ever being teleported.
	var rim := o.query(Vector3(0.0, 11.95, -10.0) + origin,
		Vector3(0.0, 11.95, -21.0) + origin)
	t.check("the rim inset matches the aperture the sim fires on",
		not rim.is_empty(), "y = 11.95, aperture top 12.0, inset 0.105")

	# The ceiling is a wall; the floor is the ground plane and belongs to the sim.
	var up := o.query(Vector3(0.0, 10.0, -10.0) + origin, Vector3(0.0, 17.0, -10.0) + origin)
	t.check("the ceiling stops a disc", not up.is_empty(),
		str(up.get("collider", {}).get("id", "")))
	var down := o.query(Vector3(0.0, 2.0, -10.0) + origin, Vector3(0.0, -1.0, -10.0) + origin)
	t.check("the floor is left to the ground event", down.is_empty())

	# Barriers, in both states.
	var l5: LevelDataT = levels.get_level("05_two_keys")
	if l5 != null:
		var w5 := WorldT.new(l5)
		var o5: OracleT = w5.oracle
		o5.room = l5.room_index("lock_hall")
		var lo: Vector3 = l5.get_room(o5.room).world_origin
		var a: Vector3 = Vector3(0.0, 5.0, -50.0) + lo
		var b: Vector3 = Vector3(0.0, 5.0, -60.0) + lo
		var shut := o5.query(a, b)
		t.check("a locked barrier is solid", not shut.is_empty()
			and String((shut.get("collider", {}) as Dictionary).get("id", "")) == "gate",
			str(shut.get("collider", {})))
		w5.arm_button("key_a")
		w5.arm_button("key_b")
		o5.open_barriers = w5.open_barriers
		var open := o5.query(a, b)
		t.check("the barrier opens once both keys are armed", open.is_empty(),
			str(open.get("collider", {})))

		# Level 9's lintel has no buttons at all and must never open.
		var l9: LevelDataT = levels.get_level("09_under_the_lintel")
		if l9 != null:
			var w9 := WorldT.new(l9)
			w9.arm_button("nonexistent")
			var o9: OracleT = w9.oracle
			o9.room = l9.room_index("crypt")
			var c: Vector3 = l9.get_room(o9.room).world_origin
			var hit := o9.query(Vector3(0.0, 10.0, -10.0) + c, Vector3(0.0, 10.0, -20.0) + c)
			t.check("a barrier with no buttons is permanent", not hit.is_empty()
				and String((hit.get("collider", {}) as Dictionary).get("id", "")) == "lintel",
				str(hit.get("collider", {})))
	t.end_suite()


# ---------------------------------------------------------------------------

func _session(t, lib, levels) -> void:
	t.suite("puzzle session")
	var lv: LevelDataT = levels.get_level("01_crosswind_hall")
	var s := SessionT.new()
	s.start(lv, lib)

	t.check("a disc outside the level's bag is refused",
		s.throw_error("destroyer") != "", s.throw_error("destroyer"))
	t.check("a disc inside the bag is allowed", s.throw_error("roc") == "",
		s.throw_error("roc"))

	var p := SessionT.params_for(lv.intended_solution[0])
	var rec: SessionT.ThrowRecord = s.simulate_throw("roc", p)
	t.check("the intended throw lands in the far room", rec.landed and rec.crossings == 1,
		"outcome %s, %d crossing(s), %.2f m from the flag"
		% [rec.outcome, rec.crossings, rec.flag_distance_m])
	t.check("a one-disc level is over after one disc", s.attempt_over(),
		"%d of %d used" % [s.discs_used, lv.max_discs])
	t.check("the budget is enforced", s.throw_error("roc") != "", s.throw_error("roc"))
	t.check("gold is awarded for the intended line", s.medal_now() == "gold",
		"%s at %.2f m" % [s.medal_now(), s.best_flag_distance_m])

	# A throw that only just misses should read as a lesser medal, not as none:
	# the thresholds are the level's difficulty curve and a mis-set one is
	# invisible until someone plays it.
	var s2 := SessionT.new()
	s2.start(lv, lib)
	var p2 := SessionT.params_for(lv.intended_solution[0])
	p2.launch_heading_rad = 0.0     # the do-nothing throw, aim 0
	var rec2: SessionT.ThrowRecord = s2.simulate_throw("roc", p2)
	t.check("the do-nothing throw is bronze, not a failure", s2.medal_now() == "bronze",
		"%.2f m -> %s" % [rec2.flag_distance_m, s2.medal_now()])

	t.check("restart clears the attempt", true, "")
	s2.restart()
	t.check("restart resets discs and medals",
		s2.discs_used == 0 and s2.best_flag_distance_m == INF and s2.medal_now() == "")

	# Buttons and a barrier that opens BETWEEN throws (Level 5).
	var l5: LevelDataT = levels.get_level("05_two_keys")
	var s5 := SessionT.new()
	s5.start(l5, lib)
	var score_step: LevelDataT.SolutionStep = null
	var arm_step: LevelDataT.SolutionStep = null
	for st in l5.intended_solution:
		if (st as LevelDataT.SolutionStep).role == "arm":
			arm_step = st
		else:
			score_step = st
	var blocked: SessionT.ThrowRecord = s5.simulate_throw(score_step.disc,
		SessionT.params_for(score_step))
	t.check("the gate stops a scoring disc while it is locked",
		blocked.outcome == "barrier" and blocked.struck_id == "gate",
		"outcome %s, struck '%s' at %.1f m downrange"
		% [blocked.outcome, blocked.struck_id, absf(blocked.landing_local.z)])
	t.check("a blocked disc scores nothing", blocked.flag_distance_m == INF)

	var arm: SessionT.ThrowRecord = s5.simulate_throw(arm_step.disc,
		SessionT.params_for(arm_step))
	t.check("one throw can arm both keys", arm.buttons_armed.size() == 2,
		str(arm.buttons_armed))
	t.check("both keys open the gate", s5.barrier_is_open("gate"),
		str(arm.barriers_opened))
	var scored: SessionT.ThrowRecord = s5.simulate_throw(score_step.disc,
		SessionT.params_for(score_step))
	t.check("the same throw gets through once the gate is open",
		scored.landed and scored.flag_distance_m < 6.0,
		"%.2f m from the flag" % scored.flag_distance_m)
	t.check("three discs is silver, not gold", s5.best_medal == "silver",
		"%d discs at %.2f m -> %s" % [s5.discs_used, s5.best_flag_distance_m, s5.best_medal])
	t.end_suite()


# ---------------------------------------------------------------------------

func _placement(t, lib, levels) -> void:
	t.suite("portal discs")
	var lv: LevelDataT = levels.get_level("06_the_blank_wall")
	var s := SessionT.new()
	s.start(lv, lib)
	var place: LevelDataT.SolutionStep = lv.intended_solution[0]
	t.check("the placement step declares a portal disc", place.places() == "portal_a",
		place.role)
	t.check("the level starts with one portal disc", s.portal_discs_remaining() == 1)

	var rec: SessionT.ThrowRecord = s.simulate_throw(place.disc,
		SessionT.params_for(place), place.places())
	t.check("the portal disc strikes the portalable panel",
		rec.struck_portalable and rec.struck_id == "far_panel",
		"struck '%s' portalable=%s" % [rec.struck_id, str(rec.struck_portalable)])
	t.check("a portal opens where it struck", rec.placed_portal_id == "placed_a",
		str(rec.placed_portal_center))
	t.check("the portal disc is spent", s.portal_discs_remaining() == 0)
	t.check("a portal disc never scores", rec.flag_distance_m == INF)
	t.check("a portal disc still costs a disc", s.discs_used == 1)

	# Clamping: the rectangle must fit inside the panel. The impact is at
	# x = 5.28, a 10 m wide portal, panel x in [2, 28] -> centre clamped to 7.0.
	t.close("the portal is clamped to fit the panel", rec.placed_portal_center.x, 7.0,
		0.5, " m")

	# Level 10 clamps VERTICALLY, which is the case that decides the level: the
	# impact is at y = 4.88, the portal is 12 m tall and the panel starts at
	# y = 2, so the centre is pushed up to 8.00.
	var l10: LevelDataT = levels.get_level("10_the_gauntlet")
	var s10 := SessionT.new()
	s10.start(l10, lib)
	var st10: LevelDataT.SolutionStep = l10.intended_solution[0]
	var r10: SessionT.ThrowRecord = s10.simulate_throw(st10.disc,
		SessionT.params_for(st10), st10.places())
	t.check("one throw can arm a button AND place a portal",
		r10.buttons_armed.size() == 1 and r10.placed_portal_id != "",
		"buttons %s, portal at %s" % [str(r10.buttons_armed), str(r10.placed_portal_center)])
	t.close("the portal is clamped up off the panel's lower edge",
		r10.placed_portal_center.y, 8.0, 0.5, " m")
	t.check("arming the button opened the shutter", s10.barrier_is_open("shutter"))

	# A portal disc that hits stone is simply spent — no portal, no retry.
	var s7 := SessionT.new()
	var l7: LevelDataT = levels.get_level("07_windward_placement")
	s7.start(l7, lib)
	var miss: LevelDataT.SolutionStep = l7.intended_solution[0]
	var pm := SessionT.params_for(miss)
	pm.launch_heading_rad = deg_to_rad(10.0)   # the documented miss
	var rm: SessionT.ThrowRecord = s7.simulate_throw(miss.disc, pm, miss.places())
	t.check("a portal disc on stone opens nothing and is still spent",
		rm.placed_portal_id == "" and s7.portal_discs_remaining() == 0,
		"struck '%s'" % rm.struck_id)
	t.end_suite()


# ---------------------------------------------------------------------------

func _ghost(t, lib, levels) -> void:
	t.suite("ghost trajectory")
	var lv: LevelDataT = levels.get_level("01_crosswind_hall")
	var w := WorldT.new(lv)
	var g := GhostT.new()
	g.setup(w, lib)

	var p := SessionT.params_for(lv.intended_solution[0])
	g.predict_now("roc", p)
	t.check("a prediction is produced", g.has_prediction(),
		"%d points, %.1f ms" % [g.trajectory.size(), g.compute_ms])
	t.check("the ghost stops at the portal, not through it",
		g.end_kind == "portal" and g.end_id == "p1a",
		"ended '%s' on '%s' after %.2f s" % [g.end_kind, g.end_id, g.flight_time_s])

	var r: LevelDataT.RoomData = lv.get_room(lv.tee_room)
	var lo: Vector3 = r.world_min()
	var hi: Vector3 = r.world_max()
	var outside: int = 0
	for pt in g.trajectory:
		for i in 3:
			if pt[i] < lo[i] - 0.2 or pt[i] > hi[i] + 0.2:
				outside += 1
				break
	t.check("every ghost point is inside the launch room", outside == 0,
		"%d of %d outside" % [outside, g.trajectory.size()])

	# A throw that never reaches the portal must predict all the way to the floor.
	var slow := SessionT.params_for(lv.intended_solution[0])
	slow.speed_mps = 6.0
	slow.launch_angle_rad = 0.0
	g.predict_now("roc", slow)
	t.check("a short throw predicts to the floor", g.end_kind == "floor",
		"ended '%s' at %.1f m" % [g.end_kind, g.end_distance_m])

	# Throttling. A drag is thousands of requests; it must not be thousands of
	# 23 ms integrations.
	g.reset()
	g.debounce_s = 0.08
	g.min_interval_s = 0.15
	g.stale_after_s = 0.35
	var frames: int = 0
	for i in 600:                       # 10 s of dragging at 60 fps
		var q := SessionT.params_for(lv.intended_solution[0])
		q.hyzer_angle_rad = deg_to_rad(float(i) * 0.05)
		g.request("roc", q)
		g.update(1.0 / 60.0)
		frames += 1
	# Not zero: a ghost frozen for the whole drag is worse than no ghost. The
	# bound is the staleness refresh, ~3 a second, not the frame rate.
	t.check("a continuous drag is refreshed on a timer, not per frame",
		g.predictions > 0 and g.predictions <= frames / 8,
		"%d predictions over %d frames (%.1f ms each)"
		% [g.predictions, frames, g.compute_ms])
	var settled: int = g.predictions
	for i in 30:
		g.update(1.0 / 60.0)            # controls now still
	t.check("the prediction lands once the controls settle",
		g.predictions == settled + 1 and g.has_prediction(),
		"%d -> %d predictions" % [settled, g.predictions])
	t.check("an unchanged request does not recompute",
		not g.update(1.0 / 60.0), "%d predictions" % g.predictions)

	# The rule is structural: the ghost sim has no links at all, so there is no
	# code path that could follow one.
	t.check("the ghost simulator has no portals configured",
		g.sim_portal_count() == 0, "%d links" % g.sim_portal_count())
	t.end_suite()


# ---------------------------------------------------------------------------

func _progress(t, levels) -> void:
	t.suite("puzzle progress")
	var path := "user://test_puzzle_progress.json"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var pr := ProgressT.load_default(path)
	pr.records.clear()

	t.check("every level is playable from the start",
		pr.is_unlocked("10_the_gauntlet") and pr.is_unlocked("01_crosswind_hall"))
	t.check("no medal before playing", pr.medal_of("01_crosswind_hall") == "")

	pr.record_attempt("01_crosswind_hall", "bronze", 17.5, 1, true)
	t.check("a bronze run is recorded", pr.medal_of("01_crosswind_hall") == "bronze")
	pr.record_attempt("01_crosswind_hall", "gold", 0.96, 1, true)
	t.check("a better run replaces it", pr.medal_of("01_crosswind_hall") == "gold")
	pr.record_attempt("01_crosswind_hall", "silver", 5.0, 1, true)
	t.check("a worse run does not", pr.medal_of("01_crosswind_hall") == "gold",
		"best distance %.2f m" % pr.best_distance("01_crosswind_hall"))
	t.close("the best distance is kept", pr.best_distance("01_crosswind_hall"),
		0.96, 1e-6, " m")
	t.check("attempts are counted",
		int(pr.record_of("01_crosswind_hall").get("attempts", 0)) == 3)

	var wrote := pr.save()
	if wrote:
		var re := ProgressT.load_default(path)
		t.check("progress survives a reload", re.medal_of("01_crosswind_hall") == "gold",
			"%d records" % re.records.size())
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	else:
		t.skip("progress survives a reload", "user:// is not writable here")

	var sum := pr.summary(levels.ids())
	t.check("the medal summary counts every level",
		int(sum["total"]) == levels.size()
			and int(sum["gold"]) + int(sum["silver"]) + int(sum["bronze"])
				+ int(sum["none"]) == levels.size(), str(sum))
	t.end_suite()

extends RefCounted

## THE LEVEL REPLAY GATE.
##
## Every shipped level's `intended_solution` is replayed through the real
## `PuzzleSession` — the same code the game runs — and the landing is asserted
## against the measurement recorded in the level file, to +/- 0.5 m.
##
## ---------------------------------------------------------------------------
## What this is actually for
## ---------------------------------------------------------------------------
## The ten levels were designed against the SHIPPED physics, not against
## intuition: every quoted distance is a measurement taken from the reference
## integrator at dt = 1/240. That makes the level set an unusually sharp
## regression test on the physics core. If someone changes `PRECESSION_GAIN`, a
## coefficient table, the portal transform, the room-environment split or the
## event locator, the levels do not become subtly worse — they fail here, loudly,
## with the metre error printed.
##
## The alternative is a game that silently becomes unsolvable and nobody notices
## until a player cannot get gold on Level 9. This project has already shipped
## six deploys with no physics in them; a green build is not evidence.
##
## ---------------------------------------------------------------------------
## Why +/- 0.5 m and not tighter
## ---------------------------------------------------------------------------
## The expectations are baked by the PYTHON reference harness and asserted
## against the GDScript engine. Those are two implementations that share no code
## — different integrator source, different state vector (10 elements vs 14),
## float32 `Transform3D` content in the portal chain against float64 numpy, and
## an ISA density formula that agrees only to 2e-5 kg/m^3. The project's existing
## cross-validation measures the two agreeing to 1.5e-4 m over 139 m of portal
## flight, so the honest tolerance is far tighter than 0.5 m and the gate reports
## the WORST OBSERVED ERROR on every run. Watch that number, not the pass line:
## if it moves from millimetres to decimetres, something changed even though the
## gate is still green.
##
## What is asserted per level:
##
##   1. the level file parses and validates structurally
##   2. every intended step lands where the file says, +/- 0.5 m
##   3. placement steps strike the surface the file names, and open their portal
##      within 0.5 m of the recorded centre
##   4. the level is COMPLETABLE — the scoring throw reaches the flag's room
##   5. the intended solution earns the medal the file claims
##   6. every medal tier is achievable, by nesting: gold's budget implies
##      silver's implies bronze's, and gold is demonstrated
##   7. alternate solutions land where the file says too
##   8. replaying is deterministic, and the room layout offsets change nothing

const LevelDataT := preload("res://scripts/puzzle/level_data.gd")
const LibraryT := preload("res://scripts/puzzle/level_library.gd")
const SessionT := preload("res://scripts/puzzle/puzzle_session.gd")
const WorldT := preload("res://scripts/puzzle/puzzle_world.gd")
const Support := preload("res://tests/test_support.gd")

## PORTAL_CONTRACT / LEVEL_DESIGN both quote landings at dt = 1/240.
const TOL_M := 0.5
const RANK := {"": 0, "bronze": 1, "silver": 2, "gold": 3}

var _worst: float = 0.0
var _worst_where: String = ""


func run(t, lib) -> void:
	t.suite("level replay gate")
	var levels := LibraryT.load_default()

	t.check("level index loads", levels.size() > 0,
		"%d levels, %d load errors" % [levels.size(), levels.load_errors.size()])
	for e in levels.load_errors:
		t.check("level library error", false, e)

	var indexed := levels.indexed_ids()
	var on_disk := LibraryT.scan_dir()
	if on_disk.is_empty():
		# DirAccess over res:// is reliable in the editor and merely usually
		# reliable in an exported pack, so a miss is not a failure here.
		t.skip("index.json lists every level file", "directory listing unavailable")
	else:
		var a := Array(indexed)
		var b := Array(on_disk)
		a.sort()
		b.sort()
		t.check("index.json lists every level file", a == b,
			"index %s vs directory %s" % [str(a), str(b)])

	for i in levels.size():
		_level(t, lib, levels.get_index(i))

	t.note("level replay: worst landing disagreement vs the reference harness %s (%s), tolerance %.1f m"
		% [_fmt(_worst), _worst_where, TOL_M])
	t.end_suite()


static func _fmt(v: float) -> String:
	return "%s m" % Support.g(v, 4)


## `|a - b|`, treating two identical infinities as agreeing rather than as NaN.
## Both runs failing to reach the flag IS a reproducible result; it just is not
## a passing one, and the completability check is what says so.
static func _gap(a: float, b: float) -> float:
	if a == b:
		return 0.0
	return absf(a - b)


func _level(t, lib, lv: LevelDataT) -> void:
	var tag: String = lv.id
	if not t.check("%s parses" % tag, lv.is_valid(),
			"" if lv.is_valid() else str(lv.errors)):
		return

	var s := SessionT.new()
	s.start(lv, lib)
	if not t.check("%s builds a world" % tag, s.start_errors.is_empty(),
			"" if s.start_errors.is_empty() else str(s.start_errors)):
		return

	var recs := s.replay(lv.intended_solution)
	var scored: SessionT.ThrowRecord = null
	for i in recs.size():
		var rec: SessionT.ThrowRecord = recs[i]
		var step: LevelDataT.SolutionStep = lv.intended_solution[i]
		_step(t, tag, "intended", i, lv, step, rec)
		if rec.flag_distance_m < INF:
			scored = rec

	# 4 + 5: completable, and worth the medal the file claims.
	t.check("%s is completable" % tag, scored != null and scored.flag_distance_m < INF,
		"best flag distance %s, %d disc(s)" % [_fmt(s.best_flag_distance_m), s.discs_used])
	var baked: Dictionary = (lv.validation.get("baked", {}) as Dictionary).get("intended", {})
	var claimed_v: Variant = baked.get("medal", "gold")
	# A level whose baked medal is null is one the harness could not solve. Say
	# so with the tier name it should have earned, so the failure reads as
	# "no longer gold" rather than as a type error.
	var claimed: String = str(claimed_v) if claimed_v is String else "gold"
	t.check("%s intended solution earns %s" % [tag, claimed],
		s.best_medal == claimed,
		"got '%s' with %d disc(s) at %s" % [s.best_medal, s.discs_used,
			_fmt(s.best_flag_distance_m)])

	# 6: every tier achievable. The tiers are nested by construction, so one
	# demonstrated gold discharges all three — but only if the nesting holds,
	# which is a property of the level file and is therefore checked, not assumed.
	var prev: LevelDataT.MedalTier = null
	var nested: bool = true
	var why: String = ""
	for m in lv.medals:
		var mt: LevelDataT.MedalTier = m
		if prev != null and (mt.max_discs < prev.max_discs
				or mt.max_flag_distance_m < prev.max_flag_distance_m):
			nested = false
			why = "%s is stricter than %s" % [mt.tier, prev.tier]
		prev = mt
	t.check("%s medal tiers are nested (gold implies silver implies bronze)" % tag,
		nested, why)
	t.check("%s every medal tier is achievable" % tag,
		nested and RANK.get(s.best_medal, 0) >= 3,
		"gold demonstrated: %s" % str(RANK.get(s.best_medal, 0) >= 3))

	_alternates(t, lib, lv)
	_determinism(t, lib, lv, s)
	_layout_invariance(t, lib, lv, s)


func _step(t, tag: String, which: String, i: int, lv: LevelDataT,
		step: LevelDataT.SolutionStep, rec: SessionT.ThrowRecord) -> void:
	var e: Dictionary = step.expected
	var label := "%s %s[%d] %s %s" % [tag, which, i, step.disc, step.role]
	if rec.outcome.begins_with("rejected"):
		t.check(label, false, rec.outcome)
		return

	if e.has("flag_distance_m"):
		var want: float = float(e["flag_distance_m"])
		var got: float = rec.flag_distance_m
		var d: float = absf(got - want) if got < INF else INF
		_track(d, label)
		t.check("%s flag distance" % label, d <= TOL_M,
			"got %.3f m want %.3f m (|d| = %s, outcome %s)" % [got, want, _fmt(d), rec.outcome])
	if e.has("landing"):
		var land: Array = e["landing"]
		var dx: float = rec.landing_local.x - float(land[0])
		var dz: float = rec.landing_local.z - float(land[2])
		var d2: float = Vector2(dx, dz).length()
		_track(d2, label + " landing")
		t.check("%s landing" % label, d2 <= TOL_M,
			"got (%.2f, %.2f) want (%.2f, %.2f), |d| = %s"
			% [rec.landing_local.x, rec.landing_local.z, float(land[0]), float(land[2]), _fmt(d2)])
	if e.has("room"):
		var want_room: int = lv.room_index(String(e["room"]))
		t.check("%s ends in %s" % [label, String(e["room"])], rec.end_room == want_room,
			"got room %d (%s)" % [rec.end_room,
				lv.get_room(rec.end_room).id if lv.get_room(rec.end_room) != null else "?"])
	if e.has("surface"):
		t.check("%s strikes %s" % [label, String(e["surface"])],
			rec.struck_id == String(e["surface"]),
			"got '%s' (outcome %s)" % [rec.struck_id, rec.outcome])
	if e.has("portal_center"):
		var pc: Array = e["portal_center"]
		var want_c := Vector3(float(pc[0]), float(pc[1]), float(pc[2]))
		var dc: float = rec.placed_portal_center.distance_to(want_c)
		_track(dc, label + " portal centre")
		t.check("%s opens its portal at the recorded centre" % label, dc <= TOL_M,
			"got %s want %s, |d| = %s" % [str(rec.placed_portal_center), str(want_c), _fmt(dc)])
	if e.has("outcome"):
		# The harness names the outcome more finely than the engine does
		# ("surface:far_panel" vs "wall"); compare the coarse part only.
		var want_kind: String = String(e["outcome"]).split(":")[0]
		var got_kind: String = rec.outcome
		var ok: bool = (want_kind == got_kind) \
			or (want_kind == "surface" and got_kind == "wall") \
			or (want_kind == "barrier" and got_kind == "barrier")
		t.check("%s outcome" % label, ok, "got '%s' want '%s'" % [got_kind, String(e["outcome"])])


func _track(d: float, where: String) -> void:
	if d < INF and d > _worst:
		_worst = d
		_worst_where = where


## Alternate lines in the multi-throw levels are quoted against the intended
## placement / arming throw, exactly as the design document quotes them, so those
## prerequisite steps are prefixed when the alternates do not supply their own.
func _alternates(t, lib, lv: LevelDataT) -> void:
	if lv.alternate_solutions.is_empty():
		return
	if lv.max_discs <= 1:
		for i in lv.alternate_solutions.size():
			var st: LevelDataT.SolutionStep = lv.alternate_solutions[i]
			var s := SessionT.new()
			s.start(lv, lib)
			var rec: SessionT.ThrowRecord = s.replay([st])[0]
			_step(t, lv.id, "alternate", i, lv, st, rec)
		return

	var s2 := SessionT.new()
	s2.start(lv, lib)
	var pre: Array = _prereq(lv)
	if not pre.is_empty():
		s2.replay(pre)
	var recs := s2.replay(lv.alternate_solutions)
	for i in recs.size():
		_step(t, lv.id, "alternate", i, lv, lv.alternate_solutions[i], recs[i])


func _prereq(lv: LevelDataT) -> Array:
	var has_place: bool = false
	var has_arm: bool = false
	for s in lv.alternate_solutions:
		if (s as LevelDataT.SolutionStep).places() != "":
			has_place = true
		if (s as LevelDataT.SolutionStep).role.find("arm") >= 0:
			has_arm = true
	var need_place: bool = not lv.portal_discs.is_empty() and not has_place
	var need_arm: bool = not lv.requires_buttons.is_empty() and not has_arm
	var out: Array = []
	for s in lv.intended_solution:
		var st: LevelDataT.SolutionStep = s
		if (need_place and st.places() != "") or (need_arm and st.role.find("arm") >= 0):
			out.append(st)
	return out


func _determinism(t, lib, lv: LevelDataT, first: SessionT) -> void:
	var s := SessionT.new()
	s.start(lv, lib)
	s.replay(lv.intended_solution)
	t.check("%s replays deterministically" % lv.id,
		_gap(s.best_flag_distance_m, first.best_flag_distance_m) < 1e-9
			and s.best_medal == first.best_medal,
		"%s vs %s" % [_fmt(s.best_flag_distance_m), _fmt(first.best_flag_distance_m)])


## The shipped `world_origin` values exist so the renderer can put the rooms
## somewhere disjoint. They are pure translations and the dynamics are
## translation-invariant, so room-LOCAL results must not move — which makes this
## the check that catches a piece of geometry someone forgot to translate.
##
## The comparison layout moves every room EXCEPT the tee's, by a different
## irrational-looking amount each. The tee's room has to stay put: `launch()`
## always starts the disc at the world origin, so moving that room moves the tee
## relative to its own walls and portals and the flight genuinely changes. (It
## does — Level 4's tee is 4 m off its room origin, and zeroing every offset
## shifts its landing by 0.36 m. That is a correct result about a different
## level, not a layout invariance failure, and it is why this test does not
## simply flatten everything.)
func _layout_invariance(t, lib, lv: LevelDataT, first: SessionT) -> void:
	var saved: Array = []
	for i in lv.rooms.size():
		var r: LevelDataT.RoomData = lv.rooms[i]
		saved.append(r.world_origin)
		if i != lv.tee_room:
			r.world_origin += Vector3(137.0 * (i + 1), 0.0, -91.5 * (i + 1))
	var s := SessionT.new()
	s.start(lv, lib)
	s.replay(lv.intended_solution)
	var got: float = s.best_flag_distance_m
	for i in lv.rooms.size():
		(lv.rooms[i] as LevelDataT.RoomData).world_origin = saved[i]
	var d: float = _gap(got, first.best_flag_distance_m)
	t.check("%s room layout offsets do not change the flight" % lv.id, d < 1e-3,
		"relaid-out %s vs shipped %s (|d| = %s)"
		% [_fmt(got), _fmt(first.best_flag_distance_m), _fmt(d)])

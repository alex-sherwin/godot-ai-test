extends RefCounted

## Track P4's UI logic, headless.
##
## Two things are worth a test here and the rest is looking at pixels:
##
##   1. **The drag really produces the numbers it displays.** `PuzzleAimController`
##      is the single owner of the release parameters — a drag on the 3D view and
##      a typed value in the exact-parameters panel go through the same setters —
##      and the whole "fine-tune, then reproduce" promise rests on that round
##      trip being exact. A screenshot cannot prove it; this can.
##
##   2. **Presentation facts agree with the level data.** Four screens ask
##      `PuzzleLevelFacts` the same questions, and the dive-portal warning in
##      particular has to fire on levels 8, 9 and 10 — where 9 and 10 place a
##      *normal* portal whose fixed exit inverts, so the naive check (does the
##      portal the player opens invert?) gets both wrong.
##
## Everything is preloaded rather than referenced by `class_name`: CI runs the
## suite as a bare `godot --headless --script`, which never populates the global
## script-class cache.

const AimT := preload("res://scripts/ui/puzzle/aim_controller.gd")
const FactsT := preload("res://scripts/ui/puzzle/level_facts.gd")
const ThemeT := preload("res://scripts/ui/puzzle/puzzle_theme.gd")
const LevelLibraryT := preload("res://scripts/puzzle/level_library.gd")
const LevelDataT := preload("res://scripts/puzzle/level_data.gd")

## Levels whose flight ends through an inverting portal. LEVEL_DESIGN §2:
## 8 is the dive itself, 9 places the entry for a fixed inverting exit, 10 does
## the same at the end of a four-mechanic chain.
const DIVE_LEVELS := ["08_the_drop", "09_under_the_lintel", "10_the_gauntlet"]


func run(t: Object, _lib: Object) -> void:
	_aim(t)
	_facts(t)
	_theme(t)


# ============================================================ drag-to-aim ===

func _aim(t: Object) -> void:
	t.suite("puzzle aim controller")

	var aim = AimT.new()
	aim.apply_category("midrange", true)
	aim.set_tee(Vector3.ZERO, Vector3(0, 0, -1))

	# --- the aim drag: a ground point in, a heading and a speed out ------
	# 30 deg right of downrange, 60 m out. Heading zero is -Z and positive is
	# +X (`DiscFlightSim.launch`), so the point is (sin 30, 0, -cos 30) * 60.
	var want_deg := 30.0
	var want_dist := 60.0
	var point := Vector3(sin(deg_to_rad(want_deg)), 0.0, -cos(deg_to_rad(want_deg))) * want_dist
	aim.aim_at_ground(point)
	t.close("a ground point 30 deg right sets aim to 30 deg", aim.heading_deg, want_deg, 0.05, "deg")

	var want_power: float = (want_dist - AimT.CARRY_MIN) / (AimT.CARRY_MAX - AimT.CARRY_MIN)
	t.close("its distance sets the power", aim.power(), want_power, 0.005)

	# The reticle is derived from the same two numbers, so dragging it there and
	# reading it back must land on the same point. This IS the round trip the
	# panel and the drag share.
	var back: Vector3 = aim.reticle_position()
	t.close("the reticle round-trips the drag point", back.distance_to(point), 0.0, 0.02, "m")

	# --- clamping ---------------------------------------------------------
	aim.aim_at_ground(Vector3(80.0, 0.0, -10.0))     # ~83 deg right
	t.close("aim clamps at +45 deg", aim.heading_deg, AimT.HEADING_LIMIT, 1e-4, "deg")
	aim.aim_at_ground(Vector3(-80.0, 0.0, -10.0))
	t.close("aim clamps at -45 deg", aim.heading_deg, -AimT.HEADING_LIMIT, 1e-4, "deg")
	aim.aim_at_ground(Vector3(0.0, 0.0, -500.0))
	t.close("power clamps at full", aim.power(), 1.0, 1e-4)
	t.close("full power is the category's top speed", aim.speed_mps, aim.speed_max, 1e-4, "m/s")

	# --- the shape drag ---------------------------------------------------
	aim.set_hyzer(0.0)
	aim.set_launch(10.0)
	aim.begin_shape(Vector2(400.0, 300.0))
	aim.shape_to(Vector2(500.0, 300.0))              # +100 px across
	t.close("100 px of shape drag is 18 deg of hyzer",
		aim.hyzer_deg, 100.0 * AimT.SHAPE_DEG_PER_PX_X, 1e-4, "deg")
	# Absolute from the press point, not incremental: dragging back to where it
	# started must restore the value, or a slow drag accumulates drift.
	aim.shape_to(Vector2(400.0, 300.0))
	t.close("the shape drag is absolute, not incremental", aim.hyzer_deg, 0.0, 1e-4, "deg")
	aim.shape_to(Vector2(400.0, 200.0))              # 100 px UP
	t.close("dragging up raises the launch angle",
		aim.launch_deg, 10.0 + 100.0 * AimT.SHAPE_DEG_PER_PX_Y, 1e-4, "deg")

	aim.set_hyzer(59.0)
	aim.nudge_hyzer(5.0)
	t.close("the wheel clamps hyzer at the limit", aim.hyzer_deg, AimT.HYZER_LIMIT, 1e-4, "deg")

	# --- the units boundary ----------------------------------------------
	aim.set_speed(21.0)
	aim.set_spin(-18.0)
	aim.set_nose(-2.5)
	aim.set_hyzer(12.0)
	aim.set_launch(7.0)
	aim.set_height(1.2)
	aim.set_heading(-9.0)
	var p = aim.build_params()
	var ok: bool = is_equal_approx(p.speed_mps, 21.0) \
		and is_equal_approx(p.spin_rps, -18.0) \
		and is_equal_approx(p.nose_angle_rad, deg_to_rad(-2.5)) \
		and is_equal_approx(p.hyzer_angle_rad, deg_to_rad(12.0)) \
		and is_equal_approx(p.launch_angle_rad, deg_to_rad(7.0)) \
		and is_equal_approx(p.launch_height_m, 1.2) \
		and is_equal_approx(p.launch_heading_rad, deg_to_rad(-9.0))
	t.check("build_params converts degrees to radians and nothing else", ok,
		"hyzer %.4f rad for 12 deg" % p.hyzer_angle_rad)

	# --- an authored solution loads exactly ------------------------------
	var lib = LevelLibraryT.load_default()
	if lib.size() == 0:
		t.skip("an authored solution loads into the panel", "no level data")
	else:
		var level: LevelDataT = lib.get_index(0)
		var step: LevelDataT.SolutionStep = FactsT.scoring_solution(level)
		if step == null:
			t.skip("an authored solution loads into the panel", "level 1 has no scoring step")
		else:
			var a = AimT.new()
			a.apply_category("midrange", true)
			a.apply_solution(step)
			t.close("the validated line's hyzer loads exactly", a.hyzer_deg, step.hyzer_deg, 1e-4, "deg")
			t.close("the validated line's aim loads exactly", a.heading_deg, step.heading_deg, 1e-4, "deg")
			t.close("the validated line's launch loads exactly", a.launch_deg, step.launch_deg, 1e-4, "deg")

	# A gesture must never produce a value the panel cannot show, or the two
	# disagree the moment the drawer is opened.
	var stress = AimT.new()
	stress.apply_category("distance_driver", true)
	stress.aim_at_ground(Vector3(9999.0, 0.0, 9999.0))
	stress.begin_shape(Vector2.ZERO)
	stress.shape_to(Vector2(-9999.0, 9999.0))
	var q = stress.build_params()
	var in_range: bool = absf(rad_to_deg(q.launch_heading_rad)) <= AimT.HEADING_LIMIT + 1e-6 \
		and absf(rad_to_deg(q.hyzer_angle_rad)) <= AimT.HYZER_LIMIT + 1e-6 \
		and rad_to_deg(q.launch_angle_rad) >= AimT.LAUNCH_MIN - 1e-6 \
		and rad_to_deg(q.launch_angle_rad) <= AimT.LAUNCH_MAX + 1e-6 \
		and q.speed_mps <= stress.speed_max + 1e-6
	t.check("no gesture can produce an out-of-range release", in_range,
		"aim %.1f hyzer %.1f launch %.1f" % [rad_to_deg(q.launch_heading_rad),
			rad_to_deg(q.hyzer_angle_rad), rad_to_deg(q.launch_angle_rad)])

	t.end_suite()


# ====================================================== presentation facts ===

func _facts(t: Object) -> void:
	t.suite("puzzle level facts")

	var lib = LevelLibraryT.load_default()
	if lib.size() == 0:
		t.skip("dive levels are flagged", "no level data in res://data/levels/")
		t.end_suite()
		return

	var flagged: Array = []
	var missing_hint: Array = []
	var missing_objective: Array = []
	for i in lib.size():
		var level: LevelDataT = lib.get_index(i)
		if FactsT.has_dive_portal(level):
			flagged.append(level.id)
		# The hint is the one piece of designer voice the player is offered and
		# the level select shows it on every card, so an empty one is a hole in
		# the screen, not a missing nicety.
		if level.hint.strip_edges().is_empty():
			missing_hint.append(level.id)
		if FactsT.objective_line(level).strip_edges().is_empty():
			missing_objective.append(level.id)

	flagged.sort()
	t.check("the dive warning fires on exactly the levels that dive",
		flagged == DIVE_LEVELS, "flagged: %s (want %s)" % [str(flagged), str(DIVE_LEVELS)])
	t.check("every level has a hint to show", missing_hint.is_empty(),
		"missing: %s" % str(missing_hint))
	t.check("every level has an objective sentence", missing_objective.is_empty(),
		"missing: %s" % str(missing_objective))

	# Level 3 is the gravity level: the HUD has to mark 4.0 m/s^2 as different
	# from standard, because that flag is the only thing separating it visually
	# from 9.81 (LEVEL_DESIGN §2, Featherfall).
	var featherfall: LevelDataT = lib.get_level("03_featherfall")
	if featherfall == null:
		t.skip("odd conditions are flagged", "03_featherfall missing")
	else:
		var odd := 0
		var standard := 0
		for r in featherfall.rooms:
			var c := FactsT.conditions(r)
			if bool(c["gravity_odd"]):
				odd += 1
			else:
				standard += 1
		t.check("Featherfall's low gravity is flagged as non-standard", odd == 1 and standard == 1,
			"%d odd, %d standard" % [odd, standard])

	# Level 2 is the density level.
	var vault: LevelDataT = lib.get_level("02_rarefied_vault")
	if vault != null:
		var thin := false
		for r in vault.rooms:
			if bool(FactsT.conditions(r)["density_odd"]):
				thin = true
		t.check("the Rarefied Vault's thin air is flagged", thin, "")

	# Wind is described by where the air is GOING, which is the opposite of the
	# meteorological convention and the thing a thrower actually needs.
	t.check("a -X wind is described as blowing left",
		FactsT.describe_wind(Vector3(-6, 0, 0)).find("left") >= 0,
		FactsT.describe_wind(Vector3(-6, 0, 0)))
	t.check("calm is called calm", FactsT.describe_wind(Vector3.ZERO) == "calm", "")

	# The font shipped in the web export has no arrows or geometric triangles and
	# draws them as tofu. Caught in a browser screenshot once; asserted here so
	# it cannot come back through a string nobody screenshots.
	var bad := "→←↑↓▶◀▸▾◂▲"
	var offenders: Array = []
	for i in lib.size():
		var level: LevelDataT = lib.get_index(i)
		for room in level.rooms:
			var text := str(FactsT.conditions(room)["wind_text"])
			for c in bad:
				if text.find(c) >= 0:
					offenders.append(level.id)
	for s: String in [FactsT.DIVE_TITLE, FactsT.DIVE_BODY, FactsT.DIVE_SHORT]:
		for c in bad:
			if s.find(c) >= 0:
				offenders.append(s.substr(0, 20))
	t.check("no UI string uses a glyph the export's font lacks", offenders.is_empty(),
		"offenders: %s" % str(offenders))

	t.end_suite()


# =================================================================== theme ===

func _theme(t: Object) -> void:
	t.suite("puzzle theme")

	var theme: Theme = ThemeT.build()
	var missing: Array = []
	# Every variation the UI names. A type variation Godot does not know about
	# falls back silently to the base type, which looks like a styling accident
	# rather than a typo.
	for name: String in ["MedalGold", "MedalSilver", "MedalBronze", "MedalNone",
			"MedalGoldLabel", "MedalSilverLabel", "MedalBronzeLabel", "MedalNoneLabel",
			"MedalGoldBig", "MedalSilverBig", "MedalBronzeBig", "MedalNoneBig",
			"DivePanel", "DiveBanner", "DiveLabel", "DiveTitle", "DiveChip",
			"PortalChip", "PortalChipLabel", "LevelCard", "LevelCardHover",
			"LevelCardCurrent", "ScreenPanel", "HintPanel", "HintLabel",
			"NumberLabel", "ResultTitle", "CardButton", "DiscButton",
			"DisclosureButton"]:
		if String(theme.get_type_variation_base(name)).is_empty():
			missing.append(name)
	t.check("every type variation the puzzle UI names exists", missing.is_empty(),
		"missing: %s" % str(missing))

	# The sandbox variations have to survive, because the puzzle theme is built
	# on top of `FlightLabTheme` rather than forked from it.
	var inherited: Array = []
	for name: String in ["HudPanel", "BarPanel", "DrawerPanel", "OverlayPanel",
			"InsetPanel", "PrimaryButton", "GhostButton", "SegButton",
			"TitleLabel", "SectionLabel", "SmallLabel", "TinyLabel", "ValueLabel"]:
		if String(theme.get_type_variation_base(name)).is_empty():
			inherited.append(name)
	t.check("the sandbox theme is extended, not replaced", inherited.is_empty(),
		"lost: %s" % str(inherited))

	# The dive portal's colour is a legend entry, and a legend with two entries
	# that are the same colour is not a legend.
	t.check("dive orange is nothing like portal blue",
		ThemeT.DIVE.r > 0.8 and ThemeT.DIVE.b < 0.4 and ThemeT.PORTAL.b > 0.8,
		"dive %s portal %s" % [ThemeT.DIVE.to_html(false), ThemeT.PORTAL.to_html(false)])

	t.end_suite()

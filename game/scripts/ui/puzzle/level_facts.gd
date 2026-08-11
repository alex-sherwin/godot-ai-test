class_name PuzzleLevelFacts
extends RefCounted

## Presentation facts derived from a `PuzzleLevelData`: the sentences, the
## colours-worth-of-meaning and the flags four different screens all need.
##
## Track P3 owns the level model and the session; this owns how a level *reads*.
## The split matters because the level select, the in-level HUD, the results
## screen and the aim overlay all ask the same questions — "does this level
## contain a dive portal?", "is this room's air standard?", "what does silver
## cost?" — and answering them in four places is how three of them end up
## disagreeing.
##
## Everything here is static and takes the level (or a room) as an argument.

const LevelDataT := preload("res://scripts/puzzle/level_data.gd")

## The dive numbers, in one place. PORTAL_CONTRACT §6 and LEVEL_DESIGN §0.2
## measured the same effect through two independent harnesses and agree: an
## inverted disc is an inverted wing, lift adds to gravity, and the flight is
## over in under three seconds whatever you threw. The warning appears in four
## places in this UI and every one of them quotes these strings.
const DIVE_TITLE := "DIVE PORTAL — an inverted disc is an inverted wing"
const DIVE_BODY := "This level has a portal mounted upside down. A disc through it comes out inverted, so its lift points DOWN and adds to gravity. Measured: 40-45% of the distance gone, and the flight over in 2.5-2.9 s whatever disc you throw. Enter the frame LOW to come out HIGH and dive further; enter high to come out low and drop short."
## The same warning as a menu legend rather than as a statement about the level
## you are standing in.
const DIVE_LEGEND := "Three of the ten levels are entered through a portal mounted upside down. A disc through one comes out inverted, so its lift points DOWN and adds to gravity: measured, 40-45% of the distance gone and the flight over in 2.5-2.9 s whatever disc you throw. Those levels carry an orange DIVE PORTAL badge below."
const DIVE_SHORT := "Lift points down past this portal: 40-45% shorter, 2.5-2.9 s in the air, any disc."

## Sea-level standard, the reference every room is described against.
const STD_DENSITY := 1.225
const STD_GRAVITY := 9.81


# --------------------------------------------------------------- portals ---

## True if any portal in the level inverts. `PuzzleLevelData` folds `inverting`
## into `PortalData.up` at parse time and marks BOTH ends of the pair, so asking
## any one portal is enough — but levels 9 and 10 place a normal entry portal
## whose fixed exit inverts, so the question has to be asked of the level, never
## of the portal the player is about to open.
static func has_dive_portal(level: LevelDataT) -> bool:
	if level == null:
		return false
	for p in level.portals:
		if (p as LevelDataT.PortalData).inverting:
			return true
	for d in level.portal_discs:
		var disc: LevelDataT.PortalDiscData = d
		if disc.inverting:
			return true
		# The disc opens one end; the level supplies the other. If THAT one
		# inverts, the player's portal leads into a dive.
		var other: LevelDataT.PortalData = level.get_portal(disc.link)
		if other != null and other.inverting:
			return true
	return false


## Does going through THIS aperture dive the disc?
##
## The player only ever sees the end they throw into, and `PuzzleLevelData` marks
## only the end that is physically mounted upside down — Level 8 ships `d1a`
## normal and `d1b` inverting. Colouring `d1a` blue would then hand the player a
## portal that looks ordinary and costs them 40-45% of their distance, which is
## precisely the thing LEVEL_DESIGN §1 says must never happen. So the question
## is asked of the PAIR.
static func portal_dives(level: LevelDataT, portal: LevelDataT.PortalData) -> bool:
	if level == null or portal == null:
		return false
	if portal.inverting:
		return true
	var other: LevelDataT.PortalData = level.get_portal(portal.link)
	return other != null and other.inverting


static func places_portals(level: LevelDataT) -> bool:
	return level != null and not level.portal_discs.is_empty()


static func portal_disc_ids(level: LevelDataT) -> PackedStringArray:
	var out := PackedStringArray()
	if level == null:
		return out
	for d in level.portal_discs:
		out.append((d as LevelDataT.PortalDiscData).id)
	return out


## One row per portal for the legend: what it is called, whether it dives,
## how big it is, and whether the player has to open it.
static func portal_rows(level: LevelDataT) -> Array:
	var rows: Array = []
	if level == null:
		return rows
	for p in level.portals:
		var portal: LevelDataT.PortalData = p
		if not portal.placed_by.is_empty():
			continue
		rows.append({
			"id": portal.id,
			"room": room_name(level, portal.room),
			"dive": portal_dives(level, portal),
			"width": portal.width_m,
			"height": portal.height_m,
			"placed": false,
		})
	for d in level.portal_discs:
		var disc: LevelDataT.PortalDiscData = d
		var other: LevelDataT.PortalData = level.get_portal(disc.link)
		rows.append({
			"id": disc.opens_portal_id,
			"room": "",
			"dive": disc.inverting or (other != null and other.inverting),
			"width": disc.width_m,
			"height": disc.height_m,
			"placed": true,
		})
	return rows


# ----------------------------------------------------------------- rooms ---

static func room_name(level: LevelDataT, index: int) -> String:
	if level == null:
		return ""
	var r: LevelDataT.RoomData = level.get_room(index)
	return r.name if r != null else ""


static func air_density(env: LevelDataT.RoomEnv) -> float:
	if env == null:
		return STD_DENSITY
	if env.density_override > 0.0:
		return env.density_override
	return Atmosphere.air_density(env.altitude_m, env.temperature_c)


## The three readings the player has to be able to compare between rooms, each
## with a flag saying whether it differs from sea-level standard. The flag is
## the point: "4.00 m/s²" and "9.81 m/s²" in the same colour read the same at a
## glance, and one of them is the whole puzzle.
static func conditions(room: LevelDataT.RoomData) -> Dictionary:
	if room == null:
		return {}
	var env: LevelDataT.RoomEnv = room.env
	var rho := air_density(env)
	var g: float = env.gravity if env != null else STD_GRAVITY
	var wind: Vector3 = env.wind if env != null else Vector3.ZERO
	return {
		"wind": wind,
		"wind_text": describe_wind(wind),
		"wind_odd": wind.length() > 0.05,
		"density_text": "%.3f kg/m³" % rho,
		"density_odd": absf(rho - STD_DENSITY) > 0.02,
		"gravity_text": "%.2f m/s²" % g,
		"gravity_odd": absf(g - STD_GRAVITY) > 0.02,
		"note": env.note if env != null else "",
	}


## World frame is -Z downrange and +X to the thrower's right (CONTRACT §1), so
## `(-6, 0, 0)` is a crosswind blowing to the thrower's LEFT. Meteorology would
## call that "wind from the right"; a disc golfer wants to know which way their
## disc is going to be pushed, so this says where the air is going.
static func describe_wind(wind: Vector3) -> String:
	if wind.length() < 0.05:
		return "calm"
	var parts: PackedStringArray = PackedStringArray()
	if absf(wind.x) >= 0.05:
		parts.append("%.1f to the %s" % [absf(wind.x), "right" if wind.x > 0.0 else "left"])
	if absf(wind.z) >= 0.05:
		parts.append("%.1f %s" % [absf(wind.z), "downrange" if wind.z < 0.0 else "into your face"])
	if absf(wind.y) >= 0.05:
		parts.append("%.1f %s" % [absf(wind.y), "UPDRAFT" if wind.y > 0.0 else "DOWNDRAFT"])
	return "%s m/s" % " · ".join(parts)


# ------------------------------------------------------------- objective ---

## The objective in one sentence, in the player's terms. Richer than
## `PuzzleSession.objective_text()` on purpose: this one is read on the level
## card before the session for that level exists, so it has to name the disc
## budget and the buttons itself.
static func objective_line(level: LevelDataT) -> String:
	if level == null:
		return ""
	var discs := "one disc" if level.max_discs == 1 else "at most %d discs" % level.max_discs
	var locks := _and_list(level.requires_buttons)
	match level.objective_type:
		LevelDataT.OBJ_BUTTONS:
			return "Arm %s, then land as close to the flag as you can — in %s." % [locks, discs]
		LevelDataT.OBJ_MIN_DISCS:
			if level.requires_buttons.is_empty():
				return "Reach the flag in as few discs as possible (%s)." % discs
			return "Arm %s, then reach the flag in as few discs as possible (%s)." % [locks, discs]
		_:
			return "Land as close to the flag as you can — in %s." % discs


static func _and_list(items: PackedStringArray) -> String:
	if items.is_empty():
		return "every lock"
	if items.size() == 1:
		return "the `%s` button" % items[0]
	var quoted: PackedStringArray = PackedStringArray()
	for s in items:
		quoted.append("`%s`" % s)
	return "the " + " and ".join(quoted) + " buttons"


# ---------------------------------------------------------------- medals ---

## "2 discs · within 6.0 m" — how a threshold reads on a medal row.
static func medal_line(tier: LevelDataT.MedalTier) -> String:
	if tier == null:
		return ""
	return "%s · within %.1f m" % [
		"1 disc" if tier.max_discs == 1 else "%d discs" % tier.max_discs,
		tier.max_flag_distance_m]


static func medal_summary(level: LevelDataT) -> String:
	if level == null:
		return ""
	var parts: PackedStringArray = PackedStringArray()
	for m in level.medals:
		var tier: LevelDataT.MedalTier = m
		parts.append("%s ≤ %.0f m" % [tier.tier.to_upper(), tier.max_flag_distance_m])
	return "  ".join(parts)


# -------------------------------------------------------------- solutions ---

## The validated release this level ships, preferring the throw that scores.
## A placement throw on its own is not a line the player can aim with.
static func scoring_solution(level: LevelDataT) -> LevelDataT.SolutionStep:
	if level == null:
		return null
	for s in level.intended_solution:
		if (s as LevelDataT.SolutionStep).scores():
			return s
	for s in level.intended_solution:
		return s
	return null

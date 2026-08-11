class_name PuzzleResultsScreen
extends PanelContainer

## What happened, and what to do next. Shown when a throw ends the attempt —
## the disc reached the flag room, or the last disc has been spent.
##
## It is a centred modal over a dimmed view rather than a full screen: the thing
## the player most wants after a throw is to see *where the disc went*, and a
## results panel that covers the landing is a results panel nobody reads.
##
## Four numbers and four buttons, in the order the question is asked: how close,
## how many discs, which medal, what next.

signal retry_requested()
signal next_level_requested()
signal levels_requested()
signal dismissed()

const PT := preload("res://scripts/ui/puzzle/puzzle_theme.gd")
const Facts := preload("res://scripts/ui/puzzle/level_facts.gd")
const LevelDataT := preload("res://scripts/puzzle/level_data.gd")

var _title: Label = null
var _medal_label: Label = null
var _medal_panel: PanelContainer = null
var _next_tier: Label = null
var _distance: Label = null
var _discs: Label = null
var _time: Label = null
var _crossings: Label = null
var _detail: Label = null
var _note_panel: PanelContainer = null
var _note: Label = null
var _next_button: Button = null
var _retry_button: Button = null


func _init() -> void:
	theme_type_variation = "OverlayPanel"
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	margin.add_child(col)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	col.add_child(head)
	_title = Label.new()
	_title.theme_type_variation = "ResultTitle"
	_title.text = "—"
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title)
	_medal_panel = PanelContainer.new()
	_medal_panel.theme_type_variation = "MedalNone"
	_medal_panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_medal_panel)
	_medal_label = Label.new()
	_medal_label.theme_type_variation = "MedalNoneBig"
	_medal_label.text = "—"
	_medal_panel.add_child(_medal_label)

	var stats := HBoxContainer.new()
	stats.add_theme_constant_override("separation", 22)
	col.add_child(stats)
	_distance = UiKit.gauge(stats, "Distance from flag", "—", 168, "HugeValueLabel")
	_discs = UiKit.gauge(stats, "Discs used", "—", 96)
	_time = UiKit.gauge(stats, "Flight time", "—", 96)
	_crossings = UiKit.gauge(stats, "Portals", "—", 76)

	_next_tier = Label.new()
	_next_tier.theme_type_variation = "BodyLabel"
	_next_tier.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_next_tier.custom_minimum_size.x = 40
	col.add_child(_next_tier)

	_detail = Label.new()
	_detail.theme_type_variation = "SmallLabel"
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail.custom_minimum_size.x = 40
	col.add_child(_detail)

	_note_panel = PanelContainer.new()
	_note_panel.theme_type_variation = "WarnPanel"
	_note_panel.visible = false
	col.add_child(_note_panel)
	_note = Label.new()
	_note.theme_type_variation = "WarnLabel"
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.custom_minimum_size.x = 40
	_note_panel.add_child(_note)

	UiKit.hsep(col)

	var actions := HFlowContainer.new()
	actions.add_theme_constant_override("h_separation", 8)
	actions.add_theme_constant_override("v_separation", 6)
	col.add_child(actions)
	_retry_button = UiKit.button(actions, "RETRY", "PrimaryButton", "Throw this level again from the tee.   (R)")
	_retry_button.pressed.connect(func() -> void: retry_requested.emit())
	_next_button = UiKit.button(actions, "Next level", "GhostButton", "Move on.   (N)")
	_next_button.pressed.connect(func() -> void: next_level_requested.emit())
	var levels := UiKit.button(actions, "All levels", "GhostButton", "Back to the level list.   (L)")
	levels.pressed.connect(func() -> void: levels_requested.emit())
	var close := UiKit.button(actions, "Look at the landing", "GhostButton",
		"Dismiss this and keep the view.   (Esc)")
	close.pressed.connect(func() -> void: dismissed.emit())


# ==================================================================== show ===

func show_outcome(level: LevelDataT, outcome: Dictionary, has_next: bool) -> void:
	var medal := str(outcome.get("medal", ""))
	var reached := bool(outcome.get("reached_flag_room", false))
	var distance := float(outcome.get("flag_distance_m", INF))
	var buttons_ok := bool(outcome.get("buttons_ok", true))

	_medal_panel.theme_type_variation = PT.medal_variation(medal)
	_medal_label.theme_type_variation = PT.medal_variation(medal) + "Big"
	_medal_label.text = PT.medal_label(medal)

	if not medal.is_empty():
		_title.text = "%s — %s" % [level.name, PT.medal_label(medal).capitalize()]
	elif reached:
		_title.text = "Landed — no medal yet"
	else:
		_title.text = "Did not reach the flag room"

	_distance.text = "—" if distance >= INF else "%.2f m" % distance
	_discs.text = "%d of %d" % [int(outcome.get("discs_used", 0)),
		int(outcome.get("discs_used", 0)) + int(outcome.get("discs_remaining", 0))]
	_time.text = "%.2f s" % float(outcome.get("flight_time_s", 0.0))
	_crossings.text = "%d" % int(outcome.get("crossings", 0))

	_next_tier.text = _next_tier_text(level, outcome, medal, distance, buttons_ok)
	_detail.text = _detail_text(level, outcome, reached, buttons_ok)
	# The one thing worth interrupting a result for: the throw did not end on the
	# floor. Hitting a wall or a shut barrier is a legal outcome and a real
	# score, but it looks like a bug unless the screen names it.
	_note.text = _blocked_text(level, outcome)
	_note_panel.visible = not _note.text.is_empty()
	_next_button.disabled = not has_next
	visible = true


## What the NEXT tier up would take — one tier, not the top one. A score with no
## next step is a dead end; "3.42 m closer" is a reason to press RETRY.
func _next_tier_text(level: LevelDataT, outcome: Dictionary, medal: String,
		distance: float, buttons_ok: bool) -> String:
	if not buttons_ok:
		return "No medal until every button is armed — this level needs %d." \
			% level.requires_buttons.size()
	if medal == "gold":
		return "Gold. That is the top tier — and LEVEL_DESIGN §5 is explicit that gold is achievable rather than optimal, so a better line almost certainly exists."

	# Tiers come back gold-first. The one to chase is the entry immediately above
	# whatever was earned, which is the last entry when nothing was.
	var tiers: Array = level.medals
	if tiers.is_empty():
		return ""
	var earned_at := tiers.size()
	for i in tiers.size():
		if (tiers[i] as LevelDataT.MedalTier).tier == medal:
			earned_at = i
			break
	var tier: LevelDataT.MedalTier = tiers[maxi(earned_at - 1, 0)]
	var name := PT.medal_label(tier.tier).capitalize()
	var used := int(outcome.get("discs_used", 0))
	if used > tier.max_discs:
		return "%s needs the flag reached in %d disc%s — this attempt used %d." % [
			name, tier.max_discs, "" if tier.max_discs == 1 else "s", used]
	if distance < INF:
		return "%s is %.2f m closer: %s." % [name,
			maxf(distance - tier.max_flag_distance_m, 0.0), Facts.medal_line(tier)]
	return "%s needs %s." % [name, Facts.medal_line(tier)]


## "wall" | "barrier" from `PuzzleSession.ThrowRecord.outcome`.
func _blocked_text(_level: LevelDataT, outcome: Dictionary) -> String:
	match str(outcome.get("outcome", "floor")):
		"wall":
			var struck := str(outcome.get("struck_id", ""))
			return "The disc stopped dead against %s and dropped. Walls are solid; that landing is where it fell." % (
				"a wall" if struck.is_empty() else "`" + struck + "`")
		"barrier":
			return "The disc stopped against a barrier that is still locked. Arm what opens it and the way through clears between throws."
		"timeout", "failed":
			return "The flight did not resolve — that is a simulation failure, not a score."
		_:
			return ""


func _detail_text(level: LevelDataT, outcome: Dictionary, reached: bool,
		buttons_ok: bool) -> String:
	var parts: PackedStringArray = PackedStringArray()
	parts.append("%s landed in %s." % [str(outcome.get("disc_name", "The disc")),
		Facts.room_name(level, int(outcome.get("room", 0)))])
	if not reached:
		parts.append("The flag is in %s." % Facts.room_name(level, level.flag_room))
	var hit: PackedStringArray = outcome.get("buttons_hit", PackedStringArray())
	if not hit.is_empty():
		parts.append("Armed %s." % ", ".join(hit))
	if not buttons_ok:
		parts.append("Still locked.")
	if int(outcome.get("crossings", 0)) > 0:
		parts.append("Crossed %d portal%s." % [int(outcome["crossings"]),
			"" if int(outcome["crossings"]) == 1 else "s"])
	return " ".join(parts)


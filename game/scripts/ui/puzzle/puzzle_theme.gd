class_name PuzzleTheme
extends RefCounted

## Portal-puzzle extension of `FlightLabTheme`.
##
## The sandbox theme is the single source of truth for the palette and for every
## widget style the two modes share, and this file does not fork it: it calls
## `FlightLabTheme.build()` and *adds* the type variations puzzle mode needs on
## top. Same discipline as the sandbox — no node in `scripts/ui/puzzle/` sets a
## `theme_override_*` for anything a theme can express, so restyling puzzle mode
## means editing this file and `flight_lab_theme.gd`, and nothing else.
##
## Three families are new, and each exists because it carries meaning the
## sandbox never had to express:
##
##   * **medals** — gold / silver / bronze / not-yet, on level cards and in the
##     HUD. A player is always chasing a threshold, so the tier has to be a
##     colour, not a word buried in a sentence.
##   * **portal kinds** — a normal portal is the accent blue the rest of the UI
##     already uses; a DIVE portal is orange and never anything else. Level
##     design §1 asks for exactly that pairing and the reason is that a dive
##     portal costs 40-45% of the disc's distance (PORTAL_CONTRACT §6), which no
##     player can infer from geometry.
##   * **objective / hint** — quiet framed copy that reads as guidance rather
##     than as a warning, so the dive warning keeps its loudness to itself.

const T := preload("res://scripts/ui/flight_lab_theme.gd")

# --------------------------------------------------------------- palette ---
# Extends the `flight_lab_theme.gd` palette; everything structural (BG, BORDER,
# TEXT, ACCENT) still comes from there.

const GOLD          := Color("e8c15a")
const GOLD_BG       := Color("2b2311")
const GOLD_BORDER   := Color("7d6427")
const SILVER        := Color("cbd6e4")
const SILVER_BG     := Color("1c232e")
const SILVER_BORDER := Color("4f5d70")
const BRONZE        := Color("d68d4e")
const BRONZE_BG     := Color("2a1a0f")
const BRONZE_BORDER := Color("7d4c23")
const NO_MEDAL      := Color("64748b")

## The dive portal's colour, and it is used for nothing else anywhere in the UI.
const DIVE          := Color("ff9a3c")
const DIVE_BRIGHT   := Color("ffc48a")
const DIVE_BG       := Color("2e1a08")
const DIVE_BORDER   := Color("96591a")

## A normal portal reuses the accent blue, so "blue = ordinary, orange = the
## disc falls out of the sky" is the only colour rule the player has to learn.
const PORTAL        := Color("5aa8ee")
const PORTAL_BRIGHT := Color("a9e4ff")

## Ghost trajectory: bright at the tee, fading to nothing where the prediction
## legitimately stops.
const GHOST         := Color("9fd2ff")
const GHOST_FADE    := Color(0.62, 0.82, 1.0, 0.0)
const AIM           := Color("ffd479")
const BUTTON_ARMED  := Color("6ee7b7")
const BUTTON_IDLE   := Color("e8b04b")


static func medal_color(medal: String) -> Color:
	match medal:
		"gold": return GOLD
		"silver": return SILVER
		"bronze": return BRONZE
		_: return NO_MEDAL


static func medal_variation(medal: String) -> String:
	match medal:
		"gold": return "MedalGold"
		"silver": return "MedalSilver"
		"bronze": return "MedalBronze"
		_: return "MedalNone"


static func medal_label(medal: String) -> String:
	match medal:
		"gold": return "GOLD"
		"silver": return "SILVER"
		"bronze": return "BRONZE"
		_: return "—"


static func build() -> Theme:
	var t: Theme = T.build()
	_medals(t)
	_portals(t)
	_cards(t)
	_buttons(t)
	return t


# ---------------------------------------------------------------- medals ---

static func _medals(t: Theme) -> void:
	var spec := {
		"MedalGold":   [GOLD_BG, GOLD_BORDER, GOLD],
		"MedalSilver": [SILVER_BG, SILVER_BORDER, SILVER],
		"MedalBronze": [BRONZE_BG, BRONZE_BORDER, BRONZE],
		"MedalNone":   [Color(1, 1, 1, 0.03), T.BORDER, NO_MEDAL],
	}
	for name: String in spec:
		var s: Array = spec[name]
		_variation(t, name, "PanelContainer")
		t.set_stylebox("panel", name, T.sb(s[0], 999, 1, s[1], 9, 2))
		# Matching label variation, so a medal chip is one PanelContainer with
		# one Label inside and no per-node colour.
		var label_name: String = name + "Label"
		_variation(t, label_name, "Label")
		t.set_font_size("font_size", label_name, T.FS_TINY)
		t.set_color("font_color", label_name, s[2])
		t.set_color("font_shadow_color", label_name, Color(0, 0, 0, 0))
		t.set_constant("outline_size", label_name, 0)

	# The big medal on the results screen.
	for name: String in ["MedalGold", "MedalSilver", "MedalBronze", "MedalNone"]:
		var big: String = name + "Big"
		_variation(t, big, "Label")
		t.set_font_size("font_size", big, T.FS_HUGE)
		t.set_color("font_color", big, t.get_color("font_color", name + "Label"))
		t.set_color("font_shadow_color", big, Color(0, 0, 0, 0))
		t.set_constant("outline_size", big, 0)


# --------------------------------------------------------------- portals ---

static func _portals(t: Theme) -> void:
	_variation(t, "DivePanel", "PanelContainer")
	var dive := T.sb(DIVE_BG, 7, 1, DIVE_BORDER, 10, 8)
	t.set_stylebox("panel", "DivePanel", dive)

	## The dive warning drawn over the 3D view: opaque enough to read against a
	## bright wall, which a 94%-alpha glass panel is not.
	_variation(t, "DiveBanner", "PanelContainer")
	var banner := T.sb(Color(0.145, 0.082, 0.031, 0.97), 8, 2, DIVE, 12, 8)
	banner.shadow_color = Color(0, 0, 0, 0.5)
	banner.shadow_size = 10
	t.set_stylebox("panel", "DiveBanner", banner)

	_variation(t, "DiveLabel", "Label")
	t.set_font_size("font_size", "DiveLabel", T.FS_SMALL)
	t.set_color("font_color", "DiveLabel", DIVE_BRIGHT)
	t.set_color("font_shadow_color", "DiveLabel", Color(0, 0, 0, 0))
	t.set_constant("outline_size", "DiveLabel", 0)

	_variation(t, "DiveTitle", "Label")
	t.set_font_size("font_size", "DiveTitle", T.FS_SECTION)
	t.set_color("font_color", "DiveTitle", DIVE)
	t.set_color("font_shadow_color", "DiveTitle", Color(0, 0, 0, 0))
	t.set_constant("outline_size", "DiveTitle", 0)

	_variation(t, "PortalChip", "PanelContainer")
	t.set_stylebox("panel", "PortalChip", T.sb(Color(0.145, 0.384, 0.788, 0.22), 999, 1, PORTAL, 9, 2))
	_variation(t, "PortalChipLabel", "Label")
	t.set_font_size("font_size", "PortalChipLabel", T.FS_TINY)
	t.set_color("font_color", "PortalChipLabel", PORTAL_BRIGHT)
	t.set_color("font_shadow_color", "PortalChipLabel", Color(0, 0, 0, 0))
	t.set_constant("outline_size", "PortalChipLabel", 0)

	_variation(t, "DiveChip", "PanelContainer")
	t.set_stylebox("panel", "DiveChip", T.sb(Color(0.6, 0.32, 0.06, 0.35), 999, 1, DIVE, 9, 2))


# ----------------------------------------------------------------- cards ---

static func _cards(t: Theme) -> void:
	_variation(t, "LevelCard", "PanelContainer")
	t.set_stylebox("panel", "LevelCard", T.sb(Color(1, 1, 1, 0.035), 9, 1, T.BORDER, 12, 10))

	_variation(t, "LevelCardHover", "PanelContainer")
	t.set_stylebox("panel", "LevelCardHover", T.sb(Color(1, 1, 1, 0.075), 9, 1, T.BORDER_BRIGHT, 12, 10))

	_variation(t, "LevelCardCurrent", "PanelContainer")
	t.set_stylebox("panel", "LevelCardCurrent", T.sb(Color(0.145, 0.384, 0.788, 0.22), 9, 1, T.ACCENT, 12, 10))

	## The level-select backdrop covers the 3D view completely on purpose — it is
	## a menu, not an overlay, and a see-through menu over a lit 3D scene was the
	## single most-reported legibility defect in the sandbox's early screenshots.
	_variation(t, "ScreenPanel", "PanelContainer")
	t.set_stylebox("panel", "ScreenPanel", T.sb(Color("070a11"), 0, 0, T.BORDER, 0, 0))

	_variation(t, "HintPanel", "PanelContainer")
	t.set_stylebox("panel", "HintPanel", T.sb(Color(0.145, 0.384, 0.788, 0.10), 6, 1,
		Color(0.35, 0.55, 0.85, 0.45), 9, 7))

	_variation(t, "HintLabel", "Label")
	t.set_font_size("font_size", "HintLabel", T.FS_SMALL)
	t.set_color("font_color", "HintLabel", Color("bcd8f6"))
	t.set_color("font_shadow_color", "HintLabel", Color(0, 0, 0, 0))
	t.set_constant("outline_size", "HintLabel", 0)

	_variation(t, "NumberLabel", "Label")
	t.set_font_size("font_size", "NumberLabel", 20)
	t.set_color("font_color", "NumberLabel", T.TEXT_FAINT)
	t.set_color("font_shadow_color", "NumberLabel", Color(0, 0, 0, 0))
	t.set_constant("outline_size", "NumberLabel", 0)

	## The results headline.
	_variation(t, "ResultTitle", "Label")
	t.set_font_size("font_size", "ResultTitle", 26)
	t.set_color("font_color", "ResultTitle", T.TEXT)
	t.set_color("font_shadow_color", "ResultTitle", Color(0, 0, 0, 0))
	t.set_constant("outline_size", "ResultTitle", 0)


# --------------------------------------------------------------- buttons ---

static func _buttons(t: Theme) -> void:
	## A whole level card is one Button, so it can be focused, hovered and
	## keyboard-activated without a hand-rolled input handler.
	_variation(t, "CardButton", "Button")
	t.set_stylebox("normal", "CardButton", T.sb(Color(1, 1, 1, 0.035), 9, 1, T.BORDER, 12, 10))
	t.set_stylebox("hover", "CardButton", T.sb(Color(1, 1, 1, 0.085), 9, 1, T.BORDER_BRIGHT, 12, 10))
	t.set_stylebox("pressed", "CardButton", T.sb(Color(0.145, 0.384, 0.788, 0.30), 9, 1, T.ACCENT, 12, 10))
	t.set_stylebox("focus", "CardButton", T.sb(Color(0, 0, 0, 0), 9, 1, T.ACCENT, 12, 10))

	## Disc picker cells in the HUD.
	_variation(t, "DiscButton", "Button")
	t.set_stylebox("normal", "DiscButton", T.sb(Color(1, 1, 1, 0.04), 6, 1, T.BORDER, 10, 4))
	t.set_stylebox("hover", "DiscButton", T.sb(Color(1, 1, 1, 0.10), 6, 1, T.BORDER_BRIGHT, 10, 4))
	t.set_stylebox("pressed", "DiscButton", T.sb(Color(0.145, 0.384, 0.788, 0.55), 6, 1, T.ACCENT, 10, 4))
	t.set_stylebox("focus", "DiscButton", T.sb_empty(10, 4))
	t.set_color("font_color", "DiscButton", T.TEXT_DIM)
	t.set_color("font_hover_color", "DiscButton", T.TEXT)
	t.set_color("font_pressed_color", "DiscButton", Color.WHITE)
	t.set_font_size("font_size", "DiscButton", T.FS_SMALL)

	## The advanced-panel disclosure. Reads as a header, behaves as a button.
	_variation(t, "DisclosureButton", "Button")
	t.set_stylebox("normal", "DisclosureButton", T.sb(Color(1, 1, 1, 0.03), 6, 1, T.BORDER, 9, 5))
	t.set_stylebox("hover", "DisclosureButton", T.sb(Color(1, 1, 1, 0.08), 6, 1, T.BORDER_BRIGHT, 9, 5))
	t.set_stylebox("pressed", "DisclosureButton", T.sb(Color(1, 1, 1, 0.10), 6, 1, T.ACCENT, 9, 5))
	t.set_stylebox("focus", "DisclosureButton", T.sb_empty(9, 5))
	t.set_color("font_color", "DisclosureButton", T.ACCENT)
	t.set_color("font_hover_color", "DisclosureButton", T.ACCENT_BRIGHT)
	t.set_font_size("font_size", "DisclosureButton", T.FS_SECTION)


static func _variation(t: Theme, name: String, base: String) -> void:
	t.add_type(name)
	t.set_type_variation(name, base)

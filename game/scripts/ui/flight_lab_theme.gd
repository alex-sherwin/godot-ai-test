class_name FlightLabTheme
extends RefCounted

## The single Theme resource every UI node in the panel draws from.
##
## Built in code rather than hand-authored as a .tres so there is exactly one
## source of truth for the palette. `ControlPanel` assigns the result to its
## root Control once, and Godot's theme propagation does the rest — no node in
## `scripts/ui/` sets a `theme_override_*` for anything the theme can express.
##
## The palette is lifted verbatim from `web/src/style.css` so the Godot canvas
## and the Vite landing page that links to it read as one product.
##
## Look: dark, instrument-like, high contrast. Flat panels, 1px hairline
## borders, a single blue accent, and colour used only where it carries meaning
## (flight numbers, provenance, out-of-spec warnings).

# --------------------------------------------------------------- palette ---
# Matches web/src/style.css :root.
const BG           := Color("080b12")
const BG_RAISED    := Color("0f1420")
const BG_INSET     := Color("0a0e17")
const BORDER       := Color("1e2738")
const BORDER_BRIGHT:= Color("33405a")
const TEXT         := Color("e6ecf5")
const TEXT_DIM     := Color("94a3b8")
const TEXT_FAINT   := Color("64748b")
const ACCENT       := Color("5aa8ee")
const ACCENT_BRIGHT:= Color("a9e4ff")
const ACCENT_DEEP  := Color("2563c9")
const WARN_BG      := Color("2a1d10")
const WARN_BORDER  := Color("6b4a1f")
const WARN_TEXT    := Color("f2c98a")
const BAD_BG       := Color("2b1216")
const BAD_BORDER   := Color("7a2b35")
const BAD_TEXT     := Color("fca5a5")
const OK_BG        := Color("0d2620")
const OK_BORDER    := Color("2b6b57")
const OK_TEXT      := Color("6ee7b7")
const ON_ACCENT    := Color("061020")

## Drawer / HUD backgrounds sit over the 3D view, so they carry alpha.
const GLASS        := Color(0.031, 0.043, 0.071, 0.94)
const GLASS_LIGHT  := Color(0.043, 0.055, 0.086, 0.90)

## Flight-number chip colours. The retail convention is four coloured cells in
## speed / glide / turn / fade order; these are the same hues pushed to values
## that stay legible on a dark background with dark text on top.
const CHIP_SPEED := Color("6cb2f0")
const CHIP_GLIDE := Color("5fd39a")
const CHIP_TURN  := Color("e8b04b")
const CHIP_FADE  := Color("ef7d7d")

# ------------------------------------------------------------ font sizes ---
const FS_BASE := 13
const FS_SMALL := 11
const FS_TINY := 10
const FS_SECTION := 12
const FS_TITLE := 16
const FS_BIG := 22
const FS_HUGE := 30


static func build() -> Theme:
	var t := Theme.new()
	t.default_font_size = FS_BASE

	_labels(t)
	_panels(t)
	_buttons(t)
	_sliders(t)
	_inputs(t)
	_tabs(t)
	_scrollbars(t)
	_misc(t)
	return t


# ---------------------------------------------------------------- helpers ---

static func sb(bg: Color, radius: int = 6, border: int = 0,
		border_color: Color = BORDER, margin_h: int = 8, margin_v: int = 5) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	s.set_border_width_all(border)
	s.border_color = border_color
	s.content_margin_left = margin_h
	s.content_margin_right = margin_h
	s.content_margin_top = margin_v
	s.content_margin_bottom = margin_v
	return s


static func sb_empty(margin_h: int = 0, margin_v: int = 0) -> StyleBoxEmpty:
	var s := StyleBoxEmpty.new()
	s.content_margin_left = margin_h
	s.content_margin_right = margin_h
	s.content_margin_top = margin_v
	s.content_margin_bottom = margin_v
	return s


static func _variation(t: Theme, name: String, base: String) -> void:
	t.add_type(name)
	t.set_type_variation(name, base)


# ----------------------------------------------------------------- labels ---

static func _labels(t: Theme) -> void:
	t.set_color("font_color", "Label", TEXT)
	t.set_color("font_shadow_color", "Label", Color(0, 0, 0, 0))
	t.set_color("font_outline_color", "Label", Color(0, 0, 0, 0))
	t.set_constant("outline_size", "Label", 0)
	t.set_font_size("font_size", "Label", FS_BASE)

	var variations := {
		# name:            [font_size,   colour]
		"TitleLabel":      [FS_TITLE,    TEXT],
		"SectionLabel":    [FS_SECTION,  ACCENT],
		"DimLabel":        [FS_BASE,     TEXT_DIM],
		"SmallLabel":      [FS_SMALL,    TEXT_DIM],
		"TinyLabel":       [FS_TINY,     TEXT_FAINT],
		"FaintLabel":      [FS_SMALL,    TEXT_FAINT],
		"ValueLabel":      [FS_BASE,     ACCENT_BRIGHT],
		"BigValueLabel":   [FS_BIG,      TEXT],
		"HugeValueLabel":  [FS_HUGE,     ACCENT_BRIGHT],
		"WarnLabel":       [FS_SMALL,    WARN_TEXT],
		"BadLabel":        [FS_SMALL,    BAD_TEXT],
		"OkLabel":         [FS_SMALL,    OK_TEXT],
		"BodyLabel":       [FS_SMALL,    TEXT_DIM],
	}
	for name: String in variations:
		_variation(t, name, "Label")
		var spec: Array = variations[name]
		t.set_font_size("font_size", name, spec[0])
		t.set_color("font_color", name, spec[1])
		t.set_color("font_shadow_color", name, Color(0, 0, 0, 0))
		t.set_constant("outline_size", name, 0)

	# Section headers get a little letter-spacing feel via all-caps at call
	# sites; the theme only carries size and colour.


# ----------------------------------------------------------------- panels ---

static func _panels(t: Theme) -> void:
	t.set_stylebox("panel", "PanelContainer", sb(BG_RAISED, 8, 1, BORDER, 10, 8))
	t.set_stylebox("panel", "Panel", sb(BG_RAISED, 8, 1, BORDER, 0, 0))

	_variation(t, "DrawerPanel", "PanelContainer")
	var drawer := sb(GLASS, 10, 1, BORDER_BRIGHT, 0, 0)
	drawer.shadow_color = Color(0, 0, 0, 0.5)
	drawer.shadow_size = 12
	t.set_stylebox("panel", "DrawerPanel", drawer)

	# The provenance overlay sits on top of the drawer, so it is fully opaque —
	# stacking two 94% panels still lets the text underneath show through.
	_variation(t, "OverlayPanel", "PanelContainer")
	var overlay := sb(Color("0a0f18"), 10, 1, BORDER_BRIGHT, 0, 0)
	overlay.shadow_color = Color(0, 0, 0, 0.6)
	overlay.shadow_size = 14
	t.set_stylebox("panel", "OverlayPanel", overlay)

	_variation(t, "HudPanel", "PanelContainer")
	var hud := sb(GLASS, 8, 1, BORDER, 12, 9)
	hud.shadow_color = Color(0, 0, 0, 0.45)
	hud.shadow_size = 8
	t.set_stylebox("panel", "HudPanel", hud)

	_variation(t, "BarPanel", "PanelContainer")
	t.set_stylebox("panel", "BarPanel", sb(GLASS_LIGHT, 8, 1, BORDER, 10, 8))

	_variation(t, "CardPanel", "PanelContainer")
	t.set_stylebox("panel", "CardPanel", sb(Color(1, 1, 1, 0.028), 8, 1, BORDER, 10, 9))

	_variation(t, "InsetPanel", "PanelContainer")
	t.set_stylebox("panel", "InsetPanel", sb(BG_INSET, 6, 1, BORDER, 8, 7))

	_variation(t, "RowPanel", "PanelContainer")
	t.set_stylebox("panel", "RowPanel", sb(Color(1, 1, 1, 0.022), 7, 1, Color(1, 1, 1, 0.05), 9, 7))

	_variation(t, "RowPanelHover", "PanelContainer")
	t.set_stylebox("panel", "RowPanelHover", sb(Color(1, 1, 1, 0.055), 7, 1, BORDER_BRIGHT, 9, 7))

	_variation(t, "RowPanelSelected", "PanelContainer")
	var sel := sb(Color(0.145, 0.384, 0.788, 0.28), 7, 1, ACCENT, 9, 7)
	t.set_stylebox("panel", "RowPanelSelected", sel)

	_variation(t, "WarnPanel", "PanelContainer")
	t.set_stylebox("panel", "WarnPanel", sb(WARN_BG, 6, 1, WARN_BORDER, 9, 7))

	_variation(t, "BadPanel", "PanelContainer")
	t.set_stylebox("panel", "BadPanel", sb(BAD_BG, 6, 1, BAD_BORDER, 9, 7))

	_variation(t, "OkPanel", "PanelContainer")
	t.set_stylebox("panel", "OkPanel", sb(OK_BG, 6, 1, OK_BORDER, 9, 7))

	_variation(t, "PlainPanel", "PanelContainer")
	t.set_stylebox("panel", "PlainPanel", sb_empty(0, 0))

	# Provenance badges.
	_variation(t, "BadgeMeasured", "PanelContainer")
	t.set_stylebox("panel", "BadgeMeasured", sb(OK_BG, 999, 1, OK_BORDER, 7, 1))
	_variation(t, "BadgeDerived", "PanelContainer")
	t.set_stylebox("panel", "BadgeDerived", sb(Color("1a2233"), 999, 1, BORDER_BRIGHT, 7, 1))

	t.set_stylebox("panel", "PopupPanel", sb(Color("0b111c"), 10, 1, BORDER_BRIGHT, 6, 6))


# ---------------------------------------------------------------- buttons ---

static func _buttons(t: Theme) -> void:
	var normal := sb(Color(1, 1, 1, 0.05), 7, 1, BORDER, 12, 7)
	var hover := sb(Color(1, 1, 1, 0.10), 7, 1, BORDER_BRIGHT, 12, 7)
	var pressed := sb(Color(0.145, 0.384, 0.788, 0.45), 7, 1, ACCENT, 12, 7)
	var disabled := sb(Color(1, 1, 1, 0.02), 7, 1, Color(1, 1, 1, 0.05), 12, 7)
	var focus := sb(Color(0, 0, 0, 0), 7, 1, ACCENT, 12, 7)

	t.set_stylebox("normal", "Button", normal)
	t.set_stylebox("hover", "Button", hover)
	t.set_stylebox("pressed", "Button", pressed)
	t.set_stylebox("disabled", "Button", disabled)
	t.set_stylebox("focus", "Button", focus)
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_hover_color", "Button", Color.WHITE)
	t.set_color("font_pressed_color", "Button", Color.WHITE)
	t.set_color("font_focus_color", "Button", TEXT)
	t.set_color("font_disabled_color", "Button", TEXT_FAINT)
	t.set_font_size("font_size", "Button", FS_BASE)
	t.set_constant("outline_size", "Button", 0)

	# Primary — the Throw button. Accent fill, dark text, like .btn-primary.
	_variation(t, "PrimaryButton", "Button")
	t.set_stylebox("normal", "PrimaryButton", sb(ACCENT, 8, 1, ACCENT_BRIGHT, 18, 11))
	t.set_stylebox("hover", "PrimaryButton", sb(ACCENT_BRIGHT, 8, 1, Color.WHITE, 18, 11))
	t.set_stylebox("pressed", "PrimaryButton", sb(ACCENT_DEEP, 8, 1, ACCENT, 18, 11))
	t.set_stylebox("disabled", "PrimaryButton", sb(Color(0.35, 0.42, 0.52, 0.5), 8, 1, BORDER, 18, 11))
	t.set_stylebox("focus", "PrimaryButton", sb(Color(0, 0, 0, 0), 8, 2, Color.WHITE, 18, 11))
	t.set_color("font_color", "PrimaryButton", ON_ACCENT)
	t.set_color("font_hover_color", "PrimaryButton", ON_ACCENT)
	t.set_color("font_pressed_color", "PrimaryButton", Color.WHITE)
	t.set_color("font_focus_color", "PrimaryButton", ON_ACCENT)
	t.set_color("font_disabled_color", "PrimaryButton", Color(0.1, 0.14, 0.2))
	t.set_font_size("font_size", "PrimaryButton", 15)

	# Ghost — quiet secondary actions.
	_variation(t, "GhostButton", "Button")
	t.set_stylebox("normal", "GhostButton", sb(Color(1, 1, 1, 0.03), 7, 1, BORDER, 10, 6))
	t.set_stylebox("hover", "GhostButton", sb(Color(1, 1, 1, 0.08), 7, 1, BORDER_BRIGHT, 10, 6))
	t.set_stylebox("pressed", "GhostButton", sb(Color(1, 1, 1, 0.12), 7, 1, ACCENT, 10, 6))
	t.set_color("font_color", "GhostButton", TEXT_DIM)
	t.set_color("font_hover_color", "GhostButton", TEXT)
	t.set_font_size("font_size", "GhostButton", FS_SMALL)

	# Segmented — camera view switcher. Toggle buttons, tight.
	_variation(t, "SegButton", "Button")
	t.set_stylebox("normal", "SegButton", sb(Color(1, 1, 1, 0.03), 6, 1, BORDER, 9, 5))
	t.set_stylebox("hover", "SegButton", sb(Color(1, 1, 1, 0.09), 6, 1, BORDER_BRIGHT, 9, 5))
	t.set_stylebox("pressed", "SegButton", sb(Color(0.145, 0.384, 0.788, 0.55), 6, 1, ACCENT, 9, 5))
	t.set_stylebox("focus", "SegButton", sb_empty(9, 5))
	t.set_color("font_color", "SegButton", TEXT_DIM)
	t.set_color("font_hover_color", "SegButton", TEXT)
	t.set_color("font_pressed_color", "SegButton", Color.WHITE)
	t.set_font_size("font_size", "SegButton", FS_SMALL)

	# Tiny square icon buttons (drawer collapse, info).
	_variation(t, "IconButton", "Button")
	t.set_stylebox("normal", "IconButton", sb(Color(1, 1, 1, 0.04), 6, 1, BORDER, 7, 3))
	t.set_stylebox("hover", "IconButton", sb(Color(1, 1, 1, 0.10), 6, 1, BORDER_BRIGHT, 7, 3))
	t.set_stylebox("pressed", "IconButton", sb(Color(1, 1, 1, 0.14), 6, 1, ACCENT, 7, 3))
	t.set_stylebox("focus", "IconButton", sb_empty(7, 3))
	t.set_color("font_color", "IconButton", TEXT_DIM)
	t.set_color("font_hover_color", "IconButton", ACCENT_BRIGHT)
	t.set_font_size("font_size", "IconButton", FS_BASE)

	# Drawer handle. It is the one button drawn straight over the 3D view with
	# no panel behind it, so it carries its own opaque background — a 3% white
	# wash vanishes against a bright sky.
	_variation(t, "HandleButton", "Button")
	var handle := sb(GLASS, 8, 1, BORDER_BRIGHT, 14, 8)
	handle.shadow_color = Color(0, 0, 0, 0.45)
	handle.shadow_size = 8
	t.set_stylebox("normal", "HandleButton", handle)
	t.set_stylebox("hover", "HandleButton", sb(Color(0.09, 0.13, 0.20, 0.97), 8, 1, ACCENT, 14, 8))
	t.set_stylebox("pressed", "HandleButton", sb(Color(0.145, 0.384, 0.788, 0.85), 8, 1, ACCENT, 14, 8))
	t.set_stylebox("focus", "HandleButton", sb_empty(14, 8))
	t.set_color("font_color", "HandleButton", TEXT)
	t.set_color("font_hover_color", "HandleButton", ACCENT_BRIGHT)
	t.set_font_size("font_size", "HandleButton", FS_SMALL)

	# Roster row — a Button styled as a flat selectable card.
	_variation(t, "RowButton", "Button")
	t.set_stylebox("normal", "RowButton", sb(Color(1, 1, 1, 0.022), 7, 1, Color(1, 1, 1, 0.05), 9, 7))
	t.set_stylebox("hover", "RowButton", sb(Color(1, 1, 1, 0.065), 7, 1, BORDER_BRIGHT, 9, 7))
	t.set_stylebox("pressed", "RowButton", sb(Color(0.145, 0.384, 0.788, 0.30), 7, 1, ACCENT, 9, 7))
	t.set_stylebox("focus", "RowButton", sb(Color(0, 0, 0, 0), 7, 1, ACCENT, 9, 7))

	# CheckButton / CheckBox keep their default icons; only text colour matters.
	for type in ["CheckButton", "CheckBox"]:
		t.set_color("font_color", type, TEXT_DIM)
		t.set_color("font_hover_color", type, TEXT)
		t.set_color("font_pressed_color", type, ACCENT_BRIGHT)
		t.set_font_size("font_size", type, FS_SMALL)
		t.set_stylebox("normal", type, sb_empty(4, 3))
		t.set_stylebox("hover", type, sb_empty(4, 3))
		t.set_stylebox("pressed", type, sb_empty(4, 3))
		t.set_stylebox("focus", type, sb_empty(4, 3))


# ---------------------------------------------------------------- sliders ---

static func _sliders(t: Theme) -> void:
	for type in ["HSlider", "VSlider"]:
		var track := sb(Color("18202f"), 3, 1, Color(1, 1, 1, 0.05), 0, 0)
		track.content_margin_top = 3
		track.content_margin_bottom = 3
		t.set_stylebox("slider", type, track)
		var area := sb(ACCENT_DEEP, 3, 0, BORDER, 0, 0)
		t.set_stylebox("grabber_area", type, area)
		var area_hi := sb(ACCENT, 3, 0, BORDER, 0, 0)
		t.set_stylebox("grabber_area_highlight", type, area_hi)
		t.set_constant("center_grabber", type, 0)
		t.set_constant("grabber_offset", type, 0)


# ----------------------------------------------------------------- inputs ---

static func _inputs(t: Theme) -> void:
	t.set_stylebox("normal", "LineEdit", sb(BG_INSET, 6, 1, BORDER, 8, 4))
	t.set_stylebox("focus", "LineEdit", sb(BG_INSET, 6, 1, ACCENT, 8, 4))
	t.set_stylebox("read_only", "LineEdit", sb(Color(1, 1, 1, 0.02), 6, 1, BORDER, 8, 4))
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_color("font_uneditable_color", "LineEdit", TEXT_DIM)
	t.set_color("font_placeholder_color", "LineEdit", TEXT_FAINT)
	t.set_color("caret_color", "LineEdit", ACCENT_BRIGHT)
	t.set_color("selection_color", "LineEdit", Color(0.145, 0.384, 0.788, 0.6))
	t.set_font_size("font_size", "LineEdit", FS_SMALL)

	t.set_color("font_color", "SpinBox", TEXT)
	t.set_font_size("font_size", "SpinBox", FS_SMALL)

	# OptionButton inherits Button styles; give it a slightly tighter box and
	# a dim popup.
	t.set_color("font_color", "OptionButton", TEXT)
	t.set_font_size("font_size", "OptionButton", FS_SMALL)
	t.set_stylebox("normal", "OptionButton", sb(BG_INSET, 6, 1, BORDER, 9, 5))
	t.set_stylebox("hover", "OptionButton", sb(Color(1, 1, 1, 0.08), 6, 1, BORDER_BRIGHT, 9, 5))
	t.set_stylebox("pressed", "OptionButton", sb(Color(1, 1, 1, 0.10), 6, 1, ACCENT, 9, 5))
	t.set_stylebox("focus", "OptionButton", sb(Color(0, 0, 0, 0), 6, 1, ACCENT, 9, 5))

	t.set_stylebox("panel", "PopupMenu", sb(Color("0b111c"), 8, 1, BORDER_BRIGHT, 4, 4))
	t.set_stylebox("hover", "PopupMenu", sb(Color(0.145, 0.384, 0.788, 0.35), 5, 0, BORDER, 6, 3))
	t.set_color("font_color", "PopupMenu", TEXT)
	t.set_color("font_hover_color", "PopupMenu", Color.WHITE)
	t.set_font_size("font_size", "PopupMenu", FS_SMALL)


# ------------------------------------------------------------------- tabs ---

static func _tabs(t: Theme) -> void:
	t.set_stylebox("panel", "TabContainer", sb_empty(0, 0))
	t.set_stylebox("tabbar_background", "TabContainer", sb_empty(0, 0))
	t.set_stylebox("tab_selected", "TabContainer", sb(Color(0.145, 0.384, 0.788, 0.30), 6, 1, ACCENT, 10, 5))
	t.set_stylebox("tab_unselected", "TabContainer", sb(Color(1, 1, 1, 0.02), 6, 1, Color(1, 1, 1, 0.04), 10, 5))
	t.set_stylebox("tab_hovered", "TabContainer", sb(Color(1, 1, 1, 0.07), 6, 1, BORDER_BRIGHT, 10, 5))
	t.set_stylebox("tab_focus", "TabContainer", sb_empty(10, 5))
	t.set_color("font_selected_color", "TabContainer", Color.WHITE)
	t.set_color("font_unselected_color", "TabContainer", TEXT_DIM)
	t.set_color("font_hovered_color", "TabContainer", TEXT)
	t.set_font_size("font_size", "TabContainer", FS_SMALL)
	t.set_constant("side_margin", "TabContainer", 0)

	t.set_stylebox("tab_selected", "TabBar", sb(Color(0.145, 0.384, 0.788, 0.30), 6, 1, ACCENT, 10, 5))
	t.set_stylebox("tab_unselected", "TabBar", sb(Color(1, 1, 1, 0.02), 6, 1, Color(1, 1, 1, 0.04), 10, 5))
	t.set_stylebox("tab_hovered", "TabBar", sb(Color(1, 1, 1, 0.07), 6, 1, BORDER_BRIGHT, 10, 5))
	t.set_stylebox("tab_focus", "TabBar", sb_empty(10, 5))
	t.set_color("font_selected_color", "TabBar", Color.WHITE)
	t.set_color("font_unselected_color", "TabBar", TEXT_DIM)
	t.set_color("font_hovered_color", "TabBar", TEXT)
	t.set_font_size("font_size", "TabBar", FS_SMALL)


# ------------------------------------------------------------- scrollbars ---

static func _scrollbars(t: Theme) -> void:
	for type in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", type, sb(Color(1, 1, 1, 0.03), 4, 0, BORDER, 0, 0))
		t.set_stylebox("scroll_focus", type, sb(Color(1, 1, 1, 0.03), 4, 0, BORDER, 0, 0))
		t.set_stylebox("grabber", type, sb(Color(1, 1, 1, 0.16), 4, 0, BORDER, 0, 0))
		t.set_stylebox("grabber_highlight", type, sb(ACCENT, 4, 0, BORDER, 0, 0))
		t.set_stylebox("grabber_pressed", type, sb(ACCENT_BRIGHT, 4, 0, BORDER, 0, 0))


# ------------------------------------------------------------------- misc ---

static func _misc(t: Theme) -> void:
	var sep := StyleBoxLine.new()
	sep.color = BORDER
	sep.thickness = 1
	t.set_stylebox("separator", "HSeparator", sep)
	t.set_constant("separation", "HSeparator", 6)

	var vsep := StyleBoxLine.new()
	vsep.color = BORDER
	vsep.thickness = 1
	vsep.vertical = true
	t.set_stylebox("separator", "VSeparator", vsep)
	t.set_constant("separation", "VSeparator", 6)

	t.set_stylebox("background", "ProgressBar", sb(BG_INSET, 4, 1, BORDER, 0, 0))
	t.set_stylebox("fill", "ProgressBar", sb(ACCENT_DEEP, 4, 0, BORDER, 0, 0))
	t.set_color("font_color", "ProgressBar", TEXT_DIM)
	t.set_font_size("font_size", "ProgressBar", FS_TINY)

	t.set_constant("separation", "BoxContainer", 6)
	t.set_constant("h_separation", "GridContainer", 10)
	t.set_constant("v_separation", "GridContainer", 5)
	t.set_constant("h_separation", "HFlowContainer", 6)
	t.set_constant("v_separation", "HFlowContainer", 6)

	t.set_stylebox("panel", "TooltipPanel", sb(Color("0b111c"), 6, 1, BORDER_BRIGHT, 8, 5))
	t.set_color("font_color", "TooltipLabel", TEXT)
	t.set_font_size("font_size", "TooltipLabel", FS_SMALL)

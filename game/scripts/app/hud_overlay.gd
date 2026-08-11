class_name HudOverlay
extends Control

## The 2D layer Track C owns: live telemetry, the angle-of-attack trace, the
## ghost-trail legend, and — only when Track D's control panel is absent — a
## minimal debug panel so the scene is independently testable.
##
## Alpha gets its own strip chart because alpha is the whole story. CM(alpha)
## changes sign somewhere around 5-10 degrees, and that sign change IS turn
## becoming fade (CONTRACT §5). Watching alpha climb through the flight while
## the trail bends the other way is the clearest available demonstration that
## the model is doing physics rather than replaying a curve.
##
## The panel keeps to one corner and can be toggled with H, because Track D owns
## the other side of the screen and its layout is not knowable from here.

const PAD := 12.0
const ROW := 17.0
const CHART_W := 268.0
const CHART_H := 62.0
const ALPHA_MIN_DEG := -12.0
const ALPHA_MAX_DEG := 42.0
const MAX_SAMPLES := 900

signal debug_throw_requested()
signal debug_clear_requested()
signal debug_vectors_toggled(on: bool)
signal debug_view_requested(view: String)
signal debug_disc_cycled(delta: int)

var show_panel: bool = true
## Compact mode: Track D's panel already shows the status line, the shortcut
## hints and the live telemetry, so when it is present this drops to the two
## things it does NOT provide — the angle-of-attack trace and the ghost-trail
## legend — and moves clear of their chrome. Duplicated readouts on top of each
## other are worse than no readouts.
var compact: bool = false

var _font: Font = null
var _telemetry: Dictionary = {}
var _legend: Array = []
var _live_color: Color = Color.WHITE
var _status: String = ""
var _alpha_samples := PackedVector2Array()   ## (t, alpha_deg)
var _hint: String = ""
var _prefer_right: bool = true
var _debug_panel: Control = null


func _ready() -> void:
	# Anchors alone leave a Control parented to a CanvasLayer at zero size, which
	# silently pushes every panel off-screen. Offsets have to be set too, and the
	# size has to be re-applied when the viewport changes.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font
	set_process(true)


func _process(_delta: float) -> void:
	queue_redraw()


func set_compact(on: bool) -> void:
	compact = on


func set_status(text: String) -> void:
	_status = text


func set_hint(text: String) -> void:
	_hint = text


func set_telemetry(d: Dictionary) -> void:
	_telemetry = d


func set_legend(entries: Array, live: Color) -> void:
	_legend = entries
	_live_color = live


func push_alpha(t: float, alpha_deg: float) -> void:
	if _alpha_samples.size() >= MAX_SAMPLES:
		return
	_alpha_samples.append(Vector2(t, alpha_deg))


func clear_alpha() -> void:
	_alpha_samples = PackedVector2Array()


func toggle_panel() -> void:
	show_panel = not show_panel
	if _debug_panel:
		_debug_panel.visible = show_panel


## Track D's panel, if it exists, gets one side of the screen; we take the other.
## Its root is a full-rect Control, so the side is decided from the largest
## descendant that is NOT full width — the drawer — rather than from the root.
func place_opposite(other: Node) -> void:
	if other == null:
		_prefer_right = true
		return
	var vw: float = get_viewport_rect().size.x
	var best_area: float = 0.0
	var best_centre: float = -1.0
	for c in _all_controls(other):
		var r: Rect2 = c.get_global_rect()
		if not c.visible or r.size.x <= 0.0 or r.size.y <= 0.0:
			continue
		if r.size.x > vw * 0.7:
			continue     # full-width container, tells us nothing
		var area: float = r.size.x * r.size.y
		if area > best_area:
			best_area = area
			best_centre = r.position.x + r.size.x * 0.5
	if best_centre < 0.0:
		return
	_prefer_right = best_centre < vw * 0.5


func _all_controls(root: Node, depth: int = 0) -> Array[Control]:
	var out: Array[Control] = []
	if depth > 4:
		return out
	for c in root.get_children():
		if c is Control:
			out.append(c as Control)
		out.append_array(_all_controls(c, depth + 1))
	return out


# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

func _draw() -> void:
	if _font == null:
		return
	# Layout may not have resolved on the first frame; fall back to the viewport.
	var vp: Vector2 = size if size.x > 1.0 else get_viewport_rect().size
	# Always-visible one-liner: status across the top-centre.
	if not _status.is_empty() and not compact:
		var w: float = minf(_font.get_string_size(_status, HORIZONTAL_ALIGNMENT_LEFT,
			-1, 15).x, vp.x - 60.0)
		# y = 46 clears the "Back to overview" pill the export preset injects.
		var sx: float = maxf(vp.x * 0.5 - w * 0.5, 20.0)
		_panel_bg(Rect2(sx - 10.0, 46.0, w + 20.0, 26.0))
		draw_string(_font, Vector2(sx, 64.0), _status,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.85, 0.92, 1.0), w)
	if not _hint.is_empty() and not compact:
		var hw: float = _font.get_string_size(_hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		draw_string(_font, Vector2(vp.x * 0.5 - hw * 0.5, vp.y - 10.0), _hint,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.62, 0.70, 0.80, 0.85))
	if not show_panel:
		return

	var panel_w: float = CHART_W + PAD * 2.0
	var rows: int = 0 if compact else _telemetry.size()
	var legend_h: float = 0.0 if _legend.is_empty() else (float(_legend.size()) * 20.0 + 24.0)
	var panel_h: float = PAD * 2.0 + float(rows) * ROW + CHART_H + 26.0 + legend_h
	var x: float = vp.x - panel_w - 14.0 if _prefer_right else 14.0
	# Compact sits just below Track D's top strip; standalone sits at the bottom.
	var y: float = 96.0 if compact else vp.y - panel_h - 34.0
	_panel_bg(Rect2(x, y, panel_w, panel_h))

	var cy: float = y + PAD + 13.0
	for key in (_telemetry if not compact else {}):
		draw_string(_font, Vector2(x + PAD, cy), str(key), HORIZONTAL_ALIGNMENT_LEFT,
			-1, 12, Color(0.60, 0.68, 0.78))
		var val := str(_telemetry[key])
		var vw2: float = _font.get_string_size(val, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		draw_string(_font, Vector2(x + panel_w - PAD - vw2, cy), val,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.94, 0.97, 1.0))
		cy += ROW

	cy += 6.0
	_draw_alpha_chart(Rect2(x + PAD, cy, CHART_W, CHART_H))
	cy += CHART_H + 20.0

	if not _legend.is_empty():
		draw_string(_font, Vector2(x + PAD, cy), "TRAILS", HORIZONTAL_ALIGNMENT_LEFT,
			-1, 11, Color(0.55, 0.64, 0.74))
		cy += 16.0
		for e in _legend:
			var c: Color = e["color"]
			draw_rect(Rect2(x + PAD, cy - 9.0, 12.0, 12.0), c)
			draw_string(_font, Vector2(x + PAD + 18.0, cy), str(e["label"]),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.88, 0.92, 0.98))
			var side := "R" if float(e["lateral"]) >= 0.0 else "L"
			var stat := "%.0f m  %.0f%s" % [float(e["distance"]), absf(float(e["lateral"])), side]
			var sw: float = _font.get_string_size(stat, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
			draw_string(_font, Vector2(x + panel_w - PAD - sw, cy), stat,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.72, 0.80, 0.90))
			cy += 20.0


func _draw_alpha_chart(r: Rect2) -> void:
	draw_rect(r, Color(0.06, 0.09, 0.14, 0.75))
	draw_rect(r, Color(0.30, 0.38, 0.48, 0.55), false, 1.0)
	# Zero line: above it the disc is nose-up and CM is heading positive (fade);
	# below it the disc is nose-down.
	var zero_t: float = (0.0 - ALPHA_MIN_DEG) / (ALPHA_MAX_DEG - ALPHA_MIN_DEG)
	var zy: float = r.position.y + r.size.y * (1.0 - zero_t)
	draw_line(Vector2(r.position.x, zy), Vector2(r.position.x + r.size.x, zy),
		Color(0.45, 0.55, 0.68, 0.7), 1.0)
	draw_string(_font, Vector2(r.position.x + 4.0, r.position.y + 12.0),
		"angle of attack  alpha", HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
		Color(0.58, 0.68, 0.80))
	draw_string(_font, Vector2(r.position.x + 4.0, zy - 3.0), "0", HORIZONTAL_ALIGNMENT_LEFT,
		-1, 9, Color(0.50, 0.60, 0.72))

	var n := _alpha_samples.size()
	if n < 2:
		return
	var t_max: float = maxf(_alpha_samples[n - 1].x, 1.0)
	var pts := PackedVector2Array()
	pts.resize(n)
	for i in n:
		var s: Vector2 = _alpha_samples[i]
		var fx: float = clampf(s.x / t_max, 0.0, 1.0)
		var fy: float = clampf((s.y - ALPHA_MIN_DEG) / (ALPHA_MAX_DEG - ALPHA_MIN_DEG), 0.0, 1.0)
		pts[i] = Vector2(r.position.x + fx * r.size.x, r.position.y + (1.0 - fy) * r.size.y)
	draw_polyline(pts, _live_color, 1.6, true)


func _panel_bg(r: Rect2) -> void:
	draw_rect(r, Color(0.04, 0.06, 0.10, 0.72))
	draw_rect(r, Color(0.28, 0.36, 0.48, 0.5), false, 1.0)


# ---------------------------------------------------------------------------
# Fallback debug panel
# ---------------------------------------------------------------------------

## Built only when `res://scenes/ui/control_panel.tscn` is missing, so this
## track stands up on its own before Track D lands.
func build_debug_panel() -> void:
	if _debug_panel != null:
		return
	var root := PanelContainer.new()
	root.name = "DebugPanel"
	root.set_anchors_preset(Control.PRESET_TOP_LEFT)
	root.position = Vector2(14.0, 82.0)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.06, 0.10, 0.85)
	style.border_color = Color(0.30, 0.40, 0.55, 0.8)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(10)
	root.add_theme_stylebox_override("panel", style)
	add_child(root)
	_debug_panel = root

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	root.add_child(box)

	var title := Label.new()
	title.text = "DEBUG PANEL  (Track D UI not found)"
	title.add_theme_font_size_override("font_size", 12)
	title.add_theme_color_override("font_color", Color(1.0, 0.78, 0.4))
	box.add_child(title)

	var throw_btn := Button.new()
	throw_btn.text = "Throw  (Space)"
	throw_btn.pressed.connect(func() -> void: debug_throw_requested.emit())
	box.add_child(throw_btn)

	var disc_row := HBoxContainer.new()
	box.add_child(disc_row)
	var prev := Button.new()
	prev.text = "< disc"
	prev.pressed.connect(func() -> void: debug_disc_cycled.emit(-1))
	disc_row.add_child(prev)
	var nxt := Button.new()
	nxt.text = "disc >"
	nxt.pressed.connect(func() -> void: debug_disc_cycled.emit(1))
	disc_row.add_child(nxt)

	var view_row := HBoxContainer.new()
	box.add_child(view_row)
	for v in ["tee", "follow", "top", "side", "free"]:
		var b := Button.new()
		b.text = v
		b.add_theme_font_size_override("font_size", 11)
		b.pressed.connect(func() -> void: debug_view_requested.emit(v))
		view_row.add_child(b)

	var tail := HBoxContainer.new()
	box.add_child(tail)
	var vec := CheckBox.new()
	vec.text = "vectors"
	vec.button_pressed = true
	vec.toggled.connect(func(on: bool) -> void: debug_vectors_toggled.emit(on))
	tail.add_child(vec)
	var clr := Button.new()
	clr.text = "clear trails"
	clr.pressed.connect(func() -> void: debug_clear_requested.emit())
	tail.add_child(clr)

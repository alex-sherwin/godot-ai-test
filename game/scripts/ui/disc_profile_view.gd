class_name DiscProfileView
extends Control

## Draws the meridional cross-section of the disc being designed.
##
## This is the link the whole designer exists to make visible: the same
## eight numbers that the mesh is lathed from and the aerodynamic model reads
## are the numbers that draw this silhouette. Drag `parting_line_m` and the
## widest point of the rim moves here, on screen, in the same edit.
##
## Input is a closed outline in (radius, height) metres — top surface outbound,
## underside inbound — either from `DiscGeometryCalc.outline()` or, when Track
## C's mesh builder is present, from the builder's own profile so the diagram
## and the rendered disc can never disagree.

const T := preload("res://scripts/ui/flight_lab_theme.gd")

## Vertical exaggeration. A disc is 211 mm across and 20 mm tall; at 1:1 the
## profile is a hairline. The factor is always drawn on screen so the picture
## never quietly lies about proportions.
var exaggeration: float = 3.0:
	set(value):
		exaggeration = clampf(value, 1.0, 8.0)
		queue_redraw()

var _outline := PackedVector2Array()
var _reference := PackedVector2Array()
var _marks: Dictionary = {}
var _label: String = ""

# Scratch, reused every frame so a slider drag does not allocate.
var _screen := PackedVector2Array()
var _ref_screen := PackedVector2Array()


func _init() -> void:
	custom_minimum_size = Vector2(140, 132)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_PASS
	tooltip_text = "Cross-section through the disc's axis of rotation, mirrored about the spin axis. The mesh is this profile swept through 360°."


## `marks` carries the annotation values (metres): parting_line_m, rim_depth_m,
## inner_rim_edge_m, diameter_m, dome_height_m.
func set_profile(outline: PackedVector2Array, marks: Dictionary = {}, label: String = "") -> void:
	_outline = outline
	_marks = marks
	_label = label
	queue_redraw()


## A faint ghost of the disc the design started from, so an edit reads as a
## change rather than as an absolute shape.
func set_reference(outline: PackedVector2Array) -> void:
	_reference = outline
	queue_redraw()


func _draw() -> void:
	var w := size.x
	var h := size.y
	if w < 20.0 or h < 20.0 or _outline.size() < 3:
		return

	var font := get_theme_font("font", "Label")
	var fs := 9

	# Frame.
	draw_rect(Rect2(Vector2.ZERO, size), Color("070b12"), true)
	draw_rect(Rect2(Vector2.ZERO, size), T.BORDER, false, 1.0)

	var pad_x := 12.0
	var pad_top := 16.0
	var pad_bottom := 22.0
	var r_max := 0.0
	var z_max := 0.0
	for p in _outline:
		r_max = maxf(r_max, absf(p.x))
		z_max = maxf(z_max, p.y)
	if r_max <= 0.0:
		return
	z_max = maxf(z_max, 0.001)
	# A half profile (Track A's convention, radius 0..R) gets mirrored; a full
	# outline (Track C's mesh polyline, −R..R) is already both halves.
	var half_profile := _is_half(_outline)

	# One scale for both axes, then the vertical one is exaggerated. Mirroring
	# doubles the radial extent.
	var sx: float = (w - 2.0 * pad_x) / (2.0 * r_max)
	var sy_natural: float = sx
	var sy: float = sy_natural * exaggeration
	var avail_h: float = h - pad_top - pad_bottom
	if z_max * sy > avail_h:
		sy = avail_h / z_max

	var cx: float = w * 0.5
	var baseline: float = h - pad_bottom

	# Resting plane (z = 0): the disc sitting on a table on its rim.
	draw_line(Vector2(6, baseline), Vector2(w - 6, baseline), Color(1, 1, 1, 0.13), 1.0)
	draw_string(font, Vector2(8, baseline + 13), "resting plane", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, T.TEXT_FAINT)

	# Reference ghost first, so the live profile sits on top of it.
	if _reference.size() >= 3:
		_project(_reference, _ref_screen, cx, baseline, sx, sy)
		_stroke(_ref_screen, cx, Color(1, 1, 1, 0.22), 1.0, true, _is_half(_reference))

	_project(_outline, _screen, cx, baseline, sx, sy)

	var fill := Color(0.35, 0.66, 0.93, 0.20)
	draw_colored_polygon(_screen, fill)
	if half_profile:
		var mirrored := PackedVector2Array()
		mirrored.resize(_screen.size())
		for i in _screen.size():
			mirrored[i] = Vector2(2.0 * cx - _screen[i].x, _screen[i].y)
		draw_colored_polygon(mirrored, fill)

	_stroke(_screen, cx, T.ACCENT_BRIGHT, 1.5, false, half_profile)

	# Spin axis.
	draw_dashed_line(Vector2(cx, pad_top - 8.0), Vector2(cx, baseline + 4.0),
		Color(1, 1, 1, 0.18), 1.0, 3.0)

	# Annotations. The parting-line caption gets a solid plate behind it — it
	# necessarily crosses the silhouette, since that is the point of it.
	if _marks.has("parting_line_m"):
		var pl: float = float(_marks["parting_line_m"])
		var y: float = baseline - pl * sy
		draw_dashed_line(Vector2(6, y), Vector2(w - 6, y), Color(T.CHIP_TURN, 0.55), 1.0, 3.0)
		var caption := "parting line %.1f mm" % (pl * 1000.0)
		var cw: float = font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_rect(Rect2(5.0, y - fs - 3.0, cw + 6.0, fs + 5.0), Color("070b12"), true)
		draw_string(font, Vector2(8, y - 4), caption, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, T.CHIP_TURN)

	if _marks.has("inner_rim_edge_m"):
		var ri: float = float(_marks["inner_rim_edge_m"])
		var x: float = cx + ri * sx
		draw_dashed_line(Vector2(x, pad_top - 8.0), Vector2(x, baseline), Color(1, 1, 1, 0.16), 1.0, 3.0)
		draw_dashed_line(Vector2(2.0 * cx - x, pad_top - 8.0), Vector2(2.0 * cx - x, baseline),
			Color(1, 1, 1, 0.16), 1.0, 3.0)

	# Header: what this is, and the honest note about the vertical scale.
	if not _label.is_empty():
		draw_string(font, Vector2(8, 12), _label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, T.TEXT_DIM)
	var scale_note := "vertical ×%.0f" % exaggeration if exaggeration > 1.01 else "true scale"
	var nw: float = font.get_string_size(scale_note, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(font, Vector2(w - 8.0 - nw, 12), scale_note, HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
		T.TEXT_FAINT)

	# Radial scale bar: 50 mm.
	var bar_m := 0.05
	var bar_px: float = bar_m * sx
	if bar_px > 12.0 and bar_px < w * 0.6:
		var by: float = baseline + 8.0
		var bx0: float = w - 8.0 - bar_px
		draw_line(Vector2(bx0, by), Vector2(w - 8.0, by), T.TEXT_FAINT, 1.0)
		draw_line(Vector2(bx0, by - 3), Vector2(bx0, by + 3), T.TEXT_FAINT, 1.0)
		draw_line(Vector2(w - 8.0, by - 3), Vector2(w - 8.0, by + 3), T.TEXT_FAINT, 1.0)
		draw_string(font, Vector2(bx0, by + 12), "50 mm", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, T.TEXT_FAINT)


func _project(src: PackedVector2Array, dst: PackedVector2Array, cx: float, baseline: float,
		sx: float, sy: float) -> void:
	if dst.size() != src.size():
		dst.resize(src.size())
	for i in src.size():
		dst[i] = Vector2(cx + src[i].x * sx, baseline - src[i].y * sy)


static func _is_half(pts: PackedVector2Array) -> bool:
	for p in pts:
		if p.x < -1e-6:
			return false
	return true


func _stroke(pts: PackedVector2Array, cx: float, color: Color, width: float,
		dashed: bool, mirror: bool) -> void:
	var closed := PackedVector2Array(pts)
	if closed.size() > 0:
		closed.append(closed[0])
	if dashed:
		for i in range(closed.size() - 1):
			draw_dashed_line(closed[i], closed[i + 1], color, width, 3.0)
			if mirror:
				draw_dashed_line(Vector2(2.0 * cx - closed[i].x, closed[i].y),
					Vector2(2.0 * cx - closed[i + 1].x, closed[i + 1].y), color, width, 3.0)
		return
	draw_polyline(closed, color, width, true)
	if not mirror:
		return
	var mir := PackedVector2Array()
	mir.resize(closed.size())
	for i in closed.size():
		mir[i] = Vector2(2.0 * cx - closed[i].x, closed[i].y)
	draw_polyline(mir, color, width, true)

class_name CompassDial
extends Control

## Wind direction picker, drawn as a compass rose oriented to the throw rather
## than to north: the top of the dial is downrange.
##
## The convention is the meteorological one — the bearing names where the wind
## comes *from* — because that is how every wind report a disc golfer will ever
## read is phrased. The arrow drawn inside the dial points the way the air is
## actually moving, so the two never get confused.
##
## 0° = wind out of the fairway (headwind), 90° = out of the thrower's right,
## 180° = tailwind, 270° = out of the left.

signal direction_changed(degrees: float)

const T := preload("res://scripts/ui/flight_lab_theme.gd")

var bearing_deg: float = 0.0:
	set(value):
		bearing_deg = fposmod(value, 360.0)
		queue_redraw()

var speed_mps: float = 0.0:
	set(value):
		speed_mps = maxf(value, 0.0)
		queue_redraw()

var _dragging := false


func _init() -> void:
	# Wide enough that "BEHIND" and "LEFT"/"RIGHT" clear the rim without being
	# clipped by the control's own bounds, plus a line for the caption.
	custom_minimum_size = Vector2(200, 158)
	size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	tooltip_text = "Wind direction, given as the bearing the wind blows FROM, relative to the throw. Top of the dial is downrange. Click or drag to set."
	focus_mode = Control.FOCUS_NONE


## World-frame wind vector (CONTRACT §1: -Z downrange, +X to the thrower's
## right). The air moves away from the source bearing, hence the sign flip.
static func wind_vector(bearing_degrees: float, speed: float) -> Vector3:
	var b := deg_to_rad(bearing_degrees)
	return Vector3(-sin(b) * speed, 0.0, cos(b) * speed)


## Component opposing the throw. Positive = headwind.
static func headwind(bearing_degrees: float, speed: float) -> float:
	return cos(deg_to_rad(bearing_degrees)) * speed


## Component across the throw. Positive = pushing the disc to the right (+X).
static func crosswind(bearing_degrees: float, speed: float) -> float:
	return -sin(deg_to_rad(bearing_degrees)) * speed


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
			if mb.pressed:
				_set_from_point(mb.position, mb.shift_pressed)
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		_set_from_point((event as InputEventMouseMotion).position,
			Input.is_key_pressed(KEY_SHIFT))
		accept_event()


func _set_from_point(p: Vector2, snap_coarse: bool) -> void:
	var c := Vector2(size.x * 0.5, (size.y - 14.0) * 0.5)
	var d := p - c
	if d.length() < 4.0:
		return
	# Screen: +x right, +y down. Bearing 0 is up, increasing clockwise.
	var deg := rad_to_deg(atan2(d.x, -d.y))
	deg = fposmod(deg, 360.0)
	deg = snappedf(deg, 15.0) if snap_coarse else snappedf(deg, 1.0)
	if is_equal_approx(deg, bearing_deg):
		return
	bearing_deg = deg
	direction_changed.emit(bearing_deg)


func _draw() -> void:
	# The caption lives on its own line under the rose, so the drawing area is
	# the control minus that line.
	var caption_h := 14.0
	var c := Vector2(size.x * 0.5, (size.y - caption_h) * 0.5)
	var radius: float = minf(size.x * 0.5 - 34.0, (size.y - caption_h) * 0.5 - 12.0)
	if radius < 12.0:
		return
	var font := get_theme_font("font", "Label")
	var fs := 9

	draw_circle(c, radius + 6.0, Color("0a0e17"))
	draw_arc(c, radius, 0.0, TAU, 64, T.BORDER_BRIGHT, 1.0, true)
	draw_arc(c, radius * 0.55, 0.0, TAU, 48, Color(1, 1, 1, 0.06), 1.0, true)

	# Ticks every 15°, longer every 45°.
	for i in range(24):
		var a := deg_to_rad(float(i) * 15.0)
		var dir := Vector2(sin(a), -cos(a))
		var major := i % 3 == 0
		var inner: float = radius - (7.0 if major else 4.0)
		draw_line(c + dir * inner, c + dir * radius,
			(T.BORDER_BRIGHT if major else Color(1, 1, 1, 0.10)), 1.0)

	# Cardinals, named for the throw rather than for the compass.
	var labels := {0: "AHEAD", 90: "RIGHT", 180: "BEHIND", 270: "LEFT"}
	for deg: int in labels:
		var a := deg_to_rad(float(deg))
		var dir := Vector2(sin(a), -cos(a))
		var p := c + dir * (radius + 13.0)
		var text: String = labels[deg]
		var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(font, p - Vector2(w * 0.5, -3.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
			T.TEXT_FAINT)

	# The wind itself: source dot on the rim, arrow through the middle pointing
	# the way the air travels.
	var b := deg_to_rad(bearing_deg)
	var src := Vector2(sin(b), -cos(b))
	var flow := -src
	var strength: float = clampf(speed_mps / 12.0, 0.0, 1.0)
	var calm: bool = speed_mps <= 0.05
	# In calm air the arrow is drawn faintly rather than removed: the direction
	# is still set, it just is not doing anything yet.
	var col: Color = T.ACCENT_BRIGHT if not calm else Color(T.TEXT_FAINT, 0.45)

	draw_line(c + src * radius, c + flow * radius * 0.86, col, 2.0, true)
	var head := c + flow * radius * 0.86
	var side := Vector2(-flow.y, flow.x) * (5.0 + 3.0 * strength)
	var tip := head + flow * (7.0 + 4.0 * strength)
	draw_colored_polygon(PackedVector2Array([tip, head + side, head - side]), col)
	draw_circle(c + src * radius, 4.0 + 2.0 * strength, col)

	var caption := "calm · set to %d°" % int(round(bearing_deg)) if calm else \
		"wind from %d° · %s" % [int(round(bearing_deg)), _quadrant(bearing_deg)]
	var cw := font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(font, Vector2(c.x - cw * 0.5, size.y - 2.0), caption,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs, T.TEXT_DIM)


static func _quadrant(deg: float) -> String:
	var d := fposmod(deg, 360.0)
	if d < 22.5 or d >= 337.5:
		return "headwind"
	if d < 67.5:
		return "head/right"
	if d < 112.5:
		return "from right"
	if d < 157.5:
		return "tail/right"
	if d < 202.5:
		return "tailwind"
	if d < 247.5:
		return "tail/left"
	if d < 292.5:
		return "from left"
	return "head/left"

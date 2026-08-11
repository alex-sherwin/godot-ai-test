class_name RibbonBuilder
extends RefCounted

## Screen-facing ribbons for trajectory trails.
##
## A trail has to stay readable both 3 m from the camera at release and 180 m
## away at landing. A fixed-width tube is 40 px at one end and sub-pixel at the
## other, so the ribbon is expanded in the VERTEX shader toward the camera with
## a width floor expressed as a fraction of view distance. The geometry itself
## is therefore static: a landed ghost trail costs zero CPU per frame no matter
## how many are on screen.
##
## Layout, two vertices per path point:
##   VERTEX  the path point (duplicated)
##   NORMAL  the unit path tangent  (not lighting — the shader is unshaded)
##   UV      (side 0|1, arclength fraction 0..1)
##   COLOR   per-vertex tint and alpha
##
## The shader treats model space as world space, so a node carrying one of these
## meshes MUST keep an identity transform.

const SHADER_CODE := """
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, depth_draw_opaque;

// Width in metres, and a floor expressed as a fraction of the distance to the
// camera (0.002 ~ 2.3 px at 1280x720 with a 60 degree fov, at any range).
uniform float width_m = 0.30;
uniform float width_frac = 0.0022;
uniform float alpha_scale = 1.0;
// A chase camera flies straight down its own trail, so the last few metres of
// ribbon expand into a wall of colour across the whole frame. Fading it out
// inside `fade_far` keeps the trail readable from the follow view without
// touching how it looks from anywhere else.
uniform float fade_near = 3.0;
uniform float fade_far = 14.0;

varying float v_alpha;

void vertex() {
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	vec3 to_cam = cam - VERTEX;
	float dist = length(to_cam);
	vec3 tc = to_cam / max(dist, 0.0001);
	vec3 tangent = normalize(NORMAL);
	vec3 side = cross(tangent, tc);
	float sl = length(side);
	side = sl > 0.00001 ? side / sl : vec3(0.0, 1.0, 0.0);
	float w = max(width_m, width_frac * dist);
	VERTEX += side * ((UV.x * 2.0 - 1.0) * w * 0.5);
	v_alpha = COLOR.a * alpha_scale * smoothstep(fade_near, fade_far, dist);
}

void fragment() {
	ALBEDO = COLOR.rgb;
	ALPHA = v_alpha;
}
"""

static var _shader: Shader = null


static func get_shader() -> Shader:
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER_CODE
	return _shader


static func make_material(width_m: float = 0.30, width_frac: float = 0.0022,
		alpha_scale: float = 1.0, fade_near: float = 3.0,
		fade_far: float = 14.0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = get_shader()
	m.set_shader_parameter("width_m", width_m)
	m.set_shader_parameter("width_frac", width_frac)
	m.set_shader_parameter("alpha_scale", alpha_scale)
	m.set_shader_parameter("fade_near", fade_near)
	m.set_shader_parameter("fade_far", fade_far)
	return m


## Build a ribbon through `points`. `head_color` is used at the newest end,
## `tail_color` at the oldest, so a live trail can fade behind the disc.
## Returns null for fewer than two usable points.
static func build(points: PackedVector3Array, head_color: Color,
		tail_color: Color = Color(0, 0, 0, 0), y_offset: float = 0.0,
		flatten_y: float = NAN) -> ArrayMesh:
	var n := points.size()
	if n < 2:
		return null
	if tail_color.a <= 0.0 and tail_color.r <= 0.0:
		tail_color = head_color

	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	verts.resize(n * 2)
	norms.resize(n * 2)
	uvs.resize(n * 2)
	cols.resize(n * 2)

	var flat := not is_nan(flatten_y)
	var inv_last: float = 1.0 / float(n - 1)
	for i in n:
		var p: Vector3 = points[i]
		if flat:
			p.y = flatten_y
		else:
			p.y += y_offset
		var tangent: Vector3
		if i == 0:
			tangent = points[1] - points[0]
		elif i == n - 1:
			tangent = points[n - 1] - points[n - 2]
		else:
			tangent = points[i + 1] - points[i - 1]
		if flat:
			tangent.y = 0.0
		if tangent.length_squared() < 1e-12:
			tangent = Vector3(0.0, 0.0, -1.0)
		tangent = tangent.normalized()
		var t: float = float(i) * inv_last
		var c: Color = tail_color.lerp(head_color, t)
		var a: int = i * 2
		verts[a] = p
		verts[a + 1] = p
		norms[a] = tangent
		norms[a + 1] = tangent
		uvs[a] = Vector2(0.0, t)
		uvs[a + 1] = Vector2(1.0, t)
		cols[a] = c
		cols[a + 1] = c

	# Godot front faces are clockwise, but the ribbon is `cull_disabled` because
	# the shader can flip it toward either side of the camera.
	var idx := PackedInt32Array()
	idx.resize((n - 1) * 6)
	var w: int = 0
	for i in n - 1:
		var a: int = i * 2
		idx[w] = a; idx[w + 1] = a + 1; idx[w + 2] = a + 2
		idx[w + 3] = a + 1; idx[w + 4] = a + 3; idx[w + 5] = a + 2
		w += 6

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Flat unshaded quads, used for the range markings: one mesh, one draw call,
## arbitrary per-quad colours. `quads` entries are {a, b, c, d, color} where the
## corners are (x0,z0), (x1,z0), (x0,z1), (x1,z1) — i.e. a grid cell — so the
## clockwise (Godot front-facing) order seen from above is a, b, c / b, d, c.
static func build_quads(quads: Array) -> ArrayMesh:
	if quads.is_empty():
		return null
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	verts.resize(quads.size() * 4)
	norms.resize(quads.size() * 4)
	cols.resize(quads.size() * 4)
	uvs.resize(quads.size() * 4)
	idx.resize(quads.size() * 6)
	var vi: int = 0
	var ii: int = 0
	for q in quads:
		var c: Color = q["color"]
		var pts: Array = [q["a"], q["b"], q["c"], q["d"]]
		for k in 4:
			verts[vi + k] = pts[k]
			norms[vi + k] = Vector3.UP
			cols[vi + k] = c
			uvs[vi + k] = Vector2(float(k & 1), float((k >> 1) & 1))
		idx[ii] = vi; idx[ii + 1] = vi + 1; idx[ii + 2] = vi + 2
		idx[ii + 3] = vi + 1; idx[ii + 4] = vi + 3; idx[ii + 5] = vi + 2
		vi += 4
		ii += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

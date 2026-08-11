shader_type spatial;

// World-space half-space clip, used on the disc and on its portal ghost.
//
// WHY THIS EXISTS
// ------------------------------------------------------------------------
// A disc crossing a portal is in two places for one frame: the real mesh on
// the entrance side and a clone at the exit, driven by the same pair transform.
// Without clipping, the real disc's leading half pokes out of the *back* of the
// entrance wall and the clone's trailing half pokes out of the front of the
// exit wall, and the illusion dies at the exact moment the player is watching.
// Each mesh is clipped by its own portal's plane so the two halves add up to
// exactly one disc.
//
// This is also the (c) leg of the contract §8 fallback for the absent oblique
// near plane: it handles the dynamic objects that room construction cannot.
//
// `discard`, deliberately, NOT `ALPHA = 0.0`. Zero alpha forces the material
// into the transparent pass, which costs a sort, loses depth write, and on
// Compatibility puts the disc behind everything it should occlude.
render_mode cull_disabled, specular_schlick_ggx;

uniform vec4 albedo : source_color = vec4(0.30, 0.62, 0.95, 1.0);
uniform float roughness_v : hint_range(0.0, 1.0) = 0.55;
uniform float metallic_v : hint_range(0.0, 1.0) = 0.0;
uniform float rim_light : hint_range(0.0, 2.0) = 0.0;

// xyz = world-space plane normal, w = plane distance. Fragments with
// `dot(n, p) < w` are discarded, i.e. the kept half-space is in front of the
// portal's own facing direction.
uniform vec4 clip_plane = vec4(0.0, 1.0, 0.0, -1.0e9);
uniform float clip_enabled : hint_range(0.0, 1.0) = 0.0;

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (clip_enabled > 0.5 && dot(clip_plane.xyz, v_world) - clip_plane.w < 0.0) {
		discard;
	}
	ALBEDO = albedo.rgb;
	ROUGHNESS = roughness_v;
	METALLIC = metallic_v;
	if (rim_light > 0.0) {
		float f = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 3.0);
		ALBEDO += albedo.rgb * f * rim_light;
	}
}

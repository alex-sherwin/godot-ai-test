shader_type spatial;

// The portal aperture: a quad that shows what the paired portal's camera sees.
//
// GL COMPATIBILITY (WebGL2) NOTES
// ------------------------------------------------------------------------
//  * `SCREEN_UV` is the fragment's own position in the *output* viewport. The
//    SubViewport camera is placed at `M * main_camera` with the same fov and
//    aspect, so screen UV is exactly the right lookup: the portal texture and
//    the frame behind it are in registration by construction, and the
//    SubViewport can therefore be rendered at a *lower* resolution than the
//    screen without any UV maths changing. (Sampling by the quad's own `UV`
//    instead is the classic mistake — it stretches the view as you move.)
//  * `source_color` on the sampler is REQUIRED. Compatibility renders with
//    `OUTPUT_IS_SRGB` true, so the SubViewport's colour attachment holds sRGB
//    bytes; without the hint they are treated as linear, sampled too bright,
//    and then encoded again — a visibly washed-out, milky portal. With it the
//    decode/encode round-trips. Verified by A/B in an exported web build.
//  * `unshaded` means EMISSION is not added, so the rim is mixed into ALBEDO.
//  * `fog_disabled`: the view through the portal already carries the
//    destination room's fog, applied by the SubViewport camera's own
//    Environment. Letting the *source* room fog the quad as well double-fogs
//    it and flattens the depth cue that makes rooms read as different air.
render_mode unshaded, cull_back, depth_draw_opaque, shadows_disabled,
	specular_disabled, ambient_light_disabled, fog_disabled;

uniform sampler2D portal_tex : filter_linear, source_color, hint_default_black;

// 1 = show the live view, 0 = show `flat_color`. A portal seen *through*
// another portal is drawn flat: depth is 1, and this is the termination the
// contract asks for (§8) rather than a hole in the wall.
uniform float live : hint_range(0.0, 1.0) = 1.0;
uniform vec3 flat_color : source_color = vec3(0.055, 0.075, 0.115);

// Visual identity. 0 = normal, 1 = dive (inverts the disc), 2 = disc-placed.
uniform int pattern : hint_range(0, 2) = 0;
uniform vec3 rim_color : source_color = vec3(0.42, 0.78, 1.0);
uniform float rim_width : hint_range(0.0, 0.5) = 0.055;
uniform float tint_strength : hint_range(0.0, 1.0) = 0.12;
uniform float anim_speed = 1.0;

// A silhouette is not enough to tell a dive portal from a normal one at 40 m,
// so the aperture itself carries the warning.
const float CHEVRON_ROWS = 5.0;
const float CHEVRON_SLANT = 0.85;

float chevrons(vec2 uv, float t) {
	// Apex pointing DOWN (+Y is down in quad UV), scrolling down: a disc that
	// goes through this one falls out of the sky, and the arrows say so.
	float f = uv.y * CHEVRON_ROWS - abs(uv.x - 0.5) * CHEVRON_SLANT - t * 0.55;
	float band = abs(fract(f) - 0.5) * 2.0;
	return smoothstep(0.62, 0.94, band);
}

float dashes(float d, vec2 uv, float t) {
	// Perimeter arc-length, roughly, so the dashes run around the border.
	float s = (uv.x + uv.y) * 6.0 + t * 0.5;
	return step(0.5, fract(s));
}

void fragment() {
	vec2 uv = clamp(SCREEN_UV, vec2(0.001), vec2(0.999));
	vec3 view = texture(portal_tex, uv).rgb;
	vec3 col = mix(flat_color, view, live);

	// Distance to the nearest aperture edge, in UV.
	vec2 e = min(UV, vec2(1.0) - UV);
	float d = min(e.x, e.y);
	float t = TIME * anim_speed;

	float rim = 1.0 - smoothstep(0.0, rim_width, d);
	float tint = tint_strength;

	if (pattern == 1) {
		// DIVE. Heavy scrolling chevrons across the whole aperture plus a fat
		// pulsing rim. Deliberately loud: 40-45% of the disc's distance is
		// lost through one of these and the player must be able to see that
		// coming from the tee.
		float c = chevrons(UV, t);
		tint = mix(tint_strength, 0.48, c);
		rim = max(rim, (1.0 - smoothstep(0.0, rim_width * 1.9, d))
			* (0.72 + 0.28 * sin(t * 3.0)));
	} else if (pattern == 2) {
		// DISC-PLACED. Dashed, restless rim — reads as "you made this one",
		// and as impermanent.
		rim *= 0.35 + 0.65 * dashes(d, UV, t);
		tint = tint_strength * 0.7;
	} else {
		// NORMAL. A quiet steady edge and almost no tint: the whole point is
		// that you are looking at the other room, not at an effect.
		rim *= 0.85 + 0.15 * sin(t * 1.2);
	}

	col = mix(col, rim_color, tint);
	ALBEDO = mix(col, rim_color, clamp(rim, 0.0, 1.0));
}

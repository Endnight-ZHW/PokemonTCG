shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;
uniform float strength = 0.23;
uniform bool clip_enabled = false;
uniform vec4 screen_clip = vec4(0.0, 0.0, 1.0, 1.0);
void fragment() {
	if (clip_enabled && (SCREEN_UV.x < screen_clip.x || SCREEN_UV.y < screen_clip.y || SCREEN_UV.x > screen_clip.z || SCREEN_UV.y > screen_clip.w)) { discard; }
	vec2 p = abs(UV * 2.0 - 1.0);
	float mask = (1.0 - smoothstep(0.66, 1.0, p.x)) * (1.0 - smoothstep(0.70, 1.0, p.y));
	ALBEDO = vec3(0.012, 0.019, 0.020);
	ALPHA = mask * strength;
}

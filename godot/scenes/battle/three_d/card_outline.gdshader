shader_type spatial;
render_mode unshaded, cull_disabled;

uniform vec4 tint : source_color = vec4(0.33, 0.57, 0.52, 1.0);
uniform bool pulse_enabled = false;
uniform bool clip_enabled = false;
uniform vec4 screen_clip = vec4(0.0, 0.0, 1.0, 1.0);

void fragment() {
	if (clip_enabled && (SCREEN_UV.x < screen_clip.x || SCREEN_UV.y < screen_clip.y || SCREEN_UV.x > screen_clip.z || SCREEN_UV.y > screen_clip.w)) {
		discard;
	}
	float pulse = pulse_enabled ? 0.88 + 0.12 * sin(TIME * 3.0) : 1.0;
	ALBEDO = tint.rgb * pulse;
	ALPHA = tint.a * smoothstep(0.0, 0.55, UV.x);
}

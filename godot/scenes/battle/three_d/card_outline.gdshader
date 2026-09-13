shader_type spatial;
render_mode unshaded;

uniform vec4 tint : source_color = vec4(0.33, 0.57, 0.52, 1.0);
uniform bool clip_enabled = false;
uniform vec4 screen_clip = vec4(0.0, 0.0, 1.0, 1.0);

void fragment() {
	if (clip_enabled && (SCREEN_UV.x < screen_clip.x || SCREEN_UV.y < screen_clip.y || SCREEN_UV.x > screen_clip.z || SCREEN_UV.y > screen_clip.w)) {
		discard;
	}
	ALBEDO = tint.rgb;
}

shader_type spatial;

uniform sampler2D face_image : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D reverse_image : source_color, filter_linear_mipmap_anisotropic;
uniform bool has_image = false;
uniform vec4 paper_tint : source_color = vec4(1.0);
uniform float paper_roughness = 0.38;
uniform float paper_layers = 1.0;
uniform bool clip_enabled = false;
uniform vec4 screen_clip = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec3 feedback_color : source_color = vec3(0.0);
uniform float feedback_strength = 0.0;
uniform float feedback_desaturation = 0.0;
uniform float feedback_sweep = -1.0;

void vertex() {
	VERTEX.y *= paper_layers;
}

void fragment() {
	if (clip_enabled && (SCREEN_UV.x < screen_clip.x || SCREEN_UV.y < screen_clip.y || SCREEN_UV.x > screen_clip.z || SCREEN_UV.y > screen_clip.w)) {
		discard;
	}
	vec3 face = COLOR.g > 0.5 ? texture(reverse_image, UV).rgb : (has_image ? texture(face_image, UV).rgb : vec3(0.65));
	float bands = UV.y * paper_layers;
	float line = (1.0 - smoothstep(0.03, 0.16, fract(bands))) * (1.0 - smoothstep(0.45, 1.0, fwidth(bands)));
	ALBEDO = COLOR.b > 0.5 ? mix(vec3(0.74, 0.73, 0.69), vec3(0.35, 0.36, 0.37), line) : paper_tint.rgb * face;
	float luminance = dot(ALBEDO, vec3(0.2126, 0.7152, 0.0722));
	ALBEDO = mix(ALBEDO, vec3(luminance), feedback_desaturation);
	ROUGHNESS = COLOR.b > 0.5 ? 0.82 : paper_roughness;
	SPECULAR = 0.28;
	CLEARCOAT = 0.12;
	float rim = pow(clamp(max(abs(UV.x - 0.5), abs(UV.y - 0.5)) * 2.0, 0.0, 1.0), 8.0);
	float sweep = feedback_sweep < 0.0 ? 0.0 : exp(-pow((UV.y + UV.x * 0.25 - feedback_sweep * 1.6 + 0.15) * 14.0, 2.0));
	EMISSION = feedback_color * feedback_strength * (rim * 0.55 + sweep * 0.60 + 0.035);
}

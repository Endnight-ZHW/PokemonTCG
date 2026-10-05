shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec4 base_color : source_color = vec4(0.22, 0.55, 0.56, 1.0);
uniform bool edge_paint = false;
uniform sampler2D pattern_image : filter_linear_mipmap, repeat_disable;
uniform float highlight = 0.0;
varying vec3 local_position;
varying vec3 local_normal;

void vertex() {
	local_position = VERTEX;
	local_normal = NORMAL;
}

float grain_noise(vec2 p) {
	vec2 cell = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	vec4 seeds = vec4(dot(cell, vec2(127.1, 311.7)), dot(cell + vec2(1.0, 0.0), vec2(127.1, 311.7)),
		dot(cell + vec2(0.0, 1.0), vec2(127.1, 311.7)), dot(cell + vec2(1.0), vec2(127.1, 311.7)));
	vec4 values = fract(sin(seeds) * 43758.5453);
	return mix(mix(values.x, values.y, f.x), mix(values.z, values.w, f.x), f.y);
}

void fragment() {
	// Fine irregular leather grain. Fade before subpixel detail can shimmer.
	vec3 weights = abs(local_normal);
	vec2 p = local_position.xy * weights.z + local_position.zy * weights.x + local_position.xz * weights.y;
	float fade = 1.0 - smoothstep(0.003, 0.013, max(length(dFdx(p)), length(dFdy(p))));
	float grain = grain_noise(p * 155.0) * 0.65 + grain_noise(p * 83.0) * 0.35 - 0.5;
	ALBEDO = base_color.rgb * (1.0 + grain * fade * 0.11);
	// A single small blind stamp on the exposed lower-right front panel.
	// The cover, gussets and back remain plain leather; no tiled cut-off motifs.
	vec2 motif_uv = (vec2(local_position.x, -local_position.y) - vec2(0.35, -0.37)) / 0.48 + vec2(0.5);
	float front_face = smoothstep(0.97, 1.0, local_normal.z) * (edge_paint ? 0.0 : 1.0);
	float in_stamp = step(0.0, motif_uv.x) * step(0.0, motif_uv.y) * step(motif_uv.x, 1.0) * step(motif_uv.y, 1.0) * front_face;
	float motif = texture(pattern_image, motif_uv).a * in_stamp;
	float bevel = (texture(pattern_image, motif_uv - vec2(0.004, 0.006)).a * in_stamp) - motif;
	ALBEDO *= 1.0 - motif * 0.095 + bevel * 0.075;
	ALBEDO = mix(ALBEDO, vec3(1.0, 0.94, 0.78), highlight * 0.13);
	if (edge_paint) {
		// Dark edge paint is confined to the cut thickness of the leather sheet.
		ALBEDO *= 1.0 - smoothstep(0.90, 0.99, abs(local_normal.x)) * smoothstep(-0.58, -0.38, local_position.z) * 0.28;
	}
	ROUGHNESS = 0.72 + grain * fade * 0.16 - motif * 0.055;
	METALLIC = 0.0;
	SPECULAR = 0.28;
}

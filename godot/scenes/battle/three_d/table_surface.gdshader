shader_type spatial;
render_mode diffuse_burley;

uniform vec4 base_color : source_color = vec4(0.08, 0.17, 0.21, 1.0);
uniform bool wood = false;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
void fragment() {
	vec2 p = UV;
	float detail;
	if (wood) {
		float grain = sin(p.y * 180.0 + sin(p.x * 12.0 + p.y * 9.0) * 5.0);
		detail = grain * 0.05 + sin(p.y * 110.0 + p.x * 2.0) * 0.08;
		ALBEDO = base_color.rgb * (1.0 + detail);
		ROUGHNESS = 0.68;
	} else {
		float weave = sin(p.x * 700.0) * sin(p.y * 700.0);
		float aa = 1.0 - smoothstep(0.001, 0.007, max(fwidth(p.x), fwidth(p.y)));
		detail = weave * aa * 0.018 + (hash(floor(p * 950.0)) - 0.5) * aa * 0.012;
		ALBEDO = base_color.rgb * (1.0 + detail);
		vec2 emblem = (p - vec2(0.5)) * vec2(1.45, 1.0);
		float ring = 1.0 - smoothstep(0.001, 0.003, abs(length(emblem) - 0.13));
		float seam = (1.0 - smoothstep(0.0005, 0.002, abs(emblem.y))) * step(length(emblem), 0.13);
		ALBEDO += vec3(0.022, 0.028, 0.030) * max(ring, seam);
		ROUGHNESS = 0.95;
	}
	SPECULAR = wood ? 0.26 : 0.10;
}

void light() {
	DIFFUSE_LIGHT += LIGHT_COLOR * (vec3(0.14) + ATTENUATION * max(dot(NORMAL, LIGHT), 0.0) * 0.86) / PI;
}

shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, fog_disabled;

// Analytic paper-light glyphs: no textures, bloom or per-card viewports.
varying float glyph;
varying float phase;
varying float brightness;

float segment(vec2 p, vec2 a, vec2 b) {
	vec2 d = b - a;
	return length(p - a - d * clamp(dot(p - a, d) / max(dot(d, d), 0.0001), 0.0, 1.0));
}

void vertex() {
	glyph = INSTANCE_CUSTOM.x;
	phase = INSTANCE_CUSTOM.y;
	brightness = INSTANCE_CUSTOM.z;
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	int shape = int(glyph + 0.5);
	float d = r - 0.65;
	if (shape == 0 || shape == 5 || shape == 10) { // ripple / psychic / air
		d = abs(r - 0.76) - 0.045;
		if (shape == 5) d = min(d, abs(r - 0.47) - 0.035);
		if (shape == 10) d += smoothstep(-0.6, 0.8, p.x) * 0.06;
	} else if (shape == 1) { // flame
		float taper = clamp((p.y + 0.95) * 0.5, 0.0, 1.0);
		d = length(vec2((p.x - sin(p.y * 4.0) * 0.13) / max(0.1, taper), p.y * 0.9)) - 0.72;
	} else if (shape == 2) { // droplet
		d = length(vec2(p.x / max(0.2, (p.y + 1.4) * 0.5), p.y)) - 0.73;
	} else if (shape == 3) { // lightning
		d = min(segment(p, vec2(0.25, -0.85), vec2(-0.28, -0.02)), segment(p, vec2(-0.28, -0.02), vec2(0.24, -0.02)));
		d = min(d, segment(p, vec2(0.24, -0.02), vec2(-0.27, 0.85))) - 0.09;
	} else if (shape == 4) { // leaf, including central vein
		d = max(length(p - vec2(0.34, 0.0)), length(p + vec2(0.34, 0.0))) - 0.97;
		d = max(d, 0.015 - abs(p.x + p.y * 0.13));
	} else if (shape == 6) { // impact shard
		d = abs(p.x) * 0.9 + abs(p.y * 0.65) - 0.56;
	} else if (shape == 7) { // dark crescent
		d = max(r - 0.82, 0.77 - length(p - vec2(0.30, -0.1)));
	} else if (shape == 8) { // metal slash
		d = abs(p.x + p.y * 0.25) + abs(p.y) * 0.10 - 0.14;
		d = max(d, abs(p.y) - 0.88);
	} else if (shape == 9) { // dragon wisps
		d = abs(p.x - sin(p.y * 4.0) * 0.34) - 0.09 * (1.0 - abs(p.y) * 0.7);
		d = max(d, abs(p.y) - 0.87);
	} else if (shape == 11) { // four-point sparkle
		d = abs(p.x * p.y) - 0.036;
		d = max(d, r - 0.85);
	} else if (shape == 12) { // recovery cross
		d = min(max(abs(p.x) - 0.16, abs(p.y) - 0.64), max(abs(p.x) - 0.64, abs(p.y) - 0.16));
	} else if (shape == 13) { // poison bubble
		d = abs(r - 0.66) - 0.07;
		d = min(d, length(p - vec2(-0.22, -0.25)) - 0.12);
	} else if (shape == 14) { // sleep Z
		d = min(segment(p, vec2(-0.48, -0.55), vec2(0.48, -0.55)), segment(p, vec2(0.48, -0.55), vec2(-0.48, 0.55)));
		d = min(d, segment(p, vec2(-0.48, 0.55), vec2(0.48, 0.55))) - 0.09;
	} else if (shape == 15) { // confusion star
		float a = atan(p.y, p.x);
		d = r - (0.47 + 0.22 * cos(a * 5.0));
	} else if (shape == 16) { // shield hexagon
		vec2 q = abs(p);
		float hex = max(q.x * 0.866025 + q.y * 0.5, q.y);
		d = abs(hex - 0.70) - 0.055;
	} else if (shape == 17 || shape == 19) { // rounded rim / brief corner glints
		vec2 q = abs(p) - vec2(0.645, 0.775);
		d = abs(length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - 0.045) - 0.015;
		if (shape == 19) d = max(d, max(0.46 - abs(p.x), 0.60 - abs(p.y)));
	} else if (shape == 18) { // soft tapered ribbon segment
		d = abs(p.y) - 0.40 * (1.0 - p.x * p.x);
	} else if (shape == 20) { // asymmetric eight-point contact flash
		float a = atan(p.y, p.x);
		d = r - (0.35 + 0.44 * pow(abs(cos(a * 4.0 + 0.3)), 7.0));
	} else if (shape == 21) { // flowing, tapered energy ribbon
		float wave = sin(p.x * 9.0 - phase * 24.0) * 0.10;
		d = abs(p.y - wave) - 0.43 * max(0.0, 1.0 - p.x * p.x);
	} else if (shape == 22) { // soft luminous nucleus
		d = r - 0.35;
	} else if (shape == 23) { // open orbit, visibly directional rather than a full ring
		d = max(abs(r - 0.70) - 0.05, p.x * 0.65 - p.y - 0.35);
	} else if (shape == 24) { // broad translucent column with a tapered upper end
		d = abs(p.x) - (0.25 + (p.y + 1.0) * 0.22);
		d = max(d, abs(p.y) - 0.95);
	}
	float aa = max(fwidth(d), 0.015);
	float ink = 1.0 - smoothstep(-aa, aa, d);
	float interior = smoothstep(0.0, 0.24, -d);
	float halo = exp(-max(d, 0.0) * 13.0) * (1.0 - ink) * 0.36;
	if (shape == 22) {
		ink = exp(-r * r * 7.0);
		halo = exp(-r * r * 3.8) * 0.25;
	}
	if (shape == 24) {
		ink *= (1.0 - smoothstep(0.15, 0.95, abs(p.x))) * smoothstep(-1.0, -0.25, p.y) * (1.0 - smoothstep(0.65, 1.0, p.y));
		halo *= 0.35;
	}
	float light = clamp(0.65 - p.y * 0.3, 0.0, 1.0);
	vec3 tint = mix(COLOR.rgb * 0.76, COLOR.rgb, light);
	// A warm luminous core and translucent falloff replace opaque flat stickers.
	tint = mix(tint, vec3(1.0, 0.98, 0.86), interior * 0.62);
	if (shape == 2 || shape == 13) {
		float highlight = 1.0 - smoothstep(0.05, 0.20, length(p - vec2(-0.18, -0.24)));
		tint = mix(tint, vec3(0.92, 0.99, 1.0), highlight * 0.80);
	}
	if (shape == 4 || shape == 6 || shape == 7) halo *= 0.35;
	ALBEDO = tint;
	EMISSION = mix(COLOR.rgb, vec3(1.0, 0.97, 0.84), interior * 0.65) * ink * 0.30 * brightness;
	ALPHA = clamp(ink * 0.94 + halo, 0.0, 1.0) * COLOR.a;
}

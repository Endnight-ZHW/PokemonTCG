shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, depth_draw_never;

uniform vec4 fill : source_color = vec4(1.0, 0.976471, 0.941176, 0.98);
uniform vec4 border : source_color = vec4(0.631373, 0.541176, 0.450980, 1.0);
uniform vec2 rect_pixels = vec2(600.0, 380.0);
uniform float radius = 18.0;
uniform float opacity = 1.0;
uniform bool showcase = true;

void fragment() {
	vec2 half_size = rect_pixels * 0.5;
	vec2 q = abs((UV - 0.5) * rect_pixels) - half_size + vec2(radius);
	float distance = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
	float edge = 1.0 - smoothstep(-1.7, -0.7, distance);
	vec3 paper = fill.rgb;
	if (showcase) {
		// A softly lit display tray, with an inset gold rule and a linen surface.
		float grain = sin(UV.x * rect_pixels.x * 1.6) * sin(UV.y * rect_pixels.y * 1.3) * 0.006;
		paper *= 0.975 + 0.035 * (1.0 - UV.y) + grain;
		float rule = 1.0 - smoothstep(0.5, 1.4, abs(distance + 6.0));
		paper = mix(paper, vec3(0.75, 0.60, 0.37), rule * 0.36);
		float top = exp(-pow((UV.y - 0.008) * rect_pixels.y / 2.5, 2.0));
		paper = mix(paper, vec3(1.0, 0.97, 0.87), top * 0.65);
	}
	ALBEDO = mix(border.rgb, paper, edge);
	ALPHA = (1.0 - smoothstep(-0.6, 0.6, distance)) * fill.a * opacity;
}

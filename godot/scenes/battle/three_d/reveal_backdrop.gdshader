shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, depth_draw_never;

uniform vec4 fill : source_color = vec4(1.0, 0.976471, 0.941176, 0.98);
uniform vec4 border : source_color = vec4(0.631373, 0.541176, 0.450980, 1.0);
uniform vec2 rect_pixels = vec2(600.0, 380.0);
uniform float radius = 18.0;
uniform float opacity = 1.0;

void fragment() {
	vec2 half_size = rect_pixels * 0.5;
	vec2 q = abs((UV - 0.5) * rect_pixels) - half_size + vec2(radius);
	float distance = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
	float edge = 1.0 - smoothstep(-1.7, -0.7, distance);
	ALBEDO = mix(border.rgb, fill.rgb, edge);
	ALPHA = (1.0 - smoothstep(-0.6, 0.6, distance)) * fill.a * opacity;
}

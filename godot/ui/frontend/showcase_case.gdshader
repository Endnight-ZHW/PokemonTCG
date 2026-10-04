shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
uniform vec4 base_color : source_color = vec4(0.12, 0.18, 0.29, 1.0);
uniform float roughness_value = 0.56;
uniform float metallic_value = 0.05;
void fragment() {
	// Small, antialiased coated-paper grain: roughness, not dirty diffuse speckles.
	float grain = sin(UV.x * 720.0) * sin(UV.y * 610.0);
	float visible_grain = 1.0 - smoothstep(0.002, 0.012, max(fwidth(UV.x), fwidth(UV.y)));
	ALBEDO = base_color.rgb;
	ROUGHNESS = roughness_value + grain * visible_grain * 0.035;
	METALLIC = metallic_value;
	SPECULAR = 0.40;
}

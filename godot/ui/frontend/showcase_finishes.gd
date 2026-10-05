class_name ShowcaseFinishes
extends RefCounted

const TYPES: Array[String] = ["Grass", "Fire", "Water", "Lightning", "Psychic", "Fighting", "Darkness", "Metal", "Dragon", "Colorless"]
const NAMES: Array[String] = ["grass", "fire", "water", "lightning", "psychic", "fighting", "darkness", "metal", "dragon", "colorless"]
const COLORS := ["77a883", "cf7860", "56a7b2", "d4b458", "a088b2", "bd8a69", "566984", "8d9fa6", "b1a075", "a6abb5"]
## Same 256px transparent globe treatment as the other attribute badges.
const DRAGON_BADGE := preload("res://assets/ui/frontend/home_dragon_badge.svg")

static func color_for(type: String) -> Color:
	var index := TYPES.find(type)
	return Color(COLORS[index if index >= 0 else 9])

static func pattern_for(type: String) -> Texture2D:
	var index := TYPES.find(type)
	return load("res://assets/ui/frontend/home_%s_pattern.svg" % NAMES[index if index >= 0 else 9]) as Texture2D

static func badge_for(type: String) -> Texture2D:
	if type == "Dragon":
		return FrontendAttributes.texture_for(type)
	var texture := FrontendAttributes.texture_for(type)
	return texture if texture else preload("res://assets/ui/frontend/club_mark.svg")

static func apply(material: ShaderMaterial, type: String) -> void:
	material.set_shader_parameter("base_color", color_for(type))
	material.set_shader_parameter("pattern_image", pattern_for(type))

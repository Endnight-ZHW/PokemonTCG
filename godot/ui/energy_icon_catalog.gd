class_name EnergyIconCatalog
extends RefCounted

const ICON_PATHS := {
	"Grass": "res://assets/ui/energy/grass.png",
	"Fire": "res://assets/ui/energy/fire.png",
	"Water": "res://assets/ui/energy/water.png",
	"Lightning": "res://assets/ui/energy/lightning.png",
	"Psychic": "res://assets/ui/energy/psychic.png",
	"Fighting": "res://assets/ui/energy/fighting.png",
	"Darkness": "res://assets/ui/energy/darkness.png",
	"Metal": "res://assets/ui/energy/metal.png",
	"Colorless": "res://assets/ui/energy/colorless.png",
}

const SOURCE_CARD_IDS := {
	"Grass": "sv1-ener-1",
	"Fire": "sv1-ener-2",
	"Water": "sv1-ener-3",
	"Lightning": "sv1-ener-4",
	"Psychic": "sv1-ener-5",
	"Fighting": "sv1-ener-6",
	"Darkness": "sv1-ener-7",
	"Metal": "sv1-ener-8",
	"Colorless": "svi-mirc",
}

const SPECIAL_ICON_PATHS := {
	"svg2-lume": "res://assets/ui/energy/luminous.png",
}

const DISPLAY_NAMES := {
	"Grass": "草能量",
	"Fire": "火能量",
	"Water": "水能量",
	"Lightning": "雷能量",
	"Psychic": "超能能量",
	"Fighting": "斗能量",
	"Darkness": "恶能量",
	"Metal": "钢能量",
	"Dragon": "龙能量",
	"Colorless": "无色能量",
	"Rainbow": "彩虹能量",
	"Special": "特殊能量",
	"Unknown": "未知能量",
}

const SHORT_LABELS := {
	"Grass": "G",
	"Fire": "F",
	"Water": "W",
	"Lightning": "L",
	"Psychic": "P",
	"Fighting": "F",
	"Darkness": "D",
	"Metal": "M",
	"Dragon": "D",
	"Colorless": "C",
	"Rainbow": "R",
	"Special": "SP",
	"Unknown": "?",
}

static var _texture_cache: Dictionary = {}


static func path_for(energy_type: String) -> String:
	return str(ICON_PATHS.get(energy_type, ""))


static func source_card_id_for(energy_type: String) -> String:
	return str(SOURCE_CARD_IDS.get(energy_type, ""))


static func path_for_card_id(card_id: String) -> String:
	return str(SPECIAL_ICON_PATHS.get(card_id, ""))


static func texture_for(energy_type: String) -> Texture2D:
	return _texture_at(path_for(energy_type))


static func texture_for_card_id(card_id: String) -> Texture2D:
	return _texture_at(path_for_card_id(card_id))


static func display_name_for(energy_type: String, fallback := "") -> String:
	return str(DISPLAY_NAMES.get(
		energy_type,
		fallback if not str(fallback).is_empty() else energy_type,
	))


static func short_label_for(energy_type: String) -> String:
	return str(SHORT_LABELS.get(energy_type, "?"))


static func _texture_at(path: String) -> Texture2D:
	if path.is_empty():
		return null
	if _texture_cache.has(path):
		return _texture_cache[path] as Texture2D
	var texture := (
		ResourceLoader.load(path, "Texture2D") as Texture2D
		if ResourceLoader.exists(path, "Texture2D")
		else null
	)
	if texture != null:
		_texture_cache[path] = texture
	return texture

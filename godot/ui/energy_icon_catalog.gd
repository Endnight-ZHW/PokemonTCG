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

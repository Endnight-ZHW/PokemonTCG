class_name FrontendAttributes
extends RefCounted

## One entry point for every front-end attribute badge, including the title props.
const DRAGON := preload("res://assets/ui/frontend/home_dragon_badge.svg")

static func texture_for(energy_type: String) -> Texture2D:
	if energy_type == "Dragon":
		return DRAGON
	return EnergyIconCatalog.texture_for(energy_type)

static func card_texture(catalog: CardCatalog, card_id: String) -> Texture2D:
	if catalog == null or card_id.is_empty():
		return null
	var tree := Engine.get_main_loop() as SceneTree
	var cache := tree.root.get_node_or_null("CardTextureCache") if tree else null
	return cache.call("get_texture", str(catalog.get_card(card_id).get("image_path", ""))) as Texture2D if cache else null

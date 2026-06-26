class_name BattleDetailPanel
extends PanelContainer

@onready var detail_image: TextureRect = %DetailImage
@onready var detail_title: Label = %DetailTitle
@onready var detail_text: RichTextLabel = %DetailText


func _ready() -> void:
	_resolve_nodes()
	hide_card()


func show_card(card_id: String, pokemon: PokemonState, catalog: CardCatalog) -> void:
	_resolve_nodes()
	if card_id.is_empty():
		hide_card()
		return
	visible = true
	var card := {}
	if catalog:
		card = catalog.get_card(card_id)
	else:
		card = CardDatabase.get_card(card_id)
	detail_image.texture = CardTextureCache.get_texture(str(card.get("image_path", "")))
	detail_title.text = str(card.get("name", card_id))
	detail_text.text = _card_detail_bbcode(card_id, pokemon, catalog)


func hide_card() -> void:
	_resolve_nodes()
	visible = false
	if detail_image:
		detail_image.texture = null
	if detail_title:
		detail_title.text = "选择一张卡牌"
	if detail_text:
		detail_text.text = "点击或长按卡牌查看详情。"


func _resolve_nodes() -> void:
	detail_image = get_node("Row/DetailImage") as TextureRect
	detail_title = get_node("Row/TextColumn/DetailTitle") as Label
	detail_text = get_node("Row/TextColumn/DetailText") as RichTextLabel


func _card_detail_bbcode(
	card_id: String,
	pokemon: PokemonState,
	catalog: CardCatalog,
) -> String:
	var card := {}
	if catalog:
		card = catalog.get_card(card_id)
	else:
		card = CardDatabase.get_card(card_id)
	var lines: Array[String] = []
	var supertype := str(card.get("supertype", ""))
	var subtypes: Array = card.get("subtypes", [])
	lines.append("[color=#9eb0ca]%s%s[/color]" % [
		supertype,
		" · %s" % "/".join(subtypes) if not subtypes.is_empty() else "",
	])
	if int(card.get("hp", 0)) > 0:
		var hp_text := "HP %d" % int(card.get("hp", 0))
		if pokemon:
			hp_text = "HP %d/%d" % [
				pokemon.current_hp(catalog),
				int(card.get("hp", 0)),
			]
		lines.append(hp_text)
	for ability_value in card.get("abilities", []):
		var ability: Dictionary = ability_value
		lines.append("[color=#62d7ff]特性 · %s[/color]\n%s" % [
			ability.get("name", ""),
			ability.get("text", ""),
		])
	for attack_value in card.get("attacks", []):
		var attack: Dictionary = attack_value
		lines.append("[color=#f4c84a]%s · %s[/color]\n%s" % [
			attack.get("name", ""),
			str(attack.get("damage", 0)),
			attack.get("text", ""),
		])
	if not str(card.get("trainer_text", "")).is_empty():
		lines.append(str(card.get("trainer_text", "")))
	for rule in card.get("rules", []):
		if not str(rule).is_empty() and str(rule) not in lines:
			lines.append(str(rule))
	return "\n\n".join(lines)

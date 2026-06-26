class_name CardInspectorPanel
extends VBoxContainer

signal card_requested(context: Dictionary)

const CARD_SCENE := preload("res://ui/card_view.tscn")

var catalog: CardCatalog


func configure(p_catalog: CardCatalog, context: Dictionary) -> void:
	catalog = p_catalog
	_clear_children()
	add_theme_constant_override("separation", 12)
	var card_id := str(context.get("card_id", ""))
	if card_id.is_empty():
		add_child(_label("没有可查看的卡牌。", 16, DesignTokens.TEXT_MUTED))
		return
	var card := catalog.get_card(card_id)
	var location := str(context.get("location", ""))
	if not location.is_empty():
		add_child(_label(location, 15, DesignTokens.TEXT_MUTED))
	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 18)
	add_child(top_row)
	var image := TextureRect.new()
	image.custom_minimum_size = Vector2(210, 294)
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	image.texture = CardTextureCache.get_texture(str(card.get("image_path", "")))
	top_row.add_child(image)
	var detail := RichTextLabel.new()
	detail.custom_minimum_size = Vector2(540, 294)
	detail.fit_content = true
	detail.bbcode_enabled = true
	detail.text = _card_detail_bbcode(card_id, context.get("pokemon") as PokemonState)
	top_row.add_child(detail)
	var pokemon := context.get("pokemon") as PokemonState
	if pokemon:
		_add_card_grid_section("进化链", _pokemon_evolution_cards(pokemon), false)
		_add_card_grid_section("附着能量", pokemon.energy_card_ids, false)
		if not pokemon.attached_tool_id.is_empty():
			_add_card_grid_section("宝可梦道具", [pokemon.attached_tool_id], false)


func _add_card_grid_section(
	title_text: String,
	card_ids: Array,
	is_hidden: bool,
) -> void:
	add_child(_label(title_text, 20, DesignTokens.GOLD))
	var grid := GridContainer.new()
	grid.columns = 6
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	add_child(grid)
	if card_ids.is_empty():
		grid.add_child(_label("无", 14, DesignTokens.TEXT_MUTED))
		return
	for value in card_ids:
		var card_id := str(value)
		var card_view := CARD_SCENE.instantiate() as CardView
		card_view.custom_minimum_size = Vector2(82, 116)
		card_view.configure(card_id, null, is_hidden, -1, -1, "", true)
		card_view.tooltip_text = (
			"隐藏卡牌"
			if is_hidden
			else str(catalog.get_card(card_id).get("name", card_id))
		)
		if not is_hidden and not card_id.is_empty():
			card_view.activated.connect(func(
				_selected_id: String,
				_hand_index: int,
				_player: int,
				_slot: String,
			) -> void:
				card_requested.emit({"card_id": card_id, "location": title_text})
			)
		grid.add_child(card_view)


func _pokemon_evolution_cards(pokemon: PokemonState) -> Array[String]:
	var result: Array[String] = []
	for value in pokemon.evolution_stack_ids:
		var card_id := str(value)
		if not card_id.is_empty():
			result.append(card_id)
	if not pokemon.card_id.is_empty():
		result.append(pokemon.card_id)
	return result


func _card_detail_bbcode(card_id: String, pokemon: PokemonState = null) -> String:
	var card := catalog.get_card(card_id)
	var rows: Array[String] = []
	var supertype := str(card.get("supertype", ""))
	var subtypes: Array = card.get("subtypes", [])
	rows.append("[color=#9eb0ca]%s%s[/color]" % [
		supertype,
		" · %s" % " / ".join(subtypes) if not subtypes.is_empty() else "",
	])
	if int(card.get("hp", 0)) > 0:
		var maximum := int(card.get("hp", 0))
		var hp_text := "HP %d" % maximum
		if pokemon:
			hp_text = "HP %d/%d · 伤害 %d" % [
				pokemon.current_hp(catalog),
				maximum,
				pokemon.damage_counters * 10,
			]
		rows.append(hp_text)
	if not str(card.get("evolves_from", "")).is_empty():
		rows.append("进化自：%s" % str(card.get("evolves_from", "")))
	if pokemon:
		if not pokemon.status_conditions.is_empty():
			var statuses: Array[String] = []
			for status in pokemon.status_conditions:
				statuses.append(_status_name(str(status)))
			rows.append("特殊状态：" + "、".join(statuses))
		if not pokemon.energy_card_ids.is_empty():
			var energy_names: Array[String] = []
			for energy_id in pokemon.energy_card_ids:
				energy_names.append(catalog.card_name(energy_id))
			rows.append("附着能量：%s" % "、".join(energy_names))
		if not pokemon.attached_tool_id.is_empty():
			rows.append("宝可梦道具：%s" % catalog.card_name(pokemon.attached_tool_id))
	for ability_value in card.get("abilities", []):
		var ability: Dictionary = ability_value
		rows.append("[color=#62d7ff]特性 · %s[/color]\n%s" % [
			str(ability.get("name", "")),
			str(ability.get("text", "")),
		])
	for attack_value in card.get("attacks", []):
		var attack: Dictionary = attack_value
		rows.append("[color=#f4c84a]%s · %s[/color]\n%s" % [
			str(attack.get("name", "")),
			str(attack.get("damage", "")),
			str(attack.get("text", "")),
		])
	if not str(card.get("trainer_text", "")).is_empty():
		rows.append(str(card.get("trainer_text", "")))
	for rule_value in card.get("rules", []):
		var rule := str(rule_value)
		if not rule.is_empty():
			rows.append(rule)
	var retreat := int(card.get("retreat_cost", 0))
	if retreat > 0:
		rows.append("撤退费用：%d" % retreat)
	return "\n\n".join(rows)


func _status_name(status: String) -> String:
	return {
		"POISONED": "中毒",
		"BURNED": "灼伤",
		"ASLEEP": "睡眠",
		"PARALYZED": "麻痹",
		"CONFUSED": "混乱",
	}.get(status, status)


func _label(text_value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text_value
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_constant_override("outline_size", 0)
	label.add_theme_color_override("font_outline_color", Color.TRANSPARENT)
	return label


func _clear_children() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()

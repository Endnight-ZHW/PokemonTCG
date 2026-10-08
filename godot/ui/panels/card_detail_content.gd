class_name CardDetailContent
extends RefCounted

## Shared card rules and attachment controls for full and battle inspection.
const BOLD := preload("res://assets/ui/fonts/noto_sans_cjk_sc_bold.tres")
const MEDIUM := preload("res://assets/ui/fonts/noto_sans_cjk_sc_medium.tres")
var catalog: CardCatalog
var front := true
var ink: Color
var muted: Color
var paper: Color
var inset: Color
var line: Color
var accent: Color
var green: Color
var attachment_buttons: Array[Button] = []


func configure(owner: Control, p_catalog: CardCatalog) -> void:
	catalog = p_catalog
	front = SurfacePalette.is_frontend(owner)
	var palette := SurfacePalette.for_control(owner)
	ink = palette.TEXT
	muted = palette.MUTED
	paper = palette.PANEL
	inset = Color("f5f6f8") if front else Color("f4ecdf")
	line = FrontendPalette.BORDER_SOFT if front else DesignTokens.BORDER_SOFT
	accent = palette.GOLD
	green = palette.SUCCESS
	attachment_buttons.clear()


func attribute_icons(card: Dictionary, pixels: int) -> HBoxContainer:
	var row := hbox(3)
	for energy_type in card.get("energy_types", []):
		var icon := FrontendAttributes.texture_for(str(energy_type))
		var description := EnergyIconCatalog.type_display_name_for(str(energy_type))
		if icon:
			var item := texture(icon, Vector2(pixels, pixels))
			item.accessibility_name = description
			item.tooltip_text = description
			item.mouse_filter = Control.MOUSE_FILTER_PASS
			row.add_child(item)
		else:
			row.add_child(label(description, 12, muted))
	return row


func add_attachment_summary(parent: VBoxContainer, pokemon: PokemonState) -> void:
	var summary := HFlowContainer.new()
	summary.add_theme_constant_override("h_separation", 10)
	summary.add_theme_constant_override("v_separation", 4)
	parent.add_child(summary)
	summary.add_child(label("附着能量  %d张" % pokemon.energy_card_ids.size(), 13, muted, true))
	var counts := CardPresentation.energy_card_counts(pokemon.energy_card_ids)
	for energy_id in counts:
		var energy := catalog.get_card(energy_id)
		var provided := Array(energy.get("provides_energy", []))
		var is_basic := "Basic" in Array(energy.get("subtypes", []))
		if is_basic and provided.size() == 1:
			var row := hbox(3)
			row.accessibility_name = "%s ×%d" % [catalog.card_name(energy_id), counts[energy_id]]
			row.add_child(texture(EnergyIconCatalog.texture_for(str(provided[0])), Vector2(18, 18)))
			row.add_child(label("×%d" % int(counts[energy_id]), 14, ink))
			summary.add_child(row)
		else:
			summary.add_child(label("%s ×%d" % [catalog.card_name(energy_id), counts[energy_id]], 13, ink))
	if not pokemon.attached_tool_id.is_empty():
		parent.add_child(paragraph("道具  " + catalog.card_name(pokemon.attached_tool_id), 14, ink))


func identity_row(card: Dictionary) -> Control:
	var row := hbox(12)
	var tags := paragraph(compact_meta(card), 16, muted)
	tags.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(tags)
	if int(card.get("hp", 0)) > 0:
		row.add_child(label("卡面 HP", 13, muted))
		row.add_child(label(str(int(card.hp)), 26, ink, true))
	return row


func compact_meta(card: Dictionary) -> String:
	return CardPresentation.meta_text(card).replace("宝可梦 · ", "").replace("属性：", "")


func add_rules(parent: VBoxContainer, card: Dictionary, compact: bool) -> void:
	var text_size := 16 if compact else 18
	var groups := CardPresentation.detail_groups(card, catalog)
	for ability in groups.filter(func(group: Dictionary) -> bool: return group.kind == "ability"):
		var block := vbox(6)
		var heading := hbox(8)
		heading.add_child(badge("特性", green, compact))
		var title := paragraph(str(ability.title), text_size + 1, green, true)
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		heading.add_child(title)
		block.add_child(heading)
		if not str(ability.get("text", "")).is_empty():
			block.add_child(paragraph(str(ability.text), text_size, ink))
		parent.add_child(block)
		parent.add_child(separator())
	for attack in groups.filter(func(group: Dictionary) -> bool: return group.kind == "attack"):
		parent.add_child(attack_block(attack, compact))
		parent.add_child(separator())
	# Consume the shared rule groups so trainer / special-energy wording and
	# de-duplication stay identical to the real game's inspected card.
	for group in groups:
		if str(group.kind) not in ["rules", "energy"]:
			continue
		var rich := RichTextLabel.new()
		rich.bbcode_enabled = true
		rich.fit_content = true
		rich.scroll_active = false
		rich.mouse_filter = Control.MOUSE_FILTER_PASS
		rich.add_theme_font_size_override("normal_font_size", text_size)
		rich.add_theme_font_size_override("bold_font_size", text_size)
		rich.add_theme_font_override("normal_font", MEDIUM)
		rich.add_theme_font_override("bold_font", BOLD)
		rich.text = SurfacePalette.card_text_for_surface(str(group.bbcode), front)
		parent.add_child(rich)
	if int(card.get("hp", 0)) > 0:
		parent.add_child(matchup_row(card, compact))


func attack_block(attack: Dictionary, compact: bool) -> VBoxContainer:
	var text_size := 16 if compact else 18
	var block := vbox(6 if compact else 10)
	block.name = "AttackRule"
	block.accessibility_description = "%s。%s。%s。%s" % [attack.get("name", ""),
		CardPresentation.energy_cost_text(attack.get("cost", [])), attack.get("damage_text", ""), attack.get("text", "")]
	var heading := hbox(10)
	block.add_child(heading)
	var cost := energy_icons(attack.get("cost", []), 20 if compact else 24)
	cost.name = "EnergyCost"
	cost.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	heading.add_child(cost)
	var name_label := paragraph(str(attack.get("name", "")), text_size + 1, ink, true)
	name_label.name = "AttackName"
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_child(name_label)
	var damage := str(attack.get("damage_text", ""))
	if not damage.is_empty():
		var damage_label := label(damage, 22 if compact else 30, accent, true)
		damage_label.name = "PrintedDamage"
		heading.add_child(damage_label)
	if not str(attack.get("text", "")).is_empty():
		block.add_child(paragraph(str(attack.text), text_size, ink))
	return block


func matchup_row(card: Dictionary, compact: bool) -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", style(inset, 8, Color.TRANSPARENT, 0, 8 if compact else 12))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	panel.add_child(row)
	for key in ["weaknesses", "resistances", "retreat_cost"]:
		var cell := vbox(4)
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(cell)
		cell.add_child(label({"weaknesses": "弱点", "resistances": "抗性", "retreat_cost": "撤退"}[key], 12, muted))
		if key == "retreat_cost":
			var count := int(card.get(key, 0))
			var costs: Array = []
			for index in count:
				costs.append("Colorless")
			cell.add_child(energy_icons(costs, 14 if compact else 18) if count > 0 else label("0", 14, ink))
		else:
			var matches := Array(card.get(key, []))
			if matches.is_empty():
				cell.add_child(label("无", 14, muted))
			else:
				for item in matches:
					var value_row := hbox(3)
					value_row.add_child(texture(EnergyIconCatalog.texture_for(str(item.energy_type)), Vector2(18, 18)))
					value_row.add_child(label(str(item.value), 14, ink, true))
					cell.add_child(value_row)
	return panel


func state_block(pokemon: PokemonState) -> Control:
	var state := CardPresentation.battle_state(pokemon, catalog, int(catalog.get_card(pokemon.card_id).get("hp", 0)))
	var block := PanelContainer.new()
	block.name = "CurrentBattleState"
	block.add_theme_stylebox_override("panel", style(Color("edf3eb") if front else DesignTokens.SUCCESS_SURFACE, 10, Color.TRANSPARENT, 0, 14))
	var column := vbox(8)
	block.add_child(column)
	var row := hbox(8)
	column.add_child(row)
	var heading := label("当前对战状态", 15, green, true)
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(heading)
	row.add_child(label("HP  %d / %d" % [state.current_hp, state.maximum_hp], 22, green, true))
	var hp_bar := ProgressBar.new()
	hp_bar.custom_minimum_size.y = 5
	hp_bar.show_percentage = false
	hp_bar.max_value = maxi(1, int(state.maximum_hp))
	hp_bar.value = int(state.current_hp)
	hp_bar.add_theme_stylebox_override("background", style(Color("d7e1d2"), 3))
	hp_bar.add_theme_stylebox_override("fill", style(green, 3))
	column.add_child(hp_bar)
	var status := status_text(pokemon)
	column.add_child(paragraph("已受伤害 %d%s" % [pokemon.damage_counters * 10, "   ·   " + status if not status.is_empty() else "   ·   无特殊状态"], 15, ink))
	if not Array(state.used_abilities).is_empty():
		column.add_child(paragraph("本回合已使用特性：" + "、".join(state.used_abilities), 15, ink))
	return block


func add_attachments(parent: VBoxContainer, pokemon: PokemonState) -> void:
	for group in CardPresentation.attachment_groups(pokemon):
		parent.add_child(label(str(group.title), 15, muted, true))
		for row in group.rows:
			parent.add_child(attachment_row(str(row.card_id), str(row.hint), int(row.count)))


func attachment_row(card_id: String, hint: String, count: int) -> Button:
	var result := button("")
	result.custom_minimum_size.y = 64
	result.set_meta("card_id", card_id)
	result.accessibility_name = "查看%s，%d张" % [catalog.card_name(card_id), count]
	var margin := MarginContainer.new()
	result.add_child(margin)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var row := hbox(10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(row)
	row.add_child(texture(FrontendAttributes.card_texture(catalog, card_id), Vector2(36, 50)))
	var name_label := paragraph(catalog.card_name(card_id), 16, ink)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)
	if not hint.is_empty():
		row.add_child(label(hint, 12, muted))
	if count > 1:
		row.add_child(label("×%d" % count, 18, ink, true))
	row.add_child(label("›", 22, muted))
	ignore_pointer_children(result)
	margin.minimum_size_changed.connect(func() -> void:
		result.custom_minimum_size.y = maxf(64.0, margin.get_combined_minimum_size().y))
	attachment_buttons.append(result)
	return result


func energy_icons(costs: Array, pixels: int) -> Control:
	var row := hbox(3)
	for energy_type in costs:
		var icon := EnergyIconCatalog.texture_for(str(energy_type))
		if icon:
			var item := texture(icon, Vector2(pixels, pixels))
			item.accessibility_name = EnergyIconCatalog.display_name_for(str(energy_type))
			row.add_child(item)
		else:
			row.add_child(label(EnergyIconCatalog.display_name_for(str(energy_type)), 14, muted))
	return row


func reading_pane() -> Dictionary:
	var scroll := ScrollContainer.new()
	scroll.name = "RuleScroll"
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.follow_focus = false
	scroll.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	FrontendPalette.style_scrollbar(scroll.get_v_scroll_bar()) if front else BattleModalPalette.style_scrollbar(scroll.get_v_scroll_bar())
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_right", 12)
	scroll.add_child(margin)
	var contents := vbox(14 if front else 12)
	margin.add_child(contents)
	return {"scroll": scroll, "contents": contents}


func button(caption: String) -> Button:
	var result := Button.new()
	result.text = caption
	result.focus_mode = Control.FOCUS_NONE
	result.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	result.custom_minimum_size.y = 48
	result.add_theme_font_override("font", BOLD)
	result.add_theme_font_size_override("font_size", 16)
	for state in ["normal", "hover", "pressed"]:
		result.add_theme_stylebox_override(state, style(paper if state == "normal" else inset, 9, line if state == "normal" else accent, 1, 8))
	for key in ["font_color", "font_hover_color", "font_pressed_color"]:
		result.add_theme_color_override(key, ink)
	return result


func label(value: String, pixels: int, color: Color, bold := false) -> Label:
	var item := Label.new()
	item.text = value
	item.mouse_filter = Control.MOUSE_FILTER_IGNORE
	item.add_theme_font_override("font", BOLD if bold else MEDIUM)
	item.add_theme_font_size_override("font_size", pixels)
	item.add_theme_color_override("font_color", color)
	return item


func paragraph(value: String, pixels: int, color: Color, bold := false) -> Label:
	var item := label(value, pixels, color, bold)
	item.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	item.add_theme_constant_override("line_spacing", 4)
	return item


func badge(value: String, color: Color, compact := false) -> PanelContainer:
	var panel := PanelContainer.new()
	var box := style(color.lerp(paper, 0.91), 5, Color.TRANSPARENT, 0, 6)
	box.content_margin_top = 2
	box.content_margin_bottom = 2
	panel.add_theme_stylebox_override("panel", box)
	panel.add_child(label(value, 12 if compact else 13, color, true))
	return panel


func texture(value: Texture2D, dimensions: Vector2) -> TextureRect:
	var item := TextureRect.new()
	item.texture = value
	item.custom_minimum_size = dimensions
	item.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	item.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	item.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return item


func separator() -> HSeparator:
	var item := HSeparator.new()
	var box := StyleBoxLine.new()
	box.color = line
	box.thickness = 1
	item.add_theme_stylebox_override("separator", box)
	item.add_theme_constant_override("separation", 2)
	return item


func vbox(gap: int) -> VBoxContainer:
	var item := VBoxContainer.new()
	item.add_theme_constant_override("separation", gap)
	return item


func hbox(gap: int) -> HBoxContainer:
	var item := HBoxContainer.new()
	item.add_theme_constant_override("separation", gap)
	return item


func style(fill: Color, radius: int, border := Color.TRANSPARENT, width := 0, padding := 0) -> StyleBoxFlat:
	return DesignTokens.panel_style(fill, radius, border, width, padding)


func status_text(pokemon: PokemonState) -> String:
	return " · ".join(CardPresentation.battle_state(pokemon, catalog, 0).statuses)


func ignore_pointer_children(parent: Node) -> void:
	for child in parent.get_children():
		if child is Control:
			child.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ignore_pointer_children(child)

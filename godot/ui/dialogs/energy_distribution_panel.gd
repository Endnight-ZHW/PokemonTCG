class_name EnergyDistributionPanel
extends Node

var panel: ChoicePanel
var draft: EnergyDistributionModel
var _energy_preview_cards: Array[CardView] = []
var _energy_assignment_labels: Array[Label] = []
var _energy_distribution_mode := false
var _energy_target_models: Array[Dictionary] = []
var _energy_target_tiles: Dictionary = {}
var _energy_target_cards: Dictionary = {}
var _energy_target_existing_rows: Dictionary = {}
var _energy_target_projected_rows: Dictionary = {}
var _energy_target_status_labels: Dictionary = {}
var _energy_target_key_by_option_id: Dictionary = {}
var _energy_index_by_option_id: Dictionary = {}
var _energy_source_card_ids: Array[String] = []


func configure(p_panel: ChoicePanel) -> void:
	panel = p_panel


func add_energy_preview(card_ids: Array[String], p_catalog: CardCatalog) -> void:
	panel._add_preview_cards(card_ids, p_catalog, "待分配能量", true)

func configure_energy_distribution(
	card_ids: Array[String],
	target_models: Array[Dictionary],
	p_catalog: CardCatalog,
) -> void:
	panel._resolve_nodes()
	if panel.catalog == null and p_catalog != null:
		panel.catalog = p_catalog
	_energy_distribution_mode = true
	_energy_target_models.assign(target_models)
	_energy_source_card_ids.assign(card_ids)
	panel._add_preview_cards(card_ids, p_catalog, "① 选择能量　② 点击目标　③ 确认分配", true)
	if draft != null and bool(draft.request.presentation.get("same_target", false)):
		panel.metadata_label.text += "\n共同目标：改派任意一张，会同步更换已分配能量的目标。"
	panel._clear_children(panel.card_grid)
	panel.card_grid.visible = not target_models.is_empty()
	panel.option_list.visible = false
	_energy_target_tiles.clear()
	_energy_target_cards.clear()
	_energy_target_existing_rows.clear()
	_energy_target_projected_rows.clear()
	_energy_target_status_labels.clear()
	_energy_target_key_by_option_id.clear()
	_energy_index_by_option_id.clear()
	for model_value in target_models:
		var model := Dictionary(model_value).duplicate(true)
		_register_energy_target_model(model)
		_add_energy_target_tile(model)
	_refresh_energy_target_tiles([])
	panel._queue_responsive_layout()

func _on_energy_placeholder_gui_input(
	event: InputEvent,
	energy_index: int,
	placeholder: Control,
) -> void:
	if not placeholder.has_meta("pointer_tap"):
		placeholder.set_meta("pointer_tap", PointerTap.new())
	var tap := placeholder.get_meta("pointer_tap") as PointerTap
	if tap.handle(placeholder, event):
		panel.energy_index_requested.emit(energy_index)

func _on_energy_preview_card_activated(
	card_id: String,
	energy_index: int,
	interactive_distribution: bool,
) -> void:
	panel._preview_card(card_id)
	if not interactive_distribution:
		return
	panel.energy_index_requested.emit(energy_index)

func _register_energy_target_model(model: Dictionary) -> void:
	var target_key := str(model.get("target_key", ""))
	var target_label := str(model.get(
		"assignment_label",
		model.get("label", target_key),
	))
	var option_ids_value: Variant = model.get("option_ids_by_energy_index", {})
	var option_ids := (
		Dictionary(option_ids_value)
		if option_ids_value is Dictionary
		else {}
	)
	for index_value in option_ids:
		var option_id := str(option_ids[index_value])
		if option_id.is_empty():
			continue
		var energy_index := int(index_value)
		_energy_target_key_by_option_id[option_id] = target_key
		_energy_index_by_option_id[option_id] = energy_index
		panel._option_labels[option_id] = target_label
		panel._selection_counts[option_id] = 0
	var fallback_option_id := str(model.get("fallback_option_id", ""))
	if not fallback_option_id.is_empty():
		_energy_target_key_by_option_id[fallback_option_id] = target_key
		panel._option_labels[fallback_option_id] = target_label
		panel._selection_counts[fallback_option_id] = 0

func _add_energy_target_tile(model: Dictionary) -> void:
	var target_key := str(model.get("target_key", ""))
	if target_key.is_empty():
		return
	var tile := PanelContainer.new()
	tile.name = "EnergyTargetTile"
	tile.custom_minimum_size = panel.ENERGY_TARGET_TILE_SIZE
	tile.mouse_filter = Control.MOUSE_FILTER_STOP
	tile.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	tile.set_meta("energy_target_key", target_key)
	tile.set_meta("choice_hovered", false)
	tile.gui_input.connect(_on_energy_target_gui_input.bind(target_key))
	tile.mouse_entered.connect(_on_energy_target_hover_changed.bind(target_key, true))
	tile.mouse_exited.connect(_on_energy_target_hover_changed.bind(target_key, false))

	var content := HBoxContainer.new()
	content.mouse_filter = Control.MOUSE_FILTER_PASS
	content.add_theme_constant_override("separation", 10)
	tile.add_child(content)

	var card := panel.CARD_SCENE.instantiate() as CardView
	card.custom_minimum_size = Vector2(82, 116)
	card.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.selected_lift = 0.0
	card.selected_scale = 1.0
	card.hover_lift = 0.0
	card.hover_scale = 1.0
	card.set_catalog(panel.catalog)
	var pokemon := model.get("pokemon") as PokemonState
	card.configure(
		str(model.get("card_id", "")),
		pokemon.clone_state() if pokemon != null else null,
		false,
		-1,
		int(model.get("player", -1)),
		str(model.get("slot", "")),
		false,
	)
	content.add_child(card)

	var summary := VBoxContainer.new()
	summary.mouse_filter = Control.MOUSE_FILTER_PASS
	summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	summary.add_theme_constant_override("separation", 3)
	content.add_child(summary)

	var title := Label.new()
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.text = str(model.get("name", model.get("label", "宝可梦")))
	title.tooltip_text = ""
	title.accessibility_name = title.text
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", BattleModalPalette.TEXT)
	summary.add_child(title)

	var location := Label.new()
	location.mouse_filter = Control.MOUSE_FILTER_IGNORE
	location.text = str(model.get("location", "目标"))
	location.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	location.add_theme_font_size_override("font_size", 16)
	location.add_theme_color_override("font_color", BattleModalPalette.GOLD)
	summary.add_child(location)

	var hp_label := Label.new()
	hp_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hp_label.text = _pokemon_hp_text(pokemon)
	hp_label.add_theme_font_size_override("font_size", 16)
	hp_label.add_theme_color_override("font_color", BattleModalPalette.MUTED)
	summary.add_child(hp_label)

	var existing_row := HFlowContainer.new()
	existing_row.name = "ExistingEnergyRow"
	existing_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	existing_row.add_theme_constant_override("h_separation", 4)
	existing_row.add_theme_constant_override("v_separation", 3)
	summary.add_child(existing_row)

	var projected_row := HFlowContainer.new()
	projected_row.name = "ProjectedEnergyRow"
	projected_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	projected_row.add_theme_constant_override("h_separation", 4)
	projected_row.add_theme_constant_override("v_separation", 3)
	summary.add_child(projected_row)

	var status := Label.new()
	status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	status.custom_minimum_size.y = 28.0
	status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.add_theme_font_size_override("font_size", 16)
	summary.add_child(status)

	panel.card_grid.add_child(tile)
	_energy_target_tiles[target_key] = tile
	_energy_target_cards[target_key] = card
	_energy_target_existing_rows[target_key] = existing_row
	_energy_target_projected_rows[target_key] = projected_row
	_energy_target_status_labels[target_key] = status

func _pokemon_hp_text(pokemon: PokemonState) -> String:
	if pokemon == null or panel.catalog == null:
		return "状态暂不可用"
	var maximum := pokemon.max_hp(panel.catalog)
	var current := pokemon.current_hp(panel.catalog)
	var damage := pokemon.damage_counters * 10
	return "HP %d/%d%s" % [
		current,
		maximum,
		" · 伤害 %d" % damage if damage > 0 else "",
	]

func _refresh_energy_target_tiles(selected_ids: Array[String]) -> void:
	if _energy_target_models.is_empty():
		return
	var selected_by_target: Dictionary = {}
	for option_id in selected_ids:
		var target_key := str(_energy_target_key_by_option_id.get(option_id, ""))
		if target_key.is_empty():
			continue
		selected_by_target[target_key] = int(selected_by_target.get(target_key, 0)) + 1
	var current_index := draft.current_index if draft != null else selected_ids.size()
	for model_value in _energy_target_models:
		var model := Dictionary(model_value)
		var target_key := str(model.get("target_key", ""))
		var tile := _energy_target_tiles.get(target_key) as PanelContainer
		if tile == null:
			continue
		var option_id := _energy_option_id_for_target(model, current_index)
		var blocked_reason := (
			""
			if current_index < 0 or current_index >= _energy_source_card_ids.size()
			else str(panel._option_disabled_reasons.get(option_id, ""))
		)
		if current_index >= 0 and current_index < _energy_source_card_ids.size() and option_id.is_empty():
			blocked_reason = "这张能量不能附着于此目标"
		var assigned_count := int(selected_by_target.get(target_key, 0))
		var hovered := bool(tile.get_meta("choice_hovered", false))
		_apply_energy_target_style(
			tile,
			assigned_count > 0,
			hovered,
			not blocked_reason.is_empty(),
		)
		var base_pokemon := model.get("pokemon") as PokemonState
		var projected := base_pokemon.clone_state() if base_pokemon != null else null
		var pending_ids: Array[String] = []
		if projected != null:
			var indices: Array = draft.assignments.keys() if draft != null else range(selected_ids.size())
			for selected_position in indices:
				var selected_id := str(draft.assignments[selected_position]) if draft != null else str(selected_ids[selected_position])
				if str(_energy_target_key_by_option_id.get(selected_id, "")) != target_key:
					continue
				var energy_index := int(_energy_index_by_option_id.get(
					selected_id, selected_position))
				if energy_index < 0 or energy_index >= _energy_source_card_ids.size():
					continue
				var energy_id := _energy_source_card_ids[energy_index]
				if energy_id.is_empty():
					continue
				projected.energy_card_ids.append(energy_id)
				pending_ids.append(energy_id)
		var card := _energy_target_cards.get(target_key) as CardView
		if card:
			card.configure(
				str(model.get("card_id", "")),
				projected,
				false,
				-1,
				int(model.get("player", -1)),
				str(model.get("slot", "")),
				false,
			)
		var existing_row := _energy_target_existing_rows.get(target_key) as Container
		var projected_row := _energy_target_projected_rows.get(target_key) as Container
		_populate_energy_summary(
			existing_row,
			"已有",
			base_pokemon.energy_card_ids if base_pokemon != null else [],
			[],
		)
		_populate_energy_summary(
			projected_row,
			"本次新增",
			pending_ids,
			pending_ids,
		)
		var status := _energy_target_status_labels.get(target_key) as Label
		if status:
			if not blocked_reason.is_empty():
				status.text = "不可选择 · %s" % PlayerFacingText.message(blocked_reason, true)
				status.tooltip_text = ""
				status.accessibility_description = blocked_reason
				status.add_theme_color_override("font_color", BattleModalPalette.DANGER)
			elif current_index < 0 or current_index >= _energy_source_card_ids.size():
				status.text = (
					"✓ 本次分配 +%d 张" % assigned_count
					if assigned_count > 0
					else "本次未分配"
				)
				status.tooltip_text = ""
				status.accessibility_description = status.text
				status.add_theme_color_override(
					"font_color",
					BattleModalPalette.GOLD if assigned_count > 0 else BattleModalPalette.MUTED,
				)
			else:
				status.text = "%s点击分配第 %d 张" % [
					"已分配 +%d 张 · " % assigned_count if assigned_count > 0 else "",
					current_index + 1,
				]
				status.tooltip_text = ""
				status.accessibility_description = status.text
				status.add_theme_color_override("font_color", BattleModalPalette.GOLD)
		var status_description := blocked_reason if not blocked_reason.is_empty() else str(
			status.text if status else model.get("label", "分配目标")
		)
		tile.tooltip_text = ""
		tile.accessibility_name = "%s，%s" % [
			str(model.get("label", "分配目标")),
			status_description,
		]
		tile.mouse_default_cursor_shape = (
			Control.CURSOR_FORBIDDEN
			if not blocked_reason.is_empty()
			else Control.CURSOR_POINTING_HAND
		)

func _populate_energy_summary(
	row: Container,
	prefix: String,
	card_ids: Array,
	pending_ids: Array[String],
) -> void:
	if row == null:
		return
	panel._clear_children_immediate(row)
	var prefix_label := Label.new()
	prefix_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	prefix_label.text = prefix
	prefix_label.add_theme_font_size_override("font_size", 16)
	prefix_label.add_theme_color_override("font_color", BattleModalPalette.MUTED)
	row.add_child(prefix_label)
	var grouped: Array = panel.ATTACHMENT_VISUALS.grouped_energy(card_ids, panel.catalog)
	if grouped.is_empty():
		var empty := Label.new()
		empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
		empty.text = "无"
		empty.add_theme_font_size_override("font_size", 16)
		empty.add_theme_color_override("font_color", BattleModalPalette.MUTED)
		row.add_child(empty)
		return
	for descriptor_value in grouped:
		var descriptor := descriptor_value as AttachmentVisualDescriptor
		if descriptor == null:
			continue
		var highlighted := false
		for pending_id in pending_ids:
			if pending_id in descriptor.card_ids:
				highlighted = true
				break
		row.add_child(_energy_summary_chip(descriptor, highlighted))

func _energy_summary_chip(
	descriptor: AttachmentVisualDescriptor,
	highlighted: bool,
) -> PanelContainer:
	var chip := PanelContainer.new()
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var border_color := (
		BattleModalPalette.GOLD
		if highlighted
		else DesignTokens.type_color(descriptor.energy_type)
	)
	chip.add_theme_stylebox_override(
		"panel",
		DesignTokens.panel_style(
			BattleModalPalette.INSET,
			8,
			Color(border_color, 0.86),
			1,
			3,
		),
	)
	var content := HBoxContainer.new()
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_theme_constant_override("separation", 2)
	chip.add_child(content)
	if descriptor.icon != null:
		var icon := TextureRect.new()
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.custom_minimum_size = Vector2(18, 18)
		icon.texture = descriptor.icon
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		content.add_child(icon)
	else:
		var fallback := Label.new()
		fallback.mouse_filter = Control.MOUSE_FILTER_IGNORE
		fallback.custom_minimum_size = Vector2(18, 18)
		fallback.text = descriptor.fallback_label
		fallback.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		fallback.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		fallback.add_theme_font_size_override("font_size", 16)
		content.add_child(fallback)
	var count := Label.new()
	count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var provided_count := descriptor.provided_unit_count()
	count.text = (
		"%d张·%d点" % [descriptor.count, provided_count]
	)
	count.add_theme_font_size_override("font_size", 16)
	count.add_theme_color_override(
		"font_color", BattleModalPalette.GOLD if highlighted else BattleModalPalette.TEXT)
	content.add_child(count)
	chip.tooltip_text = ""
	chip.accessibility_name = "%s：附着 %d 张，提供 %d 个能量%s" % [
		descriptor.display_name,
		descriptor.count,
		provided_count,
		"，本次新增" if highlighted else "",
	]
	return chip

func _energy_option_id_for_target(model: Dictionary, energy_index: int) -> String:
	var option_ids_value: Variant = model.get("option_ids_by_energy_index", {})
	if option_ids_value is Dictionary:
		var option_ids := Dictionary(option_ids_value)
		if option_ids.has(energy_index):
			return str(option_ids[energy_index])
		if option_ids.has(str(energy_index)):
			return str(option_ids[str(energy_index)])
	return str(model.get("fallback_option_id", ""))

func _on_energy_target_gui_input(event: InputEvent, target_key: String) -> void:
	var tile := _energy_target_tiles.get(target_key) as Control
	if tile == null:
		return
	if not tile.has_meta("pointer_tap"):
		tile.set_meta("pointer_tap", PointerTap.new())
	var tap := tile.get_meta("pointer_tap") as PointerTap
	if not tap.handle(tile, event):
		return
	var model := _energy_target_model(target_key)
	var current_index := draft.current_index if draft != null else panel._last_selected_ids.size()
	if model.is_empty() or current_index < 0 or current_index >= _energy_source_card_ids.size():
		panel.show_blocked_reason("点击上方能量可改派；完成后点击确认分配")
		return
	var option_id := _energy_option_id_for_target(model, current_index)
	if option_id.is_empty():
		panel.show_blocked_reason("这张能量不能附着于此目标，请选择其他目标")
		return
	var blocked_reason := str(panel._option_disabled_reasons.get(option_id, ""))
	if not blocked_reason.is_empty():
		panel.show_blocked_reason(blocked_reason)
		return
	panel._clear_blocked_reason()
	panel.option_toggled.emit(option_id)

func _energy_target_model(target_key: String) -> Dictionary:
	for model_value in _energy_target_models:
		var model := Dictionary(model_value)
		if str(model.get("target_key", "")) == target_key:
			return model
	return {}

func _on_energy_target_hover_changed(target_key: String, hovered: bool) -> void:
	var tile := _energy_target_tiles.get(target_key) as PanelContainer
	if tile == null:
		return
	tile.set_meta("choice_hovered", hovered)
	_refresh_energy_target_tiles(panel._last_selected_ids)

func _apply_energy_target_style(
	tile: PanelContainer,
	selected: bool,
	hovered: bool,
	blocked: bool,
) -> void:
	var background := BattleModalPalette.PANEL
	var border := DesignTokens.STATE_TARGET
	var width := 2
	if selected:
		background = BattleModalPalette.PANEL
		border = BattleModalPalette.GOLD
		width = 3
	elif blocked:
		background = BattleModalPalette.INSET
		border = Color(BattleModalPalette.DANGER, 0.62 if hovered else 0.38)
		width = 2 if hovered else 1
	elif hovered:
		background = DesignTokens.PANEL_HOVER
		border = BattleModalPalette.GOLD
		width = 2
	var style := DesignTokens.panel_style(
		background, DesignTokens.RADIUS_MEDIUM, border, width, 8)
	if selected:
		style.shadow_color = DesignTokens.SHADOW
		style.shadow_size = 4
		style.shadow_offset = Vector2.ZERO
	tile.add_theme_stylebox_override("panel", style)

func _refresh_energy_assignment_labels(selected_ids: Array[String]) -> void:
	if not _energy_distribution_mode:
		return
	var assigned_by_index: Dictionary = draft.assignments if draft != null else {}
	if draft == null:
		for position in range(selected_ids.size()):
			var id := selected_ids[position]
			assigned_by_index[int(_energy_index_by_option_id.get(id, position))] = id
	var current := draft.current_index if draft != null else selected_ids.size()
	for index in range(_energy_assignment_labels.size()):
		var label := _energy_assignment_labels[index]
		var card := _energy_preview_cards[index] if index < _energy_preview_cards.size() else null
		var name := panel.catalog.card_name(_energy_source_card_ids[index]) if index < _energy_source_card_ids.size() and not _energy_source_card_ids[index].is_empty() else "能量"
		var destination := str(panel._option_labels.get(str(assigned_by_index.get(index, "")), "待分配"))
		label.text = "%s第 %d 张 · %s\n%s%s" % ["▶ " if index == current else "", index + 1, name, "→ " if assigned_by_index.has(index) else "", destination]
		label.accessibility_name = label.text
		label.add_theme_color_override("font_color", BattleModalPalette.GOLD if index == current else BattleModalPalette.TEXT)
		if card:
			card.set_selected(index == current)
	var preview_index := current
	if preview_index >= 0 and preview_index < _energy_source_card_ids.size():
		var id := _energy_source_card_ids[preview_index]
		if not id.is_empty() and id != panel._previewed_card_id:
			panel._preview_card(id)


func _update_energy_action_buttons(selected_count: int) -> void:
	if panel.energy_actions:
		panel.energy_actions.visible = _energy_distribution_mode and panel._request_type == "distribute_energy"
	if panel.undo_button:
		panel.undo_button.disabled = not draft.can_undo() if draft != null else selected_count <= 0
		panel.undo_button.tooltip_text = "恢复上一次分配、改派、移除或清空之前的状态"
	if panel.clear_button:
		panel.clear_button.disabled = selected_count <= 0
	var remove := panel.get_node_or_null("EnergyActions/RemoveEnergyButton") as Button
	if remove:
		remove.disabled = draft == null or not draft.assignments.has(draft.current_index)
	var detail := panel.get_node_or_null("EnergyActions/EnergyDetailButton") as Button
	if detail:
		detail.disabled = panel._previewed_card_id.is_empty()
		detail.text = "返回分配" if panel._compact_preview_expanded else "查看详情"


func _update_energy_selection_hint(selected_count: int) -> void:
	var minimum := panel._effective_min_select()
	var current := draft.current_index if draft != null else selected_count
	var progress := "已分配 %d / %d 张" % [selected_count, panel._selection_max]
	var remaining := maxi(0, minimum - selected_count)
	if current >= 0 and current < _energy_source_card_ids.size():
		progress += " · 正在%s第 %d 张" % ["改派" if draft != null and draft.assignments.has(current) else "分配", current + 1]
	progress += " · 还需 %d 张" % remaining if remaining > 0 else " · 可以确认，或点选能量继续修改"
	panel.selection_hint_label.text = progress
	panel.selection_hint_label.visible = true

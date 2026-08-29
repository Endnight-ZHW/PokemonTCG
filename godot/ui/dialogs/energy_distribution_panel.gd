class_name EnergyDistributionPanel
extends Node

var panel: ChoicePanel
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
	panel._add_preview_cards(card_ids, p_catalog, "逐张分配", true)
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
) -> void:
	if (
		event is InputEventMouseButton
		and event.button_index == MOUSE_BUTTON_LEFT
		and not event.pressed
	):
		panel.energy_index_requested.emit(energy_index)

func _on_energy_preview_card_activated(
	card_id: String,
	energy_index: int,
	interactive_distribution: bool,
) -> void:
	panel._preview_card(card_id)
	if not interactive_distribution:
		return
	if panel._compact_choice_layout and energy_index >= panel._last_selected_ids.size():
		panel._compact_preview_expanded = true
		panel._queue_responsive_layout()
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
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title.add_theme_font_size_override("font_size", 15)
	title.add_theme_color_override("font_color", DesignTokens.TEXT)
	summary.add_child(title)

	var location := Label.new()
	location.mouse_filter = Control.MOUSE_FILTER_IGNORE
	location.text = str(model.get("location", "目标"))
	location.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	location.add_theme_font_size_override("font_size", 11)
	location.add_theme_color_override("font_color", DesignTokens.CYAN)
	summary.add_child(location)

	var hp_label := Label.new()
	hp_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hp_label.text = _pokemon_hp_text(pokemon)
	hp_label.add_theme_font_size_override("font_size", 11)
	hp_label.add_theme_color_override("font_color", DesignTokens.TEXT_MUTED)
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
	status.add_theme_font_size_override("font_size", 11)
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
	var current_index := selected_ids.size()
	for model_value in _energy_target_models:
		var model := Dictionary(model_value)
		var target_key := str(model.get("target_key", ""))
		var tile := _energy_target_tiles.get(target_key) as PanelContainer
		if tile == null:
			continue
		var option_id := _energy_option_id_for_target(model, current_index)
		var blocked_reason := (
			""
			if current_index >= panel._selection_max
			else str(panel._option_disabled_reasons.get(option_id, ""))
		)
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
			for selected_position in range(selected_ids.size()):
				var selected_id := str(selected_ids[selected_position])
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
			"分配后",
			projected.energy_card_ids if projected != null else [],
			pending_ids,
		)
		var status := _energy_target_status_labels.get(target_key) as Label
		if status:
			if not blocked_reason.is_empty():
				status.text = "不可选择 · %s" % blocked_reason
				status.tooltip_text = ""
				status.accessibility_description = blocked_reason
				status.add_theme_color_override("font_color", DesignTokens.RED)
			elif current_index >= panel._selection_max:
				status.text = (
					"✓ 本次分配 +%d 张" % assigned_count
					if assigned_count > 0
					else "本次未分配"
				)
				status.tooltip_text = ""
				status.accessibility_description = status.text
				status.add_theme_color_override(
					"font_color",
					DesignTokens.GOLD if assigned_count > 0 else DesignTokens.TEXT_MUTED,
				)
			else:
				status.text = "%s点击分配第 %d 张" % [
					"已分配 +%d 张 · " % assigned_count if assigned_count > 0 else "",
					current_index + 1,
				]
				status.tooltip_text = ""
				status.accessibility_description = status.text
				status.add_theme_color_override("font_color", DesignTokens.CYAN)
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
	prefix_label.add_theme_font_size_override("font_size", 10)
	prefix_label.add_theme_color_override("font_color", DesignTokens.TEXT_MUTED)
	row.add_child(prefix_label)
	var grouped: Array = panel.ATTACHMENT_VISUALS.grouped_energy(card_ids, panel.catalog)
	if grouped.is_empty():
		var empty := Label.new()
		empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
		empty.text = "无"
		empty.add_theme_font_size_override("font_size", 10)
		empty.add_theme_color_override("font_color", DesignTokens.TEXT_MUTED)
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
		DesignTokens.GOLD
		if highlighted
		else DesignTokens.type_color(descriptor.energy_type)
	)
	chip.add_theme_stylebox_override(
		"panel",
		DesignTokens.panel_style(
			Color(0.035, 0.075, 0.12, 0.94),
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
		fallback.add_theme_font_size_override("font_size", 9)
		content.add_child(fallback)
	var count := Label.new()
	count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var provided_count := descriptor.provided_unit_count()
	count.text = (
		"%d张·%d能" % [descriptor.count, provided_count]
		if descriptor.is_special_energy or provided_count != descriptor.count
		else "×%d" % descriptor.count
	)
	count.add_theme_font_size_override("font_size", 9)
	count.add_theme_color_override(
		"font_color", DesignTokens.GOLD if highlighted else DesignTokens.TEXT)
	content.add_child(count)
	chip.tooltip_text = ""
	chip.accessibility_name = "%s：附着 %d 张，提供 %d 个能量%s" % [
		descriptor.display_name,
		descriptor.count,
		provided_count,
		"，本次新增" if highlighted else "",
	]
	chip.accessibility_name = chip.tooltip_text
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
	if not event is InputEventMouseButton:
		return
	if event.button_index != MOUSE_BUTTON_LEFT or event.pressed:
		return
	var model := _energy_target_model(target_key)
	var current_index := panel._last_selected_ids.size()
	if model.is_empty() or current_index >= panel._selection_max:
		return
	var option_id := _energy_option_id_for_target(model, current_index)
	if option_id.is_empty():
		panel.show_blocked_reason("当前能量没有可用的目标响应，请重新选择")
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
	var background := Color(0.045, 0.085, 0.14, 0.96)
	var border := DesignTokens.BORDER
	var width := 1
	if selected:
		background = Color(0.10, 0.12, 0.14, 0.98)
		border = DesignTokens.GOLD
		width = 2
	elif blocked:
		background = Color(0.045, 0.065, 0.10, 0.92)
		border = Color(DesignTokens.RED, 0.62 if hovered else 0.38)
		width = 2 if hovered else 1
	elif hovered:
		background = Color(0.065, 0.13, 0.21, 0.98)
		border = DesignTokens.CYAN
		width = 2
	var style := DesignTokens.panel_style(
		background, DesignTokens.RADIUS_MEDIUM, border, width, 8)
	if selected:
		style.shadow_color = Color(DesignTokens.GOLD, 0.22)
		style.shadow_size = 6
		style.shadow_offset = Vector2.ZERO
	tile.add_theme_stylebox_override("panel", style)

func _refresh_energy_assignment_labels(selected_ids: Array[String]) -> void:
	if _energy_assignment_labels.is_empty():
		return
	if not _energy_distribution_mode:
		return
	var assigned_by_index: Dictionary = {}
	for selected_position in range(selected_ids.size()):
		var selected_id := str(selected_ids[selected_position])
		var energy_index := int(_energy_index_by_option_id.get(
			selected_id, selected_position))
		if energy_index >= 0:
			assigned_by_index[energy_index] = selected_id
	for index in range(_energy_assignment_labels.size()):
		var label := _energy_assignment_labels[index]
		var card := _energy_preview_cards[index] if index < _energy_preview_cards.size() else null
		if assigned_by_index.has(index):
			var option_id := str(assigned_by_index[index])
			var target_label := str(panel._option_labels.get(option_id, option_id))
			label.text = "第 %d 张 → %s" % [index + 1, target_label]
			label.tooltip_text = "第 %d 张能量已分配给%s" % [index + 1, target_label]
			label.accessibility_name = label.tooltip_text
			label.add_theme_color_override("font_color", DesignTokens.GOLD)
			if card:
				card.set_selected(true)
		elif index == selected_ids.size():
			label.text = "第 %d 张 · 请选择目标" % (index + 1)
			label.tooltip_text = "现在为第 %d 张能量选择目标" % (index + 1)
			label.accessibility_name = label.tooltip_text
			label.add_theme_color_override("font_color", DesignTokens.CYAN)
			if card:
				card.set_selected(true)
		else:
			label.text = "第 %d 张 · 等待" % (index + 1)
			label.tooltip_text = "第 %d 张能量尚未分配" % (index + 1)
			label.accessibility_name = label.tooltip_text
			label.add_theme_color_override("font_color", DesignTokens.TEXT_MUTED)
			if card:
				card.set_selected(false)
	var preview_index := mini(selected_ids.size(), _energy_source_card_ids.size() - 1)
	if preview_index >= 0 and preview_index < _energy_source_card_ids.size():
		var next_preview_id := _energy_source_card_ids[preview_index]
		if not next_preview_id.is_empty() and next_preview_id != panel._previewed_card_id:
			panel._preview_card(next_preview_id)

func _update_energy_action_buttons(selected_count: int) -> void:
	if panel.energy_actions:
		panel.energy_actions.visible = (
			_energy_distribution_mode
			and (not panel._compact_choice_layout or selected_count > 0)
		)
	if panel.undo_button:
		panel.undo_button.disabled = not _energy_distribution_mode or selected_count <= 0
		panel.undo_button.tooltip_text = (
			"撤销最近一张能量的目标"
			if not panel.undo_button.disabled
			else "当前没有可撤销的分配"
		)
	if panel.clear_button:
		panel.clear_button.disabled = not _energy_distribution_mode or selected_count <= 0
		panel.clear_button.tooltip_text = (
			"清空所有能量分配"
			if not panel.clear_button.disabled
			else "当前没有可清空的分配"
		)

func _update_energy_selection_hint(selected_count: int) -> void:
	var minimum := panel._effective_min_select()
	if selected_count >= panel._selection_max:
		panel.selection_hint_label.text = "已完成 %d / %d 张能量分配 · 可以确认" % [
			selected_count,
			panel._selection_max,
		]
	elif selected_count >= minimum:
		panel.selection_hint_label.text = (
			"正在分配第 %d / %d 张能量 · 已满足最低要求，可继续或确认"
			% [selected_count + 1, panel._selection_max]
		)
	else:
		panel.selection_hint_label.text = "正在分配第 %d / %d 张能量 · 还需分配 %d 张" % [
			selected_count + 1,
			panel._selection_max,
			minimum - selected_count,
		]
	panel.selection_hint_label.visible = true

class_name BattleScreen
extends Control

signal menu_requested
signal hand_card_selected(index: int, card_id: String)
signal pokemon_selected(player: int, slot: String, card_id: String)
signal action_requested(action: GameAction)
signal card_drop_requested(
	hand_index: int,
	card_id: String,
	target_player: int,
	target_slot: String,
)
signal detail_requested(card_id: String)

const CARD_SCENE := preload("res://ui/card_view.tscn")
const ZONE_SCENE := preload("res://ui/zone_view.tscn")

var state_ref: GameState
var catalog := CardCatalog.new()
var view_player := 0
var selected_entity_key := ""
var action_rows: Array[Dictionary] = []
var game_mode := "local"
var ai_thinking := false

var board_panel: PanelContainer
var board_canvas: Control
var playmat: BattlePlaymat
var hud: VBoxContainer
var turn_label: Label
var opponent_info: Label
var own_info: Label
var phase_labels: Dictionary = {}
var phase_advance_button: Button
var quick_actions: VBoxContainer
var action_list: VBoxContainer
var all_actions_scroll: ScrollContainer
var all_actions_toggle: Button
var detail_image: TextureRect
var detail_title: Label
var detail_text: RichTextLabel
var log_label: RichTextLabel
var hand_scroll: ScrollContainer
var hand_surface: Control
var input_blocker: Control
var effects: BattleEffectLayer
var director: PresentationDirector

var opponent_active: CardView
var own_active: CardView
var opponent_bench: Array[CardView] = []
var own_bench: Array[CardView] = []
var hand_views: Array[CardView] = []
var zones: Dictionary = {}
var slot_views: Dictionary = {}
var _all_actions_expanded := false
var _board_origin := Vector2.ZERO
var _initialized := false
var _active_flyers: Array[Control] = []
var _flyer_tweens: Dictionary = {}


func _ready() -> void:
	initialize_ui()


func initialize_ui() -> void:
	if _initialized:
		return
	_initialized = true
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_interface()
	_build_director()
	resized.connect(_layout_board)
	call_deferred("_layout_board")


func update_view(
	state: GameState,
	p_view_player: int,
	p_action_rows: Array[Dictionary],
	p_selected_entity_key: String,
	p_ai_thinking: bool,
	p_game_mode: String,
) -> void:
	state_ref = state
	view_player = p_view_player
	action_rows = p_action_rows.duplicate()
	selected_entity_key = p_selected_entity_key
	ai_thinking = p_ai_thinking
	game_mode = p_game_mode
	if not _initialized or state_ref == null:
		return
	_refresh_header()
	_refresh_field()
	_refresh_hand()
	_refresh_actions()
	_refresh_log()
	_refresh_target_hints()


func play_presentation(raw_events: Array, revision: int, fallback_actor: int = -1) -> void:
	if director == null:
		return
	var normalized := PresentationEvent.normalize_all(
		raw_events,
		revision,
		fallback_actor,
	)
	director.set_speed_mode(AppSettings.animation_mode)
	director.play(normalized)


func clear_presentation_for_resync() -> void:
	if director:
		director.clear_for_resync()
	_clear_transient_visuals()
	modulate.a = 0.35
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 1.0, 0.16)


func show_card_detail(card_id: String, pokemon: PokemonState = null) -> void:
	if card_id.is_empty():
		detail_image.texture = null
		detail_title.text = "选择一张卡牌"
		detail_text.text = "点击或长按卡牌查看详情。"
		return
	var card := CardDatabase.get_card(card_id)
	detail_image.texture = CardTextureCache.get_texture(str(card.get("image_path", "")))
	detail_title.text = str(card.get("name", card_id))
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
	detail_text.text = "\n\n".join(lines)


func get_slot_view(player: int, slot: String) -> CardView:
	return slot_views.get("%d:%s" % [player, slot]) as CardView


func resolve_endpoint_center(endpoint: Dictionary) -> Vector2:
	var player := int(endpoint.get("player", view_player))
	var slot := str(endpoint.get("slot", ""))
	var zone := str(endpoint.get("zone", ""))
	if not slot.is_empty():
		var card_view := get_slot_view(player, slot)
		if card_view and card_view.visible:
			return _effects_local(card_view.global_center())
	if zone.is_empty():
		if slot == "active":
			zone = "active"
		elif slot.begins_with("bench"):
			zone = "bench"
	match zone:
		"deck":
			return _zone_center("own_deck" if player == view_player else "opponent_deck")
		"discard":
			return _zone_center("own_discard" if player == view_player else "opponent_discard")
		"prizes":
			return _zone_center("own_prizes" if player == view_player else "opponent_prizes")
		"stadium":
			return _zone_center("stadium")
		"hand":
			return _effects_local(
				hand_scroll.global_position + hand_scroll.size * Vector2(0.5, 0.5)
			)
	return effects.size * Vector2(0.5, 0.5)


func _build_interface() -> void:
	var root := VBoxContainer.new()
	root.name = "BattleRoot"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	var header := HBoxContainer.new()
	header.custom_minimum_size.y = 52
	header.add_theme_constant_override("separation", 12)
	root.add_child(header)
	var menu := Button.new()
	menu.text = "菜单"
	menu.custom_minimum_size = Vector2(104, DesignTokens.TOUCH_MIN)
	menu.pressed.connect(menu_requested.emit)
	header.add_child(menu)
	var title := Label.new()
	title.name = "BattleTitle"
	title.text = "Pokémon TCG"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", DesignTokens.TEXT)
	header.add_child(title)
	turn_label = Label.new()
	turn_label.custom_minimum_size.x = 330
	turn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	turn_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	turn_label.add_theme_font_size_override("font_size", 16)
	turn_label.add_theme_color_override("font_color", DesignTokens.GOLD)
	header.add_child(turn_label)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 10)
	root.add_child(body)

	board_panel = PanelContainer.new()
	board_panel.name = "BoardPanel"
	board_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	board_panel.add_theme_stylebox_override(
		"panel",
		DesignTokens.panel_style(
			Color("#08130e"),
			DesignTokens.RADIUS_MEDIUM,
			Color("#294c35"),
			1,
			0,
		),
	)
	body.add_child(board_panel)
	board_canvas = Control.new()
	board_canvas.name = "BoardCanvas"
	board_canvas.clip_contents = true
	board_panel.add_child(board_canvas)
	playmat = BattlePlaymat.new()
	playmat.quality_profile = AppSettings.resolved_quality_profile()
	playmat.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	board_canvas.add_child(playmat)

	opponent_info = _info_label()
	board_canvas.add_child(opponent_info)
	own_info = _info_label()
	board_canvas.add_child(own_info)
	_build_field_cards()
	_build_zones()
	_build_hand()

	hud = VBoxContainer.new()
	hud.name = "BattleHUD"
	hud.custom_minimum_size.x = 292
	hud.add_theme_constant_override("separation", 8)
	body.add_child(hud)
	_build_phase_panel()
	_build_action_panel()
	_build_detail_panel()
	_build_log_panel()

	effects = BattleEffectLayer.new()
	effects.quality_profile = AppSettings.resolved_quality_profile()
	effects.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(effects)
	input_blocker = Control.new()
	input_blocker.name = "PresentationInputBlocker"
	input_blocker.visible = false
	input_blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	input_blocker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(input_blocker)


func _build_field_cards() -> void:
	opponent_active = _new_card_view()
	board_canvas.add_child(opponent_active)
	own_active = _new_card_view()
	board_canvas.add_child(own_active)
	for index in range(5):
		var top := _new_card_view()
		board_canvas.add_child(top)
		opponent_bench.append(top)
		var bottom := _new_card_view()
		board_canvas.add_child(bottom)
		own_bench.append(bottom)


func _build_zones() -> void:
	for key in [
		"opponent_deck",
		"opponent_discard",
		"opponent_prizes",
		"own_deck",
		"own_discard",
		"own_prizes",
		"stadium",
	]:
		var zone := ZONE_SCENE.instantiate() as ZoneView
		zone.name = key.to_pascal_case()
		zone.activated.connect(_on_detail_requested)
		zone.action_requested.connect(action_requested.emit)
		board_canvas.add_child(zone)
		zones[key] = zone


func _build_hand() -> void:
	hand_scroll = ScrollContainer.new()
	hand_scroll.name = "HandScroll"
	hand_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	hand_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	hand_scroll.clip_contents = false
	board_canvas.add_child(hand_scroll)
	hand_surface = Control.new()
	hand_surface.name = "HandSurface"
	hand_surface.custom_minimum_size.y = 156
	hand_scroll.add_child(hand_surface)


func _build_phase_panel() -> void:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.y = 170
	panel.add_theme_stylebox_override(
		"panel",
		DesignTokens.panel_style(DesignTokens.PANEL_GLASS, 14, DesignTokens.BORDER),
	)
	hud.add_child(panel)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 7)
	panel.add_child(content)
	var heading := Label.new()
	heading.text = "回合阶段"
	heading.add_theme_font_size_override("font_size", 18)
	heading.add_theme_color_override("font_color", DesignTokens.GOLD)
	content.add_child(heading)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	content.add_child(row)
	for phase in ["DRAW", "MAIN", "ATTACK", "POKEMON_CHECKUP"]:
		var label := Label.new()
		label.text = {
			"DRAW": "抽牌",
			"MAIN": "主要",
			"ATTACK": "攻击",
			"POKEMON_CHECKUP": "检查",
		}[phase]
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.custom_minimum_size.y = 28
		label.add_theme_font_size_override("font_size", 12)
		row.add_child(label)
		phase_labels[phase] = label
	var hint := Label.new()
	hint.name = "TurnHint"
	hint.text = "选择卡牌查看可执行操作"
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", DesignTokens.TEXT_MUTED)
	content.add_child(hint)
	phase_advance_button = Button.new()
	phase_advance_button.text = "进入下一阶段"
	phase_advance_button.custom_minimum_size.y = 52
	phase_advance_button.add_theme_font_size_override("font_size", 16)
	phase_advance_button.add_theme_stylebox_override(
		"normal",
		DesignTokens.panel_style(
			Color("#78521b"),
			11,
			DesignTokens.GOLD,
			2,
			0,
		),
	)
	phase_advance_button.pressed.connect(func() -> void:
		var action: GameAction = phase_advance_button.get_meta("action") as GameAction
		if action:
			action_requested.emit(action)
	)
	content.add_child(phase_advance_button)


func _build_action_panel() -> void:
	var panel := PanelContainer.new()
	panel.visible = false
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override(
		"panel",
		DesignTokens.panel_style(DesignTokens.PANEL_GLASS, 14, DesignTokens.BORDER),
	)
	add_child(panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	panel.add_child(margin)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 7)
	margin.add_child(content)
	var heading := HBoxContainer.new()
	content.add_child(heading)
	var label := Label.new()
	label.text = "当前操作"
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", DesignTokens.GOLD)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_child(label)
	all_actions_toggle = Button.new()
	all_actions_toggle.text = "全部动作"
	all_actions_toggle.custom_minimum_size.y = 38
	all_actions_toggle.pressed.connect(_toggle_all_actions)
	heading.add_child(all_actions_toggle)
	quick_actions = VBoxContainer.new()
	quick_actions.name = "QuickActions"
	quick_actions.add_theme_constant_override("separation", 6)
	content.add_child(quick_actions)
	all_actions_scroll = ScrollContainer.new()
	all_actions_scroll.visible = false
	all_actions_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(all_actions_scroll)
	action_list = VBoxContainer.new()
	action_list.name = "ActionList"
	action_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action_list.add_theme_constant_override("separation", 6)
	all_actions_scroll.add_child(action_list)


func _build_detail_panel() -> void:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.y = 224
	panel.add_theme_stylebox_override(
		"panel",
		DesignTokens.panel_style(DesignTokens.PANEL_GLASS, 14, DesignTokens.BORDER),
	)
	hud.add_child(panel)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	panel.add_child(row)
	detail_image = TextureRect.new()
	detail_image.custom_minimum_size = Vector2(116, 168)
	detail_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	detail_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	row.add_child(detail_image)
	var text_column := VBoxContainer.new()
	text_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(text_column)
	detail_title = Label.new()
	detail_title.text = "卡牌详情"
	detail_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail_title.add_theme_font_size_override("font_size", 18)
	detail_title.add_theme_color_override("font_color", DesignTokens.CYAN)
	text_column.add_child(detail_title)
	detail_text = RichTextLabel.new()
	detail_text.bbcode_enabled = true
	detail_text.fit_content = false
	detail_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_text.add_theme_font_size_override("normal_font_size", 13)
	text_column.add_child(detail_text)
	show_card_detail("")


func _build_log_panel() -> void:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.y = 126
	panel.add_theme_stylebox_override(
		"panel",
		DesignTokens.panel_style(
			Color(0.035, 0.06, 0.10, 0.92),
			14,
			DesignTokens.BORDER_SOFT,
		),
	)
	hud.add_child(panel)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 4)
	panel.add_child(content)
	var heading := Label.new()
	heading.text = "行动日志"
	heading.add_theme_font_size_override("font_size", 15)
	heading.add_theme_color_override("font_color", DesignTokens.GOLD)
	content.add_child(heading)
	log_label = RichTextLabel.new()
	log_label.bbcode_enabled = true
	log_label.fit_content = false
	log_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_label.add_theme_font_size_override("normal_font_size", 12)
	content.add_child(log_label)


func _build_director() -> void:
	director = PresentationDirector.new()
	add_child(director)
	director.sequence_started.connect(func(_count: int) -> void:
		input_blocker.visible = not AppSettings.reduced_motion
	)
	director.sequence_finished.connect(func() -> void:
		input_blocker.visible = false
	)
	director.floating_text_requested.connect(_on_floating_text_requested)
	director.burst_requested.connect(_on_burst_requested)
	director.card_motion_requested.connect(_on_card_motion_requested)
	director.camera_impulse_requested.connect(_on_camera_impulse_requested)


func _refresh_header() -> void:
	var display_actor := view_player if state_ref.phase == "SETUP" else state_ref.active_player_idx
	turn_label.text = "第 %d 回合 · %s · 玩家 %d%s" % [
		state_ref.turn_number,
		_phase_name(state_ref.phase),
		display_actor + 1,
		" · AI 思考中" if ai_thinking else "",
	]
	for phase in phase_labels:
		var active := str(phase) == state_ref.phase
		var label: Label = phase_labels[phase]
		label.add_theme_color_override(
			"font_color",
			DesignTokens.BG_DEEP if active else DesignTokens.TEXT_MUTED,
		)
		label.add_theme_stylebox_override(
			"normal",
			DesignTokens.panel_style(
				DesignTokens.GOLD if active else Color("#1b293c"),
				8,
				DesignTokens.GOLD if active else DesignTokens.BORDER_SOFT,
				1,
				0,
			),
		)


func _refresh_field() -> void:
	var own := state_ref.get_player(view_player)
	var opponent := state_ref.get_player(1 - view_player)
	opponent_info.text = "%s  ·  手牌 %d  ·  牌库 %d  ·  奖品 %d" % [
		opponent.name,
		opponent.hand.size(),
		opponent.deck.size(),
		opponent.prizes.size(),
	]
	own_info.text = "%s  ·  手牌 %d  ·  牌库 %d  ·  奖品 %d" % [
		own.name,
		own.hand.size(),
		own.deck.size(),
		own.prizes.size(),
	]
	_configure_slot(opponent_active, opponent.active, 1 - view_player, "active")
	_configure_slot(own_active, own.active, view_player, "active")
	for index in range(5):
		_configure_slot(
			opponent_bench[index],
			opponent.bench[index],
			1 - view_player,
			"bench_%d" % index,
		)
		_configure_slot(
			own_bench[index],
			own.bench[index],
			view_player,
			"bench_%d" % index,
		)
	(zones["opponent_deck"] as ZoneView).configure(
		"牌库",
		"",
		opponent.deck.size(),
		true,
	)
	(zones["opponent_discard"] as ZoneView).configure(
		"弃牌",
		opponent.discard[-1] if not opponent.discard.is_empty() else "",
		opponent.discard.size(),
	)
	(zones["opponent_prizes"] as ZoneView).configure(
		"奖品",
		"",
		opponent.prizes.size(),
		true,
	)
	(zones["own_deck"] as ZoneView).configure("牌库", "", own.deck.size(), true)
	(zones["own_discard"] as ZoneView).configure(
		"弃牌",
		own.discard[-1] if not own.discard.is_empty() else "",
		own.discard.size(),
	)
	(zones["own_prizes"] as ZoneView).configure("奖品", "", own.prizes.size(), true)
	(zones["stadium"] as ZoneView).configure(
		"竞技场",
		state_ref.stadium_card_id,
		0 if state_ref.stadium_card_id.is_empty() else 1,
	)


func _refresh_hand() -> void:
	var hand := state_ref.get_player(view_player).hand
	while hand_views.size() < hand.size():
		var card := _new_card_view()
		hand_surface.add_child(card)
		hand_views.append(card)
	for index in range(hand_views.size()):
		var view := hand_views[index]
		if index >= hand.size():
			view.visible = false
			continue
		view.visible = true
		view.configure(hand[index], null, false, index, view_player, "", true)
		view.set_selected(selected_entity_key == "hand:%d" % index)
	_layout_hand()


func _refresh_actions() -> void:
	var phase_row: Dictionary = {}
	var hand_rows: Dictionary = {}
	var slot_rows: Dictionary = {}
	var stadium_row: Dictionary = {}
	for row in action_rows:
		var action: GameAction = row.get("action")
		if action == null:
			continue
		if action.action in ["END_TURN", "SETUP_DONE"]:
			phase_row = row
			continue
		if action.action == "USE_STADIUM":
			stadium_row = row
			continue
		var hand_index := int(action.params.get("hand_idx", -1))
		if hand_index >= 0:
			if not hand_rows.has(hand_index):
				hand_rows[hand_index] = []
			(hand_rows[hand_index] as Array).append(row)
			continue
		var endpoint := action.source if action.source else action.target
		if endpoint and not endpoint.slot.is_empty():
			var key := "%d:%s" % [endpoint.player, endpoint.slot]
			if not slot_rows.has(key):
				slot_rows[key] = []
			(slot_rows[key] as Array).append(row)

	var phase_action: GameAction = phase_row.get("action") as GameAction
	phase_advance_button.set_meta("action", phase_action)
	phase_advance_button.disabled = phase_action == null or ai_thinking
	phase_advance_button.text = (
		"完成准备"
		if phase_action and phase_action.action == "SETUP_DONE"
		else "进入下一阶段"
	)
	phase_advance_button.tooltip_text = (
		""
		if phase_action
		else "等待对手行动"
		if game_mode == "network"
		else "请先完成当前卡牌操作"
	)

	for view in hand_views:
		var rows: Array[Dictionary] = []
		rows.assign(hand_rows.get(view.hand_index, []))
		var direct: Array[Dictionary] = []
		var targeted := false
		for row in rows:
			var action: GameAction = row.get("action")
			if action and action.target and not action.target.slot.is_empty():
				targeted = true
			else:
				direct.append(_compact_card_action_row(row))
		view.set_actions(
			direct,
			"点击高亮牌位" if targeted and view.selected else "",
		)
	for key in slot_views:
		var view := slot_views[key] as CardView
		var rows: Array[Dictionary] = []
		for row in slot_rows.get(key, []):
			rows.append(_compact_card_action_row(row))
		view.set_actions(rows)
	(zones["stadium"] as ZoneView).set_action(
		_compact_card_action_row(stadium_row) if not stadium_row.is_empty() else {}
	)


func _refresh_log() -> void:
	var start := maxi(0, state_ref.action_log.size() - 7)
	var lines: Array[String] = []
	for index in range(start, state_ref.action_log.size()):
		lines.append("[color=#62d7ff]◆[/color] " + state_ref.action_log[index])
	log_label.text = "\n".join(lines)
	log_label.scroll_to_line(maxi(0, lines.size() - 1))


func _refresh_target_hints() -> void:
	for view_value in slot_views.values():
		(view_value as CardView).set_targetable(false)
	if selected_entity_key.is_empty():
		return
	for row in action_rows:
		var action: GameAction = row.get("action")
		if action == null or not _action_matches_selected(action):
			continue
		var target_slot := str(action.params.get(
			"target_slot",
			action.params.get("target", action.params.get("slot", "")),
		))
		if target_slot.is_empty() and action.target:
			target_slot = action.target.slot
		if not target_slot.is_empty():
			var target_player := action.actor
			if action.target:
				target_player = action.target.player
			var view := get_slot_view(target_player, target_slot)
			if view:
				view.set_targetable(true)


func _configure_slot(
	view: CardView,
	pokemon: PokemonState,
	player: int,
	slot_name: String,
) -> void:
	slot_views["%d:%s" % [player, slot_name]] = view
	view.configure(
		pokemon.card_id if pokemon else "",
		pokemon,
		false,
		-1,
		player,
		slot_name,
		false,
	)
	view.configure_target(player, slot_name)
	view.set_empty_label("战斗区" if slot_name == "active" else "备战 %d" % (
		slot_name.trim_prefix("bench_").to_int() + 1
	))
	view.set_selected(selected_entity_key == "pokemon:%d:%s" % [player, slot_name])


func _layout_board() -> void:
	if board_canvas == null:
		return
	var width := board_canvas.size.x
	var height := board_canvas.size.y
	if width <= 0.0 or height <= 0.0:
		return
	var active_size := Vector2(118, 164)
	var bench_size := Vector2(82, 114)
	var zone_size := Vector2(90, 128)
	var hand_size := Vector2(104, 146)
	var center_x := width * 0.5
	var hand_height := 164.0
	var field_bottom := height - hand_height
	var middle_y := field_bottom * 0.5

	opponent_info.position = Vector2(18, 8)
	opponent_info.size = Vector2(width - 36, 24)
	own_info.position = Vector2(18, field_bottom - 26)
	own_info.size = Vector2(width - 36, 24)
	var bench_total := bench_size.x * 5.0 + 14.0 * 4.0
	var bench_x := center_x - bench_total * 0.5
	for index in range(5):
		_place_card(
			opponent_bench[index],
			Vector2(bench_x + index * (bench_size.x + 14.0), 30),
			bench_size,
		)
		_place_card(
			own_bench[index],
			Vector2(
				bench_x + index * (bench_size.x + 14.0),
				field_bottom - bench_size.y - 30,
			),
			bench_size,
		)
	_place_card(
		opponent_active,
		Vector2(center_x - active_size.x * 0.5, middle_y - active_size.y - 8),
		active_size,
	)
	_place_card(
		own_active,
		Vector2(center_x - active_size.x * 0.5, middle_y + 8),
		active_size,
	)

	_place_zone("opponent_prizes", Vector2(20, 42), zone_size)
	_place_zone("opponent_deck", Vector2(width - zone_size.x - 20, 42), zone_size)
	_place_zone(
		"opponent_discard",
		Vector2(width - zone_size.x - 20, middle_y - zone_size.y - 18),
		zone_size,
	)
	_place_zone("stadium", Vector2(24, middle_y - zone_size.y * 0.5), zone_size)
	_place_zone(
		"own_discard",
		Vector2(width - zone_size.x - 20, middle_y + 18),
		zone_size,
	)
	_place_zone(
		"own_deck",
		Vector2(width - zone_size.x - 20, field_bottom - zone_size.y - 34),
		zone_size,
	)
	_place_zone(
		"own_prizes",
		Vector2(20, field_bottom - zone_size.y - 34),
		zone_size,
	)

	hand_scroll.position = Vector2(126, field_bottom + 4)
	hand_scroll.size = Vector2(maxf(220, width - 252), hand_height - 8)
	hand_surface.custom_minimum_size.y = hand_height - 12
	_layout_hand(hand_size)
	effects.queue_redraw()


func _layout_hand(card_size: Vector2 = Vector2(96, 135)) -> void:
	if hand_surface == null:
		return
	var visible_count := 0
	for view in hand_views:
		if view.visible:
			visible_count += 1
	var available := maxf(220.0, hand_scroll.size.x)
	var spacing := card_size.x
	if visible_count > 1:
		spacing = clampf(
			(available - card_size.x) / float(visible_count - 1),
			44.0,
			card_size.x + 6.0,
		)
	var content_width := (
		card_size.x
		if visible_count <= 1
		else card_size.x + spacing * float(visible_count - 1)
	)
	hand_surface.custom_minimum_size.x = maxf(available, content_width)
	var start_x := maxf(0.0, (hand_surface.custom_minimum_size.x - content_width) * 0.5)
	var visible_index := 0
	for view in hand_views:
		if not view.visible:
			continue
		view.size = card_size
		view.position = Vector2(start_x + visible_index * spacing, 14)
		var normalized := (
			0.0
			if visible_count <= 1
			else float(visible_index) / float(visible_count - 1) - 0.5
		)
		view.rotation_degrees = normalized * minf(7.0, float(visible_count) * 0.55)
		view.z_index = visible_index
		view.remember_base_position()
		view.set_selected(selected_entity_key == "hand:%d" % view.hand_index)
		visible_index += 1


func _new_card_view() -> CardView:
	var view := CARD_SCENE.instantiate() as CardView
	view.set_catalog(catalog)
	view.activated.connect(_on_card_activated)
	view.detail_requested.connect(_on_detail_requested)
	view.card_dropped.connect(_on_card_dropped)
	view.action_requested.connect(action_requested.emit)
	return view


func _action_button(row: Dictionary, prominent: bool) -> Button:
	var action: GameAction = row.get("action")
	var button := Button.new()
	button.text = str(row.get("label", action.action if action else "动作"))
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.custom_minimum_size.y = 48 if prominent else 43
	button.add_theme_font_size_override("font_size", 15 if prominent else 13)
	if action and action.action == "END_TURN":
		button.add_theme_stylebox_override(
			"normal",
			DesignTokens.panel_style(
				Color("#7b2e38"),
				10,
				DesignTokens.RED,
				1,
			),
		)
	elif action and action.action == "DECLARE_ATTACK":
		button.add_theme_stylebox_override(
			"normal",
			DesignTokens.panel_style(
				Color("#8a3c2d"),
				10,
				Color("#ff9a61"),
				1,
			),
		)
	button.pressed.connect(func() -> void:
		if action:
			action_requested.emit(action)
	)
	return button


func _compact_card_action_row(row: Dictionary) -> Dictionary:
	var result := row.duplicate()
	var action: GameAction = row.get("action")
	if action == null:
		return result
	match action.action:
		"PLAY_TRAINER":
			result["label"] = "使用"
		"DECLARE_ATTACK":
			result["label"] = str(row.get("label", "攻击")).trim_prefix("攻击 · ")
		"USE_ABILITY":
			result["label"] = str(action.params.get("ability_name", "发动特性"))
		"RETREAT":
			result["label"] = "撤退到这里"
		"PROMOTE":
			result["label"] = "晋升"
		"USE_STADIUM":
			result["label"] = "发动"
	return result


func _action_matches_selected(action: GameAction) -> bool:
	if selected_entity_key.is_empty():
		return false
	if selected_entity_key.begins_with("hand:"):
		return int(action.params.get("hand_idx", -1)) == (
			selected_entity_key.trim_prefix("hand:").to_int()
		)
	if selected_entity_key.begins_with("pokemon:"):
		var parts := selected_entity_key.split(":")
		if parts.size() < 3:
			return false
		var player := int(parts[1])
		var slot_name := str(parts[2])
		if (
			action.action == "RETREAT"
			and player == action.actor
			and slot_name == "active"
		):
			return true
		return (
			(action.source and action.source.player == player and action.source.slot == slot_name)
			or (action.target and action.target.player == player and action.target.slot == slot_name)
			or str(action.params.get("slot", "")) == slot_name
			or str(action.params.get("target_slot", "")) == slot_name
		)
	return false


func _toggle_all_actions() -> void:
	_all_actions_expanded = not _all_actions_expanded
	all_actions_scroll.visible = _all_actions_expanded
	quick_actions.visible = not _all_actions_expanded
	_refresh_actions()


func _on_card_activated(
	card_id: String,
	hand_index: int,
	player: int,
	slot_name: String,
) -> void:
	if hand_index >= 0:
		hand_card_selected.emit(hand_index, card_id)
	else:
		pokemon_selected.emit(player, slot_name, card_id)


func _on_detail_requested(card_id: String) -> void:
	show_card_detail(card_id)
	detail_requested.emit(card_id)


func _on_card_dropped(
	hand_index: int,
	card_id: String,
	target_player: int,
	target_slot: String,
) -> void:
	card_drop_requested.emit(
		hand_index,
		card_id,
		target_player,
		target_slot,
	)


func _on_floating_text_requested(
	text: String,
	target: Dictionary,
	color: Color,
) -> void:
	effects.floating_text(text, resolve_endpoint_center(target), color)


func _on_burst_requested(
	kind: String,
	target: Dictionary,
	color: Color,
) -> void:
	effects.burst(resolve_endpoint_center(target), color, kind)
	var player := int(target.get("player", -1))
	var slot_name := str(target.get("slot", ""))
	var view := get_slot_view(player, slot_name)
	if view:
		view.flash(color, 0.36)
		if kind in ["impact", "ko"]:
			view.shake(8.0 if kind == "impact" else 11.0, 0.3)


func _on_card_motion_requested(event: Dictionary, duration: float) -> void:
	var data: Dictionary = event.get("data", {})
	var source: Dictionary = event.get("source", {})
	var target: Dictionary = event.get("target", {})
	var event_type := str(event.get("event_type", ""))
	var actor := int(event.get("actor", view_player))
	var card_ids: Array = data.get("card_ids", data.get("cards", []))
	var event_card_id := str(event.get("card_id", data.get("card_id", "")))
	if card_ids.is_empty() and not event_card_id.is_empty():
		card_ids = [event_card_id]
	var amount := maxi(1, int(event.get(
		"amount",
		data.get("count", card_ids.size()),
	)))
	var visible_count := mini(5, maxi(amount, card_ids.size()))
	if event_type == "cards_drawn":
		source = {"player": actor, "zone": "deck"}
		target = {"player": actor, "zone": "hand"}
	elif event_type == "cards_discarded":
		source = {"player": actor, "zone": "hand"}
		target = {"player": actor, "zone": "discard"}
	elif event_type == "prize_taken":
		source = {"player": actor, "zone": "prizes"}
		target = {"player": actor, "zone": "hand"}
	elif event_type == "pokemon_ko":
		source = {
			"player": int(data.get("player", actor)),
			"slot": str(data.get("slot", "active")),
		}
		target = {
			"player": int(data.get("player", actor)),
			"zone": "discard",
		}
	if AppSettings.reduced_motion:
		effects.burst(resolve_endpoint_center(target), DesignTokens.CYAN, "card_move")
		return
	var base_start := resolve_endpoint_center(source)
	var base_finish := resolve_endpoint_center(target)
	var hand_starts: Array[Vector2] = []
	if event_type == "cards_discarded" and actor == view_player:
		for view in hand_views:
			if view.visible:
				hand_starts.append(_effects_local(view.global_center()))
	for index in range(visible_count):
		var card_id := str(card_ids[index]) if index < card_ids.size() else event_card_id
		var texture_path := (
			str(CardDatabase.get_card(card_id).get("image_path", ""))
			if not card_id.is_empty()
			else "res://assets/cards/card_back.webp"
		)
		var texture := CardTextureCache.get_texture(texture_path)
		if texture == null:
			continue
		var start := base_start
		if not hand_starts.is_empty():
			start = hand_starts[mini(index, hand_starts.size() - 1)]
		var finish := base_finish + Vector2(
			(float(index) - float(visible_count - 1) * 0.5) * 7.0,
			-float(index) * 3.0,
		)
		if event_type in ["cards_drawn", "prize_taken"] and actor == view_player:
			finish += Vector2(
				(float(index) - float(visible_count - 1) * 0.5) * 34.0,
				18.0,
			)
		_spawn_flying_card(
			texture,
			start,
			finish,
			maxf(0.18, duration - float(index) * 0.045),
			float(index) * 0.045,
			event_type,
			index,
		)
	if event_type == "cards_drawn" and actor == view_player:
		call_deferred(
			"_mask_and_reveal_drawn_cards",
			amount,
			maxf(0.18, duration),
		)


func _spawn_flying_card(
	texture: Texture2D,
	start: Vector2,
	finish: Vector2,
	duration: float,
	delay: float,
	event_type: String,
	index: int,
) -> void:
	_prune_flyers()
	while _active_flyers.size() >= 12:
		var oldest: Control = _active_flyers.pop_front()
		_dispose_flyer(oldest)
	var flying := Control.new()
	flying.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flying.size = Vector2(94, 132)
	flying.position = start - flying.size * 0.5
	flying.pivot_offset = flying.size * 0.5
	flying.z_index = 100 + index
	var shadow := Panel.new()
	shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shadow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shadow.position = Vector2(0, 7)
	shadow.add_theme_stylebox_override("panel", DesignTokens.shadow_style(12))
	flying.add_child(shadow)
	var image := TextureRect.new()
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	image.texture = texture
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	image.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	flying.add_child(image)
	effects.add_child(flying)
	_active_flyers.append(flying)
	var arc_height := maxf(74.0, start.distance_to(finish) * 0.22)
	var control := Vector2(
		(start.x + finish.x) * 0.5,
		minf(start.y, finish.y) - arc_height - float(index) * 8.0,
	)
	var spin := (
		16.0 + float(index) * 2.0
		if event_type in ["cards_discarded", "pokemon_ko"]
		else -7.0 + float(index) * 3.0
	)
	var tween := create_tween()
	if delay > 0.0:
		tween.tween_interval(delay)
	_flyer_tweens[flying.get_instance_id()] = tween
	tween.tween_method(
		_update_flyer.bind(flying, start, control, finish, spin),
		0.0,
		1.0,
		duration,
	).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tween.tween_callback(_finish_flyer.bind(flying, finish, event_type))


func _update_flyer(
	progress: float,
	flying_value: Variant,
	start: Vector2,
	control: Vector2,
	finish: Vector2,
	spin: float,
) -> void:
	if not is_instance_valid(flying_value):
		return
	var flying := flying_value as Control
	if flying == null:
		return
	var inverse := 1.0 - progress
	var point := (
		start * inverse * inverse
		+ control * 2.0 * inverse * progress
		+ finish * progress * progress
	)
	flying.position = point - flying.size * 0.5
	flying.rotation_degrees = lerpf(-spin * 0.35, spin, progress)
	var lift := 1.0 + sin(progress * PI) * 0.16
	flying.scale = Vector2.ONE * lift
	flying.modulate.a = clampf(minf(progress * 5.0, (1.0 - progress) * 8.0), 0.0, 1.0)


func _finish_flyer(
	flying_value: Variant,
	finish: Vector2,
	event_type: String,
) -> void:
	if not is_instance_valid(flying_value):
		return
	var flying := flying_value as Control
	if flying == null:
		return
	_flyer_tweens.erase(flying.get_instance_id())
	_active_flyers.erase(flying)
	flying.queue_free()
	effects.burst(
		finish,
		DesignTokens.GOLD if event_type in ["cards_drawn", "prize_taken"] else DesignTokens.CYAN,
		"card_land",
	)


func _mask_and_reveal_drawn_cards(count: int, duration: float) -> void:
	var visible: Array[CardView] = []
	for view in hand_views:
		if view.visible:
			visible.append(view)
	var first := maxi(0, visible.size() - count)
	for index in range(first, visible.size()):
		var view := visible[index]
		view.modulate.a = 0.0
		var tween := create_tween()
		tween.tween_interval(duration * 0.58 + float(index - first) * 0.045)
		tween.tween_property(view, "modulate:a", 1.0, 0.14)


func _prune_flyers() -> void:
	var live: Array[Control] = []
	for flyer in _active_flyers:
		if is_instance_valid(flyer) and not flyer.is_queued_for_deletion():
			live.append(flyer)
	_active_flyers = live


func _clear_transient_visuals() -> void:
	for tween_value in _flyer_tweens.values():
		var tween := tween_value as Tween
		if tween and tween.is_valid():
			tween.kill()
	_flyer_tweens.clear()
	for flyer in _active_flyers:
		if is_instance_valid(flyer):
			flyer.free()
	_active_flyers.clear()
	if effects:
		effects.clear_transients()
	for view in hand_views:
		if is_instance_valid(view):
			view.modulate.a = 1.0


func _dispose_flyer(flying: Control) -> void:
	if not is_instance_valid(flying):
		return
	var tween := _flyer_tweens.get(flying.get_instance_id()) as Tween
	if tween and tween.is_valid():
		tween.kill()
	_flyer_tweens.erase(flying.get_instance_id())
	flying.free()


func _on_camera_impulse_requested(strength: float, duration: float) -> void:
	if AppSettings.reduced_motion:
		return
	var origin := board_panel.position
	var tween := create_tween()
	for offset in [
		Vector2(strength * 7.0, 0),
		Vector2(-strength * 7.0, strength * 2.0),
		Vector2(strength * 4.0, -strength * 2.0),
		Vector2.ZERO,
	]:
		tween.tween_property(
			board_panel,
			"position",
			origin + offset,
			duration / 4.0,
		)


func _place_card(view: CardView, position_value: Vector2, size_value: Vector2) -> void:
	view.position = position_value
	view.size = size_value
	view.remember_base_position()


func _place_zone(key: String, position_value: Vector2, size_value: Vector2) -> void:
	var zone := zones[key] as ZoneView
	zone.position = position_value
	zone.size = size_value


func _zone_center(key: String) -> Vector2:
	var zone := zones.get(key) as ZoneView
	if zone == null:
		return effects.size * Vector2(0.5, 0.5)
	return _effects_local(zone.global_position + zone.size * 0.5)


func _effects_local(global_point: Vector2) -> Vector2:
	return effects.get_global_transform_with_canvas().affine_inverse() * global_point


func _info_label() -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", DesignTokens.TEXT_MUTED)
	return label


func _free_children(parent: Node) -> void:
	for child in parent.get_children():
		parent.remove_child(child)
		child.queue_free()


func _phase_name(phase: String) -> String:
	return {
		"SETUP": "准备",
		"DRAW": "抽牌",
		"MAIN": "主要",
		"ATTACK": "攻击",
		"POKEMON_CHECKUP": "宝可梦检查",
		"GAME_OVER": "对局结束",
	}.get(phase, phase)

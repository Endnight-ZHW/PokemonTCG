class_name BattleTable
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
signal inspect_card_requested(context: Dictionary)
signal inspect_zone_requested(context: Dictionary)

const CARD_SCENE := preload("res://ui/card_view.tscn")
const MIN_FLYING_CARD_DURATION := 0.06
const FLYING_CARD_FINISH_PAD := 0.0
const MAX_ACTIVE_FLYERS_HIGH := 12
const MAX_ACTIVE_FLYERS_LOW := 8
const PAPER_CARD_BASE_SIZE := Vector2(94, 132)
const SHUFFLE_CARD_LIMITS := {
	"high": 7,
	"medium": 5,
	"low": 3,
}

@export_category("Table Layout")
@export_group("HUD")
@export var hud_width := 260.0
@export_group("Table Margins")
@export var table_side_margin := 22.0
@export var table_top_margin := 16.0
@export var table_bottom_margin := 10.0
@export var hand_bottom_padding := 8.0
@export_group("Board Cards")
@export var active_card_size := Vector2(130, 182)
@export var bench_card_size := Vector2(86, 120)
@export var zone_size := Vector2(96, 136)
@export var bench_spacing := 16.0
@export_group("Hand")
@export var hand_card_size := Vector2(112, 157)
@export var hand_minimum_spacing := 52.0
@export var hand_rotation_degrees := 6.0
@export_group("Opponent Hand")
@export var opponent_hand_card_size := Vector2(76, 106)
@export var opponent_hand_minimum_spacing := 26.0
@export var opponent_hand_rotation_degrees := 6.0
@export var opponent_hand_max_visible := 8
@export_category("Presentation")
@export_group("Refresh")
@export var resync_fade_duration := 0.16
@export_group("Dynamic Card Motion")
@export var motion_arc_height_min := 74.0
@export var motion_arc_distance_ratio := 0.22
@export var motion_arc_stagger_height := 8.0
@export var motion_stagger_delay := 0.045
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
var header: BattleHeader
var ai_thinking_overlay: AIThinkingOverlay
var hud: VBoxContainer
var turn_label: Label
var opponent_info: Label
var own_info: Label
var phase_labels: Dictionary = {}
var phase_advance_button: Button
var all_actions_button: Button
var action_panel: BattleActionPanel
var action_list: VBoxContainer
var all_actions_scroll: ScrollContainer
var all_actions_toggle: Button
var detail_panel: PanelContainer
var detail_image: TextureRect
var detail_title: Label
var detail_text: RichTextLabel
var detail_close_button: Button
var log_panel: BattleLogPanel
var log_label: RichTextLabel
var opponent_hand_surface: Control
var opponent_hand_count_badge: Label
var hand_scroll: ScrollContainer
var hand_surface: Control
var input_blocker: Control
var effects: BattleEffectLayer
var director: PresentationDirector
var animation_player: AnimationPlayer

var opponent_active: CardView
var own_active: CardView
var opponent_bench: Array[CardView] = []
var own_bench: Array[CardView] = []
var hand_views: Array[CardView] = []
var opponent_hand_views: Array[CardView] = []
var zones: Dictionary = {}
var slot_views: Dictionary = {}
var _all_actions_expanded := false
var _board_origin := Vector2.ZERO
var _initialized := false
var _active_flyers: Array[Control] = []
var _flyer_tweens: Dictionary = {}
var _presentation_snapshot: Dictionary = {}
var _presentation_reveals: Dictionary = {}
var _presentation_mask_counts: Dictionary = {}
var _presentation_feedbacks: Dictionary = {}
var _presentation_covers: Dictionary = {}
var _presentation_cover_tweens: Dictionary = {}
var _presentation_event_hand_targets: Dictionary = {}
var _presentation_hand_target_cursor: Dictionary = {}
var _presentation_hand_removed_counts: Dictionary = {}
var _presentation_zone_states: Dictionary = {}
var _ai_thinking_started_msec := 0


func _ready() -> void:
	initialize_ui()


func initialize_ui() -> void:
	if _initialized:
		return
	_resolve_scene_nodes()
	_initialized = true
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bind_scene_nodes()
	resized.connect(_layout_board)
	call_deferred("_layout_board")
	if not AppSettings.reduced_motion:
		animation_player.play("enter")


func _resolve_scene_nodes() -> void:
	board_panel = get_node("BattleRoot/Body/BoardPanel") as PanelContainer
	board_canvas = get_node("BattleRoot/Body/BoardPanel/BoardCanvas") as Control
	playmat = get_node("BattleRoot/Body/BoardPanel/BoardCanvas/Playmat") as BattlePlaymat
	header = get_node("BattleRoot/Header") as BattleHeader
	ai_thinking_overlay = get_node(
		"BattleRoot/Body/BoardPanel/BoardCanvas/AIThinkingOverlay"
	) as AIThinkingOverlay
	hud = get_node("BattleRoot/Body/BattleHUD") as VBoxContainer
	turn_label = get_node("BattleRoot/Header/TurnLabel") as Label
	opponent_info = get_node(
		"BattleRoot/Body/BoardPanel/BoardCanvas/OpponentInfo"
	) as Label
	own_info = get_node("BattleRoot/Body/BoardPanel/BoardCanvas/OwnInfo") as Label
	phase_advance_button = get_node(
		"BattleRoot/Body/BattleHUD/PhasePanel/Content/PhaseAdvanceButton"
	) as Button
	all_actions_button = get_node(
		"BattleRoot/Body/BattleHUD/PhasePanel/Content/AllActionsButton"
	) as Button
	action_panel = get_node("ActionPanel") as BattleActionPanel
	action_list = get_node(
		"ActionPanel/Margin/Content/AllActionsScroll/ActionList"
	) as VBoxContainer
	all_actions_scroll = get_node(
		"ActionPanel/Margin/Content/AllActionsScroll"
	) as ScrollContainer
	all_actions_toggle = get_node(
		"ActionPanel/Margin/Content/Heading/AllActionsToggle"
	) as Button
	detail_panel = get_node("OverlayPanels/DetailPanel") as PanelContainer
	detail_image = get_node(
		"OverlayPanels/DetailPanel/Row/DetailImage"
	) as TextureRect
	detail_title = get_node(
		"OverlayPanels/DetailPanel/Row/TextColumn/DetailTitle"
	) as Label
	detail_text = get_node(
		"OverlayPanels/DetailPanel/Row/TextColumn/DetailText"
	) as RichTextLabel
	log_panel = get_node("BattleRoot/Body/BattleHUD/LogPanel") as BattleLogPanel
	log_label = get_node(
		"BattleRoot/Body/BattleHUD/LogPanel/Content/LogLabel"
	) as RichTextLabel
	opponent_hand_surface = get_node(
		"BattleRoot/Body/BoardPanel/BoardCanvas/OpponentHandSurface"
	) as Control
	opponent_hand_count_badge = get_node(
		"BattleRoot/Body/BoardPanel/BoardCanvas/OpponentHandCountBadge"
	) as Label
	hand_scroll = get_node(
		"BattleRoot/Body/BoardPanel/BoardCanvas/HandScroll"
	) as ScrollContainer
	hand_surface = get_node(
		"BattleRoot/Body/BoardPanel/BoardCanvas/HandScroll/HandSurface"
	) as Control
	input_blocker = get_node("PresentationInputBlocker") as Control
	effects = get_node("Effects") as BattleEffectLayer
	director = get_node("PresentationDirector") as PresentationDirector
	animation_player = get_node("AnimationPlayer") as AnimationPlayer
	opponent_active = get_node(
		"BattleRoot/Body/BoardPanel/BoardCanvas/OpponentActive"
	) as CardView
	own_active = get_node(
		"BattleRoot/Body/BoardPanel/BoardCanvas/OwnActive"
	) as CardView


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
	_update_ai_thinking_clock(p_ai_thinking)
	ai_thinking = p_ai_thinking
	game_mode = p_game_mode
	if not _initialized or state_ref == null:
		return
	_refresh_header()
	_refresh_field()
	_refresh_opponent_hand()
	_refresh_hand()
	_refresh_actions()
	_refresh_log()
	_refresh_target_hints()
	_refresh_ai_thinking_indicator()


func _update_ai_thinking_clock(next_ai_thinking: bool) -> void:
	if next_ai_thinking:
		if not ai_thinking or _ai_thinking_started_msec <= 0:
			_ai_thinking_started_msec = Time.get_ticks_msec()
	else:
		_ai_thinking_started_msec = 0


func _refresh_ai_thinking_indicator() -> void:
	if not _initialized:
		return
	var active := ai_thinking and state_ref != null
	var ai_player := _ai_player_index()
	var ai_name := _ai_display_name(ai_player)
	if header:
		header.set_ai_thinking(
			false,
			ai_name,
			0,
			false,
		)
	if ai_thinking_overlay:
		ai_thinking_overlay.configure(
			active,
			ai_player,
			_ai_slot_rects(ai_player),
			AppSettings.reduced_motion,
			ai_name,
			_ai_thinking_started_msec,
		)


func _ai_player_index() -> int:
	if game_mode in ["challenge", "deep"]:
		return 1
	return 1 - view_player


func _ai_display_name(player_idx: int) -> String:
	if state_ref != null and player_idx >= 0 and player_idx < state_ref.players.size():
		var name := str(state_ref.get_player(player_idx).name).strip_edges()
		if not name.is_empty():
			return name
	if game_mode == "deep":
		return "Deep AI"
	if game_mode == "challenge":
		return "Challenge AI"
	return "AI"


func _ai_slot_rects(player_idx: int) -> Array[Rect2]:
	var rects: Array[Rect2] = []
	if board_canvas == null:
		return rects
	for slot_name in ["active", "bench_0", "bench_1", "bench_2", "bench_3", "bench_4"]:
		var view := get_slot_view(player_idx, slot_name)
		if view == null or not view.visible:
			continue
		rects.append(Rect2(view.position, view.size))
	return rects


func play_presentation(
	raw_events: Array,
	revision: int,
	fallback_actor: int = -1,
	previous_snapshot: Dictionary = {},
) -> void:
	if director == null:
		return
	var normalized := PresentationEvent.normalize_all(
		raw_events,
		revision,
		fallback_actor,
	)
	if normalized.is_empty():
		return
	_stage_presentation_targets(normalized, previous_snapshot)
	director.set_speed_mode(AppSettings.animation_mode)
	director.play(normalized)


func clear_presentation_for_resync() -> void:
	if director:
		director.clear_for_resync()
	_clear_transient_visuals()
	modulate.a = 0.35
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 1.0, resync_fade_duration)


func show_card_detail(card_id: String, pokemon: PokemonState = null) -> void:
	if card_id.is_empty():
		hide_card_detail()
		return
	if _all_actions_expanded:
		_collapse_all_actions()
	if detail_panel:
		detail_panel.visible = true
	if detail_close_button:
		detail_close_button.visible = true
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
		var damage_label := str(attack.get("damage_text", ""))
		if damage_label.is_empty() and int(attack.get("damage", 0)) > 0:
			damage_label = str(attack.get("damage", 0))
		lines.append("[color=#f4c84a]%s · %s[/color]\n%s" % [
			attack.get("name", ""),
			damage_label,
			attack.get("text", ""),
		])
	if not str(card.get("trainer_text", "")).is_empty():
		lines.append(str(card.get("trainer_text", "")))
	for rule in card.get("rules", []):
		if not str(rule).is_empty() and str(rule) not in lines:
			lines.append(str(rule))
	detail_text.text = "\n\n".join(lines)


func hide_card_detail() -> void:
	if detail_panel:
		detail_panel.visible = false
	if detail_close_button:
		detail_close_button.visible = false
	if detail_image:
		detail_image.texture = null
	if detail_title:
		detail_title.text = "选择一张卡牌"
	if detail_text:
		detail_text.text = "点击或长按卡牌查看详情。"


func get_slot_view(player: int, slot: String) -> CardView:
	return slot_views.get("%d:%s" % [player, slot]) as CardView


func capture_presentation_snapshot() -> Dictionary:
	if not _initialized or state_ref == null or effects == null:
		return {}
	var snapshot := {
		"view_player": view_player,
		"hand": [],
		"opponent_hand": [],
		"opponent_hand_center": _opponent_hand_center(),
		"slots": {},
		"zones": {},
	}
	for view in hand_views:
		if view == null or not view.visible:
			continue
		(snapshot["hand"] as Array).append({
			"card_id": view.card_id,
			"hand_index": view.hand_index,
			"center": _effects_local(view.global_center()),
			"size": view.size,
			"rotation_degrees": view.rotation_degrees,
			"hidden": view.is_hidden_card,
		})
	for view in opponent_hand_views:
		if view == null or not view.visible:
			continue
		(snapshot["opponent_hand"] as Array).append({
			"center": _effects_local(view.global_center()),
			"size": view.size,
			"rotation_degrees": view.rotation_degrees,
			"hidden": true,
		})
	for key_value in slot_views.keys():
		var key := str(key_value)
		var view := slot_views[key] as CardView
		if view == null:
			continue
		(snapshot["slots"] as Dictionary)[key] = {
			"card_id": view.card_id,
			"center": _effects_local(view.global_center()),
			"size": view.size,
			"rotation_degrees": view.rotation_degrees,
			"empty": view.empty,
			"hidden": view.is_hidden_card,
		}
	for zone_key in zones.keys():
		var zone := zones[zone_key] as ZoneView
		if zone == null:
			continue
		var logical_key := _logical_zone_key(str(zone_key))
		(snapshot["zones"] as Dictionary)[logical_key] = {
			"card_id": zone.card_id,
			"center": _zone_center(str(zone_key)),
			"size": zone.size,
			"rotation_degrees": zone.rotation_degrees,
			"count": zone.count,
			"hidden": zone.is_hidden_zone,
		}
	return snapshot


func _zone_context(
	player: int,
	zone_name: String,
	card_ids: Array,
	zone_count: int,
	is_hidden: bool,
) -> Dictionary:
	var visible_ids: Array[String] = []
	if not is_hidden:
		for value in card_ids:
			var card_id := str(value)
			if not card_id.is_empty():
				visible_ids.append(card_id)
	return {
		"player": player,
		"zone": zone_name,
		"title": _zone_title(zone_name),
		"card_ids": visible_ids,
		"count": zone_count,
		"hidden": is_hidden,
	}


func _card_inspection_context(card_id: String) -> Dictionary:
	var context := {
		"card_id": card_id,
		"title": CardDatabase.get_card(card_id).get("name", card_id),
		"location": "卡牌",
		"pokemon": null,
		"player": view_player,
		"slot": "",
	}
	if state_ref == null:
		return context
	if selected_entity_key.begins_with("pokemon:"):
		var parts := selected_entity_key.split(":")
		if parts.size() >= 3:
			var selected_player := int(parts[1])
			var selected_slot := str(parts[2])
			var selected_pokemon := state_ref.get_player(selected_player).get_pokemon(selected_slot)
			if selected_pokemon and selected_pokemon.card_id == card_id:
				context["pokemon"] = selected_pokemon
				context["player"] = selected_player
				context["slot"] = selected_slot
				context["location"] = _player_label(selected_player) + " " + _slot_name(selected_slot)
				return context
	for player_idx in [view_player, 1 - view_player]:
		var player_state := state_ref.get_player(player_idx)
		for row in player_state.get_all_pokemon():
			var pokemon: PokemonState = row["pokemon"]
			if pokemon and pokemon.card_id == card_id:
				context["pokemon"] = pokemon
				context["player"] = player_idx
				context["slot"] = str(row["slot"])
				context["location"] = _player_label(player_idx) + " " + _slot_name(str(row["slot"]))
				return context
	if card_id in state_ref.get_player(view_player).hand:
		context["location"] = "手牌"
	return context


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
			return (
				_own_hand_center()
				if player == view_player
				else _opponent_hand_center()
			)
	return effects.size * Vector2(0.5, 0.5)


func _bind_scene_nodes() -> void:
	hud.custom_minimum_size.x = hud_width
	if detail_panel:
		detail_panel.visible = false
		detail_panel.z_index = 34
		_ensure_detail_close_button()
	if log_panel:
		log_panel.z_index = 0
		log_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		log_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	playmat.quality_profile = AppSettings.resolved_quality_profile()
	effects.quality_profile = AppSettings.resolved_quality_profile()
	opponent_hand_surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	opponent_hand_surface.z_index = 6
	opponent_hand_count_badge.z_index = 12
	opponent_hand_count_badge.add_theme_stylebox_override(
		"normal",
		DesignTokens.panel_style(
			DesignTokens.GOLD,
			15,
			DesignTokens.TEXT,
			1,
			0,
		),
	)
	opponent_hand_count_badge.add_theme_color_override(
		"font_color",
		DesignTokens.BG_DEEP,
	)
	phase_labels = {
		"DRAW": get_node(
			"BattleRoot/Body/BattleHUD/PhasePanel/Content/PhaseRow/DrawPhase"
		),
		"MAIN": get_node(
			"BattleRoot/Body/BattleHUD/PhasePanel/Content/PhaseRow/MainPhase"
		),
		"ATTACK": get_node(
			"BattleRoot/Body/BattleHUD/PhasePanel/Content/PhaseRow/AttackPhase"
		),
		"POKEMON_CHECKUP": get_node(
			"BattleRoot/Body/BattleHUD/PhasePanel/Content/PhaseRow/CheckupPhase"
		),
	}
	var board_path := "BattleRoot/Body/BoardPanel/BoardCanvas/"
	opponent_bench.assign([
		get_node(board_path + "OpponentBench0"),
		get_node(board_path + "OpponentBench1"),
		get_node(board_path + "OpponentBench2"),
		get_node(board_path + "OpponentBench3"),
		get_node(board_path + "OpponentBench4"),
	])
	own_bench.assign([
		get_node(board_path + "OwnBench0"),
		get_node(board_path + "OwnBench1"),
		get_node(board_path + "OwnBench2"),
		get_node(board_path + "OwnBench3"),
		get_node(board_path + "OwnBench4"),
	])
	zones = {
		"opponent_deck": get_node(board_path + "OpponentDeck"),
		"opponent_discard": get_node(board_path + "OpponentDiscard"),
		"opponent_prizes": get_node(board_path + "OpponentPrizes"),
		"own_deck": get_node(board_path + "OwnDeck"),
		"own_discard": get_node(board_path + "OwnDiscard"),
		"own_prizes": get_node(board_path + "OwnPrizes"),
		"stadium": get_node(board_path + "Stadium"),
	}
	(zones["opponent_deck"] as ZoneView).set_stack_visual("deck", 60, "up")
	(zones["own_deck"] as ZoneView).set_stack_visual("deck", 60, "down")
	(zones["opponent_discard"] as ZoneView).set_stack_visual("discard", 60, "up")
	(zones["own_discard"] as ZoneView).set_stack_visual("discard", 60, "down")
	(zones["opponent_prizes"] as ZoneView).set_stack_visual("prizes", 6, "right")
	(zones["own_prizes"] as ZoneView).set_stack_visual("prizes", 6, "right")
	for view in [opponent_active, own_active] + opponent_bench + own_bench:
		_bind_card_view(view)
	for zone_value in zones.values():
		var zone := zone_value as ZoneView
		zone.activated.connect(_on_detail_requested)
		zone.inspected.connect(_on_zone_inspected)
		zone.action_requested.connect(action_requested.emit)
	(get_node("BattleRoot/Header/MenuButton") as Button).pressed.connect(_on_menu_pressed)
	phase_advance_button.pressed.connect(_on_phase_advance_pressed)
	all_actions_button.pressed.connect(_toggle_all_actions)
	all_actions_toggle.pressed.connect(_collapse_all_actions)
	if action_panel:
		action_panel.z_index = 35
		action_panel.action_requested.connect(action_requested.emit)
	show_card_detail("")
	director.sequence_started.connect(func(_count: int) -> void:
		input_blocker.visible = not AppSettings.reduced_motion
	)
	director.sequence_finished.connect(func() -> void:
		input_blocker.visible = false
		_clear_presentation_masks(true)
		_clear_active_flyers()
	)
	director.event_finished.connect(_on_presentation_event_finished)
	director.floating_text_requested.connect(_on_floating_text_requested)
	director.burst_requested.connect(_on_burst_requested)
	director.card_motion_requested.connect(_on_card_motion_requested)
	director.camera_impulse_requested.connect(_on_camera_impulse_requested)


func _bind_card_view(view: CardView) -> void:
	view.set_catalog(catalog)
	view.activated.connect(_on_card_activated)
	view.detail_requested.connect(_on_detail_requested)
	view.card_dropped.connect(_on_card_dropped)
	view.action_requested.connect(action_requested.emit)


func _on_phase_advance_pressed() -> void:
	var action: GameAction = phase_advance_button.get_meta("action") as GameAction
	if action:
		action_requested.emit(action)


func _refresh_header() -> void:
	if header:
		header.update_header(state_ref, view_player, ai_thinking)
	else:
		var display_actor := view_player if state_ref.phase == "SETUP" else state_ref.active_player_idx
		turn_label.text = "第 %d 回合 · %s · 玩家 %d" % [
			state_ref.turn_number,
			_phase_name(state_ref.phase),
			display_actor + 1,
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
		_zone_context(1 - view_player, "deck", [], opponent.deck.size(), true),
	)
	(zones["opponent_discard"] as ZoneView).configure(
		"弃牌",
		opponent.discard[-1] if not opponent.discard.is_empty() else "",
		opponent.discard.size(),
		false,
		_zone_context(1 - view_player, "discard", opponent.discard, opponent.discard.size(), false),
	)
	(zones["opponent_prizes"] as ZoneView).configure(
		"奖品",
		"",
		opponent.prizes.size(),
		true,
		_zone_context(1 - view_player, "prizes", [], opponent.prizes.size(), true),
	)
	(zones["own_deck"] as ZoneView).configure(
		"牌库",
		"",
		own.deck.size(),
		true,
		_zone_context(view_player, "deck", [], own.deck.size(), true),
	)
	(zones["own_discard"] as ZoneView).configure(
		"弃牌",
		own.discard[-1] if not own.discard.is_empty() else "",
		own.discard.size(),
		false,
		_zone_context(view_player, "discard", own.discard, own.discard.size(), false),
	)
	(zones["own_prizes"] as ZoneView).configure(
		"奖品",
		"",
		own.prizes.size(),
		true,
		_zone_context(view_player, "prizes", [], own.prizes.size(), true),
	)
	(zones["stadium"] as ZoneView).configure(
		"竞技场",
		state_ref.stadium_card_id,
		0 if state_ref.stadium_card_id.is_empty() else 1,
		false,
		_zone_context(-1, "stadium", [state_ref.stadium_card_id] if not state_ref.stadium_card_id.is_empty() else [], 0 if state_ref.stadium_card_id.is_empty() else 1, false),
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


func _refresh_opponent_hand() -> void:
	if opponent_hand_surface == null or state_ref == null:
		return
	var opponent_player := 1 - view_player
	var hand_count := state_ref.get_player(opponent_player).hand.size()
	var visible_count := mini(
		maxi(0, hand_count),
		maxi(0, opponent_hand_max_visible),
	)
	while opponent_hand_views.size() < visible_count:
		var card := _new_card_view()
		opponent_hand_surface.add_child(card)
		card.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.focus_mode = Control.FOCUS_NONE
		card.mouse_default_cursor_shape = Control.CURSOR_ARROW
		opponent_hand_views.append(card)
	for index in range(opponent_hand_views.size()):
		var view := opponent_hand_views[index]
		if index >= visible_count:
			view.visible = false
			continue
		view.visible = true
		view.configure("", null, true, -1, opponent_player, "", true)
		view.set_selected(false)
		view.set_targetable(false)
		view.set_actions([])
		view.tooltip_text = "对手手牌（隐藏）"
	opponent_hand_surface.visible = hand_count > 0
	opponent_hand_count_badge.visible = hand_count > 0
	opponent_hand_count_badge.text = str(hand_count)
	_layout_opponent_hand()


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
	_refresh_all_actions_panel()


func _refresh_all_actions_panel() -> void:
	var has_actions := not action_rows.is_empty()
	if not has_actions:
		_all_actions_expanded = false
	if all_actions_button:
		all_actions_button.disabled = not has_actions
		all_actions_button.text = "隐藏动作" if _all_actions_expanded else "全部动作"
		all_actions_button.tooltip_text = (
			"收起完整动作列表"
			if _all_actions_expanded
			else "查看全部合法动作"
			if has_actions
			else "当前没有可执行动作"
		)
	if action_panel:
		action_panel.update_actions(
			action_rows,
			selected_entity_key,
			ai_thinking,
			game_mode,
			_all_actions_expanded,
		)


func _refresh_log() -> void:
	if log_panel:
		log_panel.update_entries(state_ref.action_log)
		return
	var lines: Array[String] = []
	for index in range(state_ref.action_log.size()):
		lines.append("[color=#62d7ff]◆[/color] " + state_ref.action_log[index])
	if log_label:
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
	var metrics := _board_layout_metrics(width, height)
	_layout_player_hands(metrics)
	_layout_field_slots(metrics)
	_layout_table_zones(metrics)
	_layout_opponent_hand(metrics["hidden_hand_size"])
	_layout_hand(metrics["own_hand_size"])
	_layout_overlay_drawers()
	_refresh_ai_thinking_indicator()
	if playmat:
		playmat.queue_redraw()
	if effects:
		effects.queue_redraw()


func _board_layout_metrics(width: float, height: float) -> Dictionary:
	var layout_scale := clampf(minf(width / 1500.0, height / 840.0), 0.76, 1.08)
	var battle_card_boost := 1.32
	var active_size := active_card_size * layout_scale * battle_card_boost
	var bench_size := bench_card_size * layout_scale * battle_card_boost
	var zone_visual_size := zone_size * layout_scale
	var own_hand_size := hand_card_size * layout_scale
	var hidden_hand_size := opponent_hand_card_size * layout_scale * 0.76
	var side_margin := maxf(14.0, table_side_margin * layout_scale)
	var top_margin := maxf(10.0, table_top_margin * layout_scale)
	var bottom_margin := maxf(8.0, table_bottom_margin * layout_scale)
	var zone_gap := 12.0 * layout_scale
	var left_zone_x := side_margin
	var side_zone_x := width - zone_visual_size.x - side_margin
	var field_left := left_zone_x + zone_visual_size.x + 36.0 * layout_scale
	var field_right := side_zone_x - 36.0 * layout_scale
	if field_right <= field_left + 360.0 * layout_scale:
		field_left = side_margin
		field_right = width - side_margin
	var table_width := maxf(300.0, field_right - field_left)
	var center_x := (field_left + field_right) * 0.5
	var top_hand_height := hidden_hand_size.y + 20.0 * layout_scale
	var opponent_hand_width := clampf(
		table_width * 0.38,
		270.0 * layout_scale,
		minf(table_width, 500.0 * layout_scale),
	)
	var own_hand_height := own_hand_size.y + 22.0 * layout_scale
	var own_hand_peek := clampf(own_hand_height * 0.72, 118.0 * layout_scale, own_hand_height)
	var own_hand_y := height - own_hand_peek - bottom_margin - hand_bottom_padding * layout_scale
	var hand_width := clampf(
		table_width * 0.64,
		520.0 * layout_scale,
		minf(table_width, 850.0 * layout_scale),
	)
	var hidden_hand_visible_height := maxf(24.0, hidden_hand_size.y * 0.32)
	top_hand_height = hidden_hand_visible_height + 10.0 * layout_scale
	var opponent_hand_y := top_margin - hidden_hand_size.y * 0.72
	var opponent_info_y := top_margin + hidden_hand_visible_height + 3.0
	var own_info_y := own_hand_y - 28.0
	return {
		"width": width,
		"height": height,
		"layout_scale": layout_scale,
		"active_size": active_size,
		"bench_size": bench_size,
		"zone_size": zone_visual_size,
		"own_hand_size": own_hand_size,
		"hidden_hand_size": hidden_hand_size,
		"side_margin": side_margin,
		"top_margin": top_margin,
		"bottom_margin": bottom_margin,
		"zone_gap": zone_gap,
		"left_zone_x": left_zone_x,
		"side_zone_x": side_zone_x,
		"field_left": field_left,
		"field_right": field_right,
		"table_width": table_width,
		"center_x": center_x,
		"top_hand_height": top_hand_height,
		"opponent_hand_y": opponent_hand_y,
		"opponent_hand_visible_height": hidden_hand_visible_height,
		"opponent_hand_width": opponent_hand_width,
		"own_hand_height": own_hand_height,
		"own_hand_y": own_hand_y,
		"hand_width": hand_width,
		"opponent_info_y": opponent_info_y,
		"own_info_y": own_info_y,
		"arena_top": opponent_info_y + 8.0,
		"arena_bottom": own_hand_y - 6.0,
	}


func _layout_player_hands(metrics: Dictionary) -> void:
	var center_x := float(metrics["center_x"])
	var top_margin := float(metrics["top_margin"])
	var hidden_hand_size: Vector2 = metrics["hidden_hand_size"]
	var opponent_hand_width := float(metrics["opponent_hand_width"])
	var top_hand_height := float(metrics["top_hand_height"])
	var opponent_hand_y := float(metrics["opponent_hand_y"])
	var opponent_visible_height := float(metrics["opponent_hand_visible_height"])
	opponent_hand_surface.position = Vector2(
		center_x - opponent_hand_width * 0.5,
		opponent_hand_y,
	)
	opponent_hand_surface.size = Vector2(
		opponent_hand_width,
		top_hand_height + hidden_hand_size.y,
	)
	opponent_hand_count_badge.position = Vector2(
		opponent_hand_surface.position.x + opponent_hand_surface.size.x - 18.0,
		top_margin + opponent_visible_height - 25.0,
	)
	opponent_hand_count_badge.size = Vector2(34.0, 34.0)
	opponent_info.position = Vector2(
		float(metrics["field_left"]),
		float(metrics["opponent_info_y"]),
	)
	opponent_info.size = Vector2(float(metrics["table_width"]), 24.0)

	var own_hand_y := float(metrics["own_hand_y"])
	var hand_width := float(metrics["hand_width"])
	hand_scroll.position = Vector2(center_x - hand_width * 0.5, own_hand_y)
	hand_scroll.size = Vector2(hand_width, float(metrics["own_hand_height"]))
	hand_surface.custom_minimum_size.y = float(metrics["own_hand_height"]) - 8.0
	own_info.position = Vector2(float(metrics["field_left"]), float(metrics["own_info_y"]))
	own_info.size = Vector2(float(metrics["table_width"]), 24.0)


func _layout_field_slots(metrics: Dictionary) -> void:
	var active_size: Vector2 = metrics["active_size"]
	var bench_size: Vector2 = metrics["bench_size"]
	var layout_scale := float(metrics["layout_scale"])
	var table_width := float(metrics["table_width"])
	var center_x := float(metrics["center_x"])
	var arena_top := float(metrics["arena_top"])
	var arena_bottom := float(metrics["arena_bottom"])
	var arena_height := maxf(1.0, arena_bottom - arena_top)
	var active_gap := 30.0 * layout_scale
	var active_clearance := 20.0 * layout_scale
	var bench_edge_gap := 10.0 * layout_scale
	var required_field_height := (
		active_size.y * 2.0
		+ bench_size.y * 2.0
		+ active_gap
		+ active_clearance * 2.0
		+ bench_edge_gap * 2.0
	)
	var battle_scale := minf(
		1.0,
		arena_height / maxf(1.0, required_field_height),
	)
	if battle_scale < 1.0:
		active_size *= battle_scale
		bench_size *= battle_scale
		active_gap *= battle_scale
		active_clearance *= battle_scale
		bench_edge_gap *= battle_scale
	var arena_middle := (arena_top + arena_bottom) * 0.5
	var bench_gap := clampf(
		bench_spacing * layout_scale * battle_scale + table_width * 0.018,
		bench_spacing * layout_scale * battle_scale,
		30.0 * layout_scale,
	)
	var bench_total := bench_size.x * 5.0 + bench_gap * 4.0
	var bench_x := center_x - bench_total * 0.5
	var opponent_active_y := arena_middle - active_gap * 0.5 - active_size.y
	var own_active_y := arena_middle + active_gap * 0.5
	var top_bench_y := opponent_active_y - bench_size.y - active_clearance
	var bottom_bench_y := own_active_y + active_size.y + active_clearance
	if top_bench_y < arena_top + bench_edge_gap:
		var shift_down := arena_top + bench_edge_gap - top_bench_y
		top_bench_y += shift_down
		opponent_active_y += shift_down * 0.42
	if bottom_bench_y + bench_size.y > arena_bottom - bench_edge_gap:
		var shift_up := bottom_bench_y + bench_size.y - (arena_bottom - bench_edge_gap)
		bottom_bench_y -= shift_up
		own_active_y -= shift_up * 0.42
	var opponent_bench_rects: Array[Rect2] = []
	var own_bench_rects: Array[Rect2] = []
	for index in range(5):
		var opponent_center := Vector2(
			bench_x + index * (bench_size.x + bench_gap) + bench_size.x * 0.5,
			top_bench_y + bench_size.y * 0.5,
		)
		var own_center := Vector2(
			bench_x + index * (bench_size.x + bench_gap) + bench_size.x * 0.5,
			bottom_bench_y + bench_size.y * 0.5,
		)
		opponent_bench_rects.append(_perspective_card_rect(
			opponent_center,
			bench_size,
			metrics,
		).get("rect", Rect2()))
		own_bench_rects.append(_perspective_card_rect(
			own_center,
			bench_size,
			metrics,
		).get("rect", Rect2()))
		_place_perspective_card(
			opponent_bench[index],
			opponent_center,
			bench_size,
			metrics,
			-2.4 + float(index - 2) * 0.22,
			index,
		)
		_place_perspective_card(
			own_bench[index],
			own_center,
			bench_size,
			metrics,
			2.4 + float(index - 2) * 0.22,
			20 + index,
		)
	var opponent_active_center := Vector2(
		center_x,
		opponent_active_y + active_size.y * 0.5,
	)
	var own_active_center := Vector2(center_x, own_active_y + active_size.y * 0.5)
	var opponent_active_rect: Rect2 = _perspective_card_rect(
		opponent_active_center,
		active_size,
		metrics,
	).get("rect", Rect2())
	var own_active_rect: Rect2 = _perspective_card_rect(
		own_active_center,
		active_size,
		metrics,
	).get("rect", Rect2())
	_place_perspective_card(
		opponent_active,
		opponent_active_center,
		active_size,
		metrics,
		-1.2,
		12,
	)
	_place_perspective_card(
		own_active,
		own_active_center,
		active_size,
		metrics,
		1.2,
		34,
	)
	_update_playmat_field_guides(
		opponent_bench_rects,
		own_bench_rects,
		opponent_active_rect,
		own_active_rect,
		metrics,
	)


func _layout_table_zones(metrics: Dictionary) -> void:
	var layout_scale := float(metrics["layout_scale"])
	var top_margin := float(metrics["top_margin"])
	var left_zone_x := float(metrics["left_zone_x"])
	var side_zone_x := float(metrics["side_zone_x"])
	var zone_visual_size: Vector2 = metrics["zone_size"]
	var zone_gap := float(metrics["zone_gap"])
	var own_hand_y := float(metrics["own_hand_y"])
	var arena_middle := (float(metrics["arena_top"]) + float(metrics["arena_bottom"])) * 0.5
	var top_zone_y := top_margin + 18.0 * layout_scale
	var own_zone_y := own_hand_y - zone_visual_size.y - 12.0 * layout_scale
	var own_zone_shift_down := 110.0 * layout_scale
	own_zone_y = minf(
		own_zone_y + own_zone_shift_down,
		float(metrics["height"]) - zone_visual_size.y - float(metrics["bottom_margin"]),
	)
	var opponent_discard_y := top_zone_y + zone_visual_size.y + zone_gap
	var own_discard_y := own_zone_y - zone_visual_size.y - zone_gap
	_place_perspective_zone(
		"opponent_prizes",
		Vector2(left_zone_x, top_zone_y),
		zone_visual_size,
		metrics,
	)
	_place_perspective_zone(
		"opponent_deck",
		Vector2(side_zone_x, top_zone_y),
		zone_visual_size,
		metrics,
	)
	_place_perspective_zone(
		"opponent_discard",
		Vector2(side_zone_x, opponent_discard_y),
		zone_visual_size,
		metrics,
	)
	var stadium_y := arena_middle - zone_visual_size.y * 0.5
	var stadium_min_y := opponent_discard_y + zone_visual_size.y + zone_gap
	var stadium_max_y := own_discard_y - zone_visual_size.y - zone_gap
	if stadium_max_y > stadium_min_y:
		stadium_y = clampf(stadium_y, stadium_min_y, stadium_max_y)
	_place_perspective_zone("stadium", Vector2(left_zone_x, stadium_y), zone_visual_size, metrics)
	_place_perspective_zone(
		"own_discard",
		Vector2(side_zone_x, own_discard_y),
		zone_visual_size,
		metrics,
	)
	_place_perspective_zone(
		"own_deck",
		Vector2(side_zone_x, own_zone_y),
		zone_visual_size,
		metrics,
	)
	_place_perspective_zone(
		"own_prizes",
		Vector2(left_zone_x, own_zone_y),
		zone_visual_size,
		metrics,
	)


func _place_perspective_card(
	view: CardView,
	center: Vector2,
	base_size: Vector2,
	metrics: Dictionary,
	rotation_value: float,
	z_bias: int,
) -> void:
	var row := _perspective_card_rect(center, base_size, metrics)
	var depth := float(row.get("depth", 0.5))
	var rect: Rect2 = row.get("rect", Rect2(center - base_size * 0.5, base_size))
	_place_card(
		view,
		rect.position,
		rect.size,
		depth,
		rotation_value,
		int(10 + depth * 42.0) + z_bias,
	)


func _perspective_card_rect(
	center: Vector2,
	base_size: Vector2,
	metrics: Dictionary,
) -> Dictionary:
	var depth := _perspective_depth(center.y, metrics)
	var scale := lerpf(0.86, 1.08, depth)
	var size_value := base_size * scale
	var center_x := float(metrics["center_x"])
	var spread := lerpf(0.96, 1.035, depth)
	var projected_center := Vector2(
		center_x + (center.x - center_x) * spread,
		center.y,
	)
	return {
		"depth": depth,
		"rect": Rect2(projected_center - size_value * 0.5, size_value),
	}


func _update_playmat_field_guides(
	opponent_bench_rects: Array[Rect2],
	own_bench_rects: Array[Rect2],
	opponent_active_rect: Rect2,
	own_active_rect: Rect2,
	metrics: Dictionary,
) -> void:
	if playmat == null:
		return
	var guides: Array[Dictionary] = []
	guides.append({
		"kind": "bench",
		"side": "opponent",
		"rect": _union_rects(opponent_bench_rects).grow(
			12.0 * float(metrics["layout_scale"])
		),
		"slots": opponent_bench_rects,
		"depth": _perspective_depth(_union_rects(opponent_bench_rects).get_center().y, metrics),
	})
	guides.append({
		"kind": "bench",
		"side": "own",
		"rect": _union_rects(own_bench_rects).grow(
			12.0 * float(metrics["layout_scale"])
		),
		"slots": own_bench_rects,
		"depth": _perspective_depth(_union_rects(own_bench_rects).get_center().y, metrics),
	})
	guides.append({
		"kind": "active",
		"side": "opponent",
		"rect": opponent_active_rect,
		"depth": _perspective_depth(opponent_active_rect.get_center().y, metrics),
	})
	guides.append({
		"kind": "active",
		"side": "own",
		"rect": own_active_rect,
		"depth": _perspective_depth(own_active_rect.get_center().y, metrics),
	})
	playmat.set_field_guides(guides)


func _union_rects(rects: Array[Rect2]) -> Rect2:
	if rects.is_empty():
		return Rect2()
	var result := rects[0]
	for index in range(1, rects.size()):
		result = result.merge(rects[index])
	return result


func _place_perspective_zone(
	key: String,
	position_value: Vector2,
	base_size: Vector2,
	metrics: Dictionary,
) -> void:
	var center_y := position_value.y + base_size.y * 0.5
	var depth := _perspective_depth(center_y, metrics)
	var size_value := base_size * lerpf(0.88, 1.05, depth)
	var near_side := depth >= 0.52
	var adjusted := position_value
	if near_side:
		adjusted.y -= (size_value.y - base_size.y) * 0.5
	_place_zone(
		key,
		adjusted,
		size_value,
		depth,
		-1.6 if depth < 0.45 else 1.2,
		int(8 + depth * 34.0),
	)


func _perspective_depth(y: float, metrics: Dictionary) -> float:
	return clampf(
		(y - float(metrics["arena_top"]))
		/ maxf(1.0, float(metrics["arena_bottom"]) - float(metrics["arena_top"])),
		0.0,
		1.0,
	)


func _layout_overlay_drawers() -> void:
	if board_panel == null:
		return
	var board_origin := board_panel.global_position - global_position
	var board_rect := Rect2(board_origin, board_panel.size)
	var drawer_width := clampf(
		board_panel.size.x * 0.23,
		260.0,
		340.0,
	)
	var drawer_x := board_origin.x + board_panel.size.x - drawer_width - 14.0
	var detail_height := clampf(board_panel.size.y * 0.28, 190.0, 240.0)
	var action_height := clampf(board_panel.size.y * 0.42, 240.0, 360.0)
	if detail_panel:
		var detail_rect := _detail_drawer_rect(board_rect, drawer_width, detail_height)
		detail_panel.position = detail_rect.position
		detail_panel.size = detail_rect.size
		detail_panel.custom_minimum_size = detail_rect.size
	if action_panel:
		action_panel.position = Vector2(drawer_x, board_origin.y + 14.0)
		action_panel.size = Vector2(drawer_width, action_height)
		action_panel.custom_minimum_size = Vector2(drawer_width, action_height)
	if detail_close_button:
		var close_anchor := (
			detail_panel.position if detail_panel else Vector2(drawer_x, board_origin.y + 14.0)
		)
		var close_width := detail_panel.size.x if detail_panel else drawer_width
		detail_close_button.position = Vector2(
			close_anchor.x + close_width - 34.0,
			close_anchor.y + 6.0,
		)
		detail_close_button.size = Vector2(28.0, 28.0)


func _detail_drawer_rect(
	board_rect: Rect2,
	drawer_width: float,
	default_height: float,
) -> Rect2:
	var margin := 14.0
	var gap := 18.0
	var detail_gap := 26.0
	var minimum_height := 120.0
	var discard_rect := _control_rect_in_table(zones.get("opponent_discard") as Control)
	var own_discard_rect := _control_rect_in_table(zones.get("own_discard") as Control)
	var own_deck_rect := _control_rect_in_table(zones.get("own_deck") as Control)
	var right_edge := (
		discard_rect.end.x if discard_rect.size != Vector2.ZERO else board_rect.end.x - margin
	)
	var x_value := clampf(
		right_edge - drawer_width,
		board_rect.position.x + margin,
		board_rect.end.x - drawer_width - margin,
	)
	var preferred_y := (
		discard_rect.end.y + detail_gap
		if discard_rect.size != Vector2.ZERO
		else board_rect.position.y + margin
	)
	var lower_zone_top := board_rect.end.y - margin
	if own_discard_rect.size != Vector2.ZERO:
		lower_zone_top = minf(lower_zone_top, own_discard_rect.position.y - gap)
	if own_deck_rect.size != Vector2.ZERO:
		lower_zone_top = minf(lower_zone_top, own_deck_rect.position.y - gap)
	var max_height := maxf(minimum_height, lower_zone_top - preferred_y)
	var height_value := minf(default_height, max_height)
	var y_value := clampf(
		preferred_y,
		board_rect.position.y + margin,
		maxf(board_rect.position.y + margin, lower_zone_top - height_value),
	)
	return Rect2(Vector2(x_value, y_value), Vector2(drawer_width, height_value))


func _control_rect_in_table(control: Control) -> Rect2:
	if control == null or not is_instance_valid(control):
		return Rect2()
	return Rect2(control.global_position - global_position, control.size)


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
			hand_minimum_spacing,
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
		view.custom_minimum_size = card_size
		view.size = card_size
		view.position = Vector2(start_x + visible_index * spacing, 14)
		var normalized := (
			0.0
			if visible_count <= 1
			else float(visible_index) / float(visible_count - 1) - 0.5
		)
		view.rotation_degrees = normalized * minf(
			hand_rotation_degrees,
			float(visible_count) * 0.55,
		)
		view.z_index = 70 + visible_index
		view.set_table_depth(0.96, true)
		view.remember_base_position()
		view.set_selected(selected_entity_key == "hand:%d" % view.hand_index)
		visible_index += 1


func _layout_opponent_hand(card_size: Vector2 = Vector2(70, 98)) -> void:
	if opponent_hand_surface == null:
		return
	var visible_count := 0
	for view in opponent_hand_views:
		if view.visible:
			visible_count += 1
	var available := maxf(180.0, opponent_hand_surface.size.x)
	var spacing := card_size.x * 0.42
	if visible_count > 1:
		spacing = clampf(
			(available - card_size.x) / float(visible_count - 1),
			opponent_hand_minimum_spacing,
			card_size.x * 0.58,
		)
	var content_width := (
		card_size.x
		if visible_count <= 1
		else card_size.x + spacing * float(visible_count - 1)
	)
	var start_x := maxf(0.0, (available - content_width) * 0.5)
	var visible_index := 0
	for view in opponent_hand_views:
		if not view.visible:
			continue
		view.custom_minimum_size = card_size
		view.size = card_size
		var normalized := (
			0.0
			if visible_count <= 1
			else float(visible_index) / float(visible_count - 1) - 0.5
		)
		view.position = Vector2(
			start_x + visible_index * spacing,
			-4.0 + absf(normalized) * 5.0,
		)
		view.rotation_degrees = -normalized * minf(
			opponent_hand_rotation_degrees,
			float(visible_count) * 0.55,
		)
		view.z_index = 5 + visible_index
		view.set_table_depth(0.18, false)
		view.remember_base_position()
		visible_index += 1


func _new_card_view() -> CardView:
	var view := CARD_SCENE.instantiate() as CardView
	_bind_card_view(view)
	return view


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
			result["label"] = "撤退到这里 · %s" % _retreat_compact_suffix(action)
		"PROMOTE":
			result["label"] = "晋升"
		"USE_STADIUM":
			result["label"] = "发动"
	return result


func _retreat_compact_suffix(action: GameAction) -> String:
	var count := 0
	if action != null:
		count = action.params.get("energy_indices", []).size()
	if count <= 0:
		return "免费"
	return "丢%d能量" % count


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
	if action_rows.is_empty():
		return
	_all_actions_expanded = not _all_actions_expanded
	if _all_actions_expanded:
		hide_card_detail()
	_refresh_all_actions_panel()


func _collapse_all_actions() -> void:
	_all_actions_expanded = false
	_refresh_all_actions_panel()


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
	if not card_id.is_empty():
		inspect_card_requested.emit(_card_inspection_context(card_id))


func _on_menu_pressed() -> void:
	hide_card_detail()
	menu_requested.emit()


func _ensure_detail_close_button() -> void:
	if detail_close_button or detail_panel == null:
		return
	var overlay := detail_panel.get_parent() as Control
	if overlay == null:
		return
	detail_close_button = Button.new()
	detail_close_button.name = "DetailCloseButton"
	detail_close_button.text = "X"
	detail_close_button.tooltip_text = "关闭卡牌详情"
	detail_close_button.focus_mode = Control.FOCUS_NONE
	detail_close_button.mouse_filter = Control.MOUSE_FILTER_STOP
	detail_close_button.visible = false
	detail_close_button.z_index = 36
	detail_close_button.add_theme_font_size_override("font_size", 14)
	detail_close_button.add_theme_color_override("font_color", DesignTokens.TEXT)
	detail_close_button.add_theme_stylebox_override(
		"normal",
		DesignTokens.panel_style(
			Color(0.08, 0.14, 0.23, 0.98),
			8,
			DesignTokens.BORDER,
			1,
			0,
		),
	)
	detail_close_button.add_theme_stylebox_override(
		"hover",
		DesignTokens.panel_style(
			DesignTokens.PANEL_RAISED,
			8,
			DesignTokens.CYAN,
			1,
			0,
		),
	)
	detail_close_button.add_theme_stylebox_override(
		"pressed",
		DesignTokens.panel_style(
			DesignTokens.BORDER,
			8,
			DesignTokens.CYAN,
			1,
			0,
		),
	)
	overlay.add_child(detail_close_button)
	detail_close_button.pressed.connect(hide_card_detail)


func _on_zone_inspected(context: Dictionary) -> void:
	inspect_zone_requested.emit(context)


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


func _stage_presentation_targets(
	events: Array[Dictionary],
	previous_snapshot: Dictionary,
) -> void:
	if director == null or not director.is_playing():
		_clear_presentation_masks(true)
	_presentation_snapshot = previous_snapshot.duplicate(true)
	_presentation_event_hand_targets.clear()
	_presentation_hand_target_cursor.clear()
	_presentation_hand_removed_counts.clear()
	_stage_presentation_zone_states(events, previous_snapshot)
	for event in events:
		var event_id := str(event.get("event_id", ""))
		if event_id.is_empty():
			continue
		_record_hand_removals_for_event(event)
		_precompute_hand_targets_for_event(event)
		var targets := _presentation_targets_for_event(event)
		if not targets.is_empty():
			_presentation_reveals[event_id] = targets
			for target in targets:
				_mask_presentation_node(target)
		var feedback_targets := _presentation_feedback_targets_for_event(event)
		if not feedback_targets.is_empty():
			_presentation_feedbacks[event_id] = feedback_targets
		_stage_presentation_cover(event)


func _stage_presentation_zone_states(
	events: Array[Dictionary],
	previous_snapshot: Dictionary,
) -> void:
	_presentation_zone_states.clear()
	var zones_snapshot: Dictionary = previous_snapshot.get("zones", {})
	if zones_snapshot.is_empty():
		return
	var affected: Dictionary = {}
	for event in events:
		for endpoint in _zone_endpoints_for_event(event):
			var key := _presentation_zone_key(endpoint)
			if key.is_empty():
				continue
			affected[key] = true
	for key_value in affected.keys():
		var key := str(key_value)
		var row: Dictionary = Dictionary(zones_snapshot.get(key, {})).duplicate(true)
		if row.is_empty():
			continue
		_presentation_zone_states[key] = row
		_apply_presentation_zone_state(key)


func _zone_endpoints_for_event(event: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var event_type := str(event.get("event_type", ""))
	var actor := int(event.get("actor", view_player))
	var data: Dictionary = event.get("data", {})
	var source := _event_source_endpoint(event)
	var target := _event_target_endpoint(event)
	match event_type:
		"cards_drawn":
			result.append({"player": actor, "zone": "deck"})
		"prize_taken":
			result.append({"player": actor, "zone": "prizes"})
		"cards_discarded":
			if str(source.get("zone", "")).is_empty():
				source = {"player": actor, "zone": "hand"}
			result.append({"player": actor, "zone": "discard"})
			if str(source.get("zone", "")) != "hand":
				result.append(source)
		"trainer_played":
			result.append({"player": actor, "zone": "discard"})
		"stadium_changed":
			result.append({"player": -1, "zone": "stadium"})
		"card_moved":
			result.append(source)
			result.append(target)
		"pokemon_ko":
			result.append({
				"player": int(data.get("player", actor)),
				"zone": "discard",
			})
		"deck_shuffled":
			result.append({
				"player": int(data.get("player", actor)),
				"zone": "deck",
			})
	return result


func _presentation_zone_key(endpoint: Dictionary) -> String:
	var zone_name := str(endpoint.get("zone", ""))
	if zone_name.is_empty() or zone_name == "hand":
		return ""
	if zone_name == "stadium":
		return "-1:stadium"
	return "%d:%s" % [int(endpoint.get("player", view_player)), zone_name]


func _apply_presentation_zone_state(key: String) -> void:
	var row: Dictionary = Dictionary(_presentation_zone_states.get(key, {}))
	if row.is_empty():
		return
	var endpoint := _endpoint_from_presentation_zone_key(key)
	if endpoint.is_empty():
		return
	var zone := _zone_view_for_endpoint(endpoint)
	if zone == null:
		return
	var zone_name := str(endpoint.get("zone", ""))
	var player := int(endpoint.get("player", view_player))
	var count_value := maxi(0, int(row.get("count", zone.count)))
	var card_id_value := str(row.get("card_id", zone.card_id))
	if count_value <= 0:
		card_id_value = ""
	zone.configure(
		_zone_title(zone_name),
		card_id_value,
		count_value,
		bool(row.get("hidden", zone.is_hidden_zone)),
		_presentation_zone_context(
			player,
			zone_name,
			card_id_value,
			count_value,
			bool(row.get("hidden", zone.is_hidden_zone)),
		),
	)


func _endpoint_from_presentation_zone_key(key: String) -> Dictionary:
	if key == "-1:stadium":
		return {"player": -1, "zone": "stadium"}
	var parts := key.split(":")
	if parts.size() != 2:
		return {}
	return {"player": int(parts[0]), "zone": str(parts[1])}


func _presentation_zone_context(
	player: int,
	zone_name: String,
	card_id_value: String,
	count_value: int,
	hidden: bool,
) -> Dictionary:
	var visible_ids: Array[String] = []
	if not hidden and not card_id_value.is_empty():
		visible_ids.append(card_id_value)
	return {
		"player": player,
		"zone": zone_name,
		"title": _zone_title(zone_name),
		"card_ids": visible_ids,
		"count": count_value,
		"hidden": hidden,
		"card_id": card_id_value,
	}


func _apply_presentation_zone_event(event: Dictionary) -> void:
	if _presentation_zone_states.is_empty():
		return
	var event_type := str(event.get("event_type", ""))
	var actor := int(event.get("actor", view_player))
	var data: Dictionary = event.get("data", {})
	var source := _event_source_endpoint(event)
	var target := _event_target_endpoint(event)
	match event_type:
		"cards_drawn":
			_adjust_presentation_zone(
				{"player": actor, "zone": "deck"},
				-_event_amount(event, _event_card_ids(event)),
				[],
			)
		"prize_taken":
			_adjust_presentation_zone(
				{"player": actor, "zone": "prizes"},
				-_event_amount(event, _event_card_ids(event)),
				[],
			)
		"cards_discarded":
			_adjust_presentation_zone(
				{"player": actor, "zone": "discard"},
				_event_amount(event, _event_card_ids(event)),
				_event_card_ids(event),
			)
			if str(source.get("zone", "")) != "hand":
				_adjust_presentation_zone(
					source,
					-_event_amount(event, _event_card_ids(event)),
					[],
				)
		"trainer_played":
			_adjust_presentation_zone(
				{"player": actor, "zone": "discard"},
				1,
				_event_card_ids(event),
			)
		"stadium_changed":
			_set_presentation_zone_top(
				{"player": -1, "zone": "stadium"},
				str(event.get("card_id", data.get("card_id", ""))),
				1,
			)
		"card_moved":
			var card_ids := _event_card_ids(event)
			var amount := _event_amount(event, card_ids)
			_adjust_presentation_zone(source, -amount, [])
			_adjust_presentation_zone(target, amount, card_ids)
		"pokemon_ko":
			_adjust_presentation_zone(
				{"player": int(data.get("player", actor)), "zone": "discard"},
				_event_amount(event, _event_card_ids(event)),
				_event_card_ids(event),
			)


func _adjust_presentation_zone(
	endpoint: Dictionary,
	delta: int,
	card_ids: Array,
) -> void:
	var key := _presentation_zone_key(endpoint)
	if key.is_empty() or not _presentation_zone_states.has(key):
		return
	var row: Dictionary = Dictionary(_presentation_zone_states.get(key, {})).duplicate(true)
	var next_count := maxi(0, int(row.get("count", 0)) + delta)
	row["count"] = next_count
	if next_count <= 0:
		row["card_id"] = ""
	elif delta > 0:
		var top_card := _last_card_id(card_ids)
		if not top_card.is_empty():
			row["card_id"] = top_card
	elif delta < 0:
		var current_final := _current_zone_row(endpoint)
		row["card_id"] = str(current_final.get("card_id", row.get("card_id", "")))
	_presentation_zone_states[key] = row
	_apply_presentation_zone_state(key)


func _set_presentation_zone_top(
	endpoint: Dictionary,
	card_id_value: String,
	count_value: int,
) -> void:
	var key := _presentation_zone_key(endpoint)
	if key.is_empty() or not _presentation_zone_states.has(key):
		return
	var row: Dictionary = Dictionary(_presentation_zone_states.get(key, {})).duplicate(true)
	row["count"] = maxi(0, count_value)
	row["card_id"] = "" if int(row["count"]) <= 0 else card_id_value
	_presentation_zone_states[key] = row
	_apply_presentation_zone_state(key)


func _last_card_id(card_ids: Array) -> String:
	for index in range(card_ids.size() - 1, -1, -1):
		var card_id_value := str(card_ids[index])
		if not card_id_value.is_empty():
			return card_id_value
	return ""


func _current_zone_row(endpoint: Dictionary) -> Dictionary:
	var zone_name := str(endpoint.get("zone", ""))
	var player_idx := int(endpoint.get("player", view_player))
	if zone_name == "stadium":
		return {
			"card_id": state_ref.stadium_card_id if state_ref else "",
			"count": 0 if state_ref == null or state_ref.stadium_card_id.is_empty() else 1,
			"hidden": false,
		}
	if state_ref == null or player_idx < 0 or player_idx >= state_ref.players.size():
		return {}
	var player := state_ref.get_player(player_idx)
	match zone_name:
		"discard":
			return {
				"card_id": player.discard[-1] if not player.discard.is_empty() else "",
				"count": player.discard.size(),
				"hidden": false,
			}
		"deck":
			return {
				"card_id": "",
				"count": player.deck.size(),
				"hidden": true,
			}
		"prizes":
			return {
				"card_id": "",
				"count": player.prizes.size(),
				"hidden": true,
			}
	return {}


func _presentation_targets_for_event(event: Dictionary) -> Array[Control]:
	var result: Array[Control] = []
	var event_type := str(event.get("event_type", ""))
	var actor := int(event.get("actor", view_player))
	var source := _event_source_endpoint(event)
	var target := _event_target_endpoint(event)
	var data: Dictionary = event.get("data", {})
	match event_type:
		"cards_drawn":
			source = {"player": actor, "zone": "deck"}
			target = {"player": actor, "zone": "hand"}
			result.append_array(_hand_target_views_for_incoming(event))
		"prize_taken":
			source = {"player": actor, "zone": "prizes"}
			target = {"player": actor, "zone": "hand"}
			result.append_array(_hand_target_views_for_incoming(event))
		"cards_discarded":
			if str(source.get("zone", "")).is_empty():
				source = {"player": actor, "zone": "hand"}
			target = {"player": actor, "zone": "discard"}
		"pokemon_played":
			if _should_mask_slot_result(event):
				_append_unique_control(result, _slot_view_for_endpoint(target))
		"trainer_played", "stadium_changed":
			pass
		"card_moved":
			if not str(target.get("slot", "")).is_empty() or str(target.get("zone", "")) == "hand":
				result.append_array(_target_controls_for_endpoint(target, event))
		"pokemon_ko":
			var player := int(data.get("player", actor))
			var slot_name := str(data.get("slot", "active"))
			_append_unique_control(result, get_slot_view(player, slot_name))
		"retreat", "switched", "promoted":
			for view in _switch_slot_views_for_event(event):
				_append_unique_control(result, view)
	return result


func _presentation_feedback_targets_for_event(event: Dictionary) -> Array[Control]:
	var result: Array[Control] = []
	var event_type := str(event.get("event_type", ""))
	if event_type in ["pokemon_evolved", "energy_attached", "tool_attached"]:
		_append_unique_control(
			result,
			_slot_view_for_endpoint(_event_target_endpoint(event)),
		)
	return result


func _should_mask_slot_result(event: Dictionary) -> bool:
	var target := _event_target_endpoint(event)
	var slot_name := str(target.get("slot", ""))
	if slot_name.is_empty():
		return false
	var player := int(target.get("player", view_player))
	var snapshot_row := _snapshot_slot_row(player, slot_name)
	return snapshot_row.is_empty() or bool(snapshot_row.get("empty", true))


func _event_target_endpoint(event: Dictionary) -> Dictionary:
	var data: Dictionary = event.get("data", {})
	var actor := int(event.get("actor", data.get("player", view_player)))
	var target := Dictionary(event.get("target", {})).duplicate(true)
	if str(target.get("slot", "")).is_empty():
		var slot_name := str(data.get("target_slot", data.get("slot", "")))
		if not slot_name.is_empty():
			target["slot"] = slot_name
	if str(target.get("zone", "")).is_empty():
		var zone_name := str(data.get("target_zone", ""))
		if not zone_name.is_empty():
			target["zone"] = zone_name
	if not target.has("player"):
		target["player"] = int(data.get("target_player", data.get("player", actor)))
	return target


func _event_source_endpoint(event: Dictionary) -> Dictionary:
	var data: Dictionary = event.get("data", {})
	var actor := int(event.get("actor", data.get("player", view_player)))
	var source := Dictionary(event.get("source", {})).duplicate(true)
	if str(source.get("slot", "")).is_empty():
		var slot_name := str(data.get("source_slot", ""))
		if not slot_name.is_empty():
			source["slot"] = slot_name
	if str(source.get("zone", "")).is_empty():
		var zone_name := str(data.get("source_zone", ""))
		if not zone_name.is_empty():
			source["zone"] = zone_name
	if not source.has("player"):
		source["player"] = int(data.get("source_player", data.get("player", actor)))
	if not source.has("index") and data.has("source_index"):
		source["index"] = int(data.get("source_index", -1))
	return source


func _target_controls_for_endpoint(
	endpoint: Dictionary,
	event: Dictionary,
) -> Array[Control]:
	var result: Array[Control] = []
	var zone := str(endpoint.get("zone", ""))
	var player := int(endpoint.get("player", view_player))
	if not str(endpoint.get("slot", "")).is_empty():
		_append_unique_control(result, _slot_view_for_endpoint(endpoint))
	elif zone == "hand":
		if player == view_player:
			result.append_array(_hand_target_views_for_incoming(event))
		else:
			result.append_array(_opponent_hand_target_views_for_incoming(event))
	else:
		_append_unique_control(result, _zone_view_for_endpoint(endpoint))
	return result


func _hand_target_views_for_incoming(event: Dictionary) -> Array[Control]:
	var event_id := str(event.get("event_id", ""))
	if _presentation_event_hand_targets.has(event_id):
		var cached: Array[Control] = []
		for value in _presentation_event_hand_targets[event_id]:
			var view := value as Control
			if view:
				cached.append(view)
		return cached
	var result: Array[Control] = []
	var actor := int(event.get("actor", view_player))
	var card_ids := _event_card_ids(event)
	var amount := _event_amount(event, card_ids)
	if actor != view_player or amount <= 0:
		return result
	result.append_array(_incoming_hand_targets_for_event(event, false))
	return result


func _precompute_hand_targets_for_event(event: Dictionary) -> void:
	var event_type := str(event.get("event_type", ""))
	var target: Dictionary = event.get("target", {})
	var targets_hand := event_type in ["cards_drawn", "prize_taken"]
	if str(target.get("zone", "")) == "hand":
		targets_hand = true
	if not targets_hand:
		return
	var event_id := str(event.get("event_id", ""))
	var actor := int(event.get("actor", view_player))
	var card_ids := _event_card_ids(event)
	var amount := _event_amount(event, card_ids)
	if event_id.is_empty() or actor != view_player or amount <= 0:
		return
	var targets := _incoming_hand_targets_for_event(event, true)
	if targets.is_empty():
		return
	_presentation_event_hand_targets[event_id] = targets


func _record_hand_removals_for_event(event: Dictionary) -> void:
	var source := _event_source_endpoint(event)
	if str(source.get("zone", "")) != "hand":
		return
	var player := int(source.get("player", view_player))
	if player != view_player:
		return
	var target := _event_target_endpoint(event)
	if str(target.get("zone", "")) == "hand":
		return
	var card_ids := _event_card_ids(event)
	if card_ids.is_empty():
		return
	var player_key := str(player)
	var counts: Dictionary = Dictionary(
		_presentation_hand_removed_counts.get(player_key, {})
	)
	for value in card_ids:
		var card_id := str(value)
		if card_id.is_empty():
			continue
		counts[card_id] = int(counts.get(card_id, 0)) + 1
	_presentation_hand_removed_counts[player_key] = counts


func _incoming_hand_targets_for_event(
	event: Dictionary,
	consume_cursor: bool,
) -> Array[Control]:
	var result: Array[Control] = []
	var actor := int(event.get("actor", view_player))
	if actor != view_player:
		return result
	var card_ids := _event_card_ids(event)
	var amount := _event_amount(event, card_ids)
	if amount <= 0:
		return result
	var candidates := _incoming_hand_candidates_from_snapshot()
	if candidates.is_empty():
		return result
	var cursor := clampi(
		int(_presentation_hand_target_cursor.get(actor, 0)),
		0,
		candidates.size(),
	)
	var available: Array[CardView] = []
	for index in range(cursor, candidates.size()):
		available.append(candidates[index])
	var selected := _select_matching_hand_targets(available, card_ids, amount)
	for view in selected:
		result.append(view)
	if consume_cursor:
		_presentation_hand_target_cursor[actor] = cursor + selected.size()
	return result


func _incoming_hand_candidates_from_snapshot() -> Array[CardView]:
	var visible_views: Array[CardView] = []
	for view in hand_views:
		if view and view.visible:
			visible_views.append(view)
	if visible_views.is_empty():
		return []
	var snapshot_hand: Array = _presentation_snapshot.get("hand", [])
	if snapshot_hand.is_empty():
		return visible_views
	var snapshot_counts: Dictionary = {}
	for row_value in snapshot_hand:
		var row: Dictionary = row_value
		var card_id := str(row.get("card_id", ""))
		if card_id.is_empty():
			continue
		snapshot_counts[card_id] = int(snapshot_counts.get(card_id, 0)) + 1
	var removed_counts: Dictionary = Dictionary(
		_presentation_hand_removed_counts.get(str(view_player), {})
	)
	for removed_card_id_value in removed_counts.keys():
		var removed_card_id := str(removed_card_id_value)
		var remaining := (
			int(snapshot_counts.get(removed_card_id, 0))
			- int(removed_counts.get(removed_card_id, 0))
		)
		if remaining > 0:
			snapshot_counts[removed_card_id] = remaining
		else:
			snapshot_counts.erase(removed_card_id)
	var candidates: Array[CardView] = []
	for view in visible_views:
		var card_id := str(view.card_id)
		var remaining := int(snapshot_counts.get(card_id, 0))
		if not card_id.is_empty() and remaining > 0:
			snapshot_counts[card_id] = remaining - 1
		else:
			candidates.append(view)
	return candidates


func _select_matching_hand_targets(
	candidates: Array[CardView],
	card_ids: Array,
	amount: int,
) -> Array[CardView]:
	var selected: Array[CardView] = []
	if candidates.is_empty() or amount <= 0:
		return selected
	var used: Array[bool] = []
	for _candidate in candidates:
		used.append(false)
	for value in card_ids:
		if selected.size() >= amount:
			break
		var card_id := str(value)
		if card_id.is_empty():
			continue
		for index in range(candidates.size()):
			if used[index] or candidates[index].card_id != card_id:
				continue
			used[index] = true
			selected.append(candidates[index])
			break
	for index in range(candidates.size()):
		if selected.size() >= amount:
			break
		if used[index]:
			continue
		used[index] = true
		selected.append(candidates[index])
	return selected


func _opponent_hand_target_views_for_incoming(event: Dictionary) -> Array[Control]:
	var result: Array[Control] = []
	var actor := int(event.get("actor", view_player))
	if actor == view_player:
		return result
	var card_ids := _event_card_ids(event)
	var amount := _event_amount(event, card_ids)
	if amount <= 0:
		return result
	var visible_views: Array[CardView] = []
	for view in opponent_hand_views:
		if view and view.visible:
			visible_views.append(view)
	var first := maxi(0, visible_views.size() - mini(amount, visible_views.size()))
	for index in range(first, visible_views.size()):
		result.append(visible_views[index])
	return result


func _switch_slot_views_for_event(event: Dictionary) -> Array[Control]:
	var result: Array[Control] = []
	var data: Dictionary = event.get("data", {})
	var actor := int(event.get("actor", data.get("player", view_player)))
	var player := int(data.get("player", actor))
	var event_type := str(event.get("event_type", ""))
	var bench_slot := _bench_slot_from_event(event)
	if event_type == "promoted":
		_append_unique_control(result, get_slot_view(player, "active"))
		if not bench_slot.is_empty():
			_append_unique_control(result, get_slot_view(player, bench_slot))
	else:
		_append_unique_control(result, get_slot_view(player, "active"))
		if not bench_slot.is_empty():
			_append_unique_control(result, get_slot_view(player, bench_slot))
	return result


func _mask_presentation_node(node: Control) -> void:
	if node == null or not is_instance_valid(node):
		return
	var instance_id := node.get_instance_id()
	_presentation_mask_counts[instance_id] = (
		int(_presentation_mask_counts.get(instance_id, 0)) + 1
	)
	if node is CardView:
		(node as CardView).set_presentation_hidden(true)
	elif node is ZoneView:
		(node as ZoneView).set_presentation_hidden(true)
	else:
		node.modulate.a = 0.0


func _reveal_presentation_node(node: Control, force: bool = false) -> void:
	if node == null or not is_instance_valid(node):
		return
	var instance_id := node.get_instance_id()
	if not force:
		var count := int(_presentation_mask_counts.get(instance_id, 0)) - 1
		if count > 0:
			_presentation_mask_counts[instance_id] = count
			return
	_presentation_mask_counts.erase(instance_id)
	if node is CardView:
		(node as CardView).reveal_presentation(0.14)
		(node as CardView).flash(DesignTokens.GOLD, 0.22)
	elif node is ZoneView:
		(node as ZoneView).reveal_presentation(0.14)
	else:
		node.modulate.a = 1.0


func _stage_presentation_cover(event: Dictionary) -> void:
	var event_type := str(event.get("event_type", ""))
	if event_type not in ["pokemon_evolved", "energy_attached", "tool_attached"]:
		return
	var event_id := str(event.get("event_id", ""))
	if event_id.is_empty() or effects == null:
		return
	var target := _event_target_endpoint(event)
	var slot_name := str(target.get("slot", ""))
	if slot_name.is_empty():
		return
	var player := int(target.get("player", view_player))
	var view := get_slot_view(player, slot_name)
	if view == null or not is_instance_valid(view) or not view.visible:
		return
	var snapshot_row := _snapshot_slot_row(player, slot_name)
	if snapshot_row.is_empty() or bool(snapshot_row.get("empty", false)):
		return
	var old_card_id := str(snapshot_row.get("card_id", ""))
	if old_card_id.is_empty() or bool(snapshot_row.get("hidden", false)):
		return
	var cover := _spawn_presentation_cover(old_card_id, view)
	if cover == null:
		return
	var covers: Array[Control] = []
	if _presentation_covers.has(event_id):
		for value in _presentation_covers[event_id]:
			var existing := _valid_control(value)
			if existing:
				covers.append(existing)
	covers.append(cover)
	_presentation_covers[event_id] = covers


func _spawn_presentation_cover(card_id_value: String, target_view: CardView) -> Control:
	var texture := _texture_for_card_id(card_id_value)
	if texture == null:
		texture = _texture_for_card_id("")
	if texture == null or effects == null:
		return null
	var cover := _create_paper_card_token(
		texture,
		target_view.size,
		"PresentationCover",
		96,
		0.68,
	)
	cover.size = target_view.size
	cover.position = _effects_local(target_view.global_center()) - cover.size * 0.5
	cover.pivot_offset = cover.size * 0.5
	effects.add_child(cover)
	return cover


func _finish_presentation_covers(event_id: String) -> bool:
	var covers: Array = _presentation_covers.get(event_id, [])
	_presentation_covers.erase(event_id)
	if covers.is_empty():
		_clear_effect_child_controls(["PresentationCover"])
		return false
	var had_cover := false
	for cover_value in covers:
		var cover := _valid_control(cover_value)
		if cover == null:
			continue
		had_cover = true
		_dispose_presentation_cover(cover)
	_clear_effect_child_controls(["PresentationCover"])
	return had_cover


func _dispose_presentation_cover(cover: Control) -> void:
	if cover == null or not is_instance_valid(cover):
		return
	_presentation_cover_tweens.erase(cover.get_instance_id())
	cover.visible = false
	cover.modulate.a = 0.0
	cover.queue_free()


func _clear_presentation_covers() -> void:
	for tween_value in _presentation_cover_tweens.values():
		var tween := tween_value as Tween
		if tween and tween.is_valid():
			tween.kill()
	_presentation_cover_tweens.clear()
	for covers in _presentation_covers.values():
		for cover_value in covers:
			var cover := _valid_control(cover_value)
			_dispose_presentation_cover(cover)
	_presentation_covers.clear()
	_clear_effect_child_controls(["PresentationCover"])


func _flash_presentation_feedbacks(event_id: String) -> void:
	var nodes: Array = _presentation_feedbacks.get(event_id, [])
	_presentation_feedbacks.erase(event_id)
	for node_value in nodes:
		var view := _valid_card_view(node_value)
		if view == null:
			continue
		view.flash(DesignTokens.GOLD, 0.22)


func _on_presentation_event_finished(event: Dictionary) -> void:
	var event_id := str(event.get("event_id", ""))
	_apply_presentation_zone_event(event)
	var nodes: Array = _presentation_reveals.get(event_id, [])
	for node_value in nodes:
		_reveal_presentation_node(_valid_control(node_value))
	_presentation_reveals.erase(event_id)
	_finish_presentation_covers(event_id)
	_clear_active_flyers()
	_flash_presentation_feedbacks(event_id)


func _clear_presentation_masks(reveal: bool) -> void:
	if reveal:
		_clear_all_presentation_nodes()
	_presentation_reveals.clear()
	_presentation_mask_counts.clear()
	_clear_presentation_covers()
	_presentation_feedbacks.clear()
	_presentation_event_hand_targets.clear()
	_presentation_hand_target_cursor.clear()
	_presentation_hand_removed_counts.clear()
	_presentation_zone_states.clear()
	if state_ref != null:
		_refresh_field()


func _clear_all_presentation_nodes() -> void:
	var seen: Dictionary = {}
	for view in hand_views:
		_clear_presentation_control(view, seen)
	for view in opponent_hand_views:
		_clear_presentation_control(view, seen)
	for view_value in slot_views.values():
		_clear_presentation_control(_valid_control(view_value), seen)
	for zone_value in zones.values():
		_clear_presentation_control(_valid_control(zone_value), seen)


func _clear_presentation_control(node: Control, seen: Dictionary) -> void:
	if node == null or not is_instance_valid(node):
		return
	var instance_id := node.get_instance_id()
	if seen.has(instance_id):
		return
	seen[instance_id] = true
	if node is CardView:
		(node as CardView).clear_presentation_state()
	elif node is ZoneView:
		(node as ZoneView).clear_presentation_state()
	else:
		node.modulate.a = 1.0


func _valid_control(value: Variant) -> Control:
	if not is_instance_valid(value):
		return null
	return value as Control


func _valid_card_view(value: Variant) -> CardView:
	if not is_instance_valid(value):
		return null
	return value as CardView


func _on_card_motion_requested(event: Dictionary, duration: float) -> void:
	var data: Dictionary = event.get("data", {})
	var source := _event_source_endpoint(event)
	var target := _event_target_endpoint(event)
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
		if str(source.get("zone", "")).is_empty():
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
	elif event_type == "deck_shuffled":
		source = {
			"player": int(data.get("player", actor)),
			"zone": "deck",
		}
		target = source.duplicate(true)
	if AppSettings.reduced_motion:
		effects.burst(resolve_endpoint_center(target), _motion_landing_color(event_type), "card_move")
		return
	if event_type == "deck_shuffled":
		_spawn_shuffle_motion(source, duration)
		return
	if _spawn_slot_transition(event, duration):
		return
	var base_start := resolve_endpoint_center(source)
	var base_finish := resolve_endpoint_center(target)
	var base_size := _flying_card_size(event_type)
	var starts := _source_points_for_event(
		source,
		card_ids,
		visible_count,
		base_start,
	)
	var finishes := _target_points_for_event(
		target,
		card_ids,
		visible_count,
		base_finish,
		event,
	)
	var start_sizes := _source_sizes_for_event(
		source,
		card_ids,
		visible_count,
		base_size,
	)
	var finish_sizes := _target_sizes_for_event(
		target,
		visible_count,
		base_size,
		event,
	)
	var start_rotations := _source_rotations_for_event(
		source,
		card_ids,
		visible_count,
		0.0,
	)
	var finish_rotations := _target_rotations_for_event(
		target,
		visible_count,
		0.0,
		event,
	)
	for index in range(visible_count):
		var card_id := str(card_ids[index]) if index < card_ids.size() else event_card_id
		var texture := _texture_for_card_id(
			"" if _motion_card_hidden_from_view(card_id, source, target) else card_id
		)
		if texture == null:
			continue
		var start := starts[index] if index < starts.size() else base_start
		var finish := finishes[index] if index < finishes.size() else base_finish
		var timing := _flying_card_timing(index, visible_count, duration)
		if not bool(timing.get("spawn", false)):
			_landing_burst(finish, event_type)
			continue
		_spawn_flying_card(
			texture,
			start,
			finish,
			float(timing.get("duration", 0.0)),
			float(timing.get("delay", 0.0)),
			event_type,
			index,
			start_sizes[index] if index < start_sizes.size() else base_size,
			finish_sizes[index] if index < finish_sizes.size() else base_size,
			start_rotations[index] if index < start_rotations.size() else 0.0,
			finish_rotations[index] if index < finish_rotations.size() else 0.0,
		)


func _event_card_ids(event: Dictionary) -> Array:
	var data: Dictionary = event.get("data", {})
	var raw_cards: Array = []
	var raw_value: Variant = data.get("card_ids", data.get("cards", []))
	if raw_value is Array:
		raw_cards = raw_value
	var result: Array = []
	for value in raw_cards:
		var card_id := str(value)
		if not card_id.is_empty():
			result.append(card_id)
	var event_card_id := str(event.get("card_id", data.get("card_id", "")))
	if result.is_empty() and not event_card_id.is_empty():
		result.append(event_card_id)
	return result


func _event_amount(event: Dictionary, card_ids: Array) -> int:
	var data: Dictionary = event.get("data", {})
	return maxi(1, int(event.get(
		"amount",
		data.get("count", card_ids.size()),
	)))


func _append_unique_control(result: Array[Control], node: Control) -> void:
	if node == null or not is_instance_valid(node):
		return
	if result.has(node):
		return
	result.append(node)


func _slot_view_for_endpoint(endpoint: Dictionary) -> CardView:
	var slot_name := str(endpoint.get("slot", ""))
	if slot_name.is_empty():
		return null
	return get_slot_view(int(endpoint.get("player", view_player)), slot_name)


func _zone_view_for_endpoint(endpoint: Dictionary) -> ZoneView:
	var zone_name := str(endpoint.get("zone", ""))
	if zone_name.is_empty():
		return null
	if zone_name == "stadium":
		return zones.get("stadium") as ZoneView
	var player := int(endpoint.get("player", view_player))
	var prefix := "own" if player == view_player else "opponent"
	return zones.get("%s_%s" % [prefix, zone_name]) as ZoneView


func _logical_zone_key(scene_zone_key: String) -> String:
	match scene_zone_key:
		"own_deck":
			return "%d:deck" % view_player
		"own_discard":
			return "%d:discard" % view_player
		"own_prizes":
			return "%d:prizes" % view_player
		"opponent_deck":
			return "%d:deck" % (1 - view_player)
		"opponent_discard":
			return "%d:discard" % (1 - view_player)
		"opponent_prizes":
			return "%d:prizes" % (1 - view_player)
		"stadium":
			return "-1:stadium"
	return scene_zone_key


func _source_points_for_event(
	source: Dictionary,
	card_ids: Array,
	visible_count: int,
	fallback_start: Vector2,
) -> Array[Vector2]:
	var player := int(source.get("player", view_player))
	var zone_name := str(source.get("zone", ""))
	var source_index := int(source.get("index", -1))
	if (
		zone_name == "hand"
		and player == view_player
		and int(_presentation_snapshot.get("view_player", view_player)) == view_player
	):
		return _hand_start_points_from_snapshot(
			card_ids,
			visible_count,
			fallback_start,
			source_index,
		)
	if zone_name == "hand" and player != view_player:
		return _opponent_hand_points(visible_count, fallback_start)
	var start := _snapshot_endpoint_center(source, fallback_start)
	var result: Array[Vector2] = []
	for index in range(visible_count):
		result.append(start + _zone_motion_offset(
			source,
			index,
			visible_count,
			true,
		))
	return result


func _target_points_for_event(
	target: Dictionary,
	_card_ids: Array,
	visible_count: int,
	fallback_finish: Vector2,
	event: Dictionary,
) -> Array[Vector2]:
	var zone_name := str(target.get("zone", ""))
	var player := int(target.get("player", view_player))
	var result: Array[Vector2] = []
	if zone_name == "hand" and player == view_player:
		for view_value in _hand_target_views_for_incoming(event):
			var view := view_value as CardView
			if view:
				result.append(_effects_local(view.global_center()))
		if result.size() >= visible_count:
			return result
	elif zone_name == "hand" and player != view_player:
		for view_value in _opponent_hand_target_views_for_incoming(event):
			var view := view_value as CardView
			if view:
				result.append(_effects_local(view.global_center()))
		if result.size() >= visible_count:
			return result
	for index in range(visible_count):
		var offset := _stack_offset(index, visible_count, zone_name == "hand")
		if not zone_name.is_empty() and zone_name != "hand":
			offset = _zone_motion_offset(target, index, visible_count, false)
		result.append(fallback_finish + offset)
	return result


func _source_sizes_for_event(
	source: Dictionary,
	card_ids: Array,
	visible_count: int,
	fallback_size: Vector2,
) -> Array[Vector2]:
	var player := int(source.get("player", view_player))
	var zone_name := str(source.get("zone", ""))
	var source_index := int(source.get("index", -1))
	var result: Array[Vector2] = []
	if (
		zone_name == "hand"
		and player == view_player
		and int(_presentation_snapshot.get("view_player", view_player)) == view_player
	):
		for row in _hand_motion_rows_from_snapshot(
			card_ids,
			visible_count,
			Vector2.ZERO,
			fallback_size,
			source_index,
		):
			result.append(_vector_or_default(row.get("size"), fallback_size))
		return result
	var size_value := _snapshot_endpoint_size(
		source,
		_current_endpoint_size(source, fallback_size),
	)
	for _index in range(visible_count):
		result.append(size_value)
	return result


func _target_sizes_for_event(
	target: Dictionary,
	visible_count: int,
	fallback_size: Vector2,
	event: Dictionary,
) -> Array[Vector2]:
	var zone_name := str(target.get("zone", ""))
	var player := int(target.get("player", view_player))
	var result: Array[Vector2] = []
	if zone_name == "hand" and player == view_player:
		for view_value in _hand_target_views_for_incoming(event):
			var view := view_value as CardView
			if view:
				result.append(view.size)
		if result.size() >= visible_count:
			return result
	elif zone_name == "hand" and player != view_player:
		for view_value in _opponent_hand_target_views_for_incoming(event):
			var view := view_value as CardView
			if view:
				result.append(view.size)
		if result.size() >= visible_count:
			return result
	var size_value := _current_endpoint_size(target, fallback_size)
	while result.size() < visible_count:
		result.append(size_value)
	return result


func _source_rotations_for_event(
	source: Dictionary,
	card_ids: Array,
	visible_count: int,
	fallback_rotation: float,
) -> Array[float]:
	var player := int(source.get("player", view_player))
	var zone_name := str(source.get("zone", ""))
	var source_index := int(source.get("index", -1))
	var result: Array[float] = []
	if (
		zone_name == "hand"
		and player == view_player
		and int(_presentation_snapshot.get("view_player", view_player)) == view_player
	):
		for row in _hand_motion_rows_from_snapshot(
			card_ids,
			visible_count,
			Vector2.ZERO,
			Vector2.ZERO,
			source_index,
		):
			result.append(float(row.get("rotation_degrees", fallback_rotation)))
		return result
	var rotation := _snapshot_endpoint_rotation(
		source,
		_current_endpoint_rotation(source, fallback_rotation),
	)
	for _index in range(visible_count):
		result.append(rotation)
	return result


func _target_rotations_for_event(
	target: Dictionary,
	visible_count: int,
	fallback_rotation: float,
	event: Dictionary,
) -> Array[float]:
	var zone_name := str(target.get("zone", ""))
	var player := int(target.get("player", view_player))
	var result: Array[float] = []
	if zone_name == "hand" and player == view_player:
		for view_value in _hand_target_views_for_incoming(event):
			var view := view_value as CardView
			if view:
				result.append(view.rotation_degrees)
		if result.size() >= visible_count:
			return result
	elif zone_name == "hand" and player != view_player:
		for view_value in _opponent_hand_target_views_for_incoming(event):
			var view := view_value as CardView
			if view:
				result.append(view.rotation_degrees)
		if result.size() >= visible_count:
			return result
	var rotation := _current_endpoint_rotation(target, fallback_rotation)
	while result.size() < visible_count:
		result.append(rotation)
	return result


func _hand_start_points_from_snapshot(
	card_ids: Array,
	visible_count: int,
	fallback_start: Vector2,
	source_index: int = -1,
) -> Array[Vector2]:
	var rows := _hand_motion_rows_from_snapshot(
		card_ids,
		visible_count,
		fallback_start,
		hand_card_size,
		source_index,
	)
	var result: Array[Vector2] = []
	for row in rows:
		result.append(_vector_or_default(row.get("center"), fallback_start))
	return result


func _hand_motion_rows_from_snapshot(
	card_ids: Array,
	visible_count: int,
	fallback_start: Vector2,
	fallback_size: Vector2,
	source_index: int = -1,
) -> Array[Dictionary]:
	var snapshot_hand: Array = _presentation_snapshot.get("hand", [])
	var result: Array[Dictionary] = []
	if snapshot_hand.is_empty():
		for _index in range(visible_count):
			result.append({
				"center": fallback_start,
				"size": fallback_size,
				"rotation_degrees": 0.0,
			})
		return result
	var used: Array[bool] = []
	for _row in snapshot_hand:
		used.append(false)
	var requested_ids: Array[String] = []
	var has_identity := false
	for value in card_ids:
		var card_id := str(value)
		requested_ids.append(card_id)
		if not card_id.is_empty():
			has_identity = true
	for index in range(visible_count):
		var target_id := requested_ids[index] if index < requested_ids.size() else ""
		var start := fallback_start
		var size_value := fallback_size
		var rotation := 0.0
		var preferred_index := source_index + index if source_index >= 0 else -1
		if preferred_index >= 0 and preferred_index < snapshot_hand.size():
			var preferred: Dictionary = snapshot_hand[preferred_index]
			if (
				not used[preferred_index]
				and (
					target_id.is_empty()
					or str(preferred.get("card_id", "")) == target_id
				)
			):
				used[preferred_index] = true
				start = _vector_or_default(preferred.get("center"), fallback_start)
				size_value = _vector_or_default(preferred.get("size"), fallback_size)
				rotation = float(preferred.get("rotation_degrees", 0.0))
		if start == fallback_start and has_identity and not target_id.is_empty():
			for hand_index in range(snapshot_hand.size()):
				var row: Dictionary = snapshot_hand[hand_index]
				if used[hand_index] or str(row.get("card_id", "")) != target_id:
					continue
				used[hand_index] = true
				start = _vector_or_default(row.get("center"), fallback_start)
				size_value = _vector_or_default(row.get("size"), fallback_size)
				rotation = float(row.get("rotation_degrees", 0.0))
				break
		result.append({
			"center": start,
			"size": size_value,
			"rotation_degrees": rotation,
		})
	return result


func _snapshot_endpoint_center(endpoint: Dictionary, fallback: Vector2) -> Vector2:
	var player := int(endpoint.get("player", view_player))
	var slot_name := str(endpoint.get("slot", ""))
	if not slot_name.is_empty():
		var slot_row := _snapshot_slot_row(player, slot_name)
		if not slot_row.is_empty():
			return _vector_or_default(slot_row.get("center"), fallback)
	var zone_name := str(endpoint.get("zone", ""))
	if not zone_name.is_empty():
		if zone_name == "hand":
			return (
				_snapshot_own_hand_center(fallback)
				if player == view_player
				else _vector_or_default(
					_presentation_snapshot.get("opponent_hand_center"),
					fallback,
				)
			)
		var zone_row := _snapshot_zone_row(player, zone_name)
		if not zone_row.is_empty():
			return _vector_or_default(zone_row.get("center"), fallback)
	return fallback


func _snapshot_endpoint_size(endpoint: Dictionary, fallback: Vector2) -> Vector2:
	var player := int(endpoint.get("player", view_player))
	var slot_name := str(endpoint.get("slot", ""))
	if not slot_name.is_empty():
		var slot_row := _snapshot_slot_row(player, slot_name)
		if not slot_row.is_empty():
			return _vector_or_default(slot_row.get("size"), fallback)
	var zone_name := str(endpoint.get("zone", ""))
	if not zone_name.is_empty():
		var zone_row := _snapshot_zone_row(player, zone_name)
		if not zone_row.is_empty():
			return _vector_or_default(zone_row.get("size"), fallback)
	return fallback


func _snapshot_endpoint_rotation(endpoint: Dictionary, fallback: float) -> float:
	var player := int(endpoint.get("player", view_player))
	var slot_name := str(endpoint.get("slot", ""))
	if not slot_name.is_empty():
		var slot_row := _snapshot_slot_row(player, slot_name)
		if not slot_row.is_empty():
			return float(slot_row.get("rotation_degrees", fallback))
	var zone_name := str(endpoint.get("zone", ""))
	if not zone_name.is_empty():
		var zone_row := _snapshot_zone_row(player, zone_name)
		if not zone_row.is_empty():
			return float(zone_row.get("rotation_degrees", fallback))
	return fallback


func _current_endpoint_size(endpoint: Dictionary, fallback: Vector2) -> Vector2:
	var slot_name := str(endpoint.get("slot", ""))
	if not slot_name.is_empty():
		var view := _slot_view_for_endpoint(endpoint)
		if view:
			return view.size
	var zone_name := str(endpoint.get("zone", ""))
	if not zone_name.is_empty():
		if zone_name == "hand":
			return (
				hand_card_size
				if int(endpoint.get("player", view_player)) == view_player
				else opponent_hand_card_size
			)
		var zone := _zone_view_for_endpoint(endpoint)
		if zone:
			return zone.size
	return fallback


func _current_endpoint_rotation(endpoint: Dictionary, fallback: float) -> float:
	var slot_name := str(endpoint.get("slot", ""))
	if not slot_name.is_empty():
		var view := _slot_view_for_endpoint(endpoint)
		if view:
			return view.rotation_degrees
	var zone_name := str(endpoint.get("zone", ""))
	if not zone_name.is_empty() and zone_name != "hand":
		var zone := _zone_view_for_endpoint(endpoint)
		if zone:
			return zone.rotation_degrees
	return fallback


func _snapshot_slot_row(player: int, slot_name: String) -> Dictionary:
	var slots: Dictionary = _presentation_snapshot.get("slots", {})
	return Dictionary(slots.get("%d:%s" % [player, slot_name], {}))


func _snapshot_zone_row(player: int, zone_name: String) -> Dictionary:
	var zones_snapshot: Dictionary = _presentation_snapshot.get("zones", {})
	var key := "-1:stadium" if zone_name == "stadium" else "%d:%s" % [
		player,
		zone_name,
	]
	return Dictionary(zones_snapshot.get(key, {}))


func _vector_or_default(value: Variant, fallback: Vector2) -> Vector2:
	if value is Vector2:
		return value
	return fallback


func _snapshot_own_hand_center(fallback: Vector2) -> Vector2:
	var snapshot_hand: Array = _presentation_snapshot.get("hand", [])
	if snapshot_hand.is_empty():
		return fallback
	var total := Vector2.ZERO
	var count_value := 0
	for row_value in snapshot_hand:
		var row: Dictionary = row_value
		total += _vector_or_default(row.get("center"), fallback)
		count_value += 1
	return total / float(maxi(1, count_value))


func _opponent_hand_points(
	visible_count: int,
	fallback_start: Vector2,
) -> Array[Vector2]:
	var result: Array[Vector2] = []
	var visible_views: Array[CardView] = []
	for view in opponent_hand_views:
		if view and view.visible:
			visible_views.append(view)
	if not visible_views.is_empty():
		var first := maxi(
			0,
			visible_views.size() - mini(visible_count, visible_views.size()),
		)
		for index in range(first, visible_views.size()):
			result.append(_effects_local(visible_views[index].global_center()))
	while result.size() < visible_count:
		result.append(fallback_start + _stack_offset(
			result.size(),
			visible_count,
			true,
		))
	return result


func _stack_offset(index: int, visible_count: int, hand_target: bool) -> Vector2:
	if hand_target:
		return Vector2(
			(float(index) - float(visible_count - 1) * 0.5) * 34.0,
			18.0,
		)
	return Vector2(
		(float(index) - float(visible_count - 1) * 0.5) * 7.0,
		-float(index) * 3.0,
	)


func _zone_motion_offset(
	endpoint: Dictionary,
	index: int,
	visible_count: int,
	leaving_stack: bool,
) -> Vector2:
	var zone_name := str(endpoint.get("zone", ""))
	if zone_name.is_empty() or zone_name == "hand":
		return _stack_offset(index, visible_count, zone_name == "hand")
	var zone := _zone_view_for_endpoint(endpoint)
	var direction := "up"
	var depth := 0.55
	if zone:
		direction = zone.stack_visual_direction
		depth = zone.table_depth
	var step := _stack_visual_step(direction, depth)
	var clamped_index := clampi(index, 0, maxi(0, visible_count - 1))
	var stack_bias := step * float(mini(clamped_index + 1, 4))
	if not leaving_stack:
		stack_bias *= 0.36 if zone_name == "discard" else 0.55
	var axis := Vector2(-step.y, step.x)
	if axis.length_squared() <= 0.0001:
		axis = Vector2.RIGHT
	else:
		axis = axis.normalized()
	var spread := 5.0 if leaving_stack else 7.0
	if zone_name == "discard" and not leaving_stack:
		spread = 12.0
	var fan := axis * (
		(float(clamped_index) - float(visible_count - 1) * 0.5) * spread
	)
	return stack_bias + fan


func _stack_visual_step(direction: String, depth: float) -> Vector2:
	var depth_scale := 0.75 + clampf(depth, 0.0, 1.0) * 0.55
	match direction:
		"down":
			return Vector2(3.6, 3.2) * depth_scale
		"left":
			return Vector2(-3.6, 2.4) * depth_scale
		"right":
			return Vector2(3.6, 2.4) * depth_scale
	return Vector2(3.6, -3.2) * depth_scale


func _texture_for_card_id(card_id: String) -> Texture2D:
	var texture_path := "res://assets/cards/card_back.webp"
	if not card_id.is_empty():
		texture_path = str(CardDatabase.get_card(card_id).get("image_path", ""))
		if texture_path.is_empty():
			texture_path = "res://assets/cards/card_back.webp"
	var texture := CardTextureCache.get_texture(texture_path)
	if texture == null and texture_path != "res://assets/cards/card_back.webp":
		texture = CardTextureCache.get_texture("res://assets/cards/card_back.webp")
	return texture


func _motion_card_hidden_from_view(
	card_id: String,
	source: Dictionary,
	target: Dictionary,
) -> bool:
	if card_id.is_empty():
		return true
	return _endpoint_hidden_from_view(source) or _endpoint_hidden_from_view(target)


func _endpoint_hidden_from_view(endpoint: Dictionary) -> bool:
	var zone_name := str(endpoint.get("zone", ""))
	if not (zone_name in ["hand", "deck", "prizes"]):
		return false
	return int(endpoint.get("player", view_player)) != view_player


func _spawn_slot_transition(event: Dictionary, duration: float) -> bool:
	var event_type := str(event.get("event_type", ""))
	if event_type not in ["retreat", "switched", "promoted"]:
		return false
	var data: Dictionary = event.get("data", {})
	var actor := int(event.get("actor", data.get("player", view_player)))
	var player := int(data.get("player", actor))
	var bench_slot := _bench_slot_from_event(event)
	if bench_slot.is_empty():
		return false
	var movements: Array[Dictionary] = []
	if event_type == "promoted":
		movements.append({
			"from": bench_slot,
			"to": "active",
		})
	else:
		movements.append({
			"from": "active",
			"to": bench_slot,
		})
		movements.append({
			"from": bench_slot,
			"to": "active",
		})
	var spawned := false
	var index := 0
	for movement in movements:
		var from_slot := str(movement["from"])
		var to_slot := str(movement["to"])
		var snapshot_row := _snapshot_slot_row(player, from_slot)
		var card_id := str(snapshot_row.get("card_id", ""))
		if card_id.is_empty():
			continue
		var finish_view := get_slot_view(player, to_slot)
		if finish_view == null:
			continue
		var finish := _effects_local(finish_view.global_center())
		var start_size := _vector_or_default(
			snapshot_row.get("size"),
			finish_view.size,
		)
		var start_rotation := float(snapshot_row.get("rotation_degrees", 0.0))
		var timing := _flying_card_timing(index, movements.size(), duration, false)
		if not bool(timing.get("spawn", false)):
			_landing_burst(finish, event_type)
			spawned = true
			index += 1
			continue
		var texture := _texture_for_card_id(card_id)
		if texture == null:
			continue
		_spawn_flying_card(
			texture,
			_vector_or_default(
				snapshot_row.get("center"),
				resolve_endpoint_center({"player": player, "slot": from_slot}),
			),
			finish,
			float(timing.get("duration", 0.0)),
			float(timing.get("delay", 0.0)),
			event_type,
			index,
			start_size,
			finish_view.size,
			start_rotation,
			finish_view.rotation_degrees,
		)
		spawned = true
		index += 1
	return spawned


func _bench_slot_from_event(event: Dictionary) -> String:
	var data: Dictionary = event.get("data", {})
	if data.has("bench_idx"):
		return "bench_%d" % int(data.get("bench_idx", 0))
	for value in [
		data.get("slot", ""),
		data.get("target_slot", ""),
		event.get("target", {}).get("slot", ""),
		event.get("source", {}).get("slot", ""),
	]:
		var slot_name := str(value)
		if slot_name.begins_with("bench"):
			return slot_name
	return ""


func _discard_hand_start_points(
	card_ids: Array,
	visible_count: int,
	fallback_start: Vector2,
) -> Array[Vector2]:
	var result: Array[Vector2] = []
	var requested_ids: Array[String] = []
	var has_identity := false
	for value in card_ids:
		var card_id := str(value)
		requested_ids.append(card_id)
		if not card_id.is_empty():
			has_identity = true
	if not has_identity:
		for _index in range(visible_count):
			result.append(fallback_start)
		return result
	var used: Array[bool] = []
	for _view in hand_views:
		used.append(false)
	for index in range(visible_count):
		var target_id := (
			requested_ids[index] if index < requested_ids.size() else ""
		)
		var start := fallback_start
		if not target_id.is_empty():
			for hand_index in range(hand_views.size()):
				var view := hand_views[hand_index] as CardView
				if (
					used[hand_index]
					or view == null
					or not view.visible
					or view.card_id != target_id
				):
					continue
				used[hand_index] = true
				start = _effects_local(view.global_center())
				break
		result.append(start)
	return result


func _flying_card_timing(
	index: int,
	total_count: int,
	event_duration: float,
	stagger: bool = true,
) -> Dictionary:
	var playable_duration := maxf(0.0, event_duration - FLYING_CARD_FINISH_PAD)
	if playable_duration < MIN_FLYING_CARD_DURATION:
		return {"spawn": false, "delay": 0.0, "duration": 0.0}
	var count := maxi(1, total_count)
	var clamped_index := clampi(index, 0, count - 1)
	var max_delay := minf(
		playable_duration * 0.35,
		motion_stagger_delay * float(maxi(0, count - 1)),
	)
	var delay_step := 0.0
	if stagger and count > 1:
		delay_step = minf(
			motion_stagger_delay,
			max_delay / float(count - 1),
		)
	var delay := float(clamped_index) * delay_step
	var flight_duration := playable_duration - delay
	if flight_duration < MIN_FLYING_CARD_DURATION:
		return {"spawn": false, "delay": 0.0, "duration": 0.0}
	return {"spawn": true, "delay": delay, "duration": flight_duration}


func _landing_burst(finish: Vector2, event_type: String) -> void:
	if effects:
		effects.burst(finish, _motion_landing_color(event_type), "card_land")


func _motion_landing_color(event_type: String) -> Color:
	return (
		DesignTokens.GOLD
		if event_type in ["cards_drawn", "prize_taken"]
		else DesignTokens.CYAN
	)


func _create_paper_card_token(
	texture: Texture2D,
	size_value: Vector2,
	transient_kind: String,
	z_value: int,
	depth: float = 0.55,
) -> Control:
	var card := Control.new()
	card.name = transient_kind
	card.set_meta("battle_transient_visual", true)
	card.set_meta("battle_transient_kind", transient_kind)
	card.set_meta("paper_card_token", true)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.size = size_value
	card.custom_minimum_size = size_value
	card.pivot_offset = size_value * 0.5
	card.z_index = z_value

	var shadow := Panel.new()
	shadow.name = "PaperShadow"
	shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shadow.position = Vector2(1.0 + depth * 2.0, 5.0 + depth * 5.0)
	shadow.size = size_value
	shadow.add_theme_stylebox_override(
		"panel",
		DesignTokens.shadow_style(int(8.0 + depth * 7.0)),
	)
	card.add_child(shadow)

	var thickness := 2.0 + depth * 2.4
	var edge := Panel.new()
	edge.name = "PaperEdge"
	edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	edge.position = Vector2(thickness * 0.62, thickness)
	edge.size = size_value
	edge.add_theme_stylebox_override(
		"panel",
		DesignTokens.panel_style(
			Color("#d8dde4"),
			8,
			Color(0.60, 0.64, 0.70, 0.48),
			1,
			0,
		),
	)
	card.add_child(edge)

	var face := Panel.new()
	face.name = "PaperFace"
	face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	face.size = size_value
	face.add_theme_stylebox_override(
		"panel",
		DesignTokens.panel_style(
			Color("#eef1f5"),
			8,
			Color(0.20, 0.25, 0.32, 0.58),
			1,
			0,
		),
	)
	card.add_child(face)

	var inset := maxf(2.0, minf(size_value.x, size_value.y) * 0.032)
	var image := TextureRect.new()
	image.name = "PaperImage"
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	image.texture = texture
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	image.position = Vector2(inset, inset)
	image.size = Vector2(
		maxf(1.0, size_value.x - inset * 2.0),
		maxf(1.0, size_value.y - inset * 2.0),
	)
	image.z_index = 2
	card.add_child(image)

	var gloss := ColorRect.new()
	gloss.name = "PaperGloss"
	gloss.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gloss.color = Color(1.0, 1.0, 1.0, 0.10)
	gloss.position = Vector2(inset * 1.5, inset * 1.5)
	gloss.size = Vector2(
		maxf(1.0, size_value.x - inset * 3.0),
		maxf(3.0, size_value.y * 0.17),
	)
	gloss.z_index = 3
	card.add_child(gloss)
	return card


func _resize_paper_card_token(card: Control, size_value: Vector2) -> void:
	if card == null or not is_instance_valid(card):
		return
	card.size = size_value
	card.custom_minimum_size = size_value
	card.pivot_offset = size_value * 0.5
	var shadow := card.get_node_or_null("PaperShadow") as Panel
	if shadow:
		shadow.size = size_value
	var edge := card.get_node_or_null("PaperEdge") as Panel
	if edge:
		edge.size = size_value
	var face := card.get_node_or_null("PaperFace") as Panel
	if face:
		face.size = size_value
	var inset := maxf(2.0, minf(size_value.x, size_value.y) * 0.032)
	var image := card.get_node_or_null("PaperImage") as TextureRect
	if image:
		image.position = Vector2(inset, inset)
		image.size = Vector2(
			maxf(1.0, size_value.x - inset * 2.0),
			maxf(1.0, size_value.y - inset * 2.0),
		)
	var gloss := card.get_node_or_null("PaperGloss") as ColorRect
	if gloss:
		gloss.position = Vector2(inset * 1.5, inset * 1.5)
		gloss.size = Vector2(
			maxf(1.0, size_value.x - inset * 3.0),
			maxf(3.0, size_value.y * 0.17),
		)


func _max_active_flyers() -> int:
	return (
		MAX_ACTIVE_FLYERS_LOW
		if AppSettings.resolved_quality_profile() == "low"
		else MAX_ACTIVE_FLYERS_HIGH
	)


func _flying_card_size(event_type: String) -> Vector2:
	if event_type in ["pokemon_played", "pokemon_evolved", "stadium_changed"]:
		return PAPER_CARD_BASE_SIZE * 1.08
	if event_type == "energy_attached":
		return PAPER_CARD_BASE_SIZE * 0.94
	if event_type == "deck_shuffled":
		return PAPER_CARD_BASE_SIZE * 0.90
	return PAPER_CARD_BASE_SIZE


func _motion_depth_for_point(point: Vector2) -> float:
	if effects == null or effects.size.y <= 0.0:
		return 0.55
	return clampf(point.y / effects.size.y, 0.0, 1.0)


func _shuffle_card_count() -> int:
	return int(SHUFFLE_CARD_LIMITS.get(AppSettings.resolved_quality_profile(), 5))


func _spawn_shuffle_motion(endpoint: Dictionary, duration: float) -> bool:
	if effects == null:
		return false
	var texture := _texture_for_card_id("")
	if texture == null:
		return false
	var count := _shuffle_card_count()
	if count <= 0:
		return false
	var origin := _snapshot_endpoint_center(endpoint, resolve_endpoint_center(endpoint))
	var playable_duration := maxf(0.0, duration - FLYING_CARD_FINISH_PAD)
	if playable_duration < MIN_FLYING_CARD_DURATION:
		_landing_burst(origin, "deck_shuffled")
		return true
	var max_delay := minf(playable_duration * 0.24, 0.032 * float(maxi(0, count - 1)))
	var delay_step := max_delay / float(maxi(1, count - 1))
	var spawned := false
	for index in range(count):
		_prune_flyers()
		while _active_flyers.size() >= _max_active_flyers():
			var oldest: Control = _active_flyers.pop_front()
			_dispose_flyer(oldest)
		var delay := float(index) * delay_step
		var motion_duration := playable_duration - delay
		if motion_duration < MIN_FLYING_CARD_DURATION:
			continue
		var start: Vector2 = origin + _zone_motion_offset(endpoint, index, count, true) * 0.55
		var side: float = -1.0 if index % 2 == 0 else 1.0
		var row: float = floor(float(index) * 0.5)
		var split: Vector2 = origin + Vector2(
			side * (38.0 + row * 9.0),
			(float(index) - float(count - 1) * 0.5) * 5.0,
		)
		var finish: Vector2 = origin + _zone_motion_offset(endpoint, count - index - 1, count, false) * 0.32
		var spin: float = side * (9.0 + row * 2.0)
		var flyer := _create_paper_card_token(
			texture,
			_flying_card_size("deck_shuffled"),
			"CardMotionEntity",
			110 + index,
			_motion_depth_for_point(origin),
		)
		flyer.set_meta("shuffle_card", true)
		flyer.set_meta("card_motion_entity", true)
		flyer.set_meta("motion_start", start)
		flyer.set_meta("motion_finish", finish)
		flyer.position = start - flyer.size * 0.5
		flyer.rotation_degrees = -spin * 0.22
		flyer.modulate.a = 1.0
		effects.add_child(flyer)
		_active_flyers.append(flyer)
		var tween := create_tween()
		if delay > 0.0:
			tween.tween_interval(delay)
		_flyer_tweens[flyer.get_instance_id()] = tween
		tween.tween_method(
			_update_shuffle_card.bind(flyer, start, split, finish, spin),
			0.0,
			1.0,
			motion_duration,
		).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
		tween.tween_callback(_finish_flyer.bind(flyer, origin, "deck_shuffled"))
		spawned = true
	return spawned


func _update_shuffle_card(
	progress: float,
	flying_value: Variant,
	start: Vector2,
	split: Vector2,
	finish: Vector2,
	spin: float,
) -> void:
	if not is_instance_valid(flying_value):
		return
	var flying := flying_value as Control
	if flying == null:
		return
	var point := Vector2.ZERO
	if progress < 0.48:
		var outward := sin((progress / 0.48) * PI * 0.5)
		point = start.lerp(split, outward)
	else:
		var inward := (progress - 0.48) / 0.52
		inward = 1.0 - pow(1.0 - inward, 2.0)
		point = split.lerp(finish, inward)
	flying.position = point - flying.size * 0.5
	flying.rotation_degrees = lerpf(-spin * 0.35, spin, sin(progress * PI))
	flying.scale = Vector2.ONE * (1.0 + sin(progress * PI) * 0.08)
	flying.modulate.a = 1.0


func _spawn_flying_card(
	texture: Texture2D,
	start: Vector2,
	finish: Vector2,
	duration: float,
	delay: float,
	event_type: String,
	index: int,
	start_size: Vector2 = Vector2.ZERO,
	finish_size: Vector2 = Vector2.ZERO,
	start_rotation: float = 0.0,
	finish_rotation: float = 0.0,
) -> void:
	_prune_flyers()
	while _active_flyers.size() >= _max_active_flyers():
		var oldest: Control = _active_flyers.pop_front()
		_dispose_flyer(oldest)
	var default_size := _flying_card_size(event_type)
	var flying_size := start_size if start_size != Vector2.ZERO else default_size
	var landing_size := finish_size if finish_size != Vector2.ZERO else default_size
	var flying := _create_paper_card_token(
		texture,
		flying_size,
		"CardMotionEntity",
		100 + index,
		_motion_depth_for_point((start + finish) * 0.5),
	)
	flying.set_meta("card_motion_entity", true)
	flying.set_meta("motion_start", start)
	flying.set_meta("motion_finish", finish)
	flying.set_meta("motion_start_size", flying_size)
	flying.set_meta("motion_finish_size", landing_size)
	flying.position = start - flying.size * 0.5
	flying.pivot_offset = flying.size * 0.5
	flying.rotation_degrees = start_rotation
	flying.modulate.a = 1.0
	effects.add_child(flying)
	_active_flyers.append(flying)
	var arc_height := maxf(
		motion_arc_height_min,
		start.distance_to(finish) * motion_arc_distance_ratio,
	)
	var control := Vector2(
		(start.x + finish.x) * 0.5,
		minf(start.y, finish.y) - arc_height - float(index) * motion_arc_stagger_height,
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
		_update_flyer.bind(
			flying,
			start,
			control,
			finish,
			spin,
			flying_size,
			landing_size,
			start_rotation,
			finish_rotation,
		),
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
	start_size: Vector2,
	finish_size: Vector2,
	start_rotation: float,
	finish_rotation: float,
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
	var size_value := start_size.lerp(finish_size, progress)
	_resize_paper_card_token(flying, size_value)
	flying.position = point - size_value * 0.5
	flying.rotation_degrees = (
		lerpf(start_rotation, finish_rotation, progress)
		+ sin(progress * PI) * spin * 0.12
	)
	var lift := 1.0 + sin(progress * PI) * 0.16
	flying.scale = Vector2.ONE * lift
	flying.modulate.a = 1.0


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
	flying.set_meta("motion_completed", true)
	if flying.has_meta("motion_finish_size"):
		_resize_paper_card_token(
			flying,
			_vector_or_default(flying.get_meta("motion_finish_size"), flying.size),
		)
	flying.position = finish - flying.size * 0.5
	flying.scale = Vector2.ONE
	flying.modulate.a = 1.0
	if effects:
		effects.burst(
			finish,
			_motion_landing_color(event_type),
			"card_land",
		)


func _mask_and_reveal_drawn_cards(count: int, duration: float) -> void:
	var visible_views: Array[CardView] = []
	for view in hand_views:
		if view.visible:
			visible_views.append(view)
	var first := maxi(0, visible_views.size() - count)
	for index in range(first, visible_views.size()):
		var view := visible_views[index]
		view.modulate.a = 0.0
		var tween := create_tween()
		tween.tween_interval(
			duration * 0.58 + float(index - first) * motion_stagger_delay,
		)
		tween.tween_property(view, "modulate:a", 1.0, 0.14)


func _prune_flyers() -> void:
	var live: Array[Control] = []
	for flyer in _active_flyers:
		if is_instance_valid(flyer) and not flyer.is_queued_for_deletion():
			live.append(flyer)
	_active_flyers = live


func _clear_active_flyers() -> void:
	for tween_value in _flyer_tweens.values():
		var tween := tween_value as Tween
		if tween and tween.is_valid():
			tween.kill()
	_flyer_tweens.clear()
	for flyer in _active_flyers.duplicate():
		if is_instance_valid(flyer):
			flyer.visible = false
			flyer.modulate.a = 0.0
			flyer.free()
	_active_flyers.clear()
	_clear_effect_child_controls(["CardMotionEntity", "FlyingCard"])


func _clear_transient_visuals() -> void:
	_clear_presentation_masks(true)
	_clear_active_flyers()
	if effects:
		effects.clear_transients()
	_clear_effect_child_controls()
	_clear_all_presentation_nodes()


func _dispose_flyer(flying: Control) -> void:
	if not is_instance_valid(flying):
		return
	var tween := _flyer_tweens.get(flying.get_instance_id()) as Tween
	if tween and tween.is_valid():
		tween.kill()
	_flyer_tweens.erase(flying.get_instance_id())
	flying.visible = false
	flying.modulate.a = 0.0
	flying.free()


func _clear_effect_child_controls(prefixes: Array = []) -> void:
	if effects == null:
		return
	var active_prefixes := prefixes.duplicate()
	if active_prefixes.is_empty():
		active_prefixes = ["PresentationCover", "CardMotionEntity", "FlyingCard"]
	for child in effects.get_children():
		var control := child as Control
		if control == null or not is_instance_valid(control):
			continue
		var name_value := str(control.name)
		var kind_value := str(control.get_meta("battle_transient_kind", ""))
		var should_clear := false
		for prefix_value in active_prefixes:
			var prefix := str(prefix_value)
			if name_value.begins_with(prefix) or kind_value == prefix:
				should_clear = true
				break
		if not should_clear and prefixes.is_empty():
			should_clear = true
		if not should_clear:
			continue
		var instance_id := control.get_instance_id()
		var flyer_tween := _flyer_tweens.get(instance_id) as Tween
		if flyer_tween and flyer_tween.is_valid():
			flyer_tween.kill()
		_flyer_tweens.erase(instance_id)
		var cover_tween := _presentation_cover_tweens.get(instance_id) as Tween
		if cover_tween and cover_tween.is_valid():
			cover_tween.kill()
		_presentation_cover_tweens.erase(instance_id)
		_active_flyers.erase(control)
		control.visible = false
		control.modulate.a = 0.0
		if not control.is_queued_for_deletion():
			control.queue_free()


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


func _place_card(
	view: CardView,
	position_value: Vector2,
	size_value: Vector2,
	depth: float = 0.5,
	rotation_value: float = 0.0,
	z_value: int = 0,
) -> void:
	view.custom_minimum_size = size_value
	view.position = position_value
	view.size = size_value
	view.rotation_degrees = rotation_value
	if z_value > 0:
		view.z_index = z_value
	view.set_table_depth(depth, depth >= 0.5)
	view.remember_base_position()


func _place_zone(
	key: String,
	position_value: Vector2,
	size_value: Vector2,
	depth: float = 0.5,
	rotation_value: float = 0.0,
	z_value: int = 0,
) -> void:
	var zone := zones[key] as ZoneView
	zone.custom_minimum_size = size_value
	zone.position = position_value
	zone.size = size_value
	zone.rotation_degrees = rotation_value
	if z_value > 0:
		zone.z_index = z_value
	zone.set_table_depth(depth)


func _zone_center(key: String) -> Vector2:
	var zone := zones.get(key) as ZoneView
	if zone == null:
		return effects.size * Vector2(0.5, 0.5)
	return _effects_local(zone.global_position + zone.size * 0.5)


func _own_hand_center() -> Vector2:
	if hand_scroll == null:
		return effects.size * Vector2(0.5, 0.5)
	return _effects_local(
		hand_scroll.global_position + hand_scroll.size * Vector2(0.5, 0.5)
	)


func _opponent_hand_center() -> Vector2:
	if opponent_hand_surface == null:
		return effects.size * Vector2(0.5, 0.5)
	return _effects_local(
		opponent_hand_surface.global_position
		+ opponent_hand_surface.size * Vector2(0.5, 0.5)
	)


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


func _slot_name(slot_name: String) -> String:
	if slot_name == "active":
		return "战斗区"
	if slot_name.begins_with("bench_"):
		return "备战区 %d" % (slot_name.trim_prefix("bench_").to_int() + 1)
	return slot_name


func _zone_title(zone_name: String) -> String:
	return {
		"deck": "牌库",
		"discard": "弃牌",
		"prizes": "奖品",
		"stadium": "竞技场",
	}.get(zone_name, zone_name)


func _player_label(player_idx: int) -> String:
	if state_ref == null or player_idx < 0:
		return ""
	return state_ref.get_player(player_idx).name

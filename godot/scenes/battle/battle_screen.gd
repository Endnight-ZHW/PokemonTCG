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
signal inspect_card_requested(context: Dictionary)
signal inspect_zone_requested(context: Dictionary)

const CARD_SCENE := preload("res://ui/card_view.tscn")

@export_category("Table Layout")
@export_group("HUD")
@export var hud_width := 292.0
@export_group("Board Cards")
@export var active_card_size := Vector2(118, 164)
@export var bench_card_size := Vector2(82, 114)
@export var zone_size := Vector2(90, 128)
@export var bench_spacing := 14.0
@export_group("Hand")
@export var hand_card_size := Vector2(104, 146)
@export var hand_minimum_spacing := 44.0
@export var hand_rotation_degrees := 7.0
@export_category("Presentation")
@export_group("Refresh")
@export var resync_fade_duration := 0.16
@export_group("Dynamic Card Motion")
@export var motion_arc_height_min := 74.0
@export var motion_arc_distance_ratio := 0.22
@export var motion_arc_stagger_height := 8.0
@export var motion_stagger_delay := 0.045
@export_group("Touch Targets")
@export var primary_action_button_height := 48.0
@export var secondary_action_button_height := 43.0

var state_ref: GameState
var catalog := CardCatalog.new()
var view_player := 0
var selected_entity_key := ""
var action_rows: Array[Dictionary] = []
var game_mode := "local"
var ai_thinking := false

@onready var board_panel: PanelContainer = %BoardPanel
@onready var board_canvas: Control = %BoardCanvas
@onready var playmat: BattlePlaymat = %Playmat
@onready var hud: VBoxContainer = %BattleHUD
@onready var turn_label: Label = %TurnLabel
@onready var opponent_info: Label = %OpponentInfo
@onready var own_info: Label = %OwnInfo
var phase_labels: Dictionary = {}
@onready var phase_advance_button: Button = %PhaseAdvanceButton
@onready var quick_actions: VBoxContainer = %QuickActions
@onready var action_list: VBoxContainer = %ActionList
@onready var all_actions_scroll: ScrollContainer = %AllActionsScroll
@onready var all_actions_toggle: Button = %AllActionsToggle
@onready var detail_image: TextureRect = %DetailImage
@onready var detail_title: Label = %DetailTitle
@onready var detail_text: RichTextLabel = %DetailText
@onready var log_label: RichTextLabel = %LogLabel
@onready var hand_scroll: ScrollContainer = %HandScroll
@onready var hand_surface: Control = %HandSurface
@onready var input_blocker: Control = %PresentationInputBlocker
@onready var effects: BattleEffectLayer = %Effects
@onready var director: PresentationDirector = %PresentationDirector
@onready var animation_player: AnimationPlayer = %AnimationPlayer

@onready var opponent_active: CardView = %OpponentActive
@onready var own_active: CardView = %OwnActive
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
	hud = get_node("BattleRoot/Body/BattleHUD") as VBoxContainer
	turn_label = get_node("BattleRoot/Header/TurnLabel") as Label
	opponent_info = get_node(
		"BattleRoot/Body/BoardPanel/BoardCanvas/OpponentInfo"
	) as Label
	own_info = get_node("BattleRoot/Body/BoardPanel/BoardCanvas/OwnInfo") as Label
	phase_advance_button = get_node(
		"BattleRoot/Body/BattleHUD/PhasePanel/Content/PhaseAdvanceButton"
	) as Button
	quick_actions = get_node(
		"ActionPanel/Margin/Content/QuickActions"
	) as VBoxContainer
	action_list = get_node(
		"ActionPanel/Margin/Content/AllActionsScroll/ActionList"
	) as VBoxContainer
	all_actions_scroll = get_node(
		"ActionPanel/Margin/Content/AllActionsScroll"
	) as ScrollContainer
	all_actions_toggle = get_node(
		"ActionPanel/Margin/Content/Heading/AllActionsToggle"
	) as Button
	detail_image = get_node(
		"BattleRoot/Body/BattleHUD/DetailPanel/Row/DetailImage"
	) as TextureRect
	detail_title = get_node(
		"BattleRoot/Body/BattleHUD/DetailPanel/Row/TextColumn/DetailTitle"
	) as Label
	detail_text = get_node(
		"BattleRoot/Body/BattleHUD/DetailPanel/Row/TextColumn/DetailText"
	) as RichTextLabel
	log_label = get_node(
		"BattleRoot/Body/BattleHUD/LogPanel/Content/LogLabel"
	) as RichTextLabel
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
	tween.tween_property(self, "modulate:a", 1.0, resync_fade_duration)


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


func _zone_context(
	player: int,
	zone_name: String,
	card_ids: Array,
	zone_count: int,
	hidden: bool,
) -> Dictionary:
	var visible_ids: Array[String] = []
	if not hidden:
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
		"hidden": hidden,
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
			return _effects_local(
				hand_scroll.global_position + hand_scroll.size * Vector2(0.5, 0.5)
			)
	return effects.size * Vector2(0.5, 0.5)


func _bind_scene_nodes() -> void:
	hud.custom_minimum_size.x = hud_width
	playmat.quality_profile = AppSettings.resolved_quality_profile()
	effects.quality_profile = AppSettings.resolved_quality_profile()
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
	for view in [opponent_active, own_active] + opponent_bench + own_bench:
		_bind_card_view(view)
	for zone_value in zones.values():
		var zone := zone_value as ZoneView
		zone.activated.connect(_on_detail_requested)
		zone.inspected.connect(_on_zone_inspected)
		zone.action_requested.connect(action_requested.emit)
	(get_node("BattleRoot/Header/MenuButton") as Button).pressed.connect(
		menu_requested.emit
	)
	phase_advance_button.pressed.connect(_on_phase_advance_pressed)
	all_actions_toggle.pressed.connect(_toggle_all_actions)
	show_card_detail("")
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
	var center_x := width * 0.5
	var hand_height := 164.0
	var field_bottom := height - hand_height
	var middle_y := field_bottom * 0.5

	opponent_info.position = Vector2(18, 8)
	opponent_info.size = Vector2(width - 36, 24)
	own_info.position = Vector2(18, field_bottom - 26)
	own_info.size = Vector2(width - 36, 24)
	var bench_total := bench_card_size.x * 5.0 + bench_spacing * 4.0
	var bench_x := center_x - bench_total * 0.5
	for index in range(5):
		_place_card(
			opponent_bench[index],
			Vector2(bench_x + index * (bench_card_size.x + bench_spacing), 30),
			bench_card_size,
		)
		_place_card(
			own_bench[index],
			Vector2(
				bench_x + index * (bench_card_size.x + bench_spacing),
				field_bottom - bench_card_size.y - 30,
			),
			bench_card_size,
		)
	_place_card(
		opponent_active,
		Vector2(
			center_x - active_card_size.x * 0.5,
			middle_y - active_card_size.y - 8,
		),
		active_card_size,
	)
	_place_card(
		own_active,
		Vector2(center_x - active_card_size.x * 0.5, middle_y + 8),
		active_card_size,
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
	_layout_hand(hand_card_size)
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
		view.z_index = visible_index
		view.remember_base_position()
		view.set_selected(selected_entity_key == "hand:%d" % view.hand_index)
		visible_index += 1


func _new_card_view() -> CardView:
	var view := CARD_SCENE.instantiate() as CardView
	_bind_card_view(view)
	return view


func _action_button(row: Dictionary, prominent: bool) -> Button:
	var action: GameAction = row.get("action")
	var button := Button.new()
	button.text = str(row.get("label", action.action if action else "动作"))
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.custom_minimum_size.y = (
		primary_action_button_height
		if prominent
		else secondary_action_button_height
	)
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
	if not card_id.is_empty():
		inspect_card_requested.emit(_card_inspection_context(card_id))


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
			maxf(0.18, duration - float(index) * motion_stagger_delay),
			float(index) * motion_stagger_delay,
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

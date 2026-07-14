class_name BattleTable
extends Control

signal menu_requested
signal selection_clear_requested(expected_key: String)
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
signal choice_target_selected(option_id: String)

const CARD_SCENE := preload("res://ui/card_view.tscn")
const CARD_DRAG_SESSION := preload("res://presentation/card_drag_session.gd")
const ENERGY_ICONS := preload("res://ui/energy_icon_catalog.gd")
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
const HAND_CARD_MAX_Z := 78
const HOVERED_HAND_CARD_Z := 79
const SELECTED_HAND_CARD_Z := 80
const CARD_MOTION_EVENT_TYPES: Array[String] = [
	"cards_drawn",
	"cards_discarded",
	"card_moved",
	"cards_selected",
	"pokemon_played",
	"trainer_played",
	"stadium_changed",
	"tool_attached",
	"energy_attached",
	"pokemon_evolved",
	"retreat",
	"switched",
	"promoted",
	"pokemon_ko",
	"prize_taken",
	"deck_shuffled",
]

@export_category("Table Layout")
@export_group("HUD")
@export var hud_width := 132.0
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
@export var motion_stagger_delay := 0.10
var state_ref: GameState
var catalog: CardCatalog = CardCatalog.shared()
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
var hud: BattlePhaseHud
var turn_label: Label
var opponent_info: Label
var own_info: Label
var own_allowance_row: HBoxContainer
var own_allowance_labels: Dictionary = {}
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
var action_popover: CardActionPopover
var interaction_router := CardInteractionRouter.new()
var choice_target_options: Dictionary = {}
var choice_target_prompt := ""
var opponent_hand_surface: Control
var opponent_hand_count_badge: Label
var hand_scroll: ScrollContainer
var hand_surface: Control
var input_blocker: Control
var effects: BattleEffectLayer
var world_feedback: BattleEffectLayer
var announcement_layer: BattleAnnouncementLayer
var camera_rig: BattleCameraRig
var director: PresentationDirector
var animation_player: AnimationPlayer
var anchor_resolver := BoardAnchorResolver.new()

var opponent_active: CardView
var own_active: CardView
var opponent_bench: Array[CardView] = []
var own_bench: Array[CardView] = []
var hand_views: Array[CardView] = []
var opponent_hand_views: Array[CardView] = []
var zones: Dictionary = {}
var slot_views: Dictionary = {}
var _selected_action_group_key := ""
var _last_selected_source_key := ""
var _popover_dismissed_source_key := ""
var _popover_source_key := ""
var _forced_popover_rows: Array[Dictionary] = []
var _forced_popover_source_key := ""
var _drag_source_key := ""
var _drag_session
var _drag_session_sequence := 0
var _presentation_drag_proxy: Control
var _last_action_rows_signature := ""
var _last_selected_entity_identity := ""
var _detail_content_signature := ""
var _detail_passthrough_key := ""
var _board_origin := Vector2.ZERO
var _initialized := false
var _active_flyers: Array[Control] = []
var _flyer_tweens: Dictionary = {}
var _event_motion_completions: Dictionary = {}
var _presentation_snapshot: Dictionary = {}
var _presentation_reveals: Dictionary = {}
var _presentation_mask_counts: Dictionary = {}
var _presentation_feedbacks: Dictionary = {}
var _presentation_landing_feedbacks: Dictionary = {}
var _presentation_covers: Dictionary = {}
var _presentation_cover_tweens: Dictionary = {}
var _presentation_slot_covers: Dictionary = {}
var _presentation_slot_cover_states: Dictionary = {}
var _presentation_slot_event_queues: Dictionary = {}
var _presentation_event_hand_targets: Dictionary = {}
var _presentation_hand_target_cursor: Dictionary = {}
var _presentation_hand_removed_counts: Dictionary = {}
var _presentation_event_hand_sources: Dictionary = {}
var _presentation_hand_source_proxies: Array[Control] = []
var _presentation_opponent_hand_proxies: Array[Control] = []
var _presentation_opponent_hand_nodes: Array[Control] = []
var _presentation_opponent_hand_event_ids: Array[String] = []
var _presentation_opponent_hand_stage_count := 0
var _presentation_opponent_hand_event_deltas: Dictionary = {}
var _presentation_opponent_hand_planned_deltas: Dictionary = {}
var _presentation_opponent_hand_target_cursor := 0
var _presentation_hand_proxy_by_key: Dictionary = {}
var _presentation_hand_snapshot_rows: Dictionary = {}
var _presentation_hand_virtual_keys: Array[String] = []
var _presentation_attachment_source_proxies: Dictionary = {}
var _presentation_zone_states: Dictionary = {}
var _presentation_hand_geometry_staged := false
var _presentation_hand_old_count := 0
var _presentation_hand_final_count := 0
var _presentation_hand_stage_count := 0
var _presentation_hand_stage_generation := 0
var _hand_layout_tweens: Dictionary = {}
var _hand_layout_motion_handles: Dictionary = {}
var _hand_transition_sequences: Dictionary = {}
var hand_motion_controller := HandMotionController.new()
var card_motion_layer := CardMotionLayer.new()
var _hand_visual_sequence := 0
var _hand_identity_player := -1
var _pending_removed_hand_visual_ids: Dictionary = {}
var _ai_thinking_started_msec := 0
var _transition_input_blocked := false
var _director_input_blocked := false


func _ready() -> void:
	initialize_ui()


func _process(_delta: float) -> void:
	if (
		_drag_session == null
		or _drag_session.state != CARD_DRAG_SESSION.DRAGGING
		or _drag_session.proxy == null
		or not is_instance_valid(_drag_session.proxy)
	):
		return
	var proxy: Control = _drag_session.proxy
	proxy.position = _drag_proxy_position_for_pointer(
		_drag_pointer_position(),
		proxy,
	)


func initialize_ui() -> void:
	if _initialized:
		return
	_resolve_scene_nodes()
	anchor_resolver.configure(self)
	hand_motion_controller.configure(self, _hand_layout_tweens)
	_initialized = true
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bind_scene_nodes()
	if not AppSettings.changed.is_connected(_apply_runtime_settings):
		AppSettings.changed.connect(_apply_runtime_settings)
	_apply_runtime_settings()
	if not resized.is_connected(_layout_board):
		resized.connect(_layout_board)
	if board_canvas != null and not board_canvas.resized.is_connected(_layout_board):
		board_canvas.resized.connect(_layout_board)
	call_deferred("_layout_board")
	if not AppSettings.reduced_motion:
		animation_player.play("enter")


func _apply_runtime_settings() -> void:
	if not _initialized:
		return
	var profile := AppSettings.resolved_quality_profile()
	if playmat:
		playmat.quality_profile = profile
	if effects:
		effects.quality_profile = profile
	if world_feedback:
		world_feedback.quality_profile = profile
	_refresh_ai_thinking_indicator()


func _resolve_scene_nodes() -> void:
	board_panel = get_node("BattleRoot/Body/BoardPanel") as PanelContainer
	board_canvas = get_node("BattleRoot/Body/BoardPanel/BoardCanvas") as Control
	playmat = get_node("BattleRoot/Body/BoardPanel/BoardCanvas/Playmat") as BattlePlaymat
	header = get_node("BattleRoot/Header") as BattleHeader
	ai_thinking_overlay = get_node(
		"BattleRoot/Body/BoardPanel/BoardCanvas/AIThinkingOverlay"
	) as AIThinkingOverlay
	hud = get_node("BattleRoot/Body/BattleHUD") as BattlePhaseHud
	turn_label = get_node("BattleRoot/Header/TurnLabel") as Label
	opponent_info = get_node(
		"BattleRoot/Body/BoardPanel/BoardCanvas/OpponentInfo"
	) as Label
	own_info = get_node("BattleRoot/Body/BoardPanel/BoardCanvas/OwnInfo") as Label
	own_allowance_row = get_node(
		"BattleRoot/Body/BoardPanel/BoardCanvas/OwnAllowanceRow"
	) as HBoxContainer
	own_allowance_labels = {
		"energy": own_allowance_row.get_node("Energy") as Label,
		"supporter": own_allowance_row.get_node("Supporter") as Label,
		"retreat": own_allowance_row.get_node("Retreat") as Label,
		"stadium": own_allowance_row.get_node("Stadium") as Label,
	}
	phase_advance_button = get_node(
		"BattleRoot/Body/BattleHUD/PhasePanel/Content/PhaseAdvanceButton"
	) as Button
	all_actions_button = null
	action_panel = null
	action_list = null
	all_actions_scroll = null
	all_actions_toggle = null
	detail_panel = get_node("OverlayPanels/DetailPanel") as PanelContainer
	var detail_component := detail_panel as BattleDetailPanel
	detail_image = detail_component.detail_image if detail_component else null
	detail_title = detail_component.detail_title if detail_component else null
	detail_text = detail_component.detail_text if detail_component else null
	detail_close_button = detail_component.close_button if detail_component else null
	action_popover = get_node("CardActionPopover") as CardActionPopover
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
	world_feedback = get_node("WorldFeedback") as BattleEffectLayer
	announcement_layer = get_node("AnnouncementLayer") as BattleAnnouncementLayer
	camera_rig = get_node("CameraRig") as BattleCameraRig
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
	if (
		not _detail_passthrough_key.is_empty()
		and selected_entity_key != _detail_passthrough_key
	):
		_detail_passthrough_key = ""
	var next_action_rows_signature := _action_rows_semantic_signature(action_rows)
	var next_selected_entity_identity := _selected_entity_identity()
	var interaction_context_changed := (
		selected_entity_key != _last_selected_source_key
		or next_action_rows_signature != _last_action_rows_signature
		or next_selected_entity_identity != _last_selected_entity_identity
	)
	if interaction_context_changed:
		_reset_action_interaction_state()
	_last_selected_source_key = selected_entity_key
	_last_action_rows_signature = next_action_rows_signature
	_last_selected_entity_identity = next_selected_entity_identity
	interaction_router.rebuild(_routed_action_rows(), selected_entity_key)
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
	if selected_entity_key.is_empty():
		hide_card_detail()
	elif detail_panel and detail_panel.visible:
		_sync_visible_card_detail()
		if action_popover and action_popover.visible:
			_reposition_action_popover()


func set_choice_targets(options_by_source: Dictionary, prompt: String) -> void:
	choice_target_options = options_by_source.duplicate()
	choice_target_prompt = prompt
	if _initialized:
		_refresh_target_hints()
		_refresh_header()


func clear_choice_targets() -> void:
	choice_target_options.clear()
	choice_target_prompt = ""
	if _initialized:
		_refresh_target_hints()
		_refresh_header()


func visible_card_source_keys() -> Array[String]:
	var result: Array[String] = []
	for hand_view in hand_views:
		if hand_view and hand_view.visible and not hand_view.card_id.is_empty():
			result.append(CardInteractionRouter.hand_key(hand_view.hand_index))
	for slot_key_value in slot_views.keys():
		var slot_key := str(slot_key_value)
		var slot_view := slot_views[slot_key] as CardView
		if slot_view and slot_view.visible and not slot_view.card_id.is_empty():
			result.append("pokemon:%s" % slot_key)
	var stadium := zones.get("stadium") as ZoneView
	if stadium and stadium.visible and not stadium.card_id.is_empty():
		result.append("stadium")
	return result


func all_card_actions_reachable_from_visible_cards() -> bool:
	return interaction_router.all_card_actions_reachable_from(
		visible_card_source_keys(),
	)


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
	_hand_identity_player = -1
	for view in hand_views:
		if view != null:
			view.set_local_visual_id("")
	_clear_transient_visuals()
	modulate.a = 0.35
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 1.0, resync_fade_duration)


func show_card_detail(card_id: String, pokemon: PokemonState = null) -> void:
	if card_id.is_empty():
		hide_card_detail()
		return
	var component := detail_panel as BattleDetailPanel
	if component == null:
		return
	component.show_card(card_id, pokemon, catalog)
	_detail_content_signature = (
		_detail_signature(card_id, pokemon)
		if component.is_showing_card()
		else ""
	)
	detail_image = component.detail_image
	detail_title = component.detail_title
	detail_text = component.detail_text
	detail_close_button = component.close_button
	_layout_detail_panel()
	if action_popover and action_popover.visible:
		_reposition_action_popover()


func hide_card_detail() -> void:
	_detail_content_signature = ""
	var component := detail_panel as BattleDetailPanel
	if component:
		component.hide_card()
	elif detail_panel:
		detail_panel.visible = false
	if action_popover and action_popover.visible:
		_reposition_action_popover()


func _on_detail_close_requested() -> void:
	_detail_content_signature = ""
	var expected_key := selected_entity_key
	_reset_action_interaction_state()
	selection_clear_requested.emit(expected_key)


func _sync_visible_card_detail(force_show := false) -> void:
	var component := detail_panel as BattleDetailPanel
	if component == null or (not component.visible and not force_show) or state_ref == null:
		return
	var card_id := ""
	var pokemon: PokemonState
	if selected_entity_key.begins_with("hand:"):
		var hand_index := selected_entity_key.trim_prefix("hand:").to_int()
		var hand := state_ref.get_player(view_player).hand
		if hand_index >= 0 and hand_index < hand.size():
			card_id = str(hand[hand_index])
	elif selected_entity_key.begins_with("pokemon:"):
		var parts := selected_entity_key.split(":")
		if parts.size() >= 3:
			var player := int(parts[1])
			if player in [0, 1]:
				pokemon = state_ref.get_player(player).get_pokemon(str(parts[2]))
				if pokemon:
					card_id = pokemon.card_id
	elif selected_entity_key == "stadium":
		card_id = state_ref.stadium_card_id
	if card_id.is_empty():
		hide_card_detail()
		return
	var next_signature := _detail_signature(card_id, pokemon)
	if (
		component.current_card_id != card_id
		or next_signature != _detail_content_signature
	):
		component.show_card(card_id, pokemon, catalog)
		_detail_content_signature = (
			next_signature if component.is_showing_card() else ""
		)
	_layout_detail_panel()


func _selected_entity_identity() -> String:
	if state_ref == null or selected_entity_key.is_empty():
		return ""
	if selected_entity_key.begins_with("hand:"):
		var hand_index := selected_entity_key.trim_prefix("hand:").to_int()
		var hand := state_ref.get_player(view_player).hand
		return "hand:%d:%d:%s" % [
			view_player,
			hand_index,
			str(hand[hand_index]) if hand_index >= 0 and hand_index < hand.size() else "",
		]
	if selected_entity_key.begins_with("pokemon:"):
		var parts := selected_entity_key.split(":")
		if parts.size() >= 3:
			var player := int(parts[1])
			var slot_name := str(parts[2])
			if player in [0, 1]:
				var pokemon := state_ref.get_player(player).get_pokemon(slot_name)
				return "%s:%s" % [
					selected_entity_key,
					pokemon.card_id if pokemon else "",
				]
	if selected_entity_key == "stadium":
		return "stadium:%s" % state_ref.stadium_card_id
	return selected_entity_key


func _detail_signature(card_id: String, pokemon: PokemonState) -> String:
	return "%s|%s" % [
		card_id,
		_stable_value_signature(pokemon.to_dict()) if pokemon else "",
	]


func get_slot_view(player: int, slot: String) -> CardView:
	return slot_views.get("%d:%s" % [player, slot]) as CardView


func capture_presentation_snapshot() -> Dictionary:
	if not _initialized or state_ref == null or effects == null:
		return {}
	var snapshot := {
		"view_player": view_player,
		"state": state_ref.to_dict(),
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
			"visual_id": view.local_visual_id,
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
		var attachment_centers := {}
		if view.pokemon != null:
			for energy_index in range(view.pokemon.energy_card_ids.size()):
				var energy_id := str(view.pokemon.energy_card_ids[energy_index])
				var energy_center := _effects_local(
					view.attachment_anchor_global(
						"energy",
						energy_id,
						energy_index,
					)
				)
				if not attachment_centers.has("energy"):
					attachment_centers["energy"] = energy_center
				attachment_centers["energy:%s" % energy_id] = energy_center
			if not view.pokemon.attached_tool_id.is_empty():
				var tool_center := _effects_local(
					view.attachment_anchor_global(
						"tool",
						view.pokemon.attached_tool_id,
					)
				)
				attachment_centers["tool"] = tool_center
				attachment_centers[
					"tool:%s" % view.pokemon.attached_tool_id
				] = tool_center
		(snapshot["slots"] as Dictionary)[key] = {
			"card_id": view.card_id,
			"center": _effects_local(view.global_center()),
			"size": view.size,
			"rotation_degrees": view.rotation_degrees,
			"empty": view.empty,
			"hidden": view.is_hidden_card,
			"attachment_centers": attachment_centers,
			"pokemon": view.pokemon.to_dict() if view.pokemon != null else {},
		}
	for zone_key in zones.keys():
		var zone := zones[zone_key] as ZoneView
		if zone == null:
			continue
		var logical_key := _logical_zone_key(str(zone_key))
		(snapshot["zones"] as Dictionary)[logical_key] = {
			"card_id": zone.card_id,
			"center": _zone_center(str(zone_key)),
			"size": _zone_card_size(zone),
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
	return anchor_resolver.resolve(endpoint)


func _resolve_endpoint_center_direct(endpoint: Dictionary) -> Vector2:
	var player := int(endpoint.get("player", view_player))
	var slot := str(endpoint.get("slot", ""))
	var zone := str(endpoint.get("zone", ""))
	if not slot.is_empty():
		var slot_key := "%d:%s" % [player, slot]
		var card_view := _valid_card_view(_presentation_slot_covers.get(slot_key))
		if card_view == null:
			card_view = get_slot_view(player, slot)
		if card_view and card_view.visible:
			var attachment_type := str(endpoint.get("attachment_type", ""))
			if not attachment_type.is_empty():
				var attachment_card_id := str(endpoint.get(
					"attachment_card_id",
					endpoint.get("card_id", ""),
				))
				return _effects_local(
					card_view.attachment_anchor_global(
						attachment_type,
						attachment_card_id,
						int(endpoint.get("attachment_index", -1)),
					)
				)
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
	var detail_component := detail_panel as BattleDetailPanel
	if detail_component:
		detail_component.hide_card()
		if not detail_component.close_requested.is_connected(_on_detail_close_requested):
			detail_component.close_requested.connect(_on_detail_close_requested)
	if log_panel:
		log_panel.z_index = 0
		log_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		log_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	playmat.quality_profile = AppSettings.resolved_quality_profile()
	effects.quality_profile = AppSettings.resolved_quality_profile()
	world_feedback.quality_profile = AppSettings.resolved_quality_profile()
	card_motion_layer.configure(effects, _active_flyers, _flyer_tweens)
	if camera_rig != null:
		camera_rig.configure([board_panel, effects, world_feedback])
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
	opponent_info.z_index = 46
	opponent_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	opponent_info.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	opponent_info.add_theme_stylebox_override(
		"normal",
		DesignTokens.panel_style(
			Color(0.105, 0.025, 0.045, 0.94),
			7,
			Color(0.76, 0.22, 0.32, 0.72),
			1,
			7,
		),
	)
	own_info.z_index = 46
	own_info.add_theme_stylebox_override(
		"normal",
		DesignTokens.panel_style(
			Color(0.025, 0.060, 0.105, 0.94),
			7,
			Color(0.28, 0.53, 0.78, 0.72),
			1,
			7,
		),
	)
	for allowance_label_value in own_allowance_labels.values():
		var allowance_label := allowance_label_value as Label
		allowance_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		allowance_label.add_theme_stylebox_override(
			"normal",
			_allowance_chip_style(false),
		)
		allowance_label.add_theme_color_override("font_color", DesignTokens.GREEN)
	phase_labels.clear()
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
	# Deck/discard retain their left/bottom paper depth. Prizes use a separate
	# six-card horizontal fan matching a physical face-down prize row.
	(zones["opponent_deck"] as ZoneView).set_stack_visual("deck", 60, "down_left")
	(zones["own_deck"] as ZoneView).set_stack_visual("deck", 60, "down_left")
	(zones["opponent_discard"] as ZoneView).set_stack_visual("discard", 60, "down_left")
	(zones["own_discard"] as ZoneView).set_stack_visual("discard", 60, "down_left")
	(zones["opponent_prizes"] as ZoneView).set_stack_visual("prizes", 6, "fan_right")
	(zones["own_prizes"] as ZoneView).set_stack_visual("prizes", 6, "fan_right")
	for view in [opponent_active, own_active] + opponent_bench + own_bench:
		_bind_card_view(view)
	for zone_value in zones.values():
		var zone := zone_value as ZoneView
		zone.activated.connect(_on_detail_requested)
		zone.inspected.connect(_on_zone_inspected)
		zone.detail_requested.connect(_on_detail_requested)
		zone.action_requested.connect(action_requested.emit)
		zone.card_dropped.connect(_on_card_dropped)
	header.initialize_ui()
	header.menu_requested.connect(_on_menu_pressed)
	hud.phase_action_requested.connect(action_requested.emit)
	if not hud.log_drawer_toggled.is_connected(_on_log_drawer_toggled):
		hud.log_drawer_toggled.connect(_on_log_drawer_toggled)
	# Keep global input enabled even while the log drawer is closed. This lets us
	# remove a popover before GUI hit testing while preserving the original card
	# press and its normal release/long-press/drag semantics.
	set_process_input(true)
	if action_popover:
		action_popover.action_chosen.connect(_on_popover_action_chosen)
		action_popover.dismissed.connect(_on_popover_dismissed)
	director.sequence_started.connect(func(_count: int) -> void:
		_director_input_blocked = not AppSettings.reduced_motion
		_sync_input_blocker()
	)
	director.sequence_finished.connect(func() -> void:
		_director_input_blocked = false
		_sync_input_blocker()
		_clear_presentation_masks(true)
		_clear_active_flyers()
	)
	director.event_finished.connect(_on_presentation_event_finished)
	director.event_started.connect(_on_presentation_event_started)
	director.event_completion_requested.connect(
		_on_presentation_event_completion_requested,
	)
	director.floating_text_requested.connect(_on_floating_text_requested)
	director.burst_requested.connect(_on_burst_requested)
	director.card_motion_requested.connect(_on_card_motion_requested)
	director.card_landing_feedback_scheduled.connect(
		_on_card_landing_feedback_scheduled,
	)
	director.camera_impulse_requested.connect(_on_camera_impulse_requested)
	_sync_input_blocker()


func set_transition_blocked(value: bool) -> void:
	_transition_input_blocked = value
	_sync_input_blocker()


func _sync_input_blocker() -> void:
	if input_blocker != null:
		input_blocker.visible = _transition_input_blocked or _director_input_blocked


func _on_presentation_event_completion_requested(
	event: Dictionary,
	completion: PresentationDirector.EventCompletion,
) -> void:
	var event_type := PresentationEvent.canonical_event_type(
		str(event.get("event_type", "")),
	)
	if MotionPolicy.reduced() or event_type not in CARD_MOTION_EVENT_TYPES:
		return
	if event_type == "cards_selected" and int(event.get("amount", 0)) <= 0:
		return
	var event_id := str(event.get("event_id", ""))
	if event_id.is_empty():
		return
	completion.hold()
	var group := MotionGroup.new()
	group.completed.connect(
		_on_event_motion_group_completed.bind(event_id, completion),
		CONNECT_ONE_SHOT,
	)
	_event_motion_completions[event_id] = {
		"completion": completion,
		"group": group,
	}


func _on_event_motion_group_completed(
	group: MotionGroup,
	event_id: String,
	completion: PresentationDirector.EventCompletion,
) -> void:
	var row: Dictionary = _event_motion_completions.get(event_id, {})
	if row.get("group") == group:
		_event_motion_completions.erase(event_id)
	completion.finish()


func _bind_card_view(view: CardView) -> void:
	view.set_catalog(catalog)
	view.activated.connect(_on_card_activated)
	view.detail_requested.connect(_on_card_view_detail_requested.bind(view))
	view.card_dropped.connect(_on_card_dropped)
	view.action_requested.connect(action_requested.emit)
	view.drag_started.connect(_on_hand_drag_started)
	view.drag_ended.connect(_on_hand_drag_ended)
	view.hovered_changed.connect(_on_card_hovered_changed.bind(view))


func _on_phase_advance_pressed() -> void:
	var action: GameAction = phase_advance_button.get_meta("action") as GameAction
	if action:
		action_requested.emit(action)


func _input(event: InputEvent) -> void:
	# PresentationInputBlocker owns the GUI phase while an effect sequence runs.
	# Global input must stay read-only so it cannot dismiss transient surfaces
	# before the blocker consumes the same pointer gesture.
	if input_blocker and input_blocker.visible:
		return
	var pointer_button := event as InputEventMouseButton
	var is_left_pointer_button := (
		pointer_button != null
		and pointer_button.button_index == MOUSE_BUTTON_LEFT
	)
	if is_left_pointer_button and not pointer_button.pressed:
		if not _detail_passthrough_key.is_empty():
			var expected_key := _detail_passthrough_key
			_detail_passthrough_key = ""
			# GUI release runs after _input. Restore only on the following frame, and
			# only if CardView did not complete the normal same-card cancellation.
			call_deferred("_restore_detail_after_passthrough", expected_key)
		return
	var is_pointer_press := is_left_pointer_button and pointer_button.pressed
	if not is_pointer_press:
		return
	var pointer_position := (event as InputEventMouseButton).position
	# The log drawer is the top-most table surface. Closing it consumes this
	# press so the same gesture cannot also activate a card beneath the drawer.
	if hud and hud.is_log_drawer_open():
		if log_panel and log_panel.get_global_rect().has_point(pointer_position):
			return
		var phase_panel := hud.get_node_or_null("PhasePanel") as Control
		if phase_panel and phase_panel.get_global_rect().has_point(pointer_position):
			return
		if header and header.menu_button.get_global_rect().has_point(pointer_position):
			return
		hud.close_log_drawer()
		var viewport := get_viewport()
		if viewport:
			viewport.set_input_as_handled()
		return
	var selected_source := _source_control_for_key(selected_entity_key)
	var selected_source_pressed := (
		selected_source != null
		and _control_contains_global_point(selected_source, pointer_position)
	)
	if (
		selected_source_pressed
		and detail_panel
		and detail_panel.visible
		and detail_panel.get_global_rect().has_point(pointer_position)
	):
		# On very narrow layouts the detail surface can be forced over its source.
		# Remove both transient surfaces before GUI hit testing and let the original
		# gesture reach CardView; this preserves click, long-press and drag semantics.
		_detail_passthrough_key = selected_entity_key
		hide_card_detail()
		if action_popover and action_popover.visible:
			action_popover.dismiss()
		return
	if action_popover == null or not action_popover.visible:
		return
	var source_inside_informational_panel := (
		action_popover.is_informational_only()
		and action_popover.source_contains_global_point(pointer_position)
	)
	if (
		action_popover.panel_global_rect().has_point(pointer_position)
		and not source_inside_informational_panel
	):
		return
	if (
		detail_panel
		and detail_panel.visible
		and detail_panel.get_global_rect().has_point(pointer_position)
	):
		return
	# Hide the full-screen popover before GUI hit testing, but deliberately do
	# not handle the event. CardView must receive the original press so its
	# release, long-press and drag thresholds stay intact.
	action_popover.dismiss()


func _restore_detail_after_passthrough(expected_key: String) -> void:
	if (
		expected_key.is_empty()
		or selected_entity_key != expected_key
		or state_ref == null
		or (detail_panel and detail_panel.visible)
	):
		return
	_sync_visible_card_detail(true)


func _control_contains_global_point(control: Control, global_point: Vector2) -> bool:
	if control == null or not is_instance_valid(control) or not control.is_visible_in_tree():
		return false
	var local_point := (
		control.get_global_transform_with_canvas().affine_inverse() * global_point
	)
	return Rect2(Vector2.ZERO, control.size).has_point(local_point)


func _refresh_header(display_state: GameState = null) -> void:
	var active_state := display_state if display_state != null else state_ref
	if active_state == null:
		return
	if header:
		header.update_header(
			active_state,
			view_player,
			ai_thinking,
			_current_task_hint(),
		)
	else:
		var display_actor := (
			view_player
			if active_state.phase == "SETUP"
			else active_state.active_player_idx
		)
		turn_label.text = "第 %d 回合 · %s · 玩家 %d" % [
			active_state.turn_number,
			_phase_name(active_state.phase),
			display_actor + 1,
		]


func _refresh_field() -> void:
	_refresh_field_info(state_ref)
	var own := state_ref.get_player(view_player)
	var opponent := state_ref.get_player(1 - view_player)
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
	_refresh_field_zones(own, opponent)


func _refresh_field_info(display_state: GameState) -> void:
	if display_state == null:
		return
	var own := display_state.get_player(view_player)
	var opponent := display_state.get_player(1 - view_player)
	opponent_info.text = "%s　手牌 %d　牌库 %d　奖品 %d" % [
		opponent.name,
		opponent.hand.size(),
		opponent.deck.size(),
		opponent.prizes.size(),
	]
	own_info.text = "%s　手牌 %d　牌库 %d　奖品 %d" % [
		own.name,
		own.hand.size(),
		own.deck.size(),
		own.prizes.size(),
	]
	_refresh_turn_allowance_chips(own)


func _refresh_field_zones(own: PlayerState, opponent: PlayerState) -> void:
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
	var preserve_visible_identity := _hand_identity_player == view_player
	var previous_views := hand_views.duplicate()
	var ordered_views: Array[CardView] = []
	var used: Dictionary = {}
	# First reserve every unchanged card by local visual identity/occurrence. Only
	# after that pass may an unmatched final card reuse a leftover anchor.
	for card_id_value in hand:
		var card_id := str(card_id_value)
		var matched: CardView
		if preserve_visible_identity:
			for candidate_value in previous_views:
				var candidate := candidate_value as CardView
				if (
					candidate == null
					or not candidate.visible
					or used.has(candidate.get_instance_id())
					or _pending_removed_hand_visual_ids.has(candidate.local_visual_id)
					or candidate.card_id != card_id
				):
					continue
				matched = candidate
				used[matched.get_instance_id()] = true
				break
		ordered_views.append(matched)
	for index in range(ordered_views.size()):
		if ordered_views[index] != null:
			continue
		var matched: CardView
		# Prefer an already-hidden spare, then recycle a card that left the hand.
		for candidate_value in previous_views:
			var candidate := candidate_value as CardView
			if (
				candidate != null
				and not candidate.visible
				and not used.has(candidate.get_instance_id())
			):
				matched = candidate
				break
		if matched == null:
			for candidate_value in previous_views:
				var candidate := candidate_value as CardView
				if candidate == null or used.has(candidate.get_instance_id()):
					continue
				matched = candidate
				break
		if matched == null:
			matched = _new_card_view()
			hand_surface.add_child(matched)
			previous_views.append(matched)
		_assign_new_hand_visual_id(matched)
		used[matched.get_instance_id()] = true
		ordered_views[index] = matched
	for candidate_value in previous_views:
		var candidate := candidate_value as CardView
		if candidate != null and not used.has(candidate.get_instance_id()):
			ordered_views.append(candidate)
	hand_views.assign(ordered_views)
	_pending_removed_hand_visual_ids.clear()
	_hand_identity_player = view_player
	for index in range(hand_views.size()):
		var view := hand_views[index]
		if index >= hand.size():
			view.visible = false
			continue
		view.visible = true
		view.configure(hand[index], null, false, index, view_player, "", true)
		view.set_selected(selected_entity_key == "hand:%d" % index)
	_layout_hand(_current_hand_card_size())


func _assign_new_hand_visual_id(view: CardView) -> void:
	if view == null:
		return
	_hand_visual_sequence += 1
	view.set_local_visual_id("hand:%d:%d:%d" % [
		view_player,
		state_ref.revision if state_ref != null else -1,
		_hand_visual_sequence,
	])


func invalidate_hand_visual_identities() -> void:
	for view in hand_views:
		if view != null and view.visible:
			_assign_new_hand_visual_id(view)


func prepare_hand_identity_transition(
	raw_events: Array,
	previous_snapshot: Dictionary,
) -> void:
	_pending_removed_hand_visual_ids.clear()
	var snapshot_hand: Array = previous_snapshot.get("hand", [])
	var virtual_rows: Array[Dictionary] = []
	for snapshot_index in range(snapshot_hand.size()):
		if not snapshot_hand[snapshot_index] is Dictionary:
			continue
		var row: Dictionary = Dictionary(snapshot_hand[snapshot_index]).duplicate(true)
		row["snapshot_key"] = "snapshot:%d" % snapshot_index
		row["snapshot_index"] = snapshot_index
		virtual_rows.append(row)
	for event_index in range(raw_events.size()):
		var raw_event_value: Variant = raw_events[event_index]
		if not raw_event_value is Dictionary:
			continue
		var event := PresentationEvent.normalize(
			raw_event_value,
			state_ref.revision if state_ref != null else -1,
			view_player,
			event_index,
		)
		var source: Dictionary = event.get("source", {})
		var target: Dictionary = event.get("target", {})
		if (
			int(source.get("player", -1)) != view_player
			or str(source.get("zone", "")) != "hand"
			or str(target.get("zone", "")) == "hand"
		):
			continue
		var selected_rows := _select_virtual_hand_source_rows(event, virtual_rows)
		for row in selected_rows:
			_mark_snapshot_hand_visual_removed(
				snapshot_hand,
				int(row.get("snapshot_index", -1)),
			)
			var key := str(row.get("snapshot_key", ""))
			for virtual_index in range(virtual_rows.size() - 1, -1, -1):
				if str(virtual_rows[virtual_index].get("snapshot_key", "")) == key:
					virtual_rows.remove_at(virtual_index)
					break


func _mark_snapshot_hand_visual_removed(snapshot_hand: Array, index: int) -> void:
	if index < 0 or index >= snapshot_hand.size():
		return
	var row := snapshot_hand[index] as Dictionary
	var visual_id := str(row.get("visual_id", ""))
	if not visual_id.is_empty():
		_pending_removed_hand_visual_ids[visual_id] = true


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
	interaction_router.rebuild(_routed_action_rows(), selected_entity_key)
	if hud:
		hud.update_phase(state_ref, view_player, ai_thinking, game_mode, action_rows)
	phase_advance_button = hud.phase_advance_button if hud else null

	# CardView only receives read-only legality state. It never creates action
	# buttons and never derives rules from card data.
	for hand_view in hand_views:
		if not hand_view.visible:
			continue
		var source_key := CardInteractionRouter.hand_key(hand_view.hand_index)
		var source_actionable := interaction_router.has_source(source_key)
		hand_view.set_interaction_state(
			source_actionable,
			_disabled_reason_for_source(source_key) if hand_view.selected and not source_actionable else "",
		)
	for slot_key_value in slot_views.keys():
		var slot_key := str(slot_key_value)
		var slot_view := slot_views[slot_key] as CardView
		var source_key := "pokemon:%s" % slot_key
		var source_actionable := interaction_router.has_source(source_key)
		slot_view.set_interaction_state(
			source_actionable,
			_disabled_reason_for_source(source_key) if slot_view.selected and not source_actionable else "",
		)

	var stadium_zone := zones["stadium"] as ZoneView
	stadium_zone.set_action({})
	stadium_zone.set_actionable(interaction_router.has_source("stadium"))
	_refresh_action_popover()


func _refresh_log(display_state: GameState = null) -> void:
	var active_state := display_state if display_state != null else state_ref
	if active_state == null:
		return
	if log_panel:
		log_panel.update_entries(active_state.action_log)
		return
	var lines: Array[String] = []
	for index in range(active_state.action_log.size()):
		lines.append("[color=#62d7ff]◆[/color] " + active_state.action_log[index])
	if log_label:
		log_label.text = "\n".join(lines)
		log_label.scroll_to_line(maxi(0, lines.size() - 1))


func _refresh_target_hints() -> void:
	var selected_rows := _rows_for_active_selection()
	# A drag is an explicit interaction with its own source card. It must take
	# precedence over any card that happened to remain selected before the drag;
	# otherwise the table highlights the old card's targets and can reject a
	# completely legal drop from the card currently under the pointer.
	if not _drag_source_key.is_empty():
		selected_rows = interaction_router.rows_for_source(_drag_source_key)
	var selected_target_labels: Dictionary = {}
	for row in selected_rows:
		var action := row.get("action") as GameAction
		if action == null:
			continue
		for target_key in CardInteractionRouter.target_keys_for_action(action, row):
			selected_target_labels[target_key] = _target_hint_for_action(action)
	for target_key_value in choice_target_options.keys():
		selected_target_labels[str(target_key_value)] = "选择"

	for slot_key_value in slot_views.keys():
		var slot_key := str(slot_key_value)
		var target_key := "pokemon:%s" % slot_key
		var view := slot_views[slot_key] as CardView
		var allowed_hand_indices: Array[int] = []
		for source_key in interaction_router.source_keys():
			if not source_key.begins_with("hand:"):
				continue
			if interaction_router.is_target_legal(source_key, target_key):
				allowed_hand_indices.append(source_key.trim_prefix("hand:").to_int())
		var source_key := target_key
		var source_actionable := interaction_router.has_source(source_key)
		var disabled_reason := (
			_disabled_reason_for_source(source_key)
			if view.selected and not source_actionable
			else ""
		)
		var target_hint := str(selected_target_labels.get(target_key, ""))
		view.set_interaction_state(
			source_actionable,
			disabled_reason,
			target_hint,
			allowed_hand_indices,
		)
		if target_hint.is_empty():
			view.set_targetable(false)

	var stadium_hand_indices: Array[int] = []
	for source_key in interaction_router.source_keys():
		if source_key.begins_with("hand:"):
			var hand_index := source_key.trim_prefix("hand:").to_int()
			if interaction_router.is_drop_legal(hand_index, view_player, "stadium"):
				stadium_hand_indices.append(hand_index)
	(zones["stadium"] as ZoneView).set_drop_target(
		view_player,
		"stadium",
		stadium_hand_indices,
	)
	var stadium_highlighted := false
	if not _drag_source_key.is_empty():
		for row in selected_rows:
			var action := row.get("action") as GameAction
			if action and "stadium" in CardInteractionRouter.drag_target_keys_for_action(action, row):
				stadium_highlighted = true
				break
	(zones["stadium"] as ZoneView).set_drop_highlight(stadium_highlighted)


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
	# A responsive layout invalidates every hand-space endpoint. Cancel the old
	# property owners before writing rebased coordinates so a stale Tween cannot
	# pull cards back toward the pre-resize layout on the following frame.
	_clear_hand_layout_tweens()
	var metrics := _board_layout_metrics(width, height)
	_layout_player_hands(metrics)
	var field_plan := BattleTableLayout.field_plan(metrics, bench_spacing)
	_layout_field_slots(metrics, field_plan)
	_layout_table_zones(metrics, field_plan)
	_reposition_slot_state_covers()
	_layout_own_status(metrics, field_plan)
	_layout_opponent_hand(metrics["hidden_hand_size"])
	_reposition_opponent_hand_proxies()
	if _presentation_hand_geometry_staged:
		_snap_staged_hand_layout(metrics["own_hand_size"])
	else:
		_layout_hand(metrics["own_hand_size"])
	_layout_overlay_drawers()
	_reconcile_drag_after_layout_change()
	_refresh_ai_thinking_indicator()
	if playmat:
		playmat.queue_redraw()
	if effects:
		effects.queue_redraw()
	if world_feedback:
		world_feedback.queue_redraw()


func _board_layout_metrics(width: float, height: float) -> Dictionary:
	return BattleTableLayout.board_metrics(width, height, {
		"active_card_size": active_card_size,
		"bench_card_size": bench_card_size,
		"zone_size": zone_size,
		"hand_card_size": hand_card_size,
		"opponent_hand_card_size": opponent_hand_card_size,
		"table_side_margin": table_side_margin,
		"table_top_margin": table_top_margin,
		"table_bottom_margin": table_bottom_margin,
		"hand_bottom_padding": hand_bottom_padding,
	})


func _layout_player_hands(metrics: Dictionary) -> void:
	var center_x := float(metrics["center_x"])
	var top_margin := float(metrics["top_margin"])
	var hidden_hand_size: Vector2 = metrics["hidden_hand_size"]
	var opponent_hand_width := float(metrics["opponent_hand_width"])
	var top_hand_height := float(metrics["top_hand_height"])
	var opponent_hand_y := float(metrics["opponent_hand_y"])
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
		float(metrics.get("top_interaction_clearance", top_margin)) + 4.0,
	)
	opponent_hand_count_badge.size = Vector2(34.0, 34.0)
	opponent_info.position = Vector2(
		float(metrics["field_left"]),
		float(metrics["opponent_info_y"]),
	)
	opponent_info.size = Vector2(304.0, 24.0)

	var own_hand_y := float(metrics["own_hand_y"])
	var hand_width := float(metrics["hand_width"])
	hand_scroll.position = Vector2(center_x - hand_width * 0.5, own_hand_y)
	hand_scroll.size = Vector2(hand_width, float(metrics["own_hand_height"]))
	hand_surface.custom_minimum_size.y = float(metrics["own_hand_height"]) - 8.0


func _layout_field_slots(metrics: Dictionary, plan: Dictionary) -> void:
	var active_size: Vector2 = plan["active_size"]
	var bench_size: Vector2 = plan["bench_size"]
	var opponent_bench_centers: Array[Vector2] = plan["opponent_bench_centers"]
	var own_bench_centers: Array[Vector2] = plan["own_bench_centers"]
	var opponent_bench_rects: Array[Rect2] = plan["opponent_bench_rects"]
	var own_bench_rects: Array[Rect2] = plan["own_bench_rects"]
	for index in range(5):
		_place_perspective_card(
			opponent_bench[index],
			opponent_bench_centers[index],
			bench_size,
			metrics,
			-2.4 + float(index - 2) * 0.22,
			index,
		)
		_place_perspective_card(
			own_bench[index],
			own_bench_centers[index],
			bench_size,
			metrics,
			2.4 + float(index - 2) * 0.22,
			20 + index,
		)
	_place_perspective_card(
		opponent_active,
		plan["opponent_active_center"],
		active_size,
		metrics,
		-1.2,
		12,
	)
	_place_perspective_card(
		own_active,
		plan["own_active_center"],
		active_size,
		metrics,
		1.2,
		34,
	)
	_update_playmat_field_guides(
		opponent_bench_rects,
		own_bench_rects,
		plan["opponent_active_rect"],
		plan["own_active_rect"],
		metrics,
	)


func _layout_table_zones(metrics: Dictionary, field_plan: Dictionary) -> void:
	var plan := BattleTableLayout.zone_plan(metrics, field_plan)
	var positions: Dictionary = plan["positions"]
	var zone_visual_size: Vector2 = plan["size"]
	for key in [
		"opponent_prizes",
		"opponent_deck",
		"opponent_discard",
		"stadium",
		"own_discard",
		"own_deck",
		"own_prizes",
	]:
		var placed_position: Vector2 = positions[key]
		var placed_size := zone_visual_size
		if key == "stadium":
			var stadium_scale := float(plan.get("stadium_scale", 1.0))
			placed_size *= stadium_scale
			placed_position += (zone_visual_size - placed_size) * 0.5
		_place_perspective_zone(key, placed_position, placed_size, metrics)
	_layout_prize_stack_bounds(metrics)
	_layout_pile_docks(metrics)


func _layout_prize_stack_bounds(metrics: Dictionary) -> void:
	var layout_scale := float(metrics["layout_scale"])
	var left_safe_edge := float(metrics["left_zone_x"])
	var top_safe_edge := maxf(
		70.0,
		float(metrics["top_interaction_clearance"])
			+ clampf(8.0 * layout_scale, 6.0, 10.0),
	)
	var bottom_safe_edge := (
		float(metrics["height"])
		- clampf(18.0 * layout_scale, 14.0, 20.0)
	)
	var right_safe_edge := float(metrics["stadium_x"]) - clampf(
		14.0 * layout_scale,
		11.0,
		16.0,
	)
	var stadium := zones.get("stadium") as ZoneView
	if stadium:
		var stadium_bounds := _visual_rect_in_control(
			stadium,
			Rect2(Vector2.ZERO, stadium.size).grow(4.0),
			board_canvas,
		)
		right_safe_edge = stadium_bounds.position.x - clampf(
			10.0 * layout_scale,
			8.0,
			12.0,
		)
	for key in ["opponent_prizes", "own_prizes"]:
		var prize_stack := zones.get(key) as ZoneView
		if prize_stack == null:
			continue
		# The root already spans the six-card fan. Transform all capacity corners so
		# its subtle table rotation is included in the safe-area calculation.
		var visual_bounds := _visual_rect_in_control(
			prize_stack,
			prize_stack.get_stack_visual_max_rect().grow(6.0),
			board_canvas,
		)
		var minimum_shift := Vector2(
			left_safe_edge - visual_bounds.position.x,
			top_safe_edge - visual_bounds.position.y,
		)
		var maximum_shift := Vector2(
			right_safe_edge - visual_bounds.end.x,
			bottom_safe_edge - visual_bounds.end.y,
		)
		var safe_shift := Vector2(
			(
				clampf(0.0, minimum_shift.x, maximum_shift.x)
				if minimum_shift.x <= maximum_shift.x
				else (minimum_shift.x + maximum_shift.x) * 0.5
			),
			(
				clampf(0.0, minimum_shift.y, maximum_shift.y)
				if minimum_shift.y <= maximum_shift.y
				else (minimum_shift.y + maximum_shift.y) * 0.5
			),
		)
		prize_stack.position += safe_shift


func _visual_rect_in_control(
	control: Control,
	local_rect: Rect2,
	target: CanvasItem,
) -> Rect2:
	if control == null or target == null:
		return Rect2()
	var transform_to_target := (
		target.get_global_transform_with_canvas().affine_inverse()
		* control.get_global_transform_with_canvas()
	)
	var points := PackedVector2Array([
		transform_to_target * local_rect.position,
		transform_to_target * Vector2(local_rect.end.x, local_rect.position.y),
		transform_to_target * local_rect.end,
		transform_to_target * Vector2(local_rect.position.x, local_rect.end.y),
	])
	var minimum := points[0]
	var maximum := points[0]
	for point in points:
		minimum = minimum.min(point)
		maximum = maximum.max(point)
	return Rect2(minimum, maximum - minimum)


func _layout_pile_docks(metrics: Dictionary) -> void:
	if playmat == null:
		return
	var guides: Array[Dictionary] = []
	var layout_scale := float(metrics["layout_scale"])
	var horizontal_padding := clampf(4.8 * layout_scale, 4.0, 5.5)
	var vertical_padding := clampf(7.5 * layout_scale, 6.0, 9.0)
	var pile_gap := float(metrics["pile_gap"])
	var outer_right := float(metrics["command_dock_left"]) - float(metrics["zone_gap"])
	var right_safe_edge := (
		float(metrics["command_dock_left"])
		- clampf(10.0 * layout_scale, 8.0, 12.0)
	)
	var top_safe_edge := maxf(
		70.0,
		float(metrics["top_interaction_clearance"])
			+ clampf(8.0 * layout_scale, 6.0, 10.0),
	)
	var bottom_safe_edge := (
		float(metrics["height"])
		- clampf(18.0 * layout_scale, 14.0, 20.0)
	)
	for row in [
		{"prefix": "opponent", "side": "opponent"},
		{"prefix": "own", "side": "own"},
	]:
		var prefix := str(row["prefix"])
		var deck := zones.get("%s_deck" % prefix) as ZoneView
		var discard := zones.get("%s_discard" % prefix) as ZoneView
		if deck == null or discard == null:
			continue
		# Anchor the rendered card size, not only the planner's base size, to the
		# command-dock clearance. Near-side perspective therefore cannot consume
		# the reserved gap on wide or compact screens.
		discard.position.x = outer_right - discard.size.x
		deck.position.x = discard.position.x - deck.size.x - pile_gap
		# Top cards no longer overlap; matching Z lets the later discard sibling
		# naturally cover only any decorative paper edge that reaches the gap.
		deck.z_index = discard.z_index
		# Use transformed AABBs for both the top-card recess and full paper stack.
		# ZoneView carries a subtle perspective rotation and draws shadows outside
		# its raw rect, so position/size merging alone clips the lower-left depth.
		var deck_rect := _visual_rect_in_control(
			deck,
			deck.get_stack_face_rect().grow(2.5),
			board_canvas,
		)
		var discard_rect := _visual_rect_in_control(
			discard,
			discard.get_stack_face_rect().grow(2.5),
			board_canvas,
		)
		var deck_visual := _visual_rect_in_control(
			deck,
			deck.get_stack_visual_max_rect().grow(6.0),
			board_canvas,
		)
		var discard_visual := _visual_rect_in_control(
			discard,
			discard.get_stack_visual_max_rect().grow(6.0),
			board_canvas,
		)
		var visual_bounds := deck_visual.merge(discard_visual)
		var dock_rect := Rect2(
			visual_bounds.position - Vector2(horizontal_padding, vertical_padding),
			visual_bounds.size + Vector2(horizontal_padding, vertical_padding) * 2.0,
		)
		var safe_shift := Vector2.ZERO
		if dock_rect.end.x > right_safe_edge:
			safe_shift.x = right_safe_edge - dock_rect.end.x
		if prefix == "own" and dock_rect.end.y > bottom_safe_edge:
			safe_shift.y = bottom_safe_edge - dock_rect.end.y
		elif prefix == "opponent" and dock_rect.position.y < top_safe_edge:
			safe_shift.y = top_safe_edge - dock_rect.position.y
		if not safe_shift.is_zero_approx():
			deck.position += safe_shift
			discard.position += safe_shift
			deck_rect.position += safe_shift
			discard_rect.position += safe_shift
			dock_rect.position += safe_shift
		guides.append({
			"rect": dock_rect,
			"deck_rect": deck_rect,
			"discard_rect": discard_rect,
			"side": str(row["side"]),
			"depth": (deck.table_depth + discard.table_depth) * 0.5,
		})
	playmat.set_pile_guides(guides)


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
	return BattleTableLayout.perspective_card_rect(center, base_size, metrics)


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
	return BattleTableLayout.union_rects(rects)


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
	var zone := zones.get(key) as ZoneView
	if zone and zone.stack_visual_mode == "prizes":
		# Keep the card face at the perspective size while the ZoneView root grows
		# to the six-card capacity, making the complete visible fan interactive.
		zone.set_stack_card_size(size_value)


func _perspective_depth(y: float, metrics: Dictionary) -> float:
	return BattleTableLayout.perspective_depth(y, metrics)


func _layout_overlay_drawers() -> void:
	if hud:
		var overlay_width := maxf(504.0, hud.get_combined_minimum_size().x)
		var overlay_height := maxf(400.0, size.y - 80.0)
		hud.position = Vector2(
			maxf(
				0.0,
				size.x - overlay_width - BattlePhaseHud.DOCK_RIGHT_MARGIN,
			),
			68.0,
		)
		hud.size = Vector2(overlay_width, overlay_height)
	if detail_panel and detail_panel.visible:
		_layout_detail_panel()
	if action_popover and action_popover.visible:
		_reposition_action_popover()


func _on_log_drawer_toggled(is_open: bool) -> void:
	if is_open and action_popover and action_popover.visible:
		action_popover.dismiss()
	# BattlePhaseHud completes its own drawer layout after emitting the signal.
	# Reflow transient side surfaces on the following frame using final geometry.
	call_deferred("_layout_overlay_drawers")


func _layout_detail_panel() -> void:
	if detail_panel == null or board_panel == null:
		return
	var inverse := get_global_transform_with_canvas().affine_inverse()
	var board_global_rect := board_panel.get_global_rect()
	var board_start := inverse * board_global_rect.position
	var board_end := inverse * board_global_rect.end
	var board_rect := Rect2(board_start, board_end - board_start)
	var inset := 12.0
	var safe_rect := Rect2(
		board_rect.position + Vector2(inset, inset),
		board_rect.size - Vector2(inset * 2.0, inset * 2.0),
	)
	if safe_rect.size.x <= 1.0 or safe_rect.size.y <= 1.0:
		return

	# The detail surface owns the fixed left corridor between both six-card prize
	# rows. Capacity bounds keep this position stable as prizes are taken. The
	# panel's shadow halo participates in every bound, so the rendered surface—not
	# merely its Control rectangle—stays clear of prizes and Stadium.
	var detail_halo := 10.0
	var corridor_top := safe_rect.position.y
	var corridor_bottom := safe_rect.end.y
	var prize_gap := 10.0
	var opponent_prizes := zones.get("opponent_prizes") as ZoneView
	if opponent_prizes:
		var opponent_bounds := _visual_rect_in_control(
			opponent_prizes,
			opponent_prizes.get_stack_visual_max_rect().grow(6.0),
			self,
		)
		corridor_top = maxf(
			corridor_top,
			opponent_bounds.end.y + prize_gap + detail_halo,
		)
	var own_prizes := zones.get("own_prizes") as ZoneView
	if own_prizes:
		var own_bounds := _visual_rect_in_control(
			own_prizes,
			own_prizes.get_stack_visual_max_rect().grow(6.0),
			self,
		)
		corridor_bottom = minf(
			corridor_bottom,
			own_bounds.position.y - prize_gap - detail_halo,
		)

	var minimum_fixed_x := safe_rect.position.x + detail_halo
	var maximum_detail_right := safe_rect.end.x - detail_halo
	var stadium := zones.get("stadium") as ZoneView
	if stadium:
		var stadium_bounds := _visual_rect_in_control(
			stadium,
			Rect2(Vector2.ZERO, stadium.size).grow(4.0),
			self,
		)
		maximum_detail_right = minf(
			maximum_detail_right,
			stadium_bounds.position.x - 8.0 - detail_halo,
		)

	var available_width := maxf(1.0, maximum_detail_right - minimum_fixed_x)
	var available_height := maxf(1.0, corridor_bottom - corridor_top)
	var component := detail_panel as BattleDetailPanel
	if component:
		component.set_compact_layout(
			available_width < BattleDetailPanel.NORMAL_PANEL_SIZE.x
			or available_height < BattleDetailPanel.NORMAL_PANEL_SIZE.y
		)
	var base_panel_size := (
		component.layout_size()
		if component
		else detail_panel.get_combined_minimum_size()
	)
	if base_panel_size.x <= 1.0 or base_panel_size.y <= 1.0:
		base_panel_size = BattleDetailPanel.NORMAL_PANEL_SIZE
	var panel_scale := minf(
		1.0,
		minf(
			available_width / base_panel_size.x,
			available_height / base_panel_size.y,
		),
	)
	panel_scale = maxf(0.1, panel_scale)
	var panel_size := base_panel_size * panel_scale
	detail_panel.pivot_offset = Vector2.ZERO
	detail_panel.scale = Vector2.ONE * panel_scale

	var maximum_fixed_x := maximum_detail_right - panel_size.x
	var fixed_x := clampf(
		minimum_fixed_x,
		minimum_fixed_x,
		maxf(minimum_fixed_x, maximum_fixed_x),
	)
	var corridor_height := maxf(0.0, corridor_bottom - corridor_top)
	var fixed_y := roundf(
		corridor_top + (corridor_height - panel_size.y) * 0.5
	)
	fixed_y = clampf(
		fixed_y,
		corridor_top,
		maxf(corridor_top, corridor_bottom - panel_size.y),
	)
	detail_panel.position = Vector2(fixed_x, fixed_y)
	detail_panel.size = base_panel_size


func _layout_hand(card_size: Vector2 = Vector2(96, 135)) -> void:
	if hand_surface == null:
		return
	# Control hit testing follows sibling order more strictly than CanvasItem Z on
	# touch-emulated mouse events. Restore the canonical order first, then move the
	# selected source to the end so its lifted, visible face is also the hit target.
	for canonical_index in range(hand_views.size()):
		var canonical_view := hand_views[canonical_index]
		if (
			canonical_view.get_parent() == hand_surface
			and canonical_view.get_index() != canonical_index
		):
			hand_surface.move_child(canonical_view, canonical_index)
	var visible_count := 0
	for view in hand_views:
		if _hand_view_participates_in_layout(view):
			visible_count += 1
	var plan := BattleTableLayout.own_hand_plan(
		visible_count,
		hand_scroll.size.x,
		card_size,
		hand_minimum_spacing,
		hand_rotation_degrees,
	)
	hand_surface.custom_minimum_size.x = float(plan["surface_width"])
	var items: Array[Dictionary] = plan["items"]
	var visible_index := 0
	var selected_hand_view: CardView
	for view in hand_views:
		if not _hand_view_participates_in_layout(view):
			continue
		var item: Dictionary = items[visible_index]
		view.custom_minimum_size = card_size
		view.size = card_size
		view.position = item["position"]
		view.rotation_degrees = float(item["rotation_degrees"])
		var is_selected := selected_entity_key == "hand:%d" % view.hand_index
		# A selected card must remain the top hand hit target even in a tightly
		# overlapped fan. Keep the whole hand below the HUD/popover overlay layers.
		view.z_index = (
			SELECTED_HAND_CARD_Z
			if is_selected
			else mini(HAND_CARD_MAX_Z, int(item["z_index"]))
		)
		view.set_table_depth(0.96, true)
		view.remember_base_position()
		view.set_selected(is_selected)
		if is_selected:
			selected_hand_view = view
		visible_index += 1
	if (
		selected_hand_view
		and selected_hand_view.get_index() != hand_surface.get_child_count() - 1
	):
		hand_surface.move_child(
			selected_hand_view,
			maxi(0, hand_surface.get_child_count() - 1),
		)


func _on_card_hovered_changed(hovered: bool, view: CardView) -> void:
	if view == null or not is_instance_valid(view) or view.hand_index < 0:
		return
	if hovered:
		view.z_index = (
			SELECTED_HAND_CARD_Z
			if selected_entity_key == "hand:%d" % view.hand_index
			else HOVERED_HAND_CARD_Z
		)
		return
	# Recompute the base fan depth instead of restoring a cached number: cards
	# may have reflowed while the pointer remained over this anchor.
	var layout_views: Array[CardView] = []
	for candidate in hand_views:
		if _hand_view_participates_in_layout(candidate):
			layout_views.append(candidate)
	var layout_index := layout_views.find(view)
	if layout_index < 0:
		return
	if selected_entity_key == "hand:%d" % view.hand_index:
		view.z_index = SELECTED_HAND_CARD_Z
	else:
		view.z_index = mini(HAND_CARD_MAX_Z, 70 + layout_index)


func _snap_staged_hand_layout(card_size: Vector2) -> void:
	var visible_views: Array[CardView] = []
	for view in hand_views:
		if view != null and view.visible:
			visible_views.append(view)
	if visible_views.is_empty():
		return
	var stage_count := maxi(0, _presentation_hand_stage_count)
	var final_count := visible_views.size()
	var stage_plan := BattleTableLayout.own_hand_plan(
		stage_count,
		hand_scroll.size.x,
		card_size,
		hand_minimum_spacing,
		hand_rotation_degrees,
	)
	var final_plan := BattleTableLayout.own_hand_plan(
		final_count,
		hand_scroll.size.x,
		card_size,
		hand_minimum_spacing,
		hand_rotation_degrees,
	)
	hand_surface.custom_minimum_size.x = float(stage_plan["surface_width"])
	var stage_items: Array[Dictionary] = stage_plan["items"]
	var final_items: Array[Dictionary] = final_plan["items"]
	var snapshot_hand: Array = _presentation_snapshot.get("hand", [])
	var used_snapshot_rows: Dictionary = {}
	for index in range(visible_views.size()):
		var view := visible_views[index]
		var item: Dictionary
		if stage_count > final_count:
			var snapshot_index := _snapshot_hand_index_for_view(
				view,
				snapshot_hand,
				used_snapshot_rows,
			)
			item = (
				stage_items[snapshot_index]
				if snapshot_index >= 0 and snapshot_index < stage_items.size()
				else final_items[index]
			)
		elif index < stage_count and index < stage_items.size():
			item = stage_items[index]
		else:
			# Incoming anchors remain hidden at their eventual landing endpoints;
			# existing cards still use the smaller staged fan until contact.
			item = final_items[index]
		view.custom_minimum_size = card_size
		view.size = card_size
		view.position = item["position"]
		view.rotation_degrees = float(item["rotation_degrees"])
		view.z_index = mini(HAND_CARD_MAX_Z, int(item["z_index"]))
		view.set_table_depth(0.96, true)
		view.remember_base_position()


func _snapshot_hand_index_for_view(
	view: CardView,
	snapshot_hand: Array,
	used_rows: Dictionary,
) -> int:
	if view == null:
		return -1
	if not view.local_visual_id.is_empty():
		for index in range(snapshot_hand.size()):
			if used_rows.has(index):
				continue
			var row := snapshot_hand[index] as Dictionary
			if str(row.get("visual_id", "")) == view.local_visual_id:
				used_rows[index] = true
				return index
	for index in range(snapshot_hand.size()):
		if used_rows.has(index):
			continue
		var row := snapshot_hand[index] as Dictionary
		if str(row.get("card_id", "")) == view.card_id:
			used_rows[index] = true
			return index
	return -1


func _hand_view_participates_in_layout(view: CardView) -> bool:
	if view == null or not view.visible:
		return false
	if _drag_session == null or _drag_session.source_view != view:
		return true
	return _drag_session.state in [
		CARD_DRAG_SESSION.CANDIDATE,
		CARD_DRAG_SESSION.RETURNING,
		CARD_DRAG_SESSION.CANCELLED,
	]


func _current_hand_card_size() -> Vector2:
	if board_canvas == null or board_canvas.size.x <= 0.0 or board_canvas.size.y <= 0.0:
		return hand_card_size
	var metrics := _board_layout_metrics(board_canvas.size.x, board_canvas.size.y)
	var value: Variant = metrics.get("own_hand_size", hand_card_size)
	return value if value is Vector2 else hand_card_size


func _current_opponent_hand_card_size() -> Vector2:
	if board_canvas == null or board_canvas.size.x <= 0.0 or board_canvas.size.y <= 0.0:
		return opponent_hand_card_size
	var metrics := _board_layout_metrics(board_canvas.size.x, board_canvas.size.y)
	var value: Variant = metrics.get("hidden_hand_size", opponent_hand_card_size)
	return value if value is Vector2 else opponent_hand_card_size


func _layout_opponent_hand(card_size: Vector2 = Vector2(70, 98)) -> void:
	if opponent_hand_surface == null:
		return
	var visible_count := 0
	for view in opponent_hand_views:
		if view.visible:
			visible_count += 1
	var plan := BattleTableLayout.opponent_hand_plan(
		visible_count,
		opponent_hand_surface.size.x,
		card_size,
		opponent_hand_minimum_spacing,
		opponent_hand_rotation_degrees,
	)
	var items: Array[Dictionary] = plan["items"]
	var visible_index := 0
	for view in opponent_hand_views:
		if not view.visible:
			continue
		var item: Dictionary = items[visible_index]
		view.custom_minimum_size = card_size
		view.size = card_size
		view.position = item["position"]
		view.rotation_degrees = float(item["rotation_degrees"])
		view.z_index = int(item["z_index"])
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
		"PLAY_BASIC":
			result["label"] = "放置到场上"
		"EVOLVE":
			result["label"] = "进化"
		"ATTACH_ENERGY":
			result["label"] = "附能"
		"PLAY_TRAINER":
			var trainer_type := _trainer_type_for_action(action)
			result["label"] = (
				"打出竞技场"
				if trainer_type == "Stadium"
				else "附着道具"
				if trainer_type in ["Tool", "Pokémon Tool"]
				else "使用"
			)
		"DECLARE_ATTACK":
			result.merge(_attack_popover_metadata(action, row), true)
		"USE_ABILITY":
			result["label"] = "特性 · %s（可用）" % str(
				action.params.get("ability_name", "发动特性"),
			)
			result["hint"] = "发动特性"
		"RETREAT":
			result["label"] = "撤退到这里 · %s" % _retreat_compact_suffix(action)
		"PROMOTE":
			result["label"] = "晋升为战斗宝可梦"
		"USE_STADIUM":
			result["label"] = "发动效果"
	return result


func _trainer_type_for_action(action: GameAction) -> String:
	if action == null or state_ref == null:
		return ""
	var hand_index := int(action.params.get("hand_idx", -1))
	if hand_index < 0 or action.actor not in [0, 1]:
		return ""
	var hand := state_ref.get_player(action.actor).hand
	if hand_index >= hand.size():
		return ""
	var card_id := str(hand[hand_index])
	if catalog.is_stadium(card_id):
		return "Stadium"
	if catalog.is_tool(card_id):
		return "Tool"
	if catalog.is_supporter(card_id):
		return "Supporter"
	if catalog.is_item(card_id):
		return "Item"
	return str(catalog.get_card(card_id).get("trainer_type", ""))


func _attack_popover_metadata(action: GameAction, row: Dictionary) -> Dictionary:
	var fallback := str(row.get("label", "攻击")).trim_prefix("攻击 · ")
	var result := {
		"label": fallback,
		"hint": "攻击后结束回合",
	}
	if state_ref == null or action.actor not in [0, 1]:
		return result
	var active := state_ref.get_player(action.actor).active
	if active == null:
		return result
	var attacks: Array = catalog.get_card(active.card_id).get("attacks", [])
	var attack_index := int(action.params.get("attack_idx", -1))
	if attack_index < 0 or attack_index >= attacks.size():
		return result
	var attack: Dictionary = attacks[attack_index]
	var cost_labels: Array[String] = []
	var attack_cost: Array = attack.get("cost", [])
	for value in attack_cost:
		cost_labels.append({
			"Grass": "草", "Fire": "火", "Water": "水", "Lightning": "雷",
			"Psychic": "超", "Fighting": "斗", "Darkness": "恶",
			"Metal": "钢", "Colorless": "无",
		}.get(str(value), str(value).left(1)))
	var name := str(attack.get("name", fallback))
	var damage := str(attack.get("damage_text", ""))
	if damage.is_empty() and int(attack.get("damage", 0)) > 0:
		damage = str(attack.get("damage", 0))
	result["label"] = "%s%s%s\n攻击后结束回合" % [
		("[%s] " % "".join(cost_labels)) if not cost_labels.is_empty() else "",
		name,
		(" · %s" % damage) if not damage.is_empty() else "",
	]
	if not attack_cost.is_empty():
		result["icon"] = ENERGY_ICONS.texture_for(str(attack_cost[0]))
	return result


func _retreat_compact_suffix(action: GameAction) -> String:
	if action == null:
		return "免费"
	var indices: Array = action.params.get("energy_indices", [])
	if indices.is_empty():
		return "免费"
	var names: Array[String] = []
	if state_ref and action.actor in [0, 1]:
		var active := state_ref.get_player(action.actor).active
		if active:
			for raw_index in indices:
				var index := int(raw_index)
				if index >= 0 and index < active.energy_card_ids.size():
					var name := catalog.card_name(active.energy_card_ids[index])
					names.append(name)
	if names.is_empty():
		return "丢%d能量" % indices.size()
	return "丢%s" % "、".join(names)


func _refresh_turn_allowance_chips(player: PlayerState) -> void:
	if player == null or own_allowance_labels.is_empty():
		return
	var rows := {
		"energy": ["附能", player.energy_attached_this_turn],
		"supporter": ["支援", player.supporter_played_this_turn],
		"retreat": ["撤退", player.retreated_this_turn],
		"stadium": ["竞技场", player.stadium_played_this_turn],
	}
	for key_value in rows.keys():
		var key := str(key_value)
		var row: Array = rows[key]
		var used := bool(row[1])
		var allowance_label := own_allowance_labels.get(key) as Label
		if allowance_label == null:
			continue
		allowance_label.text = "%s  %s" % [str(row[0]), "已用" if used else "可用"]
		allowance_label.add_theme_stylebox_override(
			"normal",
			_allowance_chip_style(used),
		)
		allowance_label.add_theme_color_override(
			"font_color",
			Color(0.52, 0.60, 0.70, 0.86) if used else DesignTokens.GREEN,
		)


func _allowance_chip_style(used: bool) -> StyleBoxFlat:
	return DesignTokens.panel_style(
		Color(0.025, 0.040, 0.060, 0.90) if used else Color(0.025, 0.105, 0.090, 0.94),
		7,
		Color(0.25, 0.34, 0.45, 0.62) if used else Color(0.36, 0.78, 0.58, 0.78),
		1,
		5,
	)


func _layout_own_status(metrics: Dictionary, field_plan: Dictionary) -> void:
	if own_info == null or own_allowance_row == null:
		return
	var stadium_rect := Rect2()
	var stadium := zones.get("stadium") as ZoneView
	if stadium:
		stadium_rect = _visual_rect_in_control(
			stadium,
			Rect2(Vector2.ZERO, stadium.size).grow(4.0),
			board_canvas,
		)
	var status_height := 48.0 if float(metrics["height"]) < 600.0 else 56.0
	var status_plan := BattleTableLayout.own_status_plan(
		metrics,
		field_plan["own_active_rect"],
		Vector2(304.0, status_height),
		stadium_rect,
	)
	var info_rect: Rect2 = status_plan["info_rect"]
	var allowance_rect: Rect2 = status_plan["allowance_rect"]
	own_info.position = info_rect.position
	own_info.size = info_rect.size
	own_allowance_row.position = allowance_rect.position
	own_allowance_row.size = allowance_rect.size
	var compact_status := allowance_rect.size.x < 300.0
	var separation := 3 if compact_status else 6
	own_allowance_row.add_theme_constant_override("separation", separation)
	own_info.add_theme_font_size_override("font_size", 11 if compact_status else 12)
	var compact_unit := maxf(
		1.0,
		(allowance_rect.size.x - float(separation * 3)) / 4.2,
	)
	for key in ["energy", "supporter", "retreat", "stadium"]:
		var label := own_allowance_labels.get(key) as Label
		if label == null:
			continue
		label.add_theme_font_size_override("font_size", 10 if compact_status else 12)
		label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		if compact_status:
			label.custom_minimum_size.x = compact_unit * (1.2 if key == "stadium" else 1.0)
		else:
			label.custom_minimum_size.x = 82.0 if key == "stadium" else 68.0


func _routed_action_rows() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for value in action_rows:
		var row := value.duplicate()
		var action := row.get("action") as GameAction
		# Playing a Stadium is a no-target action on the rules layer, but the UI
		# also accepts the same action when that hand card is dragged onto the
		# Stadium zone. This metadata never enters GameAction serialization.
		if action and action.action == "PLAY_TRAINER" and _trainer_type_for_action(action) == "Stadium":
			row["drag_target_keys"] = ["stadium"]
		result.append(row)
	return result


func _action_rows_semantic_signature(rows: Array[Dictionary]) -> String:
	var result: Array[String] = []
	for input_row in rows:
		var row := input_row as Dictionary
		var action_value = row.get("action")
		var action := action_value as GameAction
		if action == null and action_value is Dictionary:
			action = GameAction.from_dict(action_value as Dictionary)
		var parts: Array[String] = [
			_action_semantic_signature(action),
			str(row.get("label", "")),
			str(row.get("hint", "")),
			str(row.get("source_key", "")),
			str(row.get("target_key", "")),
			str(row.get("group_key", "")),
			_stable_value_signature(row.get("target_keys", [])),
			_stable_value_signature(row.get("drag_target_keys", [])),
			str(bool(row.get("disabled", false))),
		]
		result.append("|".join(parts))
	return "\n".join(result)


func _action_semantic_signature(action: GameAction) -> String:
	if action == null:
		return ""
	return _stable_value_signature(action.to_dict())


func _stable_value_signature(value: Variant) -> String:
	if value is Dictionary:
		var dictionary := value as Dictionary
		var keys: Array = dictionary.keys()
		keys.sort_custom(func(left: Variant, right: Variant) -> bool:
			return str(left) < str(right)
		)
		var parts: Array[String] = []
		for key in keys:
			parts.append("%s:%s" % [
				str(key),
				_stable_value_signature(dictionary[key]),
			])
		return "{" + ",".join(parts) + "}"
	if value is Array:
		var parts: Array[String] = []
		for item in value:
			parts.append(_stable_value_signature(item))
		return "[" + ",".join(parts) + "]"
	return str(value)


func _current_task_hint() -> String:
	if not choice_target_options.is_empty():
		return choice_target_prompt if not choice_target_prompt.is_empty() else "选择场上的卡牌"
	if selected_entity_key.is_empty():
		return ""
	if (
		_popover_dismissed_source_key == selected_entity_key
		and _selected_action_group_key.is_empty()
	):
		return "再次点击卡牌取消选择"
	var groups := interaction_router.action_groups_for_source(selected_entity_key)
	if groups.is_empty():
		return _disabled_reason_for_source(selected_entity_key)
	if not _selected_action_group_key.is_empty():
		var selected_group := _group_by_key(groups, _selected_action_group_key)
		var rows: Array = selected_group.get("rows", [])
		if not rows.is_empty():
			var action := (rows[0] as Dictionary).get("action") as GameAction
			return "选择%s目标" % _target_hint_for_action(action)
	if groups.size() > 1:
		return "选择一个卡牌动作"
	var only_group: Dictionary = groups[0]
	if bool(only_group.get("requires_target", false)):
		var rows: Array = only_group.get("rows", [])
		if not rows.is_empty():
			var action := (rows[0] as Dictionary).get("action") as GameAction
			return "选择%s目标" % _target_hint_for_action(action)
	return "确认要执行的卡牌动作"


func _disabled_reason_for_source(source_key: String) -> String:
	if state_ref == null:
		return "正在载入对局状态"
	if ai_thinking:
		return "等待对手行动"
	if state_ref.phase not in ["SETUP", "MAIN"]:
		return "当前阶段不能执行卡牌动作"
	if state_ref.phase != "SETUP" and state_ref.active_player_idx != view_player:
		return "现在是对手的回合"
	var player := state_ref.get_player(view_player)
	if source_key.begins_with("hand:"):
		var hand_index := source_key.trim_prefix("hand:").to_int()
		if hand_index < 0 or hand_index >= player.hand.size():
			return "这张卡已不在手牌中"
		var card := catalog.get_card(player.hand[hand_index])
		var supertype := str(card.get("supertype", ""))
		var card_id := str(player.hand[hand_index])
		var trainer_type := (
			"Stadium"
			if catalog.is_stadium(card_id)
			else "Tool"
			if catalog.is_tool(card_id)
			else "Supporter"
			if catalog.is_supporter(card_id)
			else str(card.get("trainer_type", ""))
		)
		var subtypes: Array = card.get("subtypes", [])
		if supertype == "Energy" and player.energy_attached_this_turn:
			return "本回合已附能"
		if supertype == "Energy":
			return "当前没有可附能的宝可梦"
		if trainer_type == "Supporter" and player.supporter_played_this_turn:
			return "本回合已使用支援者"
		if trainer_type == "Stadium" and player.stadium_played_this_turn:
			return "本回合已打出竞技场"
		if (
			trainer_type == "Stadium"
			and state_ref.stadium_card_id == player.hand[hand_index]
		):
			return "场上已经是同名竞技场"
		if trainer_type in ["Tool", "Pokémon Tool"]:
			return "没有可附着道具的宝可梦，或目标已有道具"
		if "Basic" in subtypes:
			return "战斗区与备战区没有合法空位"
		if "Stage 1" in subtypes or "Stage 2" in subtypes:
			return "场上没有可进化为这张卡的宝可梦"
		if state_ref.phase == "SETUP":
			return "准备阶段只能放置基础宝可梦"
		return "当前没有合法目标或不满足使用条件"
	if source_key.begins_with("pokemon:"):
		var parts := source_key.split(":")
		if parts.size() >= 3 and int(parts[1]) != view_player:
			return "对手的卡牌不能由你操作"
		if parts.size() >= 3 and str(parts[2]) == "active" and player.retreated_this_turn:
			return "本回合已撤退"
		return "当前没有可用招式、特性或撤退动作"
	if source_key == "stadium":
		return "该竞技场没有可主动发动的效果"
	return "当前没有合法卡牌动作"


func _rows_for_active_selection() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if selected_entity_key.is_empty():
		return result
	var groups := interaction_router.action_groups_for_source(selected_entity_key)
	if groups.is_empty():
		return result
	if not _selected_action_group_key.is_empty():
		var selected_group := _group_by_key(groups, _selected_action_group_key)
		for value in selected_group.get("rows", []):
			result.append(value as Dictionary)
		return result
	if groups.size() == 1:
		for value in (groups[0] as Dictionary).get("rows", []):
			result.append(value as Dictionary)
	return result


func _matching_active_selection_rows(target_key: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for row in _rows_for_active_selection():
		var action := row.get("action") as GameAction
		if action and target_key in CardInteractionRouter.target_keys_for_action(action, row):
			result.append(row)
	return result


func _group_by_key(groups: Array[Dictionary], group_key: String) -> Dictionary:
	for group in groups:
		if str(group.get("key", "")) == group_key:
			return group
	return {}


func _group_for_action(source_key: String, action: GameAction) -> Dictionary:
	for group in interaction_router.action_groups_for_source(source_key):
		for candidate_value in group.get("actions", []):
			if candidate_value == action:
				return group
	return {}


func _target_hint_for_action(action: GameAction) -> String:
	if action == null:
		return "选择"
	match action.action:
		"PLAY_BASIC":
			return "放置"
		"EVOLVE":
			return "进化"
		"ATTACH_ENERGY":
			return "附能"
		"RETREAT":
			return "撤退"
		"PLAY_TRAINER":
			var hand_index := int(action.params.get("hand_idx", -1))
			if state_ref and hand_index >= 0:
				var hand := state_ref.get_player(action.actor).hand
				if hand_index < hand.size():
					if catalog.is_tool(str(hand[hand_index])):
						return "道具"
			return "使用"
		_:
			return "选择"


func _refresh_action_popover() -> void:
	if action_popover == null:
		return
	if selected_entity_key.is_empty():
		action_popover.dismiss(false)
		_popover_source_key = ""
		return
	if _popover_dismissed_source_key == selected_entity_key:
		action_popover.dismiss(false)
		return
	if not _forced_popover_rows.is_empty():
		_present_popover_rows(_forced_popover_source_key, _forced_popover_rows)
		return
	var groups := interaction_router.action_groups_for_source(selected_entity_key)
	var contextual_disabled_rows := _disabled_context_rows_for_source(selected_entity_key)
	if groups.is_empty():
		_present_popover_rows(
			selected_entity_key,
			contextual_disabled_rows,
			"无法操作",
			_disabled_reason_for_source(selected_entity_key),
		)
		return
	if not _selected_action_group_key.is_empty():
		action_popover.dismiss(false)
		return
	if (
		groups.size() == 1
		and bool(groups[0].get("requires_target", false))
	):
		# Disabled informational rows (for example, an ability already used this
		# turn) do not turn a single targeted action into a multi-action choice.
		# Keep the one-tap contract and enter target selection immediately.
		action_popover.dismiss(false)
		return
	var popover_rows := _popover_rows_for_groups(groups)
	popover_rows.append_array(contextual_disabled_rows)
	_present_popover_rows(
		selected_entity_key,
		popover_rows,
	)


func _popover_rows_for_groups(groups: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if groups.size() == 1:
		for row_value in groups[0].get("rows", []):
			result.append(_compact_card_action_row(row_value as Dictionary))
		return result
	for group in groups:
		var rows: Array = group.get("rows", [])
		if rows.is_empty():
			continue
		var row := _compact_card_action_row(rows[0] as Dictionary)
		if str(group.get("action_type", "")) == "RETREAT":
			# This button chooses the retreat action family, not a particular
			# benched Pokemon or payment. Show those details only after the target
			# card has been chosen and the concrete rows are presented.
			row["label"] = "撤退"
			row["hint"] = "选择备战宝可梦"
		elif bool(group.get("requires_target", false)):
			row["hint"] = "选择合法目标"
		result.append(row)
	return result


func _disabled_context_rows_for_source(source_key: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if state_ref == null or not source_key.begins_with("pokemon:"):
		return result
	var parts := source_key.split(":")
	if parts.size() < 3:
		return result
	var pokemon := state_ref.get_player(int(parts[1])).get_pokemon(str(parts[2]))
	if pokemon == null or pokemon.used_abilities.is_empty():
		return result
	var legal_abilities: Dictionary = {}
	for action in interaction_router.actions_for_source(source_key):
		if action.action == "USE_ABILITY":
			legal_abilities[str(action.params.get("ability_name", ""))] = true
	for ability_value in catalog.get_card(pokemon.card_id).get("abilities", []):
		var ability: Dictionary = ability_value
		var ability_name := str(ability.get("name", ""))
		if ability_name in pokemon.used_abilities and not legal_abilities.has(ability_name):
			result.append({
				"label": "特性 · %s（已使用）" % ability_name,
				"hint": "本回合已发动",
				"disabled": true,
			})
	return result


func _present_popover_rows(
	source_key: String,
	rows: Array[Dictionary],
	title := "卡牌操作",
	hint := "",
) -> void:
	if action_popover == null:
		return
	var source_control := _source_control_for_key(source_key)
	if source_control == null:
		action_popover.dismiss(false)
		return
	var display_rows: Array[Dictionary] = []
	for row in rows:
		display_rows.append(_compact_card_action_row(row))
	var avoidance_rows := rows
	if _forced_popover_source_key != source_key:
		avoidance_rows = interaction_router.rows_for_source(source_key)
	_popover_source_key = source_key
	action_popover.show_for_control(
		display_rows,
		source_control,
		_safe_popover_rect(),
		_avoid_controls_for_rows(avoidance_rows),
		title,
		hint,
	)


func _source_control_for_key(source_key: String) -> Control:
	if source_key.begins_with("hand:"):
		var hand_index := source_key.trim_prefix("hand:").to_int()
		if hand_index >= 0 and hand_index < hand_views.size():
			var hand_view := hand_views[hand_index]
			return hand_view if hand_view.visible else null
	if source_key.begins_with("pokemon:"):
		var parts := source_key.split(":")
		if parts.size() >= 3:
			return get_slot_view(int(parts[1]), str(parts[2]))
	if source_key == "stadium":
		return zones.get("stadium") as Control
	return null


func _safe_popover_rect() -> Rect2:
	var inset := Vector2(8.0, 8.0)
	var result := Rect2()
	if board_panel and board_panel.size.x > 16.0 and board_panel.size.y > 16.0:
		result = Rect2(
			board_panel.global_position + inset,
			board_panel.size - inset * 2.0,
		)
	elif size.x > 16.0 and size.y > 16.0:
		result = Rect2(global_position + inset, size - inset * 2.0)
	if result.size.x <= 0.0 or result.size.y <= 0.0:
		return Rect2()
	# The header is deliberately above every table-local overlay so the menu is
	# always reachable. Exclude the same strip from popover placement; otherwise
	# an upper card could put its action panel behind the visible header.
	if header and header.visible:
		var header_bottom := header.get_global_rect().end.y + inset.y
		if header_bottom > result.position.y and header_bottom < result.end.y:
			var result_bottom := result.end.y
			result.position.y = header_bottom
			result.size.y = result_bottom - header_bottom
	return result


func _avoid_controls_for_rows(rows: Array[Dictionary]) -> Array[Control]:
	var result: Array[Control] = []
	var seen: Dictionary = {}
	# Popovers are transient controls, but they should not hide the board objects
	# a player is trying to read. Reserve the fixed HUD edge, occupied zones and
	# visible cards before adding action-specific legal targets below.
	var persistent_controls: Array[Control] = []
	if header:
		persistent_controls.append(header)
	if hud:
		var phase_panel := hud.get_node_or_null("PhasePanel") as Control
		if phase_panel:
			persistent_controls.append(phase_panel)
	if log_panel and log_panel.visible and log_panel.is_visible_in_tree():
		persistent_controls.append(log_panel)
	for zone_value in zones.values():
		var zone := zone_value as ZoneView
		if zone and zone.visible and zone.count > 0:
			persistent_controls.append(zone)
	for hand_view in hand_views:
		if hand_view.visible and not hand_view.empty:
			persistent_controls.append(hand_view)
	for slot_value in slot_views.values():
		var slot_view := slot_value as CardView
		if slot_view and slot_view.visible and not slot_view.empty:
			persistent_controls.append(slot_view)
	for control in persistent_controls:
		if seen.has(control):
			continue
		seen[control] = true
		result.append(control)
	if detail_panel and detail_panel.visible:
		seen[detail_panel] = true
		result.append(detail_panel)
	for row in rows:
		var action := row.get("action") as GameAction
		if action == null:
			continue
		if action.action == "DECLARE_ATTACK" and action.actor in [0, 1]:
			var defending_active := get_slot_view(1 - action.actor, "active")
			if defending_active and not seen.has(defending_active):
				seen[defending_active] = true
				result.append(defending_active)
		for target_key in CardInteractionRouter.target_keys_for_action(action, row):
			var control := _source_control_for_key(target_key)
			if control and not seen.has(control):
				seen[control] = true
				result.append(control)
	return result


func _reposition_action_popover() -> void:
	if action_popover == null or not action_popover.visible:
		return
	var source_control := _source_control_for_key(_popover_source_key)
	if source_control == null:
		action_popover.dismiss(false)
		return
	var avoidance_rows := interaction_router.rows_for_source(_popover_source_key)
	if _forced_popover_source_key == _popover_source_key:
		avoidance_rows = _forced_popover_rows
	action_popover.reposition_for_control(
		source_control,
		_safe_popover_rect(),
		_avoid_controls_for_rows(avoidance_rows),
	)


func _show_forced_action_rows(
	rows: Array[Dictionary],
	source_key: String = selected_entity_key,
) -> void:
	_forced_popover_rows.clear()
	for row in rows:
		_forced_popover_rows.append(_compact_card_action_row(row))
	_forced_popover_source_key = source_key
	_popover_dismissed_source_key = ""
	_present_popover_rows(
		source_key,
		_forced_popover_rows,
		"选择具体动作",
		"同一目标存在多种合法执行方式",
	)


func _on_popover_action_chosen(action: GameAction) -> void:
	if action == null:
		return
	for row in _forced_popover_rows:
		if row.get("action") == action:
			_forced_popover_rows.clear()
			_forced_popover_source_key = ""
			_popover_source_key = ""
			action_requested.emit(action)
			return
	var group := _group_for_action(_popover_source_key, action)
	if not group.is_empty() and bool(group.get("requires_target", false)):
		_selected_action_group_key = str(group.get("key", ""))
		_popover_source_key = ""
		_refresh_target_hints()
		_refresh_header()
		return
	_popover_source_key = ""
	action_requested.emit(action)


func _on_popover_dismissed() -> void:
	var dismissed_forced_source := _forced_popover_source_key
	if not _popover_source_key.is_empty():
		_popover_dismissed_source_key = _popover_source_key
		if _forced_popover_source_key == _popover_source_key:
			_forced_popover_rows.clear()
			_forced_popover_source_key = ""
	_popover_source_key = ""
	_refresh_header()
	if (
		_drag_session != null
		and _drag_session.state == CARD_DRAG_SESSION.AWAITING_VARIANT
		and dismissed_forced_source
		== CardInteractionRouter.hand_key(_drag_session.hand_index)
	):
		_return_drag_session("variant_cancelled")


func _reset_action_interaction_state(dismiss_popover := true) -> void:
	_selected_action_group_key = ""
	_popover_dismissed_source_key = ""
	_popover_source_key = ""
	_forced_popover_rows.clear()
	_forced_popover_source_key = ""
	if dismiss_popover and action_popover and action_popover.visible:
		action_popover.dismiss(false)


func _on_card_activated(
	card_id: String,
	hand_index: int,
	player: int,
	slot_name: String,
) -> void:
	var clicked_key := (
		CardInteractionRouter.hand_key(hand_index)
		if hand_index >= 0
		else CardInteractionRouter.pokemon_key(player, slot_name)
	)
	if not selected_entity_key.is_empty() and clicked_key == selected_entity_key:
		_reset_action_interaction_state()
		selection_clear_requested.emit(clicked_key)
		return
	if choice_target_options.has(clicked_key):
		choice_target_selected.emit(str(choice_target_options[clicked_key]))
		return
	if not selected_entity_key.is_empty() and clicked_key != selected_entity_key:
		var target_rows := _matching_active_selection_rows(clicked_key)
		if target_rows.size() == 1:
			var target_action := target_rows[0].get("action") as GameAction
			if target_action:
				action_requested.emit(target_action)
				return
		elif target_rows.size() > 1:
			_show_forced_action_rows(target_rows)
			return
	if hand_index < 0 and card_id.is_empty():
		return
	if hand_index >= 0:
		hand_card_selected.emit(hand_index, card_id)
	else:
		pokemon_selected.emit(player, slot_name, card_id)


func _on_detail_requested(card_id: String) -> void:
	detail_requested.emit(card_id)
	if not card_id.is_empty():
		inspect_card_requested.emit(_card_inspection_context(card_id))


func _on_card_view_detail_requested(card_id: String, view: CardView) -> void:
	detail_requested.emit(card_id)
	if card_id.is_empty() or view == null:
		return
	var context := _card_inspection_context(card_id)
	context["player"] = view.owner_player
	if view.hand_index >= 0:
		context["location"] = "%s 手牌" % _player_label(view.owner_player)
		context["hand_index"] = view.hand_index
		context["slot"] = ""
		context["pokemon"] = null
	elif not view.slot.is_empty():
		context["slot"] = view.slot
		context["pokemon"] = view.pokemon
		context["location"] = "%s %s" % [
			_player_label(view.owner_player),
			_slot_name(view.slot),
		]
	inspect_card_requested.emit(context)


func _on_menu_pressed() -> void:
	var expected_key := selected_entity_key
	hide_card_detail()
	_reset_action_interaction_state()
	if hud and hud.is_log_drawer_open():
		hud.close_log_drawer()
	selection_clear_requested.emit(expected_key)
	menu_requested.emit()


func _on_zone_inspected(context: Dictionary) -> void:
	if str(context.get("zone", "")) == "stadium" and interaction_router.has_source("stadium"):
		if action_popover and action_popover.visible and _popover_source_key == "stadium":
			action_popover.dismiss()
		else:
			_popover_dismissed_source_key = ""
			_present_popover_rows(
				"stadium",
				interaction_router.rows_for_source("stadium"),
				"竞技场操作",
			)
		return
	inspect_zone_requested.emit(context)


func _on_card_dropped(
	hand_index: int,
	card_id: String,
	target_player: int,
	target_slot: String,
) -> void:
	var matching_rows := interaction_router.matching_drag_rows(
		hand_index,
		target_player,
		target_slot,
	)
	if matching_rows.is_empty():
		return
	_park_drag_session(target_player, target_slot)
	if matching_rows.size() > 1:
		if _drag_session != null:
			_drag_session.state = CARD_DRAG_SESSION.AWAITING_VARIANT
		_show_forced_action_rows(
			matching_rows,
			CardInteractionRouter.hand_key(hand_index),
		)
		return
	if _drag_session != null:
		_drag_session.state = CARD_DRAG_SESSION.AWAITING_VARIANT
	card_drop_requested.emit(
		hand_index,
		card_id,
		target_player,
		target_slot,
	)


func _on_hand_drag_started(hand_index: int) -> void:
	if hand_index < 0 or hand_index >= hand_views.size():
		return
	var source_view := hand_views[hand_index]
	if source_view == null or not source_view.visible or source_view.card_id.is_empty():
		return
	if _drag_session != null:
		# A parked/pending proxy owns the only visual copy of its card until the
		# authoritative transition resolves. Reject a second native drag without
		# tearing down that first transaction; clearing it here used to orphan the
		# parked entity and enabled duplicate actions from the same revision.
		source_view.cancel_drag_state()
		if source_view == _drag_session.source_view:
			source_view.set_drag_masked(true)
		var viewport := get_viewport()
		if viewport != null and viewport.gui_is_dragging():
			viewport.gui_cancel_drag()
		if header:
			header.set_task_hint("上一张卡仍在等待结算")
		return
	_drag_session_sequence += 1
	_drag_session = CARD_DRAG_SESSION.new()
	_drag_session.session_id = "drag:%d:%d:%d" % [
		state_ref.revision if state_ref != null else -1,
		hand_index,
		_drag_session_sequence,
	]
	_drag_session.state = CARD_DRAG_SESSION.DRAGGING
	_drag_session.revision = state_ref.revision if state_ref != null else -1
	_drag_session.actor = view_player
	_drag_session.hand_index = hand_index
	_drag_session.card_id = source_view.card_id
	_drag_session.visual_id = "%s:%s" % [_drag_session.session_id, source_view.card_id]
	_drag_session.source_view = source_view
	_drag_session.source_position = source_view.position
	_drag_session.source_size = source_view.size
	_drag_session.source_rotation = source_view.rotation_degrees
	_drag_session.grab_offset = source_view.drag_grab_offset_local()
	source_view.set_drag_masked(true)
	_ensure_drag_proxy(_drag_pointer_position())
	_drag_source_key = CardInteractionRouter.hand_key(hand_index)
	if action_popover:
		action_popover.dismiss(false)
	_refresh_target_hints()
	if header:
		header.set_task_hint("将卡牌拖到青色合法目标")
	_tween_drag_hand_layout()


func _on_hand_drag_ended() -> void:
	if _drag_session == null:
		return
	_drag_source_key = ""
	_refresh_target_hints()
	_refresh_header()
	if _drag_session.is_pending():
		return
	_return_drag_session("cancelled")


func active_drag_context() -> Dictionary:
	if _drag_session == null:
		return {}
	return {
		"session_id": _drag_session.session_id,
		"revision": _drag_session.revision,
		"actor": _drag_session.actor,
		"hand_index": _drag_session.hand_index,
		"card_id": _drag_session.card_id,
		"state": _drag_session.state,
		"origin_action_id": _drag_session.origin_action_id,
	}


func mark_drag_pending(action_id: String, network_pending: bool) -> String:
	if _drag_session == null:
		return ""
	if state_ref == null or not _drag_session.matches(
		_drag_session.hand_index,
		_drag_session.card_id,
		state_ref.revision,
	):
		_return_drag_session("stale_drag")
		return ""
	_drag_session.origin_action_id = action_id
	_drag_session.state = (
		CARD_DRAG_SESSION.PENDING_AUTHORITY
		if network_pending
		else CARD_DRAG_SESSION.COMMITTED
	)
	if network_pending and header:
		header.set_task_hint("等待对局服务器确认…")
	return _drag_session.session_id


func drag_session_id_for_origin(action_id: String) -> String:
	if (
		_drag_session != null
		and not action_id.is_empty()
		and _drag_session.origin_action_id == action_id
	):
		return _drag_session.session_id
	return ""


func prepare_pending_drag_for_transition(session_id: String) -> void:
	if _drag_session == null or _drag_session.session_id != session_id:
		return
	_presentation_drag_proxy = _drag_session.proxy


func commit_pending_drag_source(session_id: String) -> void:
	if _drag_session == null or _drag_session.session_id != session_id:
		return
	if _drag_session.source_view != null and is_instance_valid(_drag_session.source_view):
		_drag_session.source_view.clear_drag_mask()
	_drag_session.state = CARD_DRAG_SESSION.COMMITTED
	_layout_hand(_current_hand_card_size())


func finish_pending_drag_transition(session_id: String) -> void:
	if _drag_session == null or _drag_session.session_id != session_id:
		return
	if _drag_session.proxy != null and is_instance_valid(_drag_session.proxy):
		_dispose_flyer(_drag_session.proxy)
	_presentation_drag_proxy = null
	_drag_session = null
	_drag_source_key = ""
	_layout_hand(_current_hand_card_size())


func clear_pending_drag(reason: String = "cancelled") -> void:
	if _drag_session == null:
		return
	if (
		state_ref != null
		and state_ref.revision == _drag_session.revision
		and _drag_session.source_view != null
		and is_instance_valid(_drag_session.source_view)
		and _drag_session.source_view.card_id == _drag_session.card_id
	):
		_return_drag_session(reason)
	else:
		_clear_drag_session_immediately()


func clear_pending_drag_immediately(_reason: String = "cancelled") -> void:
	if _drag_session == null:
		return
	_clear_drag_session_immediately()


func _park_drag_session(target_player: int, target_slot: String) -> void:
	if _drag_session == null:
		return
	_drag_session.release_position = _drag_pointer_position()
	_drag_session.target_player = target_player
	_drag_session.target_slot = target_slot
	var proxy := _ensure_drag_proxy(_drag_session.release_position)
	if proxy == null:
		return
	var finish := resolve_endpoint_center({
		"player": target_player,
		"slot": target_slot,
	})
	_animate_drag_proxy(proxy, finish, 0.14, Callable())


func _ensure_drag_proxy(start: Vector2) -> Control:
	if _drag_session == null:
		return null
	if _drag_session.proxy != null and is_instance_valid(_drag_session.proxy):
		return _drag_session.proxy
	var texture := _texture_for_card_id(_drag_session.card_id)
	if texture == null or effects == null:
		return null
	var size_value: Vector2 = _drag_session.source_size
	if size_value == Vector2.ZERO:
		size_value = _current_hand_card_size()
	var proxy := _create_paper_card_token(
		texture,
		size_value,
		"DragMotionEntity",
		150,
		1.0,
		true,
	)
	proxy.set_meta("drag_session_id", _drag_session.session_id)
	proxy.set_meta("card_motion_entity", true)
	proxy.position = _drag_proxy_position_for_pointer(start, proxy)
	proxy.rotation_degrees = _drag_session.source_rotation
	proxy.modulate.a = 1.0
	card_motion_layer.add(proxy)
	_drag_session.proxy = proxy
	return proxy


func _return_drag_session(reason: String) -> void:
	if _drag_session == null:
		return
	var session_id: String = _drag_session.session_id
	_drag_session.state = CARD_DRAG_SESSION.RETURNING
	var proxy := _ensure_drag_proxy(_drag_pointer_position())
	_tween_drag_hand_layout()
	var finish_pose := _drag_source_layout_pose()
	var finish: Vector2 = finish_pose.get("center", _own_hand_center())
	if proxy == null or MotionPolicy.reduced():
		_finish_drag_return(session_id, reason)
		return
	_animate_drag_proxy(
		proxy,
		finish,
		MotionPolicy.duration("return"),
		_finish_drag_return.bind(session_id, reason),
		float(finish_pose.get("rotation_degrees", 0.0)),
	)


func _finish_drag_return(session_id: String, _reason: String = "") -> void:
	if _drag_session == null or _drag_session.session_id != session_id:
		return
	if _drag_session.source_view != null and is_instance_valid(_drag_session.source_view):
		_drag_session.source_view.clear_drag_mask()
	if _drag_session.proxy != null and is_instance_valid(_drag_session.proxy):
		_dispose_flyer(_drag_session.proxy)
	_drag_session.state = CARD_DRAG_SESSION.CANCELLED
	_drag_session = null
	_presentation_drag_proxy = null
	_layout_hand(_current_hand_card_size())


func _clear_drag_session_immediately() -> void:
	if _drag_session == null:
		return
	if _drag_session.source_view != null and is_instance_valid(_drag_session.source_view):
		_drag_session.source_view.cancel_drag_state()
	var viewport := get_viewport()
	if viewport != null and viewport.gui_is_dragging():
		viewport.gui_cancel_drag()
	if _drag_session.proxy != null and is_instance_valid(_drag_session.proxy):
		_dispose_flyer(_drag_session.proxy)
	_drag_session = null
	_presentation_drag_proxy = null
	_drag_source_key = ""
	_layout_hand(_current_hand_card_size())


func _animate_drag_proxy(
	proxy: Control,
	finish: Vector2,
	duration: float,
	completion: Callable,
	finish_rotation: float = 0.0,
) -> void:
	if proxy == null or not is_instance_valid(proxy):
		if completion.is_valid():
			completion.call()
		return
	var instance_id := proxy.get_instance_id()
	var previous := _flyer_tweens.get(instance_id) as Tween
	if previous != null and previous.is_valid():
		previous.kill()
	_flyer_tweens.erase(instance_id)
	if duration <= 0.0:
		proxy.position = finish - proxy.size * 0.5
		proxy.rotation_degrees = finish_rotation
		if completion.is_valid():
			completion.call()
		return
	var tween := create_tween().set_parallel(true)
	card_motion_layer.bind_tween(proxy, tween)
	tween.tween_property(
		proxy,
		"position",
		finish - proxy.size * 0.5,
		duration,
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(proxy, "rotation_degrees", finish_rotation, duration).set_trans(
		Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	if completion.is_valid():
		tween.chain().tween_callback(completion)


func _reconcile_drag_after_layout_change() -> void:
	if _drag_session == null:
		return
	var proxy := _drag_session.proxy as Control
	if proxy == null or not is_instance_valid(proxy):
		return
	match _drag_session.state:
		CARD_DRAG_SESSION.DRAGGING:
			proxy.position = _drag_proxy_position_for_pointer(
				_drag_pointer_position(),
				proxy,
			)
		CARD_DRAG_SESSION.AWAITING_VARIANT, CARD_DRAG_SESSION.PENDING_AUTHORITY:
			_cancel_proxy_position_tween(proxy)
			var finish: Vector2 = (
				resolve_endpoint_center({
					"player": _drag_session.target_player,
					"slot": _drag_session.target_slot,
				})
				if not _drag_session.target_slot.is_empty()
				else _drag_session.release_position
			)
			proxy.position = finish - proxy.size * 0.5
		CARD_DRAG_SESSION.RETURNING:
			var session_id: String = _drag_session.session_id
			_cancel_proxy_position_tween(proxy)
			var finish_pose := _drag_source_layout_pose()
			proxy.position = Vector2(
				finish_pose.get("center", _own_hand_center()),
			) - proxy.size * 0.5
			proxy.rotation_degrees = float(finish_pose.get("rotation_degrees", 0.0))
			_finish_drag_return(session_id, "layout_changed")


func _cancel_proxy_position_tween(proxy: Control) -> void:
	if proxy == null or not is_instance_valid(proxy):
		return
	var instance_id := proxy.get_instance_id()
	var tween := _flyer_tweens.get(instance_id) as Tween
	if tween != null and tween.is_valid():
		tween.kill()
	_flyer_tweens.erase(instance_id)


func _tween_drag_hand_layout() -> void:
	var layout_views: Array[CardView] = []
	for view in hand_views:
		if _hand_view_participates_in_layout(view):
			layout_views.append(view)
	var card_size := _current_hand_card_size()
	var plan := BattleTableLayout.own_hand_plan(
		layout_views.size(),
		hand_scroll.size.x,
		card_size,
		hand_minimum_spacing,
		hand_rotation_degrees,
	)
	hand_surface.custom_minimum_size.x = float(plan["surface_width"])
	var items: Array[Dictionary] = plan["items"]
	var duration := MotionPolicy.duration("hand_reflow")
	for index in range(layout_views.size()):
		var view := layout_views[index]
		var item: Dictionary = items[index]
		view.custom_minimum_size = card_size
		view.size = card_size
		view.z_index = mini(HAND_CARD_MAX_Z, int(item["z_index"]))
		_move_hand_card(
			view,
			item["position"],
			float(item["rotation_degrees"]),
			duration,
		)


func _drag_source_layout_center() -> Vector2:
	return Vector2(_drag_source_layout_pose().get("center", _own_hand_center()))


func _drag_source_layout_pose() -> Dictionary:
	if _drag_session == null or _drag_session.source_view == null:
		return {"center": _own_hand_center(), "rotation_degrees": 0.0}
	var layout_views: Array[CardView] = []
	for view in hand_views:
		if _hand_view_participates_in_layout(view):
			layout_views.append(view)
	var card_size := _current_hand_card_size()
	var plan := BattleTableLayout.own_hand_plan(
		layout_views.size(),
		hand_scroll.size.x,
		card_size,
		hand_minimum_spacing,
		hand_rotation_degrees,
	)
	var source_index := layout_views.find(_drag_session.source_view)
	if source_index < 0:
		return {"center": _own_hand_center(), "rotation_degrees": 0.0}
	var items: Array[Dictionary] = plan["items"]
	var item: Dictionary = items[source_index]
	var local_center: Vector2 = item["position"] + card_size * 0.5
	var viewport_center: Vector2 = (
		hand_surface.get_global_transform_with_canvas() * local_center
	)
	return {
		"center": _effects_local(viewport_center),
		"rotation_degrees": float(item.get("rotation_degrees", 0.0)),
	}


func _drag_proxy_position_for_pointer(pointer: Vector2, proxy: Control) -> Vector2:
	if proxy == null or _drag_session == null:
		return pointer
	var source_size: Vector2 = _drag_session.source_size
	var grab_offset: Vector2 = _drag_session.grab_offset
	if source_size.x > 0.0 and source_size.y > 0.0:
		grab_offset *= Vector2(
			proxy.size.x / source_size.x,
			proxy.size.y / source_size.y,
		)
	else:
		grab_offset = proxy.size * 0.5
	var center := proxy.size * 0.5
	var rendered_grab_offset := center + (grab_offset - center).rotated(
		deg_to_rad(proxy.rotation_degrees),
	)
	return pointer - rendered_grab_offset


func _drag_pointer_position() -> Vector2:
	var viewport := get_viewport()
	if viewport != null and effects != null:
		return _effects_local(viewport.get_mouse_position())
	if _drag_session != null and _drag_session.source_view != null:
		var source_view: CardView = _drag_session.source_view
		if is_instance_valid(source_view) and effects != null:
			return _effects_local(source_view.global_center())
	return _own_hand_center()


func _on_floating_text_requested(
	text: String,
	target: Dictionary,
	color: Color,
) -> void:
	if (
		str(target.get(PresentationDirector.FEEDBACK_CHANNEL_KEY, ""))
		== PresentationDirector.FEEDBACK_CHANNEL_ANNOUNCEMENT
	):
		if announcement_layer:
			var handle := announcement_layer.show_announcement(
				text,
				color,
				MotionPolicy.reduced(),
			)
			director.register_feedback_motion(handle)
		return
	var layer := _world_feedback_layer()
	if layer:
		var handle := layer.floating_text(
			text,
			_world_feedback_point(resolve_endpoint_center(target)),
			color,
			not MotionPolicy.reduced(),
		)
		director.register_feedback_motion(handle)


func _on_burst_requested(
	kind: String,
	target: Dictionary,
	color: Color,
) -> void:
	_burst_world_at_motion_point(resolve_endpoint_center(target), color, kind)
	var player := int(target.get("player", -1))
	var slot_name := str(target.get("slot", ""))
	var view := _valid_card_view(_presentation_slot_covers.get(
		"%d:%s" % [player, slot_name],
	))
	if view == null:
		view = get_slot_view(player, slot_name)
	if view:
		view.flash(color, 0.36)
		if kind in ["impact", "ko"]:
			view.shake(8.0 if kind == "impact" else 11.0, 0.3)


func _on_card_landing_feedback_scheduled(
	event: Dictionary,
	feedback: Dictionary,
) -> void:
	var event_id := str(event.get("event_id", ""))
	if event_id.is_empty():
		return
	_presentation_landing_feedbacks[event_id] = feedback.duplicate(true)


func _play_card_landing_feedback(
	flying: Control,
	finish: Vector2,
) -> bool:
	if flying == null:
		return false
	var event_id := str(flying.get_meta("motion_event_id", ""))
	if event_id.is_empty() or not _presentation_landing_feedbacks.has(event_id):
		return false
	var feedback: Dictionary = _presentation_landing_feedbacks.get(event_id, {})
	_presentation_landing_feedbacks.erase(event_id)
	_burst_world_at_motion_point(
		finish,
		feedback.get("color", DesignTokens.CYAN) as Color,
		str(feedback.get("kind", "card_land")),
	)
	var camera_strength := float(feedback.get("camera_strength", 0.0))
	var camera_duration := float(feedback.get("camera_duration", 0.0))
	if camera_rig != null and camera_strength > 0.0:
		camera_rig.impulse(
			camera_strength,
			camera_duration,
			AppSettings.reduced_motion,
		)
	return true


func _world_feedback_layer() -> BattleEffectLayer:
	if world_feedback != null and is_instance_valid(world_feedback):
		return world_feedback
	return null


func _world_feedback_point(motion_point: Vector2) -> Vector2:
	var layer := _world_feedback_layer()
	if layer == null or effects == null or layer == effects:
		return motion_point
	var global_point := effects.get_global_transform_with_canvas() * motion_point
	return layer.get_global_transform_with_canvas().affine_inverse() * global_point


func _burst_world_at_motion_point(
	motion_point: Vector2,
	color: Color,
	kind: String,
) -> void:
	if MotionPolicy.reduced():
		return
	var layer := _world_feedback_layer()
	if layer:
		layer.burst(_world_feedback_point(motion_point), color, kind)


func _stage_presentation_hud(previous_snapshot: Dictionary) -> void:
	var state_value: Variant = previous_snapshot.get("state", {})
	if not state_value is Dictionary or Dictionary(state_value).is_empty():
		return
	var previous_state := GameState.from_dict(Dictionary(state_value))
	_refresh_header(previous_state)
	_refresh_field_info(previous_state)
	_refresh_log(previous_state)
	var previous_opponent_hand := previous_state.get_player(1 - view_player).hand.size()
	if opponent_hand_count_badge != null:
		opponent_hand_count_badge.visible = previous_opponent_hand > 0
		opponent_hand_count_badge.text = str(previous_opponent_hand)


func _stage_slot_visual_transactions(
	events: Array[Dictionary],
	previous_snapshot: Dictionary,
) -> void:
	_clear_slot_visual_transactions()
	var event_queues: Dictionary = {}
	for event in events:
		var event_id := str(event.get("event_id", ""))
		if event_id.is_empty():
			continue
		for key in _slot_visual_keys_for_event(event):
			var queue: Array = event_queues.get(key, [])
			if event_id not in queue:
				queue.append(event_id)
			event_queues[key] = queue
	var snapshot_slots: Dictionary = previous_snapshot.get("slots", {})
	for key_value in event_queues.keys():
		var key := str(key_value)
		var row: Dictionary = snapshot_slots.get(key, {})
		if row.is_empty() or bool(row.get("empty", true)):
			continue
		var pokemon_data: Dictionary = row.get("pokemon", {})
		if pokemon_data.is_empty():
			continue
		var state := PokemonState.from_dict(pokemon_data)
		var cover := _spawn_slot_state_cover(key, row, state)
		if cover == null:
			continue
		_presentation_slot_covers[key] = cover
		_presentation_slot_cover_states[key] = state
		_presentation_slot_event_queues[key] = event_queues[key]


func _slot_visual_keys_for_event(event: Dictionary) -> Array[String]:
	var event_type := PresentationEvent.canonical_event_type(
		str(event.get("event_type", "")),
	)
	if event_type not in [
		"card_moved",
		"cards_discarded",
		"damage_counters_placed",
		"damage_dealt",
		"energy_attached",
		"healed",
		"pokemon_evolved",
		"pokemon_ko",
		"pokemon_played",
		"promoted",
		"retreat",
		"status_applied",
		"switched",
		"tool_attached",
	]:
		return []
	var result: Array[String] = []
	var data: Dictionary = event.get("data", {})
	var actor := int(event.get("actor", data.get("player", view_player)))
	for endpoint in [_event_source_endpoint(event), _event_target_endpoint(event)]:
		var slot_name := str(endpoint.get("slot", ""))
		if slot_name.is_empty():
			continue
		var key := "%d:%s" % [int(endpoint.get("player", actor)), slot_name]
		if key not in result:
			result.append(key)
	if event_type == "pokemon_ko":
		var ko_key := "%d:%s" % [
			int(data.get("player", actor)),
			str(data.get("slot", "active")),
		]
		if ko_key not in result:
			result.append(ko_key)
	if event_type in ["retreat", "switched", "promoted"]:
		var player := int(data.get("player", actor))
		for slot_name in ["active", _bench_slot_from_event(event)]:
			if slot_name.is_empty():
				continue
			var switch_key := "%d:%s" % [player, slot_name]
			if switch_key not in result:
				result.append(switch_key)
	return result


func _spawn_slot_state_cover(
	key: String,
	row: Dictionary,
	pokemon_state: PokemonState,
) -> CardView:
	if effects == null or pokemon_state == null:
		return null
	var parts := key.split(":")
	if parts.size() < 2:
		return null
	var cover := CARD_SCENE.instantiate() as CardView
	if cover == null:
		return null
	cover.name = "SlotStateCover_%s" % key.replace(":", "_")
	cover.set_meta("battle_transient_visual", true)
	cover.set_meta("battle_transient_kind", "SlotStateCover")
	cover.set_meta("presentation_slot_key", key)
	cover.z_index = 94
	effects.add_child(cover)
	cover.set_catalog(catalog)
	cover.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cover.focus_mode = Control.FOCUS_NONE
	cover.configure(
		pokemon_state.card_id,
		pokemon_state,
		bool(row.get("hidden", false)),
		-1,
		int(parts[0]),
		str(parts[1]),
		false,
	)
	var size_value := _vector_or_default(row.get("size"), active_card_size)
	cover.custom_minimum_size = size_value
	cover.size = size_value
	cover.position = _vector_or_default(row.get("center"), Vector2.ZERO) - size_value * 0.5
	cover.rotation_degrees = float(row.get("rotation_degrees", 0.0))
	cover.set_table_depth(_motion_depth_for_point(cover.position + size_value * 0.5), true)
	cover.remember_base_position()
	return cover


func _on_presentation_event_started(event: Dictionary) -> void:
	var event_type := PresentationEvent.canonical_event_type(
		str(event.get("event_type", "")),
	)
	var keys := _slot_visual_keys_for_event(event)
	if event_type in ["card_moved", "pokemon_ko", "promoted", "retreat", "switched"]:
		for key in keys:
			_release_slot_state_cover(key)
		return
	if event_type in ["damage_counters_placed", "damage_dealt", "healed", "status_applied"]:
		for key in keys:
			_apply_event_to_slot_cover(key, event)


func _apply_event_to_slot_cover(key: String, event: Dictionary) -> void:
	var state := _presentation_slot_cover_states.get(key) as PokemonState
	var cover := _valid_card_view(_presentation_slot_covers.get(key))
	if state == null or cover == null:
		return
	var event_type := PresentationEvent.canonical_event_type(
		str(event.get("event_type", "")),
	)
	var data: Dictionary = event.get("data", {})
	var amount := maxi(0, int(event.get("amount", data.get("amount", 0))))
	match event_type:
		"damage_dealt", "damage_counters_placed":
			var counters := int(data.get("counter_count", 0))
			if counters <= 0 and amount > 0:
				counters = ceili(float(amount) / 10.0)
			state.damage_counters += maxi(0, counters)
		"healed":
			state.damage_counters = maxi(
				0,
				state.damage_counters - ceili(float(amount) / 10.0),
			)
		"status_applied":
			var status := str(data.get("status", event.get("status", "")))
			if not status.is_empty() and status not in state.status_conditions:
				state.status_conditions.append(status)
		"cards_discarded":
			var source := _discard_endpoints_for_event(event).get("source", {}) as Dictionary
			match str(source.get("attachment_type", "")):
				"energy":
					for card_id_value in _event_card_ids(event):
						state.energy_card_ids.erase(str(card_id_value))
				"tool":
					if _event_card_ids(event).is_empty() or state.attached_tool_id in _event_card_ids(event):
						state.attached_tool_id = ""
		"energy_attached":
			var source := _event_source_endpoint(event)
			var target := _event_target_endpoint(event)
			var key_parts := key.split(":")
			var key_player := int(key_parts[0])
			var key_slot := str(key_parts[1])
			for card_id_value in _event_card_ids(event):
				var card_id := str(card_id_value)
				if (
					int(source.get("player", -99)) == key_player
					and str(source.get("slot", "")) == key_slot
				):
					state.energy_card_ids.erase(card_id)
				if (
					int(target.get("player", -99)) == key_player
					and str(target.get("slot", "")) == key_slot
					and card_id not in state.energy_card_ids
				):
					state.energy_card_ids.append(card_id)
		"tool_attached":
			var card_ids := _event_card_ids(event)
			if not card_ids.is_empty():
				state.attached_tool_id = str(card_ids[0])
		"pokemon_evolved":
			if state.card_id not in state.evolution_stack_ids:
				state.evolution_stack_ids.append(state.card_id)
			state.card_id = str(event.get("card_id", data.get("card_id", state.card_id)))
			state.status_conditions.clear()
	cover.configure(
		state.card_id,
		state,
		false,
		-1,
		cover.owner_player,
		cover.slot,
		false,
	)
	cover.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cover.remember_base_position()


func _finish_slot_visual_event(event: Dictionary) -> void:
	var event_id := str(event.get("event_id", ""))
	var event_type := PresentationEvent.canonical_event_type(
		str(event.get("event_type", "")),
	)
	for key in _slot_visual_keys_for_event(event):
		if not _presentation_slot_event_queues.has(key):
			continue
		if event_type in [
			"cards_discarded",
			"energy_attached",
			"pokemon_evolved",
			"tool_attached",
		]:
			_apply_event_to_slot_cover(key, event)
		var queue: Array = _presentation_slot_event_queues.get(key, [])
		queue.erase(event_id)
		_presentation_slot_event_queues[key] = queue
		if queue.is_empty():
			_release_slot_state_cover(key)


func _release_slot_state_cover(key: String) -> void:
	var cover := _valid_card_view(_presentation_slot_covers.get(key))
	_presentation_slot_covers.erase(key)
	_presentation_slot_cover_states.erase(key)
	_presentation_slot_event_queues.erase(key)
	if cover != null:
		cover.visible = false
		cover.queue_free()


func _clear_slot_visual_transactions() -> void:
	for key_value in _presentation_slot_covers.keys():
		_release_slot_state_cover(str(key_value))
	_presentation_slot_covers.clear()
	_presentation_slot_cover_states.clear()
	_presentation_slot_event_queues.clear()
	_clear_effect_child_controls(["SlotStateCover"])


func _reposition_slot_state_covers() -> void:
	for key_value in _presentation_slot_covers.keys():
		var key := str(key_value)
		var cover := _valid_card_view(_presentation_slot_covers.get(key))
		var parts := key.split(":")
		if cover == null or parts.size() < 2:
			continue
		var slot_view := get_slot_view(int(parts[0]), str(parts[1]))
		if slot_view == null:
			continue
		cover.custom_minimum_size = slot_view.size
		cover.size = slot_view.size
		cover.position = _effects_local(slot_view.global_center()) - cover.size * 0.5
		cover.rotation_degrees = slot_view.rotation_degrees
		cover.remember_base_position()


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
	_stage_presentation_hud(previous_snapshot)
	_stage_hand_transition_geometry(previous_snapshot)
	_stage_snapshot_hand_sources(events, previous_snapshot)
	_stage_opponent_hand_transaction(events, previous_snapshot)
	_stage_attachment_source_proxies(events)
	_stage_presentation_zone_states(events, previous_snapshot)
	_stage_slot_visual_transactions(events, previous_snapshot)
	for event in events:
		if PresentationEvent.canonical_event_type(
			str(event.get("event_type", "")),
		) == "deck_shuffled":
			invalidate_hand_visual_identities()
			break
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


func _stage_snapshot_hand_sources(
	events: Array[Dictionary],
	previous_snapshot: Dictionary,
) -> void:
	_clear_snapshot_hand_sources()
	if (
		effects == null
		or int(previous_snapshot.get("view_player", -1)) != view_player
	):
		return
	var snapshot_hand: Array = previous_snapshot.get("hand", [])
	if snapshot_hand.is_empty():
		return
	var virtual_rows: Array[Dictionary] = []
	for snapshot_index in range(snapshot_hand.size()):
		if not snapshot_hand[snapshot_index] is Dictionary:
			continue
		var row: Dictionary = Dictionary(snapshot_hand[snapshot_index]).duplicate(true)
		var key := "snapshot:%d" % snapshot_index
		row["snapshot_key"] = key
		row["snapshot_index"] = snapshot_index
		virtual_rows.append(row)
		_presentation_hand_snapshot_rows[key] = row
		_presentation_hand_virtual_keys.append(key)

	var staged_keys: Dictionary = {}
	for event in events:
		var source := _event_source_endpoint(event)
		var target := _event_target_endpoint(event)
		if (
			int(source.get("player", view_player)) != view_player
			or str(source.get("zone", "")) != "hand"
			or str(target.get("zone", "")) == "hand"
		):
			continue
		var event_id := str(event.get("event_id", ""))
		if event_id.is_empty():
			continue
		var selected_rows := _select_virtual_hand_source_rows(event, virtual_rows)
		if selected_rows.is_empty():
			continue
		var event_keys: Array[String] = []
		for row in selected_rows:
			var key := str(row.get("snapshot_key", ""))
			if key.is_empty():
				continue
			event_keys.append(key)
			staged_keys[key] = true
		_presentation_event_hand_sources[event_id] = event_keys
		for row in selected_rows:
			var key := str(row.get("snapshot_key", ""))
			for virtual_index in range(virtual_rows.size() - 1, -1, -1):
				if str(virtual_rows[virtual_index].get("snapshot_key", "")) == key:
					virtual_rows.remove_at(virtual_index)
					break

	var drag_snapshot_key := ""
	if _presentation_drag_proxy != null and _drag_session != null:
		var drag_index := int(_drag_session.hand_index)
		var candidate_key := "snapshot:%d" % drag_index
		var candidate_row: Dictionary = _presentation_hand_snapshot_rows.get(
			candidate_key,
			{},
		)
		if (
			staged_keys.has(candidate_key)
			and str(candidate_row.get("card_id", "")) == _drag_session.card_id
		):
			drag_snapshot_key = candidate_key

	for key_value in staged_keys.keys():
		var key := str(key_value)
		if key == drag_snapshot_key:
			# The user's drag entity already owns this visual card and may be parked
			# at its target. Creating a snapshot copy here would briefly put a second
			# complete face back into the hand.
			continue
		var row: Dictionary = _presentation_hand_snapshot_rows.get(key, {})
		var card_id := str(row.get("card_id", ""))
		var texture := _texture_for_card_id(card_id)
		if texture == null:
			continue
		var size_value := _vector_or_default(row.get("size"), _current_hand_card_size())
		var center := _vector_or_default(row.get("center"), _own_hand_center())
		var proxy := _create_paper_card_token(
			texture,
			size_value,
			"SnapshotHandProxy",
			84 + int(row.get("snapshot_index", 0)),
			_motion_depth_for_point(center),
		)
		proxy.position = center - size_value * 0.5
		proxy.rotation_degrees = float(row.get("rotation_degrees", 0.0))
		var motion_proxy := proxy as CardMotionEntity
		if motion_proxy != null:
			motion_proxy.configure_motion(
				str(row.get("visual_id", key)),
				{
					"position": proxy.position,
					"size": size_value,
					"rotation_degrees": proxy.rotation_degrees,
				},
			)
		proxy.set_meta("snapshot_hand_key", key)
		proxy.set_meta("snapshot_card_id", card_id)
		effects.add_child(proxy)
		_presentation_hand_source_proxies.append(proxy)
		_presentation_hand_proxy_by_key[key] = proxy


func _stage_opponent_hand_transaction(
	events: Array[Dictionary],
	previous_snapshot: Dictionary,
) -> void:
	_clear_opponent_hand_transaction(false)
	if effects == null:
		return
	var opponent := 1 - view_player
	var incoming_count := 0
	for event in events:
		if _opponent_hand_event_amount(event) <= 0:
			continue
		var source := _event_source_endpoint(event)
		var target := _event_target_endpoint(event)
		var touches_opponent_hand := (
			(str(source.get("zone", "")) == "hand"
				and int(source.get("player", -1)) == opponent)
			or (str(target.get("zone", "")) == "hand"
				and int(target.get("player", -1)) == opponent)
		)
		if not touches_opponent_hand:
			continue
		var event_id := str(event.get("event_id", ""))
		if not event_id.is_empty() and event_id not in _presentation_opponent_hand_event_ids:
			_presentation_opponent_hand_event_ids.append(event_id)
		var event_delta := _opponent_hand_event_delta(event)
		if not event_id.is_empty():
			_presentation_opponent_hand_planned_deltas[event_id] = event_delta
		if event_delta > 0:
			incoming_count += event_delta
	if _presentation_opponent_hand_event_ids.is_empty():
		return
	var final_visible_count := 0
	for view in opponent_hand_views:
		if view == null or not view.visible:
			continue
		final_visible_count += 1
		_mask_presentation_node(view)
		_presentation_opponent_hand_nodes.append(view)
	_presentation_opponent_hand_target_cursor = maxi(
		0,
		final_visible_count - mini(incoming_count, final_visible_count),
	)
	var snapshot_rows: Array = previous_snapshot.get("opponent_hand", [])
	var back_texture := _texture_for_card_id("")
	if back_texture == null:
		_clear_opponent_hand_transaction(true)
		return
	for index in range(snapshot_rows.size()):
		var row: Dictionary = snapshot_rows[index]
		var size_value := _vector_or_default(row.get("size"), opponent_hand_card_size)
		var center := _vector_or_default(row.get("center"), _opponent_hand_center())
		var proxy := _create_paper_card_token(
			back_texture,
			size_value,
			"SnapshotOpponentHandProxy",
			86 + index,
			_motion_depth_for_point(center),
		)
		# This entity is a stationary replacement for the pre-transition hand,
		# not an in-flight card. It becomes a motion entity only if a later event
		# claims it as an outgoing source.
		proxy.remove_meta("card_motion_entity")
		proxy.position = center - size_value * 0.5
		proxy.rotation_degrees = float(row.get("rotation_degrees", 0.0))
		proxy.set_meta("snapshot_opponent_hand_index", index)
		effects.add_child(proxy)
		_presentation_opponent_hand_proxies.append(proxy)
	var state_value: Variant = previous_snapshot.get("state", {})
	if state_value is Dictionary and not Dictionary(state_value).is_empty():
		var previous_state := GameState.from_dict(Dictionary(state_value))
		var count_value := previous_state.get_player(opponent).hand.size()
		_presentation_opponent_hand_stage_count = count_value
		opponent_hand_count_badge.visible = count_value > 0
		opponent_hand_count_badge.text = str(count_value)
	else:
		_presentation_opponent_hand_stage_count = snapshot_rows.size()
	_reconcile_opponent_hand_proxy_count()


func _opponent_hand_event_amount(event: Dictionary) -> int:
	var card_ids := _event_card_ids(event)
	var data: Dictionary = event.get("data", {})
	return maxi(0, int(event.get(
		"amount",
		data.get("count", card_ids.size()),
	)))


func _opponent_hand_event_delta(event: Dictionary) -> int:
	var opponent := 1 - view_player
	var source := _event_source_endpoint(event)
	var target := _event_target_endpoint(event)
	var source_is_hand := (
		str(source.get("zone", "")) == "hand"
		and int(source.get("player", -1)) == opponent
	)
	var target_is_hand := (
		str(target.get("zone", "")) == "hand"
		and int(target.get("player", -1)) == opponent
	)
	if source_is_hand == target_is_hand:
		return 0
	var amount := _opponent_hand_event_amount(event)
	return amount if target_is_hand else -amount


func _apply_opponent_hand_stage_delta(
	event_id: String,
	delta: int,
	reflow: bool = true,
) -> void:
	if delta == 0:
		return
	_presentation_opponent_hand_stage_count = maxi(
		0,
		_presentation_opponent_hand_stage_count + delta,
	)
	_presentation_opponent_hand_event_deltas[event_id] = (
		int(_presentation_opponent_hand_event_deltas.get(event_id, 0)) + delta
	)
	_sync_opponent_hand_stage_visuals(reflow)


func _claim_opponent_hand_sources(event: Dictionary) -> Array[Control]:
	var result: Array[Control] = []
	var event_id := str(event.get("event_id", ""))
	var amount_value := _opponent_hand_event_amount(event)
	if amount_value <= 0:
		return result
	var amount := mini(
		amount_value,
		_presentation_opponent_hand_proxies.size(),
	)
	var requested_indices: Array[int] = []
	var data: Dictionary = event.get("data", {})
	var raw_indices: Variant = data.get("source_indices", [])
	if raw_indices is Array:
		for value in raw_indices:
			var source_index := int(value)
			if (
				source_index >= 0
				and source_index < _presentation_opponent_hand_proxies.size()
				and source_index not in requested_indices
			):
				requested_indices.append(source_index)
	if requested_indices.is_empty():
		var first_index := int(_event_source_endpoint(event).get("index", -1))
		if first_index >= 0:
			for offset in range(amount):
				var source_index := first_index + offset
				if source_index >= 0 and source_index < _presentation_opponent_hand_proxies.size():
					requested_indices.append(source_index)
	var selected: Array[Control] = []
	for source_index in requested_indices:
		if selected.size() >= amount:
			break
		var indexed_proxy := _presentation_opponent_hand_proxies[source_index]
		if indexed_proxy != null and is_instance_valid(indexed_proxy) and indexed_proxy not in selected:
			selected.append(indexed_proxy)
	for index in range(_presentation_opponent_hand_proxies.size() - 1, -1, -1):
		if selected.size() >= amount:
			break
		var fallback_proxy := _presentation_opponent_hand_proxies[index]
		if fallback_proxy != null and is_instance_valid(fallback_proxy) and fallback_proxy not in selected:
			selected.push_front(fallback_proxy)
	for proxy in selected:
		_presentation_opponent_hand_proxies.erase(proxy)
		if proxy != null and is_instance_valid(proxy):
			_cancel_hand_layout_motion(proxy)
			result.append(proxy)
	var event_delta := _opponent_hand_event_delta(event)
	if event_delta < 0:
		_apply_opponent_hand_stage_delta(
			event_id,
			event_delta,
			not _opponent_hand_next_event_consumes_remainder(
				event_id,
				event_delta,
			),
		)
	return result


func _opponent_hand_next_event_consumes_remainder(
	event_id: String,
	current_delta: int,
) -> bool:
	var event_index := _presentation_opponent_hand_event_ids.find(event_id)
	if event_index < 0 or event_index + 1 >= _presentation_opponent_hand_event_ids.size():
		return false
	var next_event_id := _presentation_opponent_hand_event_ids[event_index + 1]
	var next_delta := int(_presentation_opponent_hand_planned_deltas.get(
		next_event_id,
		0,
	))
	var projected_count := maxi(
		0,
		_presentation_opponent_hand_stage_count + current_delta,
	)
	return (
		next_delta < 0
		and -next_delta >= projected_count
	)


func _finish_opponent_hand_event(event: Dictionary) -> void:
	var event_id := str(event.get("event_id", ""))
	if event_id.is_empty() or event_id not in _presentation_opponent_hand_event_ids:
		return
	_adopt_opponent_hand_landing_flyers(event_id)
	var expected_delta := _opponent_hand_event_delta(event)
	var applied_delta := int(_presentation_opponent_hand_event_deltas.get(event_id, 0))
	var remaining_delta := expected_delta - applied_delta
	if remaining_delta != 0:
		_apply_opponent_hand_stage_delta(event_id, remaining_delta)
	_presentation_opponent_hand_event_deltas.erase(event_id)
	_presentation_opponent_hand_event_ids.erase(event_id)
	if not _presentation_opponent_hand_event_ids.is_empty():
		return
	_clear_opponent_hand_transaction(true)


func _adopt_opponent_hand_landing_flyers(event_id: String) -> void:
	for flyer in _active_flyers.duplicate():
		if (
			flyer == null
			or not is_instance_valid(flyer)
			or str(flyer.get_meta("motion_event_id", "")) != event_id
			or not bool(flyer.get_meta("opponent_hand_staged_landing", false))
		):
			continue
		_adopt_opponent_hand_landing_flyer(flyer)


func _adopt_opponent_hand_landing_flyer(flyer: Control) -> bool:
	if (
		flyer == null
		or not is_instance_valid(flyer)
		or not bool(flyer.get_meta("opponent_hand_staged_landing", false))
	):
		return false
	var event_id := str(flyer.get_meta("motion_event_id", ""))
	var stage_delta := int(flyer.get_meta("opponent_hand_stage_count_delta", 1))
	_active_flyers.erase(flyer)
	_flyer_tweens.erase(flyer.get_instance_id())
	card_motion_layer.forget(flyer)
	_cancel_hand_layout_motion(flyer)
	flyer.name = "SnapshotOpponentHandProxy_%d" % flyer.get_instance_id()
	flyer.remove_meta("card_motion_entity")
	flyer.remove_meta("motion_landing_view")
	flyer.remove_meta("opponent_hand_staged_landing")
	flyer.remove_meta("opponent_hand_stage_count_delta")
	flyer.set_meta("battle_transient_kind", "SnapshotOpponentHandProxy")
	flyer.z_index = 86 + _presentation_opponent_hand_proxies.size()
	_presentation_opponent_hand_proxies.append(flyer)
	if stage_delta != 0:
		_apply_opponent_hand_stage_delta(event_id, stage_delta)
	else:
		_sync_opponent_hand_stage_visuals()
	return true


func _sync_opponent_hand_stage_visuals(reflow: bool = true) -> void:
	_reconcile_opponent_hand_proxy_count()
	if opponent_hand_count_badge != null:
		opponent_hand_count_badge.visible = _presentation_opponent_hand_stage_count > 0
		opponent_hand_count_badge.text = str(_presentation_opponent_hand_stage_count)
	if reflow:
		_reflow_opponent_hand_proxies()


func _reconcile_opponent_hand_proxy_count() -> void:
	var live: Array[Control] = []
	for proxy in _presentation_opponent_hand_proxies:
		if proxy != null and is_instance_valid(proxy) and not proxy.is_queued_for_deletion():
			live.append(proxy)
	_presentation_opponent_hand_proxies.assign(live)
	var desired := mini(
		_presentation_opponent_hand_stage_count,
		maxi(0, opponent_hand_max_visible),
	)
	while _presentation_opponent_hand_proxies.size() > desired:
		var oldest: Control = _presentation_opponent_hand_proxies.pop_front()
		if oldest != null and is_instance_valid(oldest):
			_dispose_flyer(oldest)
	var back_texture := _texture_for_card_id("")
	while (
		_presentation_opponent_hand_proxies.size() < desired
		and effects != null
		and back_texture != null
	):
		var size_value := _current_opponent_hand_card_size()
		var center := _opponent_hand_center()
		var proxy := _create_paper_card_token(
			back_texture,
			size_value,
			"SnapshotOpponentHandProxy",
			86 + _presentation_opponent_hand_proxies.size(),
			_motion_depth_for_point(center),
		)
		proxy.remove_meta("card_motion_entity")
		proxy.position = center - size_value * 0.5
		effects.add_child(proxy)
		_presentation_opponent_hand_proxies.append(proxy)


func _reflow_opponent_hand_proxies() -> void:
	if _presentation_opponent_hand_proxies.is_empty() or opponent_hand_surface == null:
		return
	var size_value := _current_opponent_hand_card_size()
	var plan := BattleTableLayout.opponent_hand_plan(
		_presentation_opponent_hand_proxies.size(),
		opponent_hand_surface.size.x,
		size_value,
		opponent_hand_minimum_spacing,
		opponent_hand_rotation_degrees,
	)
	var items: Array[Dictionary] = plan.get("items", [])
	for index in range(mini(items.size(), _presentation_opponent_hand_proxies.size())):
		var proxy := _presentation_opponent_hand_proxies[index]
		if proxy == null or not is_instance_valid(proxy):
			continue
		_cancel_hand_layout_motion(proxy)
		var item: Dictionary = items[index]
		var local_center: Vector2 = item.get("position", Vector2.ZERO) + size_value * 0.5
		var global_center := opponent_hand_surface.get_global_transform_with_canvas() * local_center
		_move_snapshot_hand_source(
			proxy,
			_effects_local(global_center),
			float(item.get("rotation_degrees", 0.0)),
			size_value,
			MotionPolicy.duration("hand_reflow"),
		)


func _clear_opponent_hand_transaction(reconcile: bool) -> void:
	if reconcile:
		_layout_opponent_hand(_current_opponent_hand_card_size())
		for node in _presentation_opponent_hand_nodes:
			var control := _valid_control(node)
			if control == null:
				continue
			_presentation_mask_counts.erase(control.get_instance_id())
			if control is CardView:
				(control as CardView).set_presentation_hidden(false)
			else:
				control.modulate.a = 1.0
		if state_ref != null and opponent_hand_count_badge != null:
			var count_value := state_ref.get_player(1 - view_player).hand.size()
			opponent_hand_count_badge.visible = count_value > 0
			opponent_hand_count_badge.text = str(count_value)
	for proxy in _presentation_opponent_hand_proxies.duplicate():
		if proxy != null and is_instance_valid(proxy):
			_cancel_hand_layout_motion(proxy)
			_dispose_flyer(proxy)
	_presentation_opponent_hand_proxies.clear()
	_presentation_opponent_hand_nodes.clear()
	_presentation_opponent_hand_event_ids.clear()
	_presentation_opponent_hand_event_deltas.clear()
	_presentation_opponent_hand_planned_deltas.clear()
	_presentation_opponent_hand_stage_count = 0
	_presentation_opponent_hand_target_cursor = 0


func _reposition_opponent_hand_proxies() -> void:
	if _presentation_opponent_hand_proxies.is_empty() or opponent_hand_surface == null:
		return
	var size_value := _current_opponent_hand_card_size()
	var plan := BattleTableLayout.opponent_hand_plan(
		_presentation_opponent_hand_proxies.size(),
		opponent_hand_surface.size.x,
		size_value,
		opponent_hand_minimum_spacing,
		opponent_hand_rotation_degrees,
	)
	var items: Array[Dictionary] = plan.get("items", [])
	for index in range(mini(items.size(), _presentation_opponent_hand_proxies.size())):
		var proxy := _presentation_opponent_hand_proxies[index]
		if proxy == null or not is_instance_valid(proxy):
			continue
		_cancel_hand_layout_motion(proxy)
		var item: Dictionary = items[index]
		_resize_paper_card_token(proxy, size_value)
		var local_center: Vector2 = item.get("position", Vector2.ZERO) + size_value * 0.5
		var global_center := opponent_hand_surface.get_global_transform_with_canvas() * local_center
		proxy.position = _effects_local(global_center) - size_value * 0.5
		proxy.rotation_degrees = float(item.get("rotation_degrees", 0.0))


func _stage_attachment_source_proxies(events: Array[Dictionary]) -> void:
	_clear_attachment_source_proxies()
	if effects == null:
		return
	for event in events:
		var event_id := str(event.get("event_id", ""))
		var source := _event_source_endpoint(event)
		if (
			event_id.is_empty()
			or str(source.get("slot", "")).is_empty()
			or str(source.get("attachment_type", "")).is_empty()
		):
			continue
		var card_ids := _event_card_ids(event)
		if card_ids.is_empty():
			continue
		var proxy_size := _snapshot_endpoint_size(
			source,
			_flying_card_size(str(event.get("event_type", ""))),
		)
		var rotation := _snapshot_endpoint_rotation(source, 0.0)
		var proxies: Array[Control] = []
		for index in range(mini(card_ids.size(), _max_active_flyers())):
			var card_id := str(card_ids[index])
			var exact_source := source.duplicate(true)
			exact_source["attachment_card_id"] = card_id
			exact_source["attachment_index"] = index
			var base_center := _snapshot_endpoint_center(
				exact_source,
				resolve_endpoint_center(exact_source),
			)
			var texture := _texture_for_card_id(card_id)
			if texture == null:
				continue
			var proxy := _create_paper_card_token(
				texture,
				proxy_size,
				"AttachmentSourceProxy",
				94 + index,
				_motion_depth_for_point(base_center),
			)
			var center := base_center + Vector2(
				float(index) * 2.0,
				-float(index) * 1.5,
			)
			proxy.position = center - proxy.size * 0.5
			proxy.rotation_degrees = rotation
			proxy.set_meta("motion_start", center)
			proxy.set_meta("attachment_source_event_id", event_id)
			effects.add_child(proxy)
			proxies.append(proxy)
		if not proxies.is_empty():
			_presentation_attachment_source_proxies[event_id] = proxies


func _select_virtual_hand_source_rows(
	event: Dictionary,
	virtual_rows: Array[Dictionary],
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if virtual_rows.is_empty():
		return result
	var data: Dictionary = event.get("data", {})
	var card_ids := _event_card_ids(event)
	var amount := _event_amount(event, card_ids)
	var requested_indices: Array[int] = []
	var raw_indices: Variant = data.get("source_indices", [])
	if raw_indices is Array:
		for value in raw_indices:
			var index := int(value)
			if index >= 0 and index < virtual_rows.size() and index not in requested_indices:
				requested_indices.append(index)
	if requested_indices.is_empty():
		var source_index := int(_event_source_endpoint(event).get("index", -1))
		if source_index >= 0:
			for offset in range(amount):
				var index := source_index + offset
				if index >= 0 and index < virtual_rows.size():
					requested_indices.append(index)

	var used_keys: Dictionary = {}
	for requested_index in requested_indices:
		if result.size() >= amount:
			break
		var target_id := (
			str(card_ids[result.size()])
			if result.size() < card_ids.size()
			else ""
		)
		var row: Dictionary = virtual_rows[requested_index]
		if not target_id.is_empty() and str(row.get("card_id", "")) != target_id:
			row = _first_virtual_hand_row_for_card(
				virtual_rows,
				target_id,
				used_keys,
			)
		if row.is_empty():
			continue
		var key := str(row.get("snapshot_key", ""))
		if key.is_empty() or used_keys.has(key):
			continue
		used_keys[key] = true
		result.append(row)

	for card_id_value in card_ids:
		if result.size() >= amount:
			break
		var row := _first_virtual_hand_row_for_card(
			virtual_rows,
			str(card_id_value),
			used_keys,
		)
		if row.is_empty():
			continue
		var key := str(row.get("snapshot_key", ""))
		used_keys[key] = true
		result.append(row)

	for row in virtual_rows:
		if result.size() >= amount:
			break
		var key := str(row.get("snapshot_key", ""))
		if key.is_empty() or used_keys.has(key):
			continue
		used_keys[key] = true
		result.append(row)
	return result


func _first_virtual_hand_row_for_card(
	virtual_rows: Array[Dictionary],
	card_id: String,
	used_keys: Dictionary,
) -> Dictionary:
	if card_id.is_empty():
		return {}
	for row in virtual_rows:
		var key := str(row.get("snapshot_key", ""))
		if used_keys.has(key) or str(row.get("card_id", "")) != card_id:
			continue
		return row
	return {}


func _stage_hand_transition_geometry(previous_snapshot: Dictionary) -> void:
	_clear_hand_layout_tweens()
	_presentation_hand_stage_generation += 1
	_presentation_hand_geometry_staged = false
	var snapshot_hand: Array = previous_snapshot.get("hand", [])
	var current_views: Array[CardView] = []
	for view in hand_views:
		if view != null and view.visible:
			current_views.append(view)
	if snapshot_hand.is_empty() or current_views.is_empty():
		return
	_presentation_hand_old_count = snapshot_hand.size()
	_presentation_hand_final_count = current_views.size()
	_presentation_hand_stage_count = _presentation_hand_old_count
	var used: Dictionary = {}
	var restored := 0
	for row_value in snapshot_hand:
		if not row_value is Dictionary:
			continue
		var row: Dictionary = row_value
		var card_id := str(row.get("card_id", ""))
		var visual_id := str(row.get("visual_id", ""))
		var matched: CardView
		for candidate in current_views:
			var instance_id := candidate.get_instance_id()
			if used.has(instance_id):
				continue
			if (
				(not visual_id.is_empty() and candidate.local_visual_id != visual_id)
				or (visual_id.is_empty() and candidate.card_id != card_id)
			):
				continue
			matched = candidate
			used[instance_id] = true
			break
		if matched == null:
			continue
		var previous_size: Variant = row.get("size", matched.size)
		if previous_size is Vector2:
			matched.custom_minimum_size = previous_size
			matched.size = previous_size
		var center_value: Variant = row.get("center", Vector2.ZERO)
		if center_value is Vector2 and effects != null and hand_surface != null:
			var previous_center: Vector2 = center_value
			var global_center: Vector2 = (
				effects.get_global_transform_with_canvas() * previous_center
			)
			var hand_center: Vector2 = (
				hand_surface.get_global_transform_with_canvas().affine_inverse()
				* global_center
			)
			matched.position = hand_center - matched.size * 0.5
		matched.rotation_degrees = float(row.get(
			"rotation_degrees", matched.rotation_degrees))
		matched.remember_base_position()
		restored += 1
	# A full hand replacement (Professor's Research, Judge, etc.) has no final
	# anchor that can be matched back to the snapshot. The snapshot proxies still
	# own all old cards, so the staged geometry must remain active even when zero
	# real anchors were restored; otherwise the incoming hand is laid out at its
	# final count before the discard sequence begins.
	var old_plan := BattleTableLayout.own_hand_plan(
		_presentation_hand_old_count,
		hand_scroll.size.x,
		_current_hand_card_size(),
		hand_minimum_spacing,
		hand_rotation_degrees,
	)
	hand_surface.custom_minimum_size.x = float(old_plan["surface_width"])
	_presentation_hand_geometry_staged = true


func _schedule_hand_transition_for_event(event: Dictionary, duration: float) -> void:
	if not _presentation_hand_geometry_staged:
		return
	var source := _event_source_endpoint(event)
	var target := _event_target_endpoint(event)
	var actor := int(event.get("actor", view_player))
	if actor != view_player:
		return
	var card_ids := _event_card_ids(event)
	var amount := maxi(1, _event_amount(event, card_ids))
	var generation := _presentation_hand_stage_generation
	var event_id := str(event.get("event_id", ""))
	if str(target.get("zone", "")) == "hand" and str(source.get("zone", "")) != "hand":
		var insertion_sequence := _begin_hand_transition_sequence(event_id, generation)
		_run_hand_insertions(
			amount,
			duration,
			generation,
			event_id,
			insertion_sequence,
		)
	elif str(source.get("zone", "")) == "hand" and str(target.get("zone", "")) != "hand":
		var removal_sequence := _begin_hand_transition_sequence(event_id, generation)
		_run_hand_removal(
			amount,
			duration,
			generation,
			event_id,
			removal_sequence,
		)


func _begin_hand_transition_sequence(
	event_id: String,
	generation: int,
) -> MotionHandle:
	if event_id.is_empty() or not _event_motion_completions.has(event_id):
		return null
	var completion_row: Dictionary = _event_motion_completions.get(event_id, {})
	var group := completion_row.get("group") as MotionGroup
	if group == null:
		return null
	var previous_row: Dictionary = _hand_transition_sequences.get(event_id, {})
	var previous := previous_row.get("handle") as MotionHandle
	if previous != null and not previous.is_finished():
		previous.cancel()
	var handle := MotionHandle.new()
	_hand_transition_sequences[event_id] = {
		"handle": handle,
		"generation": generation,
		"reflow_handles": [],
		"flight_handles": [],
		"landing_handles": [],
	}
	handle.completed.connect(
		_on_hand_transition_sequence_completed.bind(event_id, handle),
		CONNECT_ONE_SHOT,
	)
	group.add(handle)
	return handle


func _on_hand_transition_sequence_completed(
	_completed_handle: MotionHandle,
	event_id: String,
	expected_handle: MotionHandle,
) -> void:
	var row: Dictionary = _hand_transition_sequences.get(event_id, {})
	if row.get("handle") == expected_handle:
		_hand_transition_sequences.erase(event_id)


func _set_hand_sequence_handles(event_id: String, key: String, handles: Array) -> void:
	if not _hand_transition_sequences.has(event_id):
		return
	var row: Dictionary = _hand_transition_sequences[event_id]
	row[key] = handles.duplicate()
	_hand_transition_sequences[event_id] = row


func _hand_sequence_handles(event_id: String, key: String) -> Array:
	var result: Array = []
	var row: Dictionary = _hand_transition_sequences.get(event_id, {})
	for value in row.get(key, []):
		var handle := value as MotionHandle
		if handle != null:
			result.append(handle)
	return result


func _wait_for_motion_handles(handles: Array) -> void:
	var group := MotionGroup.new()
	for value in handles:
		var handle := value as MotionHandle
		if handle != null:
			group.add(handle)
	group.seal()
	if not group.is_completed():
		await group.completed


func _finish_hand_transition_sequence(
	event_id: String,
	handle: MotionHandle,
	cancelled: bool = false,
) -> void:
	if handle == null or handle.is_finished():
		return
	var row: Dictionary = _hand_transition_sequences.get(event_id, {})
	if row.get("handle") != handle:
		handle.cancel()
		return
	if cancelled:
		handle.cancel()
	else:
		handle.finish()


func _run_hand_insertions(
	amount: int,
	flight_duration: float,
	generation: int,
	event_id: String,
	sequence: MotionHandle,
) -> void:
	var delay := flight_duration * 0.55
	if MotionPolicy.reduced():
		delay = 0.0
	if delay > 0.0:
		await get_tree().create_timer(delay).timeout
	if generation != _presentation_hand_stage_generation:
		_finish_hand_transition_sequence(event_id, sequence, true)
		return
	var latest_reflow_handles: Array = []
	# Multi-card arrivals are separated by one stagger interval.  Letting every
	# insertion start the normal (longer) hand reflow means each tween is killed
	# by the next card before it can settle; the visible cards consequently bunch
	# up and only fan out after the final arrival.  A per-insertion reflow still
	# preserves the physical "incoming card pushes the hand" behaviour, but must
	# finish just before the following card reaches the hand.
	var insertion_reflow_duration := -1.0
	if amount > 1 and not MotionPolicy.reduced():
		insertion_reflow_duration = minf(
			MotionPolicy.duration("hand_reflow"),
			MotionPolicy.duration("multi_card_stagger") * 0.82,
		)
	for index in range(amount):
		_presentation_hand_stage_count = mini(
			_presentation_hand_final_count,
			_presentation_hand_stage_count + 1,
		)
		latest_reflow_handles = _tween_hand_to_stage_count(
			_presentation_hand_stage_count,
			insertion_reflow_duration,
		)
		_set_hand_sequence_handles(event_id, "reflow_handles", latest_reflow_handles)
		if index + 1 < amount and not MotionPolicy.reduced():
			await get_tree().create_timer(
				MotionPolicy.duration("multi_card_stagger")).timeout
			if generation != _presentation_hand_stage_generation:
				_finish_hand_transition_sequence(event_id, sequence, true)
				return
	if sequence == null:
		return
	await _wait_for_motion_handles(latest_reflow_handles)
	if sequence.is_finished():
		return
	await _wait_for_motion_handles(_hand_sequence_handles(event_id, "flight_handles"))
	if sequence.is_finished():
		return
	await _wait_for_motion_handles(_hand_sequence_handles(event_id, "landing_handles"))
	_finish_hand_transition_sequence(event_id, sequence)


func _run_hand_removal(
	amount: int,
	flight_duration: float,
	generation: int,
	event_id: String,
	sequence: MotionHandle,
) -> void:
	var delay := minf(0.06, flight_duration * 0.12)
	if MotionPolicy.reduced():
		delay = 0.0
	if delay > 0.0:
		await get_tree().create_timer(delay).timeout
	if generation != _presentation_hand_stage_generation:
		_finish_hand_transition_sequence(event_id, sequence, true)
		return
	_presentation_hand_stage_count = maxi(
		0,
		_presentation_hand_stage_count - amount,
	)
	var reflow_handles := _tween_hand_to_stage_count(_presentation_hand_stage_count)
	reflow_handles.append_array(_tween_snapshot_hand_sources_to_virtual_layout())
	_set_hand_sequence_handles(event_id, "reflow_handles", reflow_handles)
	if sequence == null:
		return
	await _wait_for_motion_handles(reflow_handles)
	_finish_hand_transition_sequence(event_id, sequence)


func _claim_snapshot_hand_sources(event: Dictionary) -> Array[Control]:
	var result: Array[Control] = []
	var event_id := str(event.get("event_id", ""))
	var keys: Array = _presentation_event_hand_sources.get(event_id, [])
	for key_value in keys:
		var key := str(key_value)
		_presentation_hand_virtual_keys.erase(key)
		var proxy := _valid_control(_presentation_hand_proxy_by_key.get(key))
		if proxy != null:
			_cancel_hand_layout_motion(proxy)
			_presentation_hand_source_proxies.erase(proxy)
		_presentation_hand_proxy_by_key.erase(key)
		result.append(proxy)
	return result


func _tween_snapshot_hand_sources_to_virtual_layout() -> Array[MotionHandle]:
	var handles: Array[MotionHandle] = []
	if _presentation_hand_source_proxies.is_empty() or hand_surface == null:
		return handles
	var card_size := _current_hand_card_size()
	var plan := BattleTableLayout.own_hand_plan(
		_presentation_hand_virtual_keys.size(),
		hand_scroll.size.x,
		card_size,
		hand_minimum_spacing,
		hand_rotation_degrees,
	)
	var items: Array[Dictionary] = plan.get("items", [])
	var duration := MotionPolicy.duration("hand_reflow")
	for proxy in _presentation_hand_source_proxies.duplicate():
		if proxy == null or not is_instance_valid(proxy):
			_presentation_hand_source_proxies.erase(proxy)
			continue
		var key := str(proxy.get_meta("snapshot_hand_key", ""))
		var virtual_index := _presentation_hand_virtual_keys.find(key)
		if virtual_index < 0 or virtual_index >= items.size():
			continue
		var item: Dictionary = items[virtual_index]
		var local_center: Vector2 = item.get("position", Vector2.ZERO) + card_size * 0.5
		var global_center := hand_surface.get_global_transform_with_canvas() * local_center
		var target_center := _effects_local(global_center)
		var handle := _move_snapshot_hand_source(
			proxy,
			target_center,
			float(item.get("rotation_degrees", 0.0)),
			card_size,
			duration,
		)
		if handle != null:
			handles.append(handle)
	return handles


func _move_snapshot_hand_source(
	proxy: Control,
	target_center: Vector2,
	target_rotation: float,
	target_size: Vector2,
	duration: float,
) -> MotionHandle:
	var handle := MotionHandle.new()
	if proxy == null or not is_instance_valid(proxy):
		handle.cancel()
		return handle
	_cancel_hand_layout_motion(proxy)
	_resize_paper_card_token(proxy, target_size)
	var target_position := target_center - target_size * 0.5
	if duration <= 0.0:
		proxy.position = target_position
		proxy.rotation_degrees = target_rotation
		handle.finish()
		return handle
	var tween := create_tween().set_parallel(true)
	tween.tween_property(proxy, "position", target_position, duration).set_trans(
		Tween.TRANS_QUAD,
	).set_ease(Tween.EASE_OUT)
	tween.tween_property(
		proxy,
		"rotation_degrees",
		target_rotation,
		duration,
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	handle.bind_tween(tween)
	var instance_id := proxy.get_instance_id()
	_hand_layout_motion_handles[instance_id] = handle
	handle.completed.connect(
		_on_hand_layout_motion_completed.bind(instance_id, handle),
		CONNECT_ONE_SHOT,
	)
	return handle


func _cancel_hand_layout_motion(control: Control) -> void:
	if control == null or not is_instance_valid(control):
		return
	var instance_id := control.get_instance_id()
	var handle := _hand_layout_motion_handles.get(instance_id) as MotionHandle
	if handle != null and not handle.is_finished():
		handle.cancel()
	_hand_layout_motion_handles.erase(instance_id)


func _tween_hand_to_stage_count(
	stage_count: int,
	duration_override: float = -1.0,
) -> Array[MotionHandle]:
	var handles: Array[MotionHandle] = []
	var card_size := _current_hand_card_size()
	var layout_count := mini(stage_count, _presentation_hand_final_count)
	var plan := BattleTableLayout.own_hand_plan(
		layout_count,
		hand_scroll.size.x,
		card_size,
		hand_minimum_spacing,
		hand_rotation_degrees,
	)
	hand_surface.custom_minimum_size.x = float(plan["surface_width"])
	var items: Array[Dictionary] = plan["items"]
	var duration := (
		duration_override
		if duration_override >= 0.0
		else MotionPolicy.duration("hand_reflow")
	)
	for index in range(layout_count):
		if index >= hand_views.size():
			break
		var view := hand_views[index]
		if view == null or not view.visible:
			continue
		var item: Dictionary = items[index]
		view.custom_minimum_size = card_size
		view.size = card_size
		view.z_index = mini(HAND_CARD_MAX_Z, int(item["z_index"]))
		var handle := _move_hand_card(
			view,
			item["position"],
			float(item["rotation_degrees"]),
			duration,
		)
		if handle != null:
			handles.append(handle)
	return handles


func _move_hand_card(
	view: CardView,
	target_position: Vector2,
	target_rotation: float,
	duration: float,
) -> MotionHandle:
	if view == null or not is_instance_valid(view):
		var missing := MotionHandle.new()
		missing.cancel()
		return missing
	var instance_id := view.get_instance_id()
	var previous := _hand_layout_motion_handles.get(instance_id) as MotionHandle
	if previous != null and not previous.is_finished():
		previous.cancel()
	var handle := hand_motion_controller.move_card(
		view,
		target_position,
		target_rotation,
		duration,
	)
	_hand_layout_motion_handles[instance_id] = handle
	handle.completed.connect(
		_on_hand_layout_motion_completed.bind(instance_id, handle),
		CONNECT_ONE_SHOT,
	)
	return handle


func _on_hand_layout_motion_completed(
	_completed_handle: MotionHandle,
	instance_id: int,
	expected_handle: MotionHandle,
) -> void:
	if _hand_layout_motion_handles.get(instance_id) == expected_handle:
		_hand_layout_motion_handles.erase(instance_id)


func _clear_hand_layout_tweens() -> void:
	for handle_value in _hand_layout_motion_handles.values().duplicate():
		var handle := handle_value as MotionHandle
		if handle != null and not handle.is_finished():
			handle.cancel()
	_hand_layout_motion_handles.clear()
	hand_motion_controller.cancel_all()


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
			var discard_endpoints := _discard_endpoints_for_event(event)
			source = discard_endpoints["source"]
			target = discard_endpoints["target"]
			result.append(target)
			if str(source.get("zone", "")) != "hand":
				result.append(source)
		"energy_attached":
			if (
				not str(source.get("zone", "")).is_empty()
				and str(source.get("zone", "")) != "hand"
			):
				result.append(source)
		"cards_selected":
			for endpoint in [source, target]:
				var zone_name := str(endpoint.get("zone", ""))
				if not zone_name.is_empty() and zone_name != "hand":
					result.append(endpoint)
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
			var discard_endpoints := _discard_endpoints_for_event(event)
			source = discard_endpoints["source"]
			target = discard_endpoints["target"]
			_adjust_presentation_zone(
				target,
				_event_amount(event, _event_card_ids(event)),
				_event_card_ids(event),
			)
			if str(source.get("zone", "")) != "hand":
				_adjust_presentation_zone(
					source,
					-_event_amount(event, _event_card_ids(event)),
					[],
				)
		"energy_attached":
			if (
				not str(source.get("zone", "")).is_empty()
				and str(source.get("zone", "")) != "hand"
			):
				_adjust_presentation_zone(
					source,
					-_event_amount(event, _event_card_ids(event)),
					[],
				)
		"cards_selected":
			var selected_ids := _event_card_ids(event)
			var selected_data: Dictionary = event.get("data", {})
			var selected_amount := maxi(0, int(event.get(
				"amount",
				selected_data.get("count", selected_ids.size()),
			)))
			if (
				not str(source.get("zone", "")).is_empty()
				and str(source.get("zone", "")) != "hand"
			):
				_adjust_presentation_zone(source, -selected_amount, [])
			if (
				not str(target.get("zone", "")).is_empty()
				and str(target.get("zone", "")) != "hand"
			):
				_adjust_presentation_zone(target, selected_amount, selected_ids)
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
			var discard_endpoints := _discard_endpoints_for_event(event)
			source = discard_endpoints["source"]
			target = discard_endpoints["target"]
		"pokemon_played":
			if _should_mask_slot_result(event):
				_append_unique_control(result, _slot_view_for_endpoint(target))
		"trainer_played", "stadium_changed":
			pass
		"card_moved":
			if not str(target.get("slot", "")).is_empty() or str(target.get("zone", "")) == "hand":
				result.append_array(_target_controls_for_endpoint(target, event))
		"cards_selected":
			# Search continuations commit their authoritative target before the
			# presentation starts. Keep that real node hidden until the moving card
			# lands, exactly like draws and prize cards.
			if (
				not str(target.get("slot", "")).is_empty()
				or str(target.get("zone", "")) == "hand"
			):
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
	if event_type == "energy_attached":
		_append_unique_control(
			result,
			_slot_view_for_endpoint(_event_source_endpoint(event)),
		)
	elif event_type == "cards_discarded":
		var source := _event_source_endpoint(event)
		if not str(source.get("attachment_type", "")).is_empty():
			_append_unique_control(result, _slot_view_for_endpoint(source))
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
		var slot_name := str(data.get("target_slot", ""))
		if slot_name.is_empty() and str(target.get("zone", "")).is_empty():
			slot_name = str(data.get("slot", ""))
		if not slot_name.is_empty():
			target["slot"] = slot_name
	if str(target.get("zone", "")).is_empty():
		var zone_name := str(data.get("target_zone", ""))
		if not zone_name.is_empty():
			target["zone"] = zone_name
	if not target.has("player"):
		target["player"] = int(data.get("target_player", data.get("player", actor)))
	var inferred_attachment_type := str({
		"energy_attached": "energy",
		"tool_attached": "tool",
	}.get(str(event.get("event_type", "")), ""))
	if (
		not inferred_attachment_type.is_empty()
		and not str(target.get("slot", "")).is_empty()
		and str(target.get("attachment_type", "")).is_empty()
	):
		target["attachment_type"] = inferred_attachment_type
	return target


func _event_source_endpoint(event: Dictionary) -> Dictionary:
	var data: Dictionary = event.get("data", {})
	var actor := int(event.get("actor", data.get("player", view_player)))
	var source := Dictionary(event.get("source", {})).duplicate(true)
	if (
		str(source.get("slot", "")).is_empty()
		and str(source.get("zone", "")).is_empty()
	):
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
	if (
		str(event.get("event_type", "")) == "energy_attached"
		and not str(source.get("slot", "")).is_empty()
		and str(source.get("zone", "")).is_empty()
		and str(source.get("attachment_type", "")).is_empty()
	):
		source["attachment_type"] = "energy"
	return source


func _discard_endpoints_for_event(event: Dictionary) -> Dictionary:
	var actor := int(event.get("actor", view_player))
	var source := _event_source_endpoint(event)
	var target := _event_target_endpoint(event)
	# Legacy hand-discard events sometimes omitted the source completely. A slot
	# is already a complete location, however; treating `zone == ""` alone as an
	# unknown source erased attachment player/slot/index data (Crushing Hammer,
	# retreat costs and attack energy costs all use slot-only endpoints).
	if (
		str(source.get("zone", "")).is_empty()
		and str(source.get("slot", "")).is_empty()
	):
		source["zone"] = "hand"
		if int(source.get("player", -1)) < 0:
			source["player"] = actor
	if (
		str(target.get("zone", "")).is_empty()
		and str(target.get("slot", "")).is_empty()
	):
		target["zone"] = "discard"
	# Discard ownership follows the moved card, not the player who caused the
	# effect. This matters whenever actor != source.player, such as Crushing
	# Hammer removing an opponent's attachment.
	if str(target.get("zone", "")) == "discard":
		target["player"] = int(source.get("player", actor))
	return {"source": source, "target": target}


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
	var target := _event_target_endpoint(event)
	var targets_hand := event_type in ["cards_drawn", "prize_taken"]
	if str(target.get("zone", "")) == "hand":
		targets_hand = true
	if not targets_hand:
		return
	var event_id := str(event.get("event_id", ""))
	var actor := int(event.get("actor", view_player))
	var card_ids := _event_card_ids(event)
	var amount := _event_amount(event, card_ids)
	if event_id.is_empty() or amount <= 0:
		return
	if int(target.get("player", actor)) == 1 - view_player:
		var opponent_targets := _opponent_hand_target_views_for_incoming(event, true)
		if not opponent_targets.is_empty():
			_presentation_event_hand_targets[event_id] = opponent_targets
		return
	if actor != view_player:
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


func _opponent_hand_target_views_for_incoming(
	event: Dictionary,
	consume_cursor: bool = false,
) -> Array[Control]:
	var result: Array[Control] = []
	var event_id := str(event.get("event_id", ""))
	if _presentation_event_hand_targets.has(event_id):
		for value in _presentation_event_hand_targets[event_id]:
			var cached := value as Control
			if cached != null and is_instance_valid(cached):
				result.append(cached)
		return result
	var target := _event_target_endpoint(event)
	if (
		str(target.get("zone", "")) != "hand"
		or int(target.get("player", view_player)) != 1 - view_player
	):
		return result
	var card_ids := _event_card_ids(event)
	var amount := _opponent_hand_event_amount(event)
	if amount <= 0:
		return result
	var visible_views: Array[CardView] = []
	for view in opponent_hand_views:
		if view and view.visible:
			visible_views.append(view)
	var transaction_active := not _presentation_opponent_hand_event_ids.is_empty()
	var first := 0
	var finish := visible_views.size()
	if transaction_active:
		first = clampi(
			_presentation_opponent_hand_target_cursor,
			0,
			visible_views.size(),
		)
		finish = mini(visible_views.size(), first + amount)
	else:
		# Compatibility callers may resolve a single event without staging a
		# replacement transaction.  In that case incoming cards belong to the
		# newly appended tail of the visible opponent hand, not its first cards.
		first = maxi(0, visible_views.size() - mini(amount, visible_views.size()))
	for index in range(first, finish):
		result.append(visible_views[index])
	if consume_cursor and transaction_active:
		_presentation_opponent_hand_target_cursor = finish
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


func _reveal_presentation_node(
	node: Control,
	force: bool = false,
	reveal_duration: float = 0.14,
) -> MotionHandle:
	var handle := MotionHandle.new()
	if node == null or not is_instance_valid(node):
		handle.cancel()
		return handle
	var instance_id := node.get_instance_id()
	if not force:
		var count := int(_presentation_mask_counts.get(instance_id, 0)) - 1
		if count > 0:
			_presentation_mask_counts[instance_id] = count
			handle.finish()
			return handle
	_presentation_mask_counts.erase(instance_id)
	if node is CardView:
		handle = (node as CardView).reveal_presentation(reveal_duration)
		(node as CardView).flash(DesignTokens.GOLD, 0.22)
	elif node is ZoneView:
		(node as ZoneView).reveal_presentation(reveal_duration)
		handle.finish()
	else:
		node.modulate.a = 1.0
		handle.finish()
	return handle


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
	var slot_key := "%d:%s" % [player, slot_name]
	if _presentation_slot_covers.has(slot_key):
		var slot_cover := _valid_card_view(_presentation_slot_covers.get(slot_key))
		if slot_cover != null:
			_presentation_covers[event_id] = [slot_cover]
		return
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
		return false
	var had_cover := false
	for cover_value in covers:
		var cover := _valid_control(cover_value)
		if cover == null:
			continue
		had_cover = true
		if cover in _presentation_slot_covers.values():
			continue
		_dispose_presentation_cover(cover)
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
	_finish_slot_visual_event(event)
	_finish_opponent_hand_event(event)
	_finish_presentation_covers(event_id)
	_clear_active_flyers()
	_flash_presentation_feedbacks(event_id)


func _clear_presentation_masks(reveal: bool) -> void:
	_presentation_hand_stage_generation += 1
	_clear_hand_layout_tweens()
	_clear_snapshot_hand_sources()
	_clear_opponent_hand_transaction(false)
	_clear_attachment_source_proxies()
	_presentation_hand_geometry_staged = false
	_presentation_hand_old_count = 0
	_presentation_hand_final_count = 0
	_presentation_hand_stage_count = 0
	if reveal:
		_clear_all_presentation_nodes()
	_presentation_reveals.clear()
	_presentation_mask_counts.clear()
	_clear_presentation_covers()
	_clear_slot_visual_transactions()
	_presentation_feedbacks.clear()
	_presentation_landing_feedbacks.clear()
	_presentation_event_hand_targets.clear()
	_presentation_hand_target_cursor.clear()
	_presentation_hand_removed_counts.clear()
	_presentation_zone_states.clear()
	if state_ref != null:
		_refresh_field()
		_refresh_header()
		_refresh_log()
		_layout_hand(_current_hand_card_size())


func _dispose_snapshot_hand_source(proxy: Control) -> void:
	if proxy == null or not is_instance_valid(proxy):
		return
	_cancel_hand_layout_motion(proxy)
	_presentation_hand_source_proxies.erase(proxy)
	var key := str(proxy.get_meta("snapshot_hand_key", ""))
	if not key.is_empty() and _presentation_hand_proxy_by_key.get(key) == proxy:
		_presentation_hand_proxy_by_key.erase(key)
	_dispose_flyer(proxy)


func _clear_snapshot_hand_sources() -> void:
	for proxy in _presentation_hand_source_proxies.duplicate():
		_dispose_snapshot_hand_source(proxy)
	_presentation_hand_source_proxies.clear()
	_presentation_hand_proxy_by_key.clear()
	_presentation_event_hand_sources.clear()
	_presentation_hand_snapshot_rows.clear()
	_presentation_hand_virtual_keys.clear()


func _claim_attachment_source_proxies(event: Dictionary) -> Array[Control]:
	var event_id := str(event.get("event_id", ""))
	var result: Array[Control] = []
	for proxy_value in _presentation_attachment_source_proxies.get(event_id, []):
		var proxy := _valid_control(proxy_value)
		if proxy != null:
			result.append(proxy)
	_presentation_attachment_source_proxies.erase(event_id)
	return result


func _clear_attachment_source_proxies() -> void:
	for proxies_value in _presentation_attachment_source_proxies.values():
		for proxy_value in proxies_value:
			var proxy := _valid_control(proxy_value)
			if proxy != null:
				_dispose_flyer(proxy)
	_presentation_attachment_source_proxies.clear()


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


func _motion_landing_control(
	target: Dictionary,
	event: Dictionary,
	index: int,
	staged_hand_nodes: Array,
) -> Control:
	if index < staged_hand_nodes.size():
		var staged := _valid_control(staged_hand_nodes[index])
		if staged != null:
			return staged
	var slot_view := _slot_view_for_endpoint(target)
	if slot_view != null:
		return slot_view
	var zone_name := str(target.get("zone", ""))
	var target_player := int(target.get("player", view_player))
	if zone_name == "hand":
		var hand_targets: Array = (
			_hand_target_views_for_incoming(event)
			if target_player == view_player
			else _opponent_hand_target_views_for_incoming(event)
		)
		if index < hand_targets.size():
			return _valid_control(hand_targets[index])
	return _zone_view_for_endpoint(target)


func _motion_entity_finish(flying: Control, fallback: Vector2) -> Vector2:
	if flying == null or not flying.has_meta("motion_landing_view"):
		return fallback
	var landing_view := _valid_control(flying.get_meta("motion_landing_view"))
	if landing_view == null:
		return fallback
	var attachment_type := str(flying.get_meta(
		"motion_landing_attachment_type",
		"",
	))
	if landing_view is CardView and not attachment_type.is_empty():
		return _effects_local(
			(landing_view as CardView).attachment_anchor_global(
				attachment_type,
				str(flying.get_meta("motion_landing_attachment_card_id", "")),
				int(flying.get_meta("motion_landing_attachment_index", -1)),
			)
		)
	return anchor_resolver.control_center(landing_view)


func _on_card_motion_requested(event: Dictionary, duration: float) -> void:
	var data: Dictionary = event.get("data", {})
	var motion_event_id := str(event.get("event_id", ""))
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
	# MotionPolicy already caps concurrent entities at 12/8 by quality. Do not
	# impose a second hard-coded five-card ceiling: large draws/returns otherwise
	# change the visible card count and appear to teleport their remainder.
	var visible_limit := _max_active_flyers()
	var visible_count := mini(visible_limit, maxi(amount, card_ids.size()))
	if event_type == "cards_drawn":
		source = {"player": actor, "zone": "deck"}
		target = {"player": actor, "zone": "hand"}
	elif event_type == "cards_discarded":
		var discard_endpoints := _discard_endpoints_for_event(event)
		source = discard_endpoints["source"]
		target = discard_endpoints["target"]
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
	var staged_source_proxies: Array[Control] = []
	if (
		str(source.get("zone", "")) == "hand"
		and int(source.get("player", actor)) == view_player
	):
		staged_source_proxies = _claim_snapshot_hand_sources(event)
	elif (
		str(source.get("zone", "")) == "hand"
		and int(source.get("player", actor)) == 1 - view_player
	):
		staged_source_proxies = _claim_opponent_hand_sources(event)
	var staged_attachment_proxies := _claim_attachment_source_proxies(event)
	_schedule_hand_transition_for_event(event.merged({
		"source": source,
		"target": target,
	}, true), duration)
	if AppSettings.reduced_motion:
		for proxy in staged_source_proxies:
			_dispose_snapshot_hand_source(proxy)
		for proxy in staged_attachment_proxies:
			_dispose_flyer(proxy)
		var reduced_feedback: Dictionary = _presentation_landing_feedbacks.get(
			motion_event_id,
			{},
		)
		_presentation_landing_feedbacks.erase(motion_event_id)
		_burst_world_at_motion_point(
			resolve_endpoint_center(target),
			reduced_feedback.get(
				"color",
				_motion_landing_color(event_type),
			) as Color,
			str(reduced_feedback.get("kind", "card_move")),
		)
		_finish_event_motion_dispatch(motion_event_id)
		return
	if event_type == "deck_shuffled":
		_spawn_shuffle_motion(source, duration, motion_event_id)
		_finish_event_motion_dispatch(motion_event_id)
		return
	if _spawn_slot_transition(event, duration, motion_event_id):
		_finish_event_motion_dispatch(motion_event_id)
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
	var landing_nodes: Array = _presentation_event_hand_targets.get(
		str(event.get("event_id", "")),
		[],
	)
	for index in range(visible_count):
		var existing_flyer: Control
		if index < staged_source_proxies.size():
			existing_flyer = staged_source_proxies[index]
		elif index < staged_attachment_proxies.size():
			existing_flyer = staged_attachment_proxies[index]
		if index == 0 and str(source.get("zone", "")) == "hand":
			if _presentation_drag_proxy != null:
				_dispose_snapshot_hand_source(existing_flyer)
				existing_flyer = _presentation_drag_proxy
		var card_id := str(card_ids[index]) if index < card_ids.size() else event_card_id
		var source_hidden := _endpoint_hidden_from_view(source)
		var target_hidden := _endpoint_hidden_from_view(target)
		var texture := _texture_for_card_id("" if source_hidden else card_id)
		var flip_texture: Texture2D
		if source_hidden != target_hidden and not card_id.is_empty():
			flip_texture = _texture_for_card_id("" if target_hidden else card_id)
		if texture == null:
			_dispose_snapshot_hand_source(existing_flyer)
			continue
		var start := starts[index] if index < starts.size() else base_start
		var finish := finishes[index] if index < finishes.size() else base_finish
		var timing := _flying_card_timing(index, visible_count, duration)
		if not bool(timing.get("spawn", false)):
			_dispose_snapshot_hand_source(existing_flyer)
			_landing_burst(finish, event_type)
			continue
		var landing_view := _motion_landing_control(
			target,
			event,
			index,
			landing_nodes,
		)
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
			landing_view,
			existing_flyer,
			motion_event_id,
			str(target.get("attachment_type", "")),
			(
				card_id
				if not str(target.get("attachment_type", "")).is_empty()
				else ""
			),
			index,
			flip_texture,
			(
				str(target.get("zone", "")) == "hand"
				and int(target.get("player", actor)) == 1 - view_player
				and not _presentation_opponent_hand_event_ids.is_empty()
			),
			(
				0
				if (
					str(source.get("zone", "")) == "hand"
					and int(source.get("player", actor)) == 1 - view_player
				)
				else 1
			),
		)
		if index == 0 and str(source.get("zone", "")) == "hand":
			_presentation_drag_proxy = null
	for index in range(visible_count, staged_source_proxies.size()):
		_dispose_snapshot_hand_source(staged_source_proxies[index])
	for index in range(visible_count, staged_attachment_proxies.size()):
		_dispose_flyer(staged_attachment_proxies[index])
	_finish_event_motion_dispatch(motion_event_id)


func _register_event_motion(
	flying: Control,
	event_id: String,
	tween: Tween,
) -> void:
	if (
		event_id.is_empty()
		or flying == null
		or not is_instance_valid(flying)
		or not _event_motion_completions.has(event_id)
	):
		return
	var row: Dictionary = _event_motion_completions.get(event_id, {})
	var group := row.get("group") as MotionGroup
	if group == null:
		return
	var handle := MotionHandle.new()
	handle.bind_tween(tween)
	group.add(handle)
	if _hand_transition_sequences.has(event_id):
		var hand_row: Dictionary = _hand_transition_sequences[event_id]
		var flight_handles: Array = hand_row.get("flight_handles", [])
		flight_handles.append(handle)
		hand_row["flight_handles"] = flight_handles
		_hand_transition_sequences[event_id] = hand_row
	flying.set_meta("motion_event_id", event_id)
	flying.set_meta("motion_handle", handle)


func _finish_event_motion_dispatch(event_id: String) -> void:
	if event_id.is_empty() or not _event_motion_completions.has(event_id):
		return
	var row: Dictionary = _event_motion_completions.get(event_id, {})
	var group := row.get("group") as MotionGroup
	if group != null:
		group.seal()
	if group == null or group.is_completed():
		_event_motion_completions.erase(event_id)


func _complete_event_motion_entity(flying: Control) -> void:
	if flying == null or not is_instance_valid(flying):
		return
	if not flying.has_meta("motion_handle"):
		return
	var handle := flying.get_meta("motion_handle") as MotionHandle
	if handle != null:
		handle.cancel()
	flying.remove_meta("motion_handle")


func _finish_all_event_motions() -> void:
	var rows := _event_motion_completions.values().duplicate()
	_event_motion_completions.clear()
	for row_value in rows:
		var row := row_value as Dictionary
		var group := row.get("group") as MotionGroup
		if group != null:
			group.cancel()
		var completion := row.get("completion") as PresentationDirector.EventCompletion
		if completion != null:
			completion.finish()


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
	if not str(source.get("slot", "")).is_empty():
		var component_result: Array[Vector2] = []
		for index in range(visible_count):
			var card_id := str(card_ids[index]) if index < card_ids.size() else ""
			var component_endpoint := _slot_component_endpoint(
				source,
				card_id,
				index,
			)
			component_result.append(_snapshot_endpoint_center(
				component_endpoint,
				fallback_start,
			))
		return component_result
	if not str(source.get("attachment_type", "")).is_empty():
		var attachment_result: Array[Vector2] = []
		for index in range(visible_count):
			var exact_source := source.duplicate(true)
			if index < card_ids.size():
				exact_source["attachment_card_id"] = str(card_ids[index])
			exact_source["attachment_index"] = index
			attachment_result.append(_snapshot_endpoint_center(
				exact_source,
				fallback_start,
			))
		return attachment_result
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
	card_ids: Array,
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
	if not str(target.get("attachment_type", "")).is_empty():
		for index in range(visible_count):
			var exact_target := target.duplicate(true)
			if index < card_ids.size():
				exact_target["attachment_card_id"] = str(card_ids[index])
			exact_target["attachment_index"] = index
			result.append(resolve_endpoint_center(exact_target))
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
	for index in range(visible_count):
		if not str(source.get("slot", "")).is_empty():
			var card_id := str(card_ids[index]) if index < card_ids.size() else ""
			var component_endpoint := _slot_component_endpoint(source, card_id, index)
			result.append(_snapshot_endpoint_size(component_endpoint, size_value))
		else:
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


func _slot_component_endpoint(
	source: Dictionary,
	card_id: String,
	component_index: int,
) -> Dictionary:
	var result := source.duplicate(true)
	if card_id.is_empty() or str(source.get("slot", "")).is_empty():
		return result
	var row := _snapshot_slot_row(
		int(source.get("player", view_player)),
		str(source.get("slot", "")),
	)
	var pokemon_data: Dictionary = row.get("pokemon", {})
	if pokemon_data.is_empty():
		return result
	if card_id == str(pokemon_data.get("attached_tool_id", "")):
		result["attachment_type"] = "tool"
		result["attachment_card_id"] = card_id
	elif card_id in Array(pokemon_data.get("energy_card_ids", [])):
		result["attachment_type"] = "energy"
		result["attachment_card_id"] = card_id
		result["attachment_index"] = component_index
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
			var attachment_type := str(endpoint.get("attachment_type", ""))
			if not attachment_type.is_empty():
				var attachment_centers: Dictionary = slot_row.get(
					"attachment_centers",
					{},
				)
				var attachment_card_id := str(endpoint.get(
					"attachment_card_id",
					endpoint.get("card_id", ""),
				))
				var attachment_key := (
					"%s:%s" % [attachment_type, attachment_card_id]
					if not attachment_card_id.is_empty()
					else attachment_type
				)
				if attachment_centers.has(attachment_key):
					return _vector_or_default(
						attachment_centers.get(attachment_key),
						fallback,
					)
				if attachment_centers.has(attachment_type):
					return _vector_or_default(
						attachment_centers.get(attachment_type),
						fallback,
					)
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
			if not str(endpoint.get("attachment_type", "")).is_empty():
				return _attachment_motion_size(
					_vector_or_default(slot_row.get("size"), fallback),
					fallback,
				)
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
			if not str(endpoint.get("attachment_type", "")).is_empty():
				return _attachment_motion_size(view.size, fallback)
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
			return _zone_card_size(zone)
	return fallback


func _attachment_motion_size(slot_size: Vector2, fallback: Vector2) -> Vector2:
	var reference := slot_size if slot_size != Vector2.ZERO else fallback
	var height := clampf(
		minf(reference.y * 0.48, PAPER_CARD_BASE_SIZE.y * 0.58),
		32.0,
		PAPER_CARD_BASE_SIZE.y * 0.58,
	)
	return Vector2(height * PAPER_CARD_BASE_SIZE.x / PAPER_CARD_BASE_SIZE.y, height)


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
	if not _presentation_opponent_hand_proxies.is_empty():
		var first_proxy := maxi(
			0,
			_presentation_opponent_hand_proxies.size()
			- mini(visible_count, _presentation_opponent_hand_proxies.size()),
		)
		for index in range(first_proxy, _presentation_opponent_hand_proxies.size()):
			var proxy := _presentation_opponent_hand_proxies[index]
			if proxy != null and is_instance_valid(proxy):
				result.append(proxy.position + proxy.size * 0.5)
		if result.size() >= visible_count:
			return result
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
	var player := int(endpoint.get("player", view_player))
	if zone_name.is_empty() or zone_name == "hand":
		return _stack_offset(index, visible_count, zone_name == "hand")
	var zone := _zone_view_for_endpoint(endpoint)
	var direction := "up"
	var depth := 0.55
	if zone:
		direction = zone.stack_visual_direction
		depth = zone.table_depth
	var step := (
		zone.get_stack_motion_step()
		if zone
		else _stack_visual_step(direction, depth)
	)
	if zone:
		var zone_transform := zone.get_global_transform_with_canvas()
		var step_origin := _effects_local(zone_transform * Vector2.ZERO)
		step = _effects_local(zone_transform * step) - step_origin
	var clamped_index := clampi(index, 0, maxi(0, visible_count - 1))
	if zone_name == "prizes":
		var stack_count := zone.count if zone else visible_count
		if leaving_stack:
			var staged_key := _presentation_zone_key({
				"player": player,
				"zone": "prizes",
			})
			var staged_row: Dictionary = _presentation_zone_states.get(
				staged_key,
				{},
			)
			if not staged_row.is_empty():
				stack_count = int(staged_row.get("count", stack_count))
			else:
				var snapshot_row := _snapshot_zone_row(player, "prizes")
				stack_count = int(snapshot_row.get("count", stack_count))
			# With no explicit prize index, remove cards from the visible fan edge.
			# A one-card pile therefore starts exactly at the physical face center.
			var source_slot := maxi(0, stack_count - 1 - clamped_index)
			return step * float(source_slot)
		# Incoming cards occupy the newly added rightmost slots in final-state order.
		var first_target_slot := maxi(0, stack_count - visible_count)
		var target_slot := first_target_slot + clamped_index
		if zone:
			target_slot = mini(target_slot, maxi(0, zone.stack_visual_max_count - 1))
		return step * float(target_slot)
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
		"down_left":
			return Vector2(-1.5, 3.6) * depth_scale
		"up_right":
			return Vector2(1.5, -3.6) * depth_scale
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
	# True means the identity must stay hidden for the entire flight. A transition
	# from a hidden pile to a public local zone now starts on the back and flips at
	# mid-flight, so only hidden-to-hidden movement is fully concealed.
	return _endpoint_hidden_from_view(source) and _endpoint_hidden_from_view(target)


func _endpoint_hidden_from_view(endpoint: Dictionary) -> bool:
	var zone_name := str(endpoint.get("zone", ""))
	if zone_name in ["deck", "prizes"]:
		return true
	if zone_name == "hand":
		return int(endpoint.get("player", view_player)) != view_player
	return false


func _spawn_slot_transition(
	event: Dictionary,
	duration: float,
	motion_event_id: String = "",
) -> bool:
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
			finish_view,
			null,
			motion_event_id,
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
	var delay_step := 0.0
	if stagger and count > 1:
		delay_step = motion_stagger_delay
	var delay := float(clamped_index) * delay_step
	# Each card receives the full physical flight. Subtracting its launch delay
	# made every card land on the same frame, defeating the stagger visually.
	var flight_duration := playable_duration
	if flight_duration < MIN_FLYING_CARD_DURATION:
		return {"spawn": false, "delay": 0.0, "duration": 0.0}
	return {"spawn": true, "delay": delay, "duration": flight_duration}


func _landing_burst(finish: Vector2, event_type: String) -> void:
	_burst_world_at_motion_point(
		finish,
		_motion_landing_color(event_type),
		"card_land",
	)


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
	single_face: bool = true,
) -> Control:
	var card := CardMotionEntity.new()
	card.name = transient_kind
	card.configure_motion("visual:%d" % card.get_instance_id())
	card.set_meta("battle_transient_visual", true)
	card.set_meta("battle_transient_kind", transient_kind)
	card.set_meta("paper_card_token", true)
	card.set_meta("paper_card_single_face", single_face)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.size = size_value
	card.custom_minimum_size = size_value
	card.pivot_offset = size_value * 0.5
	card.z_index = z_value

	var shadow := Panel.new()
	shadow.name = "PaperShadow"
	shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shadow.position = Vector2.ZERO
	shadow.size = size_value
	var shadow_style := DesignTokens.shadow_style(int(8.0 + depth * 7.0))
	# Motion already separates the card from the table.  An offset filled panel
	# reads as a second card stuck underneath, so every transient card uses only
	# a transparent soft cast shadow.
	shadow_style.bg_color = Color.TRANSPARENT
	shadow_style.shadow_color = Color(0.0, 0.0, 0.0, 0.42)
	shadow_style.shadow_size = 7
	shadow_style.shadow_offset = Vector2(0.0, 4.0)
	shadow.add_theme_stylebox_override(
		"panel",
		shadow_style,
	)
	card.add_child(shadow)

	var inset := (
		0.0
		if single_face
		else maxf(2.0, minf(size_value.x, size_value.y) * 0.032)
	)
	var image := TextureRect.new()
	image.name = "PaperImage"
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	image.texture = texture
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = (
		TextureRect.STRETCH_KEEP_ASPECT_COVERED
		if single_face
		else TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	)
	image.position = Vector2(inset, inset)
	image.size = Vector2(
		maxf(1.0, size_value.x - inset * 2.0),
		maxf(1.0, size_value.y - inset * 2.0),
	)
	image.z_index = 2
	card.add_child(image)

	if not single_face:
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
	var single_face := bool(card.get_meta("paper_card_single_face", true))
	var inset := (
		0.0
		if single_face
		else maxf(2.0, minf(size_value.x, size_value.y) * 0.032)
	)
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


func _spawn_shuffle_motion(
	endpoint: Dictionary,
	duration: float,
	motion_event_id: String = "",
) -> bool:
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
		card_motion_layer.add(flyer)
		var tween := create_tween()
		if delay > 0.0:
			tween.tween_interval(delay)
		card_motion_layer.bind_tween(flyer, tween)
		tween.tween_method(
			_update_shuffle_card.bind(flyer, start, split, finish, spin),
			0.0,
			1.0,
			motion_duration,
		).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
		tween.tween_callback(_finish_flyer.bind(flyer, origin, "deck_shuffled"))
		_register_event_motion(flyer, motion_event_id, tween)
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
	landing_view: Control = null,
	existing_flyer: Control = null,
	motion_event_id: String = "",
	landing_attachment_type: String = "",
	landing_attachment_card_id: String = "",
	landing_attachment_index: int = -1,
	flip_texture: Texture2D = null,
	stage_opponent_hand_landing: bool = false,
	opponent_hand_stage_count_delta: int = 0,
) -> void:
	_prune_flyers()
	while existing_flyer == null and _active_flyers.size() >= _max_active_flyers():
		var oldest: Control = _active_flyers.pop_front()
		_dispose_flyer(oldest)
	var default_size := _flying_card_size(event_type)
	var flying_size := start_size if start_size != Vector2.ZERO else default_size
	var landing_size := finish_size if finish_size != Vector2.ZERO else default_size
	var motion_start := start
	var flying: Control
	if existing_flyer != null and is_instance_valid(existing_flyer):
		flying = existing_flyer
		_cancel_hand_layout_motion(flying)
		motion_start = flying.position + flying.size * 0.5
		flying_size = flying.size
		# A staged hand proxy may already have reflowed, and a drag proxy may be
		# tilted at its parked target. Continue from that exact pose instead of
		# snapping back to the batch snapshot rotation.
		start_rotation = flying.rotation_degrees
		var previous := _flyer_tweens.get(flying.get_instance_id()) as Tween
		if previous != null and previous.is_valid():
			previous.kill()
		_flyer_tweens.erase(flying.get_instance_id())
		if flying not in _active_flyers:
			card_motion_layer.add(flying)
	else:
		flying = _create_paper_card_token(
			texture,
			flying_size,
			"CardMotionEntity",
			100 + index,
			_motion_depth_for_point((start + finish) * 0.5),
		)
	flying.set_meta("card_motion_entity", true)
	flying.set_meta("motion_start", motion_start)
	flying.set_meta("motion_finish", finish)
	flying.set_meta("motion_start_size", flying_size)
	flying.set_meta("motion_finish_size", landing_size)
	if landing_view != null:
		flying.set_meta("motion_landing_view", landing_view)
	if not landing_attachment_type.is_empty():
		flying.set_meta(
			"motion_landing_attachment_type",
			landing_attachment_type,
		)
	elif flying.has_meta("motion_landing_attachment_type"):
		flying.remove_meta("motion_landing_attachment_type")
	if not landing_attachment_card_id.is_empty():
		flying.set_meta(
			"motion_landing_attachment_card_id",
			landing_attachment_card_id,
		)
		flying.set_meta("motion_landing_attachment_index", landing_attachment_index)
	if flip_texture != null:
		flying.set_meta("motion_flip_texture", flip_texture)
		flying.set_meta("motion_flip_swapped", false)
	elif flying.has_meta("motion_flip_texture"):
		flying.remove_meta("motion_flip_texture")
		flying.remove_meta("motion_flip_swapped")
	if stage_opponent_hand_landing:
		flying.set_meta("opponent_hand_staged_landing", true)
		flying.set_meta(
			"opponent_hand_stage_count_delta",
			opponent_hand_stage_count_delta,
		)
	elif flying.has_meta("opponent_hand_staged_landing"):
		flying.remove_meta("opponent_hand_staged_landing")
		flying.remove_meta("opponent_hand_stage_count_delta")
	flying.position = motion_start - flying.size * 0.5
	flying.pivot_offset = flying.size * 0.5
	flying.rotation_degrees = start_rotation
	flying.modulate.a = 1.0
	card_motion_layer.add(flying)
	var drag_continuation := flying.has_meta("drag_session_id")
	var travel_distance := motion_start.distance_to(finish)
	if drag_continuation:
		# The player already performed the large spatial movement. Successful
		# authority only needs a short physical settle from the release/park pose;
		# replaying the normal 74 px arc reads as a second card placement.
		duration = minf(duration, clampf(travel_distance / 420.0, 0.12, 0.22))
		delay = 0.0
	var arc_height := (
		clampf(travel_distance * 0.16, 10.0, 26.0)
		if drag_continuation
		else maxf(
			motion_arc_height_min,
			travel_distance * motion_arc_distance_ratio,
		)
	)
	var control := Vector2(
		(motion_start.x + finish.x) * 0.5,
		minf(motion_start.y, finish.y) - arc_height - float(index) * motion_arc_stagger_height,
	)
	var spin := 2.0 if drag_continuation else (
		16.0 + float(index) * 2.0
		if event_type in ["cards_discarded", "pokemon_ko"]
		else -7.0 + float(index) * 3.0
	)
	var tween := create_tween()
	if delay > 0.0:
		tween.tween_interval(delay)
	card_motion_layer.bind_tween(flying, tween)
	tween.tween_method(
		_update_flyer.bind(
			flying,
			motion_start,
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
	if landing_view != null:
		var landing_wait := (
			MotionPolicy.duration("draw_landing")
			if event_type in ["cards_drawn", "prize_taken"]
			else 0.14
		)
		var landing_feedback: Dictionary = _presentation_landing_feedbacks.get(
			motion_event_id,
			{},
		)
		landing_wait = maxf(
			landing_wait,
			float(landing_feedback.get("camera_duration", 0.0)),
		)
		if bool(flying.get_meta("opponent_hand_staged_landing", false)):
			landing_wait = maxf(
				landing_wait,
				MotionPolicy.duration("hand_reflow"),
			)
		tween.tween_interval(landing_wait)
	_register_event_motion(flying, motion_event_id, tween)


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
	var dynamic_finish := _motion_entity_finish(flying, finish)
	var dynamic_control := control + (dynamic_finish - finish) * 0.5
	var inverse := 1.0 - progress
	var point := (
		start * inverse * inverse
		+ dynamic_control * 2.0 * inverse * progress
		+ dynamic_finish * progress * progress
	)
	var size_value := start_size.lerp(finish_size, progress)
	_resize_paper_card_token(flying, size_value)
	flying.position = point - size_value * 0.5
	flying.rotation_degrees = (
		lerpf(start_rotation, finish_rotation, progress)
		+ sin(progress * PI) * spin * 0.12
	)
	var lift := 1.0 + sin(progress * PI) * 0.16
	var flip_scale := _update_flyer_flip(flying, progress)
	flying.scale = Vector2(lift * flip_scale, lift)
	flying.modulate.a = 1.0


func _update_flyer_flip(flying: Control, progress: float) -> float:
	if flying == null or not flying.has_meta("motion_flip_texture"):
		return 1.0
	var phase := clampf((progress - 0.32) / 0.34, 0.0, 1.0)
	if phase >= 0.5 and not bool(flying.get_meta("motion_flip_swapped", false)):
		var paper_image := flying.get_node_or_null("PaperImage") as TextureRect
		if paper_image != null:
			paper_image.texture = flying.get_meta("motion_flip_texture") as Texture2D
		flying.set_meta("motion_flip_swapped", true)
	return maxf(0.025, absf(cos(phase * PI)))


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
	finish = _motion_entity_finish(flying, finish)
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
	if flying.has_meta("motion_flip_texture"):
		var paper_image := flying.get_node_or_null("PaperImage") as TextureRect
		if paper_image != null:
			paper_image.texture = flying.get_meta("motion_flip_texture") as Texture2D
	var handed_off_to_local_hand := false
	if flying.has_meta("motion_landing_view"):
		var landing_view := _valid_control(flying.get_meta("motion_landing_view"))
		if landing_view != null:
			handed_off_to_local_hand = (
				event_type in ["cards_drawn", "prize_taken"]
				and landing_view is CardView
				and (landing_view as CardView).hand_index >= 0
				and (landing_view as CardView).owner_player == view_player
			)
			var reveal_duration := (
				0.0
				if handed_off_to_local_hand
				else MotionPolicy.duration("draw_landing")
				if event_type in ["cards_drawn", "prize_taken"]
				else 0.14
			)
			var reveal_handle := _reveal_presentation_node(
				landing_view,
				false,
				reveal_duration,
			)
			var event_id := str(flying.get_meta("motion_event_id", ""))
			if not event_id.is_empty() and _hand_transition_sequences.has(event_id):
				var row: Dictionary = _hand_transition_sequences[event_id]
				var landing_handles: Array = row.get("landing_handles", [])
				landing_handles.append(reveal_handle)
				row["landing_handles"] = landing_handles
				_hand_transition_sequences[event_id] = row
			_remove_revealed_node_from_events(landing_view)
	if not _play_card_landing_feedback(flying, finish):
		_burst_world_at_motion_point(
			finish,
			_motion_landing_color(event_type),
			"card_land",
		)
	_adopt_opponent_hand_landing_flyer(flying)
	if handed_off_to_local_hand and is_instance_valid(flying):
		# The landing CardView now owns the visual and will participate in every
		# later insertion reflow.  Keeping the completed flyer visible at its old
		# landing pose produced a second, stale hand fan until the event ended.
		flying.visible = false
		flying.modulate.a = 0.0
		flying.set_meta("motion_visual_handed_off", true)


func _remove_revealed_node_from_events(node: Control) -> void:
	for event_id_value in _presentation_reveals.keys():
		var event_id := str(event_id_value)
		var nodes: Array = _presentation_reveals.get(event_id, [])
		if node in nodes:
			nodes.erase(node)
			_presentation_reveals[event_id] = nodes


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
	_active_flyers.assign(live)


func _clear_active_flyers() -> void:
	for tween_value in _flyer_tweens.values():
		var tween := tween_value as Tween
		if tween and tween.is_valid():
			tween.kill()
	_flyer_tweens.clear()
	for flyer in _active_flyers.duplicate():
		if is_instance_valid(flyer):
			_complete_event_motion_entity(flyer)
			flyer.visible = false
			flyer.modulate.a = 0.0
			flyer.free()
	_active_flyers.clear()
	_clear_effect_child_controls(["CardMotionEntity", "FlyingCard"])
	_finish_all_event_motions()


func _clear_transient_visuals() -> void:
	if camera_rig != null:
		camera_rig.cancel()
	_clear_presentation_masks(true)
	_clear_active_flyers()
	if effects:
		effects.clear_transients()
	if world_feedback:
		world_feedback.clear_transients()
	if announcement_layer:
		announcement_layer.clear()
	_clear_effect_child_controls()
	_clear_all_presentation_nodes()


func _dispose_flyer(flying: Control) -> void:
	if not is_instance_valid(flying):
		return
	_cancel_hand_layout_motion(flying)
	_complete_event_motion_entity(flying)
	var tween := _flyer_tweens.get(flying.get_instance_id()) as Tween
	if tween and tween.is_valid():
		tween.kill()
	_flyer_tweens.erase(flying.get_instance_id())
	card_motion_layer.forget(flying)
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
		if (
			not prefixes.is_empty()
			and kind_value == "SnapshotOpponentHandProxy"
		):
			continue
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
		_complete_event_motion_entity(control)
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
	if camera_rig != null:
		var handle := camera_rig.impulse(
			strength,
			duration,
			AppSettings.reduced_motion,
		)
		director.register_feedback_motion(handle)


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
	var local_center := zone.size * 0.5
	if zone.stack_visual_mode == "prizes":
		local_center = zone.get_stack_face_rect().get_center()
	return _effects_local(zone.get_global_transform_with_canvas() * local_center)


func _zone_card_size(zone: ZoneView) -> Vector2:
	if zone != null and zone.stack_visual_mode == "prizes":
		return zone.get_stack_face_size()
	return zone.size if zone != null else Vector2.ZERO


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

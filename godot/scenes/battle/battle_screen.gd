class_name BattleScreen
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

@onready var table: BattleTable = %BattleTable

var state_ref: GameState:
	get:
		if table:
			return table.state_ref
		return null
	set(value):
		if table:
			table.state_ref = value
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
# Keep the compatibility facade broad: callers historically treated this as a
# generic Control/Container surface, while BattleTable owns the concrete HUD.
var hud: Control
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
var log_panel: PanelContainer
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
var _initialized := false
var _signals_bound := false


func _ready() -> void:
	initialize_ui()


func initialize_ui() -> void:
	_resolve_table()
	if table == null:
		return
	table.initialize_ui()
	_bind_table_signals()
	_sync_from_table()
	_initialized = true


func update_view(
	state: GameState,
	p_view_player: int,
	p_action_rows: Array[Dictionary],
	p_selected_entity_key: String,
	p_ai_thinking: bool,
	p_game_mode: String,
) -> void:
	_resolve_table()
	if table == null:
		return
	table.update_view(
		state,
		p_view_player,
		p_action_rows,
		p_selected_entity_key,
		p_ai_thinking,
		p_game_mode,
	)
	_sync_from_table()


func set_choice_targets(options_by_source: Dictionary, prompt: String) -> void:
	if table:
		table.set_choice_targets(options_by_source, prompt)


func clear_choice_targets() -> void:
	if table:
		table.clear_choice_targets()


func play_presentation(
	raw_events: Array,
	revision: int,
	fallback_actor: int = -1,
	previous_snapshot: Dictionary = {},
) -> void:
	_sync_to_table()
	table.play_presentation(raw_events, revision, fallback_actor, previous_snapshot)
	_sync_from_table()


func clear_presentation_for_resync() -> void:
	_sync_to_table()
	table.clear_presentation_for_resync()
	_sync_from_table()


func show_card_detail(card_id: String, pokemon: PokemonState = null) -> void:
	table.show_card_detail(card_id, pokemon)
	_sync_from_table()


func hide_card_detail() -> void:
	table.hide_card_detail()
	_sync_from_table()


func get_slot_view(player: int, slot: String) -> CardView:
	return table.get_slot_view(player, slot)


func capture_presentation_snapshot() -> Dictionary:
	_sync_to_table()
	var result := table.capture_presentation_snapshot()
	_sync_from_table()
	return result


func resolve_endpoint_center(endpoint: Dictionary) -> Vector2:
	_sync_to_table()
	return table.resolve_endpoint_center(endpoint)


func _target_points_for_event(
	target: Dictionary,
	card_ids: Array,
	visible_count: int,
	fallback_finish: Vector2,
	event: Dictionary,
) -> Array[Vector2]:
	_sync_to_table()
	var result: Array[Vector2] = table._target_points_for_event(
		target,
		card_ids,
		visible_count,
		fallback_finish,
		event,
	)
	_sync_from_table()
	return result


func _source_points_for_event(
	source: Dictionary,
	card_ids: Array,
	visible_count: int,
	fallback_start: Vector2,
) -> Array[Vector2]:
	_sync_to_table()
	var result: Array[Vector2] = table._source_points_for_event(
		source,
		card_ids,
		visible_count,
		fallback_start,
	)
	_sync_from_table()
	return result


func _discard_hand_start_points(
	card_ids: Array,
	visible_count: int,
	fallback_start: Vector2,
) -> Array[Vector2]:
	_sync_to_table()
	var result: Array[Vector2] = table._discard_hand_start_points(
		card_ids,
		visible_count,
		fallback_start,
	)
	_sync_from_table()
	return result


func _effects_local(global_point: Vector2) -> Vector2:
	return table._effects_local(global_point)


func _own_hand_center() -> Vector2:
	return table._own_hand_center()


func _opponent_hand_center() -> Vector2:
	return table._opponent_hand_center()


func _motion_card_hidden_from_view(
	card_id: String,
	source: Dictionary,
	target: Dictionary,
) -> bool:
	return table._motion_card_hidden_from_view(card_id, source, target)


func _stage_presentation_targets(
	normalized_events: Array,
	previous_snapshot: Dictionary,
) -> void:
	_sync_to_table()
	table._stage_presentation_targets(normalized_events, previous_snapshot)
	_sync_from_table()


func _on_presentation_event_finished(event: Dictionary) -> void:
	_sync_to_table()
	table._on_presentation_event_finished(event)
	_sync_from_table()


func _on_card_motion_requested(event: Dictionary, duration: float) -> void:
	_sync_to_table()
	table._on_card_motion_requested(event, duration)
	_sync_from_table()


func _clear_transient_visuals() -> void:
	_sync_to_table()
	table._clear_transient_visuals()
	_sync_from_table()


func _on_detail_requested(card_id: String) -> void:
	table._on_detail_requested(card_id)
	_sync_from_table()


func _refresh_log() -> void:
	table._refresh_log()
	_sync_from_table()


func _refresh_actions() -> void:
	table._refresh_actions()
	_sync_from_table()


func _layout_board() -> void:
	table._layout_board()
	_sync_from_table()


func _resolve_table() -> void:
	if table == null:
		table = get_node_or_null("BattleTable") as BattleTable


func _bind_table_signals() -> void:
	if _signals_bound or table == null:
		return
	_signals_bound = true
	table.menu_requested.connect(menu_requested.emit)
	table.selection_clear_requested.connect(selection_clear_requested.emit)
	table.hand_card_selected.connect(hand_card_selected.emit)
	table.pokemon_selected.connect(pokemon_selected.emit)
	table.action_requested.connect(action_requested.emit)
	table.card_drop_requested.connect(card_drop_requested.emit)
	table.detail_requested.connect(detail_requested.emit)
	table.inspect_card_requested.connect(inspect_card_requested.emit)
	table.inspect_zone_requested.connect(inspect_zone_requested.emit)
	table.choice_target_selected.connect(choice_target_selected.emit)


func _sync_from_table() -> void:
	if table == null:
		return
	catalog = table.catalog
	view_player = table.view_player
	selected_entity_key = table.selected_entity_key
	action_rows = table.action_rows
	game_mode = table.game_mode
	ai_thinking = table.ai_thinking
	board_panel = table.board_panel
	board_canvas = table.board_canvas
	playmat = table.playmat
	header = table.header
	ai_thinking_overlay = table.ai_thinking_overlay
	hud = table.hud
	turn_label = table.turn_label
	opponent_info = table.opponent_info
	own_info = table.own_info
	phase_labels = table.phase_labels
	phase_advance_button = table.phase_advance_button
	all_actions_button = table.all_actions_button
	action_panel = table.action_panel
	action_list = table.action_list
	all_actions_scroll = table.all_actions_scroll
	all_actions_toggle = table.all_actions_toggle
	detail_panel = table.detail_panel
	detail_image = table.detail_image
	detail_title = table.detail_title
	detail_text = table.detail_text
	detail_close_button = table.detail_close_button
	log_panel = table.log_panel
	log_label = table.log_label
	opponent_hand_surface = table.opponent_hand_surface
	opponent_hand_count_badge = table.opponent_hand_count_badge
	hand_scroll = table.hand_scroll
	hand_surface = table.hand_surface
	input_blocker = table.input_blocker
	effects = table.effects
	director = table.director
	animation_player = table.animation_player
	opponent_active = table.opponent_active
	own_active = table.own_active
	opponent_bench = table.opponent_bench
	own_bench = table.own_bench
	hand_views = table.hand_views
	opponent_hand_views = table.opponent_hand_views
	zones = table.zones
	slot_views = table.slot_views
	_active_flyers = table._active_flyers
	_flyer_tweens = table._flyer_tweens
	_presentation_snapshot = table._presentation_snapshot
	_presentation_reveals = table._presentation_reveals
	_presentation_mask_counts = table._presentation_mask_counts
	_presentation_feedbacks = table._presentation_feedbacks
	_presentation_covers = table._presentation_covers
	_presentation_cover_tweens = table._presentation_cover_tweens
	_presentation_event_hand_targets = table._presentation_event_hand_targets
	_presentation_hand_target_cursor = table._presentation_hand_target_cursor
	_presentation_hand_removed_counts = table._presentation_hand_removed_counts


func _sync_to_table() -> void:
	if table == null:
		return
	table._presentation_snapshot = _presentation_snapshot
	table._presentation_reveals = _presentation_reveals
	table._presentation_mask_counts = _presentation_mask_counts
	table._presentation_feedbacks = _presentation_feedbacks
	table._presentation_covers = _presentation_covers
	table._presentation_cover_tweens = _presentation_cover_tweens
	table._presentation_event_hand_targets = _presentation_event_hand_targets
	table._presentation_hand_target_cursor = _presentation_hand_target_cursor
	table._presentation_hand_removed_counts = _presentation_hand_removed_counts
	table._active_flyers = _active_flyers
	table._flyer_tweens = _flyer_tweens

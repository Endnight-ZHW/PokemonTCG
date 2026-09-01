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
signal choice_option_toggled(option_id: String)
signal choice_selection_confirmed
signal choice_cancel_requested
signal transition_started(handle: PresentationHandle)
signal transition_finished(handle: PresentationHandle)
signal presentation_busy_changed(busy: bool)
signal audio_requested(cue: String)

const CARD_SCENE := preload("res://ui/card_view.tscn")
const CARD_BACK_TEXTURE: Texture2D = preload("res://assets/cards/card_back.webp")
const CARD_DRAG_SESSION := preload("res://presentation/card_drag_session.gd")
const ENERGY_ICONS := preload("res://ui/energy_icon_catalog.gd")
const ATTACHMENT_POPOVER := preload(
	"res://scenes/battle/components/attachment_choice_popover.gd"
)
const MIN_FLYING_CARD_DURATION := 0.06
const FLYING_CARD_FINISH_PAD := 0.0
const SLOT_COMPOSITE_LIFT_SCALE := 0.08
const SLOT_COMPOSITE_CLEARANCE := 8.0
const MAX_ACTIVE_FLYERS_HIGH := 12
const MAX_ACTIVE_FLYERS_LOW := 8
const PAPER_CARD_BASE_SIZE := Vector2(94, 132)
const SHUFFLE_CARD_LIMITS := {
	"high": 8,
	"medium": 6,
	"low": 4,
}
const REVEAL_CARD_MAX_SIZE := Vector2(100, 140)
const REVEAL_CARD_GAP := 14.0
const REVEAL_MIN_READ_HOLD := 0.90
const HAND_CARD_MAX_Z := 78
const SELECTED_HAND_CARD_Z := 80
const PRESENTATION_INSPECTION_MOUSE_MARGIN := 16.0
const PRESENTATION_INSPECTION_TOUCH_MARGIN := 28.0
const CARD_MOTION_EVENT_TYPES: Array[String] = [
	"cards_drawn",
	"cards_revealed",
	"coin_flip",
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
const ZERO_CARD_SEMANTIC_MOTION_TYPES: Array[String] = [
	"cards_revealed",
	"deck_shuffled",
	"promoted",
	"retreat",
	"switched",
]

@export_category("Table Layout")
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
var attachment_choice_popover: AttachmentChoicePopover
var interaction_router := BattleInteractionController.new()
var presentation_runtime: BattlePresentationRuntime
var choice_target_options: Dictionary = {}
var choice_target_prompt := ""
var opponent_hand_surface: Control
var opponent_hand_count_badge: Label
var hand_scroll: ScrollContainer
var hand_surface: Control
var input_blocker: Control
var effects: BattleEffectLayer
var world_feedback: BattleEffectLayer
var reveal_layer: BattleRevealLayer
var coin_showcase: CoinShowcase
var announcement_layer: BattleAnnouncementLayer
var camera_rig: BattleCameraRig
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
var _selected_action_group_key := ""
var _last_selected_source_key := ""
var _popover_dismissed_source_key := ""
var _popover_source_key := ""
var _forced_popover_rows: Array[Dictionary] = []
var _forced_popover_source_key := ""
var _attachment_popover_source_key := ""
var _hand_layout_geometry_signature := ""
var _hand_scroll_center_generation := 0
var _drag_source_key := ""
var _drag_session
var _drag_session_sequence := 0
var _presentation_drag_proxy: Control
var _last_action_rows_signature := ""
var _last_selected_entity_identity := ""
var _detail_content_signature := ""
var _detail_passthrough_key := ""
var _read_only_detail_key := ""
var _board_origin := Vector2.ZERO
var _initialized := false
var card_motion_layer: BattleCardMotionLayer
var motion_geometry: BattleMotionGeometry
var motion_entities: BattleMotionEntities
var hand_view: BattleHandView
var hand_presentation: BattleHandPresentation
var board_view: BattleBoardView
var _hand_visual_sequence := 0
var _hand_identity_player := -1
var _pending_removed_hand_visual_ids: Dictionary = {}
var _ai_thinking_started_msec := 0
var _transition_input_blocked := false
var _director_input_blocked := false
var _startup_input_blocked := false
var _recovery_input_blocked := false
var _startup_shuffle_handle: MotionHandle
var _shuffle_source_masks: Dictionary = {}
var _local_hand_privacy_hidden := false
var _resync_tween: Tween
var presentation_coordinator: BattlePresentationCoordinator


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
	proxy.position = hand_view._drag_proxy_position_for_pointer(
		hand_view._drag_pointer_position(),
		proxy,
	)


func initialize_ui() -> void:
	if _initialized:
		return
	_resolve_scene_nodes()
	_ensure_presentation_coordinator()
	_ensure_presentation_runtime()
	_ensure_motion_components()
	_initialized = true
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bind_scene_nodes()
	if director and not director.audio_requested.is_connected(_on_director_audio_requested):
		director.audio_requested.connect(_on_director_audio_requested)
	var settings := _settings_node()
	if (
		settings != null
		and not settings.is_connected("changed", _apply_runtime_settings)
	):
		settings.connect("changed", _apply_runtime_settings)
	_apply_runtime_settings()
	if not resized.is_connected(board_view._layout_board):
		resized.connect(board_view._layout_board)
	if board_canvas != null and not board_canvas.resized.is_connected(board_view._layout_board):
		board_canvas.resized.connect(board_view._layout_board)
	board_view.call_deferred("_layout_board")
	if not _settings_reduced_motion():
		animation_player.play("enter")


func _on_director_audio_requested(cue: String) -> void:
	audio_requested.emit(cue)


func set_task_hint(message: String) -> void:
	if header:
		header.set_task_hint(message)


func clear_task_hint() -> void:
	if header:
		header.clear_task_hint()


func close_log_drawer() -> void:
	if hud:
		hud.close_log_drawer()


func toast_anchor_rect() -> Rect2:
	if header == null or header.menu_button == null or header.turn_label == null:
		return Rect2()
	var menu_rect := header.menu_button.get_global_rect()
	var status_rect := header.turn_label.get_global_rect()
	var gap_left := menu_rect.end.x + 12.0
	var gap_right := status_rect.position.x - 12.0
	return Rect2(
		Vector2(gap_left, menu_rect.position.y),
		Vector2(maxf(0.0, gap_right - gap_left), menu_rect.size.y),
	)


func toast_avoidance_rect() -> Rect2:
	var controls: Array[Control] = []
	if opponent_hand_surface:
		controls.append(opponent_hand_surface)
	for view_value in opponent_hand_views:
		var view := view_value as Control
		if view:
			controls.append(view)
	var merged := Rect2()
	var has_rect := false
	for control in controls:
		if not is_instance_valid(control) or not control.is_visible_in_tree():
			continue
		var control_rect := control.get_global_rect()
		if control_rect.size.x <= 1.0 or control_rect.size.y <= 1.0:
			continue
		merged = merged.merge(control_rect) if has_rect else control_rect
		has_rect = true
	return merged.grow(10.0) if has_rect else Rect2()


func _ensure_presentation_coordinator() -> void:
	if presentation_coordinator != null:
		presentation_coordinator.configure(self)
		return
	presentation_coordinator = BattlePresentationCoordinator.new()
	presentation_coordinator.name = "BattlePresentationCoordinator"
	add_child(presentation_coordinator)
	presentation_coordinator.configure(self)
	presentation_coordinator.transition_started.connect(transition_started.emit)
	presentation_coordinator.transition_finished.connect(transition_finished.emit)
	presentation_coordinator.busy_changed.connect(presentation_busy_changed.emit)


func _ensure_presentation_runtime() -> void:
	if presentation_runtime != null and is_instance_valid(presentation_runtime):
		return
	presentation_runtime = get_node_or_null(
		"BattlePresentationRuntime"
	) as BattlePresentationRuntime
	if presentation_runtime == null:
		presentation_runtime = BattlePresentationRuntime.new()
		presentation_runtime.name = "BattlePresentationRuntime"
		add_child(presentation_runtime)
	presentation_runtime.configure(self)


func _ensure_motion_components() -> void:
	motion_geometry = get_node_or_null(
		"BattleMotionGeometry"
	) as BattleMotionGeometry
	if motion_geometry == null:
		motion_geometry = BattleMotionGeometry.new()
		motion_geometry.name = "BattleMotionGeometry"
		add_child(motion_geometry)
	motion_geometry.configure(self)
	motion_entities = get_node_or_null(
		"BattleMotionEntities"
	) as BattleMotionEntities
	if motion_entities == null:
		motion_entities = BattleMotionEntities.new()
		motion_entities.name = "BattleMotionEntities"
		add_child(motion_entities)
	motion_entities.configure(self)
	card_motion_layer = get_node_or_null(
		"BattleCardMotionLayer"
	) as BattleCardMotionLayer
	if card_motion_layer == null:
		card_motion_layer = BattleCardMotionLayer.new()
		card_motion_layer.name = "BattleCardMotionLayer"
		add_child(card_motion_layer)
	card_motion_layer.configure(self, effects)
	hand_view = get_node_or_null("BattleHandView") as BattleHandView
	if hand_view == null:
		hand_view = BattleHandView.new()
		hand_view.name = "BattleHandView"
		add_child(hand_view)
	hand_view.configure(self)
	hand_presentation = get_node_or_null(
		"BattleHandPresentation"
	) as BattleHandPresentation
	if hand_presentation == null:
		hand_presentation = BattleHandPresentation.new()
		hand_presentation.name = "BattleHandPresentation"
		add_child(hand_presentation)
	hand_presentation.configure(self)
	board_view = get_node_or_null("BattleBoardView") as BattleBoardView
	if board_view == null:
		board_view = BattleBoardView.new()
		board_view.name = "BattleBoardView"
		add_child(board_view)
	board_view.configure(self)




func active_drag_context() -> Dictionary:
	return hand_view.active_drag_context()


func prepare_hand_identity_transition(
	events: Array,
	previous_snapshot: Dictionary,
) -> void:
	hand_view.prepare_hand_identity_transition(events, previous_snapshot)


func mark_drag_pending(origin_action_id: String, await_authoritative_view: bool) -> String:
	return hand_view.mark_drag_pending(origin_action_id, await_authoritative_view)


func drag_session_id_for_origin(origin_action_id: String) -> String:
	return hand_view.drag_session_id_for_origin(origin_action_id)


func prepare_pending_drag_for_transition(session_id: String) -> void:
	hand_view.prepare_pending_drag_for_transition(session_id)


func commit_pending_drag_source(session_id: String) -> void:
	hand_view.commit_pending_drag_source(session_id)


func finish_pending_drag_transition(session_id: String) -> void:
	hand_view.finish_pending_drag_transition(session_id)


func clear_pending_drag(reason: String = "cancelled") -> void:
	hand_view.clear_pending_drag(reason)


func clear_pending_drag_immediately(reason: String = "cancelled") -> void:
	hand_view.clear_pending_drag_immediately(reason)

func submit_transition(request: BattleTransitionRequest) -> PresentationHandle:
	_ensure_presentation_coordinator()
	return presentation_coordinator.submit(request)


func is_presentation_busy() -> bool:
	return (
		presentation_coordinator != null
		and presentation_coordinator.is_busy()
	)


func cancel_presentations(
	reason: String = "cancelled",
	replacement: BattleViewModel = null,
) -> void:
	_ensure_presentation_coordinator()
	presentation_coordinator.cancel_all(reason, replacement)


## Recovery snapshots are not transitions: cancel every in-flight/queued visual
## transaction and synchronously render the authoritative replacement.
func snap_to_authoritative_view(
	replacement: BattleViewModel,
	reason: String = "resync",
) -> void:
	_ensure_presentation_coordinator()
	presentation_coordinator.cancel_all(reason, replacement)


func _apply_runtime_settings() -> void:
	if not _initialized:
		return
	var profile := _settings_quality_profile()
	if playmat:
		playmat.quality_profile = profile
	if effects:
		effects.quality_profile = profile
	if world_feedback:
		world_feedback.quality_profile = profile
	_refresh_ai_thinking_indicator()


func _settings_node() -> Node:
	return _autoload_node("AppSettings")


func _autoload_node(node_name: String) -> Node:
	var main_loop := Engine.get_main_loop()
	if main_loop is SceneTree and (main_loop as SceneTree).root != null:
		return (main_loop as SceneTree).root.get_node_or_null(node_name)
	return null


func _settings_reduced_motion() -> bool:
	var settings := _settings_node()
	return bool(settings.get("reduced_motion")) if settings != null else false


func _settings_animation_mode() -> String:
	var settings := _settings_node()
	return str(settings.get("animation_mode")) if settings != null else "cinematic"


func _settings_quality_profile() -> String:
	var settings := _settings_node()
	return (
		str(settings.call("resolved_quality_profile"))
		if settings != null
		else "high"
	)


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
	var next_action_rows_signature := board_view._action_rows_semantic_signature(action_rows)
	var next_selected_entity_identity := _selected_entity_identity()
	var interaction_context_changed := (
		selected_entity_key != _last_selected_source_key
		or next_action_rows_signature != _last_action_rows_signature
		or next_selected_entity_identity != _last_selected_entity_identity
	)
	if interaction_context_changed:
		board_view._reset_action_interaction_state()
	_last_selected_source_key = selected_entity_key
	_last_action_rows_signature = next_action_rows_signature
	_last_selected_entity_identity = next_selected_entity_identity
	interaction_router.rebuild(board_view._routed_action_rows(), selected_entity_key)
	_update_ai_thinking_clock(p_ai_thinking)
	ai_thinking = p_ai_thinking
	game_mode = p_game_mode
	if not _initialized or state_ref == null:
		return
	board_view._refresh_header()
	board_view._refresh_field()
	hand_view._refresh_opponent_hand()
	hand_view._refresh_hand()
	board_view._refresh_actions()
	board_view._refresh_log()
	board_view._refresh_target_hints()
	_refresh_ai_thinking_indicator()
	if not _read_only_detail_key.is_empty():
		if detail_panel and detail_panel.visible:
			_sync_visible_card_detail()
	elif selected_entity_key.is_empty():
		hide_card_detail()
	elif detail_panel and detail_panel.visible:
		_sync_visible_card_detail()
		if action_popover and action_popover.visible:
			board_view._reposition_action_popover()


func set_choice_targets(options_by_source: Dictionary, prompt: String) -> void:
	choice_target_options = options_by_source.duplicate(true)
	choice_target_prompt = prompt
	if (
		attachment_choice_popover != null
		and attachment_choice_popover.visible
		and not choice_target_options.has(_attachment_popover_source_key)
	):
		attachment_choice_popover.dismiss(false)
		_attachment_popover_source_key = ""
	if _initialized:
		board_view._refresh_target_hints()
		board_view._refresh_header()


func clear_choice_targets() -> void:
	choice_target_options.clear()
	choice_target_prompt = ""
	_attachment_popover_source_key = ""
	if attachment_choice_popover != null:
		attachment_choice_popover.dismiss(false)
	if _initialized:
		board_view._refresh_target_hints()
		board_view._refresh_header()


func update_choice_selection(
	selected_ids: Array,
	disabled_reasons: Dictionary = {},
) -> void:
	for key_value in choice_target_options.keys():
		var key := str(key_value)
		var group_value: Variant = choice_target_options[key]
		if not group_value is Dictionary:
			continue
		var group := Dictionary(group_value).duplicate(true)
		group["selected_ids"] = selected_ids.duplicate()
		group["disabled_reasons"] = disabled_reasons.duplicate(true)
		choice_target_options[key] = group
	if attachment_choice_popover != null and attachment_choice_popover.visible:
		attachment_choice_popover.refresh_selection(selected_ids, disabled_reasons)


func visible_card_source_keys() -> Array[String]:
	var result: Array[String] = []
	for hand_view in hand_views:
		if hand_view and hand_view.visible and not hand_view.card_id.is_empty():
			result.append(BattleInteractionController.hand_key(hand_view.hand_index))
	for slot_key_value in slot_views.keys():
		var slot_key := str(slot_key_value)
		var slot_view := slot_views[slot_key] as CardView
		if slot_view and slot_view.visible and not slot_view.card_id.is_empty():
			result.append("pokemon:%s" % slot_key)
	var stadium := zones.get("stadium") as ZoneView
	if stadium and stadium.visible and not stadium.card_id.is_empty():
		result.append("stadium")
	for scene_key in ["own_discard", "opponent_discard"]:
		var discard := zones.get(scene_key) as ZoneView
		if discard == null or not discard.visible or discard.count <= 0:
			continue
		var player := view_player if scene_key == "own_discard" else 1 - view_player
		result.append(BattleInteractionController.zone_key(player, "discard"))
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
			_settings_reduced_motion(),
			ai_name,
			_ai_thinking_started_msec,
		)


func _ai_player_index() -> int:
	if game_mode == "challenge":
		return 1
	return 1 - view_player


func _ai_display_name(player_idx: int) -> String:
	if state_ref != null and player_idx >= 0 and player_idx < state_ref.players.size():
		var name := str(state_ref.get_player(player_idx).name).strip_edges()
		if not name.is_empty():
			return name
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
	var normalized_all := PresentationEvent.normalize_all(
		raw_events,
		revision,
		fallback_actor,
	)
	var normalized: Array[Dictionary] = []
	for event in normalized_all:
		var visible_event := PresentationEvent.for_player(event, view_player)
		if not visible_event.is_empty():
			normalized.append(visible_event)
	if normalized.is_empty():
		return
	presentation_runtime._stage_presentation_targets(normalized, previous_snapshot)
	director.set_speed_mode(_settings_animation_mode())
	director.play(normalized)


func clear_unplayed_presentation_staging() -> void:
	# A coordinator batch made entirely from already-seen event IDs never starts
	# the director and therefore has no sequence_finished signal. Keep this
	# explicit instead of clearing in play_presentation(): preview/compatibility
	# callers are allowed to drive event lifecycle callbacks manually.
	presentation_runtime._clear_presentation_masks(true)


func play_startup_shuffle(mulligan_counts: Array = []) -> MotionHandle:
	_cancel_startup_shuffle()
	var handle := MotionHandle.new()
	_startup_shuffle_handle = handle
	if not is_inside_tree() or effects == null:
		handle.finish()
		_ensure_presentation_coordinator()
		presentation_coordinator.set_preflight(handle)
		return handle
	var mode_scale: float = float({
		"cinematic": 1.0,
		"standard": 0.82,
		"fast": 0.58,
		"reduced": 0.0,
	}.get(_settings_animation_mode(), 0.82))
	var reduced := MotionPolicy.reduced()
	var duration := 0.22 if reduced else maxf(0.46, 0.80 * mode_scale)
	for player_idx in [0, 1]:
		var endpoint := {"player": player_idx, "zone": "deck"}
		if reduced:
			presentation_runtime._burst_world_at_motion_point(
				resolve_endpoint_center(endpoint),
				DesignTokens.CYAN,
				"shuffle",
			)
		else:
			card_motion_layer._spawn_shuffle_motion(endpoint, duration, "", true)
		var mulligan_count := (
			maxi(0, int(mulligan_counts[player_idx]))
			if player_idx < mulligan_counts.size()
			else 0
		)
		if mulligan_count > 0:
			_spawn_startup_mulligan_summary(
				endpoint,
				mulligan_count,
				duration,
				reduced,
			)
	if director != null:
		director.audio_requested.emit("shuffle")
	var timer := create_tween()
	timer.tween_interval(duration)
	handle.bind_tween(timer)
	handle.completed.connect(
		_on_startup_shuffle_completed.bind(handle),
		CONNECT_ONE_SHOT,
	)
	_ensure_presentation_coordinator()
	presentation_coordinator.set_preflight(handle)
	return handle


func _spawn_startup_mulligan_summary(
	endpoint: Dictionary,
	count: int,
	duration: float,
	reduced: bool,
) -> void:
	if effects == null:
		return
	var label := Label.new()
	label.name = "StartupShuffleSummary"
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.text = "再战 ×%d" % count
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.size = Vector2(102.0, 30.0)
	label.pivot_offset = label.size * 0.5
	var label_offset_y := (
		-label.size.y - 56.0
		if int(endpoint.get("player", view_player)) == view_player
		else 56.0
	)
	label.position = (
		resolve_endpoint_center(endpoint)
		+ Vector2(-label.size.x * 0.5, label_offset_y)
	)
	label.z_index = 142
	label.modulate.a = 0.0
	label.set_meta("startup_shuffle", true)
	label.set_meta("battle_transient_visual", true)
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", DesignTokens.GOLD)
	label.add_theme_stylebox_override(
		"normal",
		DesignTokens.panel_style(
			Color(DesignTokens.BG_DEEP, 0.92),
			10,
			DesignTokens.GOLD,
			1,
			4,
		),
	)
	card_motion_layer.add(label)
	var tween := create_tween()
	card_motion_layer.bind_tween(label, tween)
	tween.tween_property(label, "modulate:a", 1.0, minf(0.12, duration * 0.25))
	if not reduced:
		tween.parallel().tween_property(label, "scale", Vector2.ONE * 1.04, minf(0.12, duration * 0.25))
	tween.tween_interval(maxf(0.0, duration - minf(0.24, duration * 0.5)))
	tween.tween_property(label, "modulate:a", 0.0, minf(0.12, duration * 0.25))


func _on_startup_shuffle_completed(
	_completed_handle: MotionHandle,
	expected_handle: MotionHandle,
) -> void:
	if _startup_shuffle_handle == expected_handle:
		_startup_shuffle_handle = null
	_clear_startup_shuffle_visuals()


func _cancel_startup_shuffle() -> void:
	var handle := _startup_shuffle_handle
	_startup_shuffle_handle = null
	if handle != null and not handle.is_finished():
		handle.cancel()
	_clear_startup_shuffle_visuals()


func _clear_startup_shuffle_visuals() -> void:
	for flyer in card_motion_layer.entities.duplicate():
		if (
			is_instance_valid(flyer)
			and bool(flyer.get_meta("startup_shuffle", false))
		):
			motion_entities._dispose_flyer(flyer)


func clear_presentation_for_resync() -> void:
	if presentation_coordinator != null:
		presentation_coordinator.cancel_all("resync")
		return
	clear_presentation_visuals_for_resync()


func clear_presentation_visuals_for_resync() -> void:
	if _resync_tween != null and _resync_tween.is_valid():
		_resync_tween.kill()
	_resync_tween = null
	if director:
		director.clear_for_resync()
	_hand_identity_player = -1
	for view in hand_views:
		if view != null:
			view.set_local_visual_id("")
	card_motion_layer._clear_transient_visuals()
	# A recovery snapshot is already authoritative. Keep the snap synchronous so
	# interaction cannot reopen while a decorative, untracked fade is pending.
	modulate.a = 1.0


func show_card_detail(card_id: String, pokemon: PokemonState = null) -> void:
	_read_only_detail_key = ""
	_show_card_detail_content(card_id, pokemon)


func show_read_only_card_detail(
	card_id: String,
	pokemon: PokemonState,
	player: int,
	slot_name: String,
) -> void:
	if card_id.is_empty() or pokemon == null or player not in [0, 1] or slot_name.is_empty():
		return
	var key := BattleInteractionController.pokemon_key(player, slot_name)
	var component := detail_panel as BattleDetailPanel
	if (
		_read_only_detail_key == key
		and component != null
		and component.visible
		and component.current_card_id == card_id
	):
		# Read-only inspection is idempotent. A quick double click must not look as
		# if the first click was ignored by immediately closing the panel again.
		return
	_read_only_detail_key = key
	if action_popover != null and action_popover.visible:
		action_popover.dismiss(false)
	_show_card_detail_content(card_id, pokemon)


func release_read_only_card_detail() -> void:
	# Main calls this immediately before a real local selection refresh. Keeping
	# the panel visible lets that refresh replace its content without a flash.
	_read_only_detail_key = ""


func _show_card_detail_content(card_id: String, pokemon: PokemonState = null) -> void:
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
	board_view._layout_detail_panel()
	if action_popover and action_popover.visible:
		board_view._reposition_action_popover()


func hide_card_detail() -> void:
	_detail_content_signature = ""
	_read_only_detail_key = ""
	var component := detail_panel as BattleDetailPanel
	if component:
		component.hide_card()
	elif detail_panel:
		detail_panel.visible = false
	if action_popover and action_popover.visible:
		board_view._reposition_action_popover()


func _on_detail_close_requested() -> void:
	_detail_content_signature = ""
	if not _read_only_detail_key.is_empty():
		_read_only_detail_key = ""
		return
	var expected_key := selected_entity_key
	board_view._reset_action_interaction_state()
	selection_clear_requested.emit(expected_key)


func _sync_visible_card_detail(force_show := false) -> void:
	var component := detail_panel as BattleDetailPanel
	if component == null or (not component.visible and not force_show) or state_ref == null:
		return
	var detail_key := (
		_read_only_detail_key
		if not _read_only_detail_key.is_empty()
		else selected_entity_key
	)
	var card_id := ""
	var pokemon: PokemonState
	if detail_key.begins_with("hand:"):
		var hand_index := detail_key.trim_prefix("hand:").to_int()
		var hand := state_ref.get_player(view_player).hand
		if hand_index >= 0 and hand_index < hand.size():
			card_id = str(hand[hand_index])
	elif detail_key.begins_with("pokemon:"):
		var parts := detail_key.split(":")
		if parts.size() >= 3:
			var player := int(parts[1])
			if player in [0, 1]:
				pokemon = state_ref.get_player(player).get_pokemon(str(parts[2]))
				if pokemon:
					card_id = pokemon.card_id
	elif detail_key == "stadium":
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
	board_view._layout_detail_panel()


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
		board_view._stable_value_signature(pokemon.to_dict()) if pokemon else "",
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
				attachment_centers["energy:%d" % energy_index] = energy_center
				attachment_centers[
					"energy:%d:%s" % [energy_index, energy_id]
				] = energy_center
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
		var logical_key := motion_geometry._logical_zone_key(str(zone_key))
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
		"title": catalog.get_card(card_id).get("name", card_id),
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
	return _resolve_endpoint_center_direct(endpoint)


func _endpoint_attachment_index(endpoint: Dictionary, fallback: int = -1) -> int:
	var value := int(endpoint.get("index", -1))
	return fallback if value < 0 and fallback >= 0 else value


func _resolve_endpoint_center_direct(endpoint: Dictionary) -> Vector2:
	var player := int(endpoint.get("player", view_player))
	var slot := str(endpoint.get("slot", ""))
	var zone := str(endpoint.get("zone", ""))
	if not slot.is_empty():
		var slot_key := "%d:%s" % [player, slot]
		var card_view := presentation_runtime._valid_card_view(presentation_runtime.slot_covers.get(slot_key))
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
						_endpoint_attachment_index(endpoint),
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
	if (
		input_blocker != null
		and not input_blocker.gui_input.is_connected(
			_on_presentation_input_blocker_gui_input
		)
	):
		input_blocker.gui_input.connect(_on_presentation_input_blocker_gui_input)
	if log_panel:
		log_panel.z_index = 0
		log_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		log_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	playmat.quality_profile = _settings_quality_profile()
	effects.quality_profile = _settings_quality_profile()
	world_feedback.quality_profile = _settings_quality_profile()
	card_motion_layer.configure(self, effects)
	if reveal_layer == null:
		reveal_layer = BattleRevealLayer.new()
		reveal_layer.name = "BattleRevealLayer"
		effects.add_child(reveal_layer)
	if coin_showcase == null:
		coin_showcase = CoinShowcase.new()
		coin_showcase.name = "BattleCoinShowcase"
		coin_showcase.z_index = 95
		coin_showcase.visible = false
		coin_showcase.audio_requested.connect(card_motion_layer._on_coin_showcase_audio_requested)
		add_child(coin_showcase)
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
			board_view._allowance_chip_style(false),
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
		zone.activated.connect(board_view._on_detail_requested)
		zone.inspected.connect(board_view._on_zone_inspected)
		zone.detail_requested.connect(board_view._on_detail_requested)
		zone.action_requested.connect(action_requested.emit)
		zone.action_menu_requested.connect(board_view._on_zone_action_menu_requested)
		zone.card_dropped.connect(board_view._on_card_dropped)
	(zones["own_prizes"] as ZoneView).stack_index_activated.connect(
		board_view._on_prize_index_activated.bind(true))
	(zones["opponent_prizes"] as ZoneView).stack_index_activated.connect(
		board_view._on_prize_index_activated.bind(false))
	header.initialize_ui()
	header.menu_requested.connect(board_view._on_menu_pressed)
	hud.phase_action_requested.connect(action_requested.emit)
	if not hud.log_drawer_toggled.is_connected(board_view._on_log_drawer_toggled):
		hud.log_drawer_toggled.connect(board_view._on_log_drawer_toggled)
	# Keep global input enabled even while the log drawer is closed. This lets us
	# remove a popover before GUI hit testing while preserving the original card
	# press and its normal release/long-press/drag semantics.
	set_process_input(true)
	if action_popover:
		action_popover.action_chosen.connect(board_view._on_popover_action_chosen)
		action_popover.dismissed.connect(board_view._on_popover_dismissed)
	if attachment_choice_popover == null:
		attachment_choice_popover = ATTACHMENT_POPOVER.new() as AttachmentChoicePopover
		attachment_choice_popover.name = "AttachmentChoicePopover"
		add_child(attachment_choice_popover)
		attachment_choice_popover.option_chosen.connect(
			board_view._on_attachment_option_chosen,
		)
		attachment_choice_popover.option_toggled.connect(
			choice_option_toggled.emit,
		)
		attachment_choice_popover.confirmed.connect(
			board_view._on_attachment_selection_confirmed,
		)
		attachment_choice_popover.cancelled.connect(
			board_view._on_attachment_selection_cancelled,
		)
		attachment_choice_popover.dismissed.connect(
			board_view._on_attachment_popover_dismissed,
		)
	director.sequence_started.connect(func(_count: int) -> void:
		_director_input_blocked = not _settings_reduced_motion()
		_sync_input_blocker()
	)
	director.sequence_finished.connect(func() -> void:
		_director_input_blocked = false
		_sync_input_blocker()
		presentation_runtime._clear_presentation_masks(true)
		motion_entities._clear_active_flyers()
	)
	director.event_finished.connect(presentation_runtime._on_presentation_event_finished)
	director.event_started.connect(presentation_runtime._on_presentation_event_started)
	director.event_completion_requested.connect(
		_on_presentation_event_completion_requested,
	)
	director.floating_text_requested.connect(presentation_runtime._on_floating_text_requested)
	director.burst_requested.connect(presentation_runtime._on_burst_requested)
	director.card_motion_requested.connect(card_motion_layer._on_card_motion_requested)
	director.card_landing_feedback_scheduled.connect(
		presentation_runtime._on_card_landing_feedback_scheduled,
	)
	director.camera_impulse_requested.connect(card_motion_layer._on_camera_impulse_requested)
	_sync_input_blocker()


func set_transition_blocked(value: bool) -> void:
	_transition_input_blocked = value
	_sync_input_blocker()


func set_startup_blocked(value: bool) -> void:
	_startup_input_blocked = value
	if value:
		hand_view.clear_pending_drag_immediately("startup_choreography")
	_sync_input_blocker()


func set_local_hand_privacy_hidden(value: bool) -> void:
	_local_hand_privacy_hidden = value
	_sync_local_hand_privacy()


func set_recovery_blocked(value: bool) -> void:
	_recovery_input_blocked = value
	if value:
		hand_view.clear_pending_drag_immediately("network_recovery")
	_sync_input_blocker()


func _sync_local_hand_privacy() -> void:
	if hand_scroll == null:
		return
	hand_scroll.visible = not _local_hand_privacy_hidden
	hand_scroll.mouse_filter = (
		Control.MOUSE_FILTER_IGNORE
		if _local_hand_privacy_hidden
		else Control.MOUSE_FILTER_PASS
	)


func _sync_input_blocker() -> void:
	if input_blocker != null:
		var blocked := (
			_transition_input_blocked
			or _director_input_blocked
			or _startup_input_blocked
			or _recovery_input_blocked
		)
		input_blocker.visible = blocked
		if not blocked:
			input_blocker.mouse_default_cursor_shape = Control.CURSOR_ARROW


func _on_presentation_input_blocker_gui_input(event: InputEvent) -> void:
	# Presentation remains mutation-locked, but public field cards stay available
	# for read-only inspection. The blocker consumes every other gesture exactly
	# as before, so playing, dragging and target selection cannot race the staged
	# presentation snapshot.
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if (
			mouse_event.button_index != MOUSE_BUTTON_LEFT
			or not mouse_event.pressed
		):
			return
		# Resolve on press. Waiting for release made a moving card or a blocker state
		# transition invalidate a perfectly good initial hit 1-2 frames later.
		_inspect_public_field_card_at(
			_blocker_global_point(mouse_event.position),
			PRESENTATION_INSPECTION_MOUSE_MARGIN,
		)
		return
	if event is InputEventMouseMotion:
		var motion_event := event as InputEventMouseMotion
		input_blocker.mouse_default_cursor_shape = (
			Control.CURSOR_POINTING_HAND
			if _public_field_card_at(
				_blocker_global_point(motion_event.position),
				PRESENTATION_INSPECTION_MOUSE_MARGIN,
			) != null
			else Control.CURSOR_ARROW
		)
		return
	if event is InputEventScreenTouch:
		var touch_event := event as InputEventScreenTouch
		if not touch_event.pressed:
			return
		_inspect_public_field_card_at(
			_blocker_global_point(touch_event.position),
			PRESENTATION_INSPECTION_TOUCH_MARGIN,
		)


func _blocker_global_point(local_point: Vector2) -> Vector2:
	if input_blocker == null:
		return local_point
	return input_blocker.get_global_transform_with_canvas() * local_point


func _inspect_public_field_card_at(global_point: Vector2, hit_margin: float) -> void:
	var view := _public_field_card_at(global_point, hit_margin)
	if view == null:
		return
	show_read_only_card_detail(
		view.card_id,
		view.pokemon,
		view.owner_player,
		view.slot,
	)


func _public_field_card_at(global_point: Vector2, hit_margin: float = 0.0) -> CardView:
	var candidates: Array[CardView] = []
	# Switch/retreat/evolution animations temporarily replace a slot with a live
	# CardView mover. It is the card the player sees and therefore owns the first
	# inspection opportunity.
	for value in card_motion_layer.entities:
		var mover := presentation_runtime._valid_card_view(value)
		if mover != null and mover not in candidates:
			candidates.append(mover)
	# Staged covers represent what is actually visible while an action is being
	# presented. Prefer them over the authoritative landing views underneath.
	for value in presentation_runtime.slot_covers.values():
		var cover := presentation_runtime._valid_card_view(value)
		if cover != null:
			candidates.append(cover)
	for value in slot_views.values():
		var field_view := presentation_runtime._valid_card_view(value)
		if field_view != null and field_view not in candidates:
			candidates.append(field_view)
	var best_view: CardView
	var best_score := INF
	for view in candidates:
		if (
			not view.is_visible_in_tree()
			or view.modulate.a <= 0.05
			or view.card_id.is_empty()
			or view.pokemon == null
			or view.is_hidden_card
			or view.is_presentation_hidden()
		):
			continue
		var bounds := view.visual_global_bounds()
		var exact_hit := view.contains_visual_global_point(global_point)
		if not exact_hit and not bounds.grow(maxf(0.0, hit_margin)).has_point(global_point):
			continue
		var score := bounds.get_center().distance_squared_to(global_point)
		if not exact_hit:
			score += 1000000.0
		if score < best_score:
			best_score = score
			best_view = view
	return best_view


func _on_presentation_event_completion_requested(
	event: Dictionary,
	completion: PresentationDirector.EventCompletion,
) -> void:
	var event_type := PresentationEvent.canonical_event_type(
		str(event.get("event_type", "")),
	)
	if event_type not in CARD_MOTION_EVENT_TYPES:
		return
	if MotionPolicy.reduced() and event_type != "coin_flip":
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
	card_motion_layer.event_motion_completions[event_id] = {
		"completion": completion,
		"group": group,
	}


func _on_event_motion_group_completed(
	group: MotionGroup,
	event_id: String,
	completion: PresentationDirector.EventCompletion,
) -> void:
	var row: Dictionary = card_motion_layer.event_motion_completions.get(event_id, {})
	if row.get("group") == group:
		card_motion_layer.event_motion_completions.erase(event_id)
	completion.finish()


func _bind_card_view(view: CardView) -> void:
	view.set_catalog(catalog)
	view.activated.connect(board_view._on_card_activated)
	view.detail_requested.connect(board_view._on_card_view_detail_requested.bind(view))
	view.card_dropped.connect(board_view._on_card_dropped)
	view.action_requested.connect(action_requested.emit)
	view.drag_started.connect(hand_view._on_hand_drag_started)
	view.drag_ended.connect(hand_view._on_hand_drag_ended)


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
	if attachment_choice_popover != null and attachment_choice_popover.visible:
		if attachment_choice_popover.panel_global_rect().has_point(pointer_position):
			return
		# Dismiss before GUI hit testing without consuming the press. Tapping a
		# different highlighted Pokemon can therefore open its energy list with
		# the same gesture.
		attachment_choice_popover.dismiss()
	var selected_source := board_view._source_control_for_key(selected_entity_key)
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
	if control.has_method("contains_visual_global_point"):
		return bool(control.call("contains_visual_global_point", global_point))
	var local_point := (
		control.get_global_transform_with_canvas().affine_inverse() * global_point
	)
	return Rect2(Vector2.ZERO, control.size).has_point(local_point)


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
		"prizes": "奖赏卡",
		"stadium": "竞技场",
	}.get(zone_name, zone_name)


func _player_label(player_idx: int) -> String:
	if state_ref == null or player_idx < 0:
		return ""
	return state_ref.get_player(player_idx).name

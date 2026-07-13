extends Control

const BATTLE_SCENE := preload("res://scenes/battle/battle_screen.tscn")
const CARD_SCENE := preload("res://ui/card_view.tscn")
const VICTORY_SCENE := preload("res://scenes/end/victory_screen.tscn")
const TITLE_SCENE := preload("res://scenes/title/title_page.tscn")
const DECK_SELECT_SCENE := preload("res://scenes/decks/deck_select_page.tscn")
const NETWORK_LOBBY_SCENE := preload("res://scenes/network/network_lobby_page.tscn")
const SETTINGS_PANEL_SCENE := preload("res://ui/dialogs/settings_panel.tscn")
const CHOICE_PANEL_SCENE := preload("res://ui/dialogs/choice_panel.tscn")
const PRIVACY_PANEL_SCENE := preload("res://ui/dialogs/privacy_panel.tscn")
const PAUSE_PANEL_SCENE := preload("res://ui/dialogs/pause_panel.tscn")
const HELP_PANEL_SCENE := preload("res://ui/panels/help_panel.tscn")
const CARD_INSPECTOR_PANEL_SCENE := preload("res://ui/panels/card_inspector_panel.tscn")
const ZONE_INSPECTOR_PANEL_SCENE := preload("res://ui/panels/zone_inspector_panel.tscn")
const DECK_DETAIL_PANEL_SCENE := preload("res://ui/panels/deck_detail_panel.tscn")
const FRONTEND_THEME := preload("res://ui/frontend/front_end_theme.tres")

const SCREEN_TITLE := "title"
const SCREEN_DECKS := "decks"
const SCREEN_NETWORK := "network"
const SCREEN_GAME := "game"
const SCREEN_END := "end"
const MODE_LOCAL := "local"
const MODE_CHALLENGE := "challenge"
const MODE_DEEP := "deep"
const MODE_NETWORK := "network"
const MODAL_SHADE_ALPHA := 0.72
const MODAL_SHADE_OPAQUE_ALPHA := 1.0

var catalog: CardCatalog = CardDatabase.catalog
var engine := GameEngine.new(catalog)
var state: GameState
var rng := PortableRandomSource.new(1)
var last_match_seed := 0

var current_screen := SCREEN_TITLE
var current_view_player := 0
var action_sequence := 0
var selected_entity_key := ""
var selected_choice_ids: Array[String] = []
var option_buttons: Array[Button] = []
var game_mode := MODE_LOCAL
var ai_deck_key := ""
var ai_thinking := false
var ai_request_sequence := 0
var active_ai_request_id := ""
var ai_coordinator := AICoordinator.new()
var ai_inference: Variant
var deep_runtime := DeepAIRuntime.new()
var network_controller := NetworkMatchController.new(catalog)
var network_legal_actions: Array[GameAction] = []
var network_choice_request: ChoiceRequest
var network_kind := "lan"
var network_player_idx := -1

var safe_margin: MarginContainer
var screen_host: Control
var title_full_bleed_backdrop: Control
var toast_label: Label
var sound_player: AudioStreamPlayer
var audio_director: AudioDirector
var click_stream: AudioStreamWAV
var success_stream: AudioStreamWAV
var loading_layer: Control
var loading_label: Label
var shell_animations: AnimationPlayer
var lifecycle_network_interrupted := false
var screen_router: ScreenRouter
var modal_host_controller: ModalHost
var current_network_page: NetworkLobbyPage

var action_list: VBoxContainer
var log_label: RichTextLabel
var detail_image: TextureRect
var detail_title: Label
var detail_text: RichTextLabel
var battle_screen: BattleScreen

var modal_layer: Control
var modal_shade: ColorRect
var modal_panel: PanelContainer
var modal_title: Label
var modal_body: VBoxContainer
var modal_scroll: ScrollContainer
var modal_confirm: Button
var modal_cancel: Button
var active_request: ChoiceRequest
var active_choice_panel: ChoicePanel
var ui_initialized := false
var _modal_generation := 0
var _modal_back_action := Callable()
var _toast_tween: Tween
var _toast_generation := 0
var _deep_start_generation := 0


func _ready() -> void:
	set_process(false)
	var user_args := OS.get_cmdline_user_args()
	if ExportSmokeRunner.PHASE_FOUR_FLAG in user_args:
		_run_phase_four_export_smoke()
		return
	elif ExportSmokeRunner.PHASE_FIVE_FLAG in user_args:
		_run_phase_five_export_smoke()
		return
	elif ExportSmokeRunner.PHASE_SIX_FLAG in user_args:
		_run_phase_six_export_smoke()
		return
	initialize_ui()


func _run_phase_four_export_smoke() -> void:
	_run_export_smoke(ExportSmokeRunner.PHASE_FOUR_FLAG)


func _run_phase_five_export_smoke() -> void:
	_run_export_smoke(ExportSmokeRunner.PHASE_FIVE_FLAG)


func _run_phase_six_export_smoke() -> void:
	_run_export_smoke(ExportSmokeRunner.PHASE_SIX_FLAG)


func _run_export_smoke(flag: String) -> void:
	var smoke_result := ExportSmokeRunner.new().run_if_requested(
		PackedStringArray([flag]),
		deep_runtime,
		_export_smoke_services(),
	)
	if bool(smoke_result.get("handled", false)):
		_finish_export_smoke(smoke_result)


func _export_smoke_services() -> Dictionary:
	return {
		"app_version": AppState.APP_VERSION,
		"card_cache_size": AppSettings.card_cache_size,
		"release_manifest": CardDatabase.release_manifest,
		"texture_cache": CardTextureCache,
	}


func _finish_export_smoke(result: Dictionary) -> void:
	var message := str(result.get("message", "EXPORT_SMOKE_FAILED"))
	if bool(result.get("success", false)):
		print(message)
	else:
		push_error(message)
	get_tree().quit(int(result.get("exit_code", 1)))


func _process(_delta: float) -> void:
	if network_controller.needs_poll():
		_poll_network()
	if ai_thinking:
		var result := ai_coordinator.poll_result()
		if not result.is_empty():
			_apply_ai_result(result)
	_refresh_process_state()


func _exit_tree() -> void:
	if _toast_tween and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast_tween = null
	_stop_ai()
	_stop_network()


func initialize_ui() -> void:
	if ui_initialized:
		return
	ui_initialized = true
	click_stream = UISound.make_tone(620.0, 0.055, 0.12)
	success_stream = UISound.make_tone(880.0, 0.11, 0.14)
	_build_shell()
	if not AppSettings.changed.is_connected(_apply_runtime_settings):
		AppSettings.changed.connect(_apply_runtime_settings)
	_apply_runtime_settings()
	_show_title()
	_apply_safe_area()
	Engine.max_fps = AppSettings.target_fps()


func _build_shell() -> void:
	safe_margin = get_node("SafeArea") as MarginContainer
	screen_host = get_node("SafeArea/ScreenHost") as Control
	title_full_bleed_backdrop = get_node_or_null("TitleFullBleedBackdrop") as Control
	toast_label = get_node("Toast") as Label
	toast_label.theme = FRONTEND_THEME
	toast_label.theme_type_variation = &"FrontToastLabel"
	toast_label.set("accessibility_live", 1)
	sound_player = get_node("UISound") as AudioStreamPlayer
	audio_director = get_node("AudioDirector") as AudioDirector
	modal_layer = get_node("ModalLayer") as Control
	modal_shade = get_node("ModalLayer/ModalShade") as ColorRect
	modal_panel = get_node("ModalLayer/Center/ModalPanel") as PanelContainer
	modal_title = get_node(
		"ModalLayer/Center/ModalPanel/Margin/Content/ModalTitle"
	) as Label
	modal_body = get_node(
		"ModalLayer/Center/ModalPanel/Margin/Content/Scroll/ModalBody"
	) as VBoxContainer
	modal_scroll = get_node(
		"ModalLayer/Center/ModalPanel/Margin/Content/Scroll"
	) as ScrollContainer
	modal_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	modal_cancel = get_node(
		"ModalLayer/Center/ModalPanel/Margin/Content/Buttons/ModalCancel"
	) as Button
	modal_confirm = get_node(
		"ModalLayer/Center/ModalPanel/Margin/Content/Buttons/ModalConfirm"
	) as Button
	loading_layer = get_node("LoadingLayer") as Control
	loading_label = get_node(
		"LoadingLayer/Center/Panel/Margin/Content/LoadingLabel"
	) as Label
	loading_label.accessibility_name = "加载状态"
	loading_label.set("accessibility_live", 1)
	shell_animations = get_node("ShellAnimations") as AnimationPlayer
	screen_router = get_node_or_null("Controllers/ScreenRouter") as ScreenRouter
	modal_host_controller = get_node_or_null("Controllers/ModalHost") as ModalHost
	if screen_router:
		screen_router.configure(screen_host)
	if modal_host_controller:
		modal_host_controller.configure(
			modal_layer,
			modal_body,
			modal_confirm,
			modal_cancel,
			modal_panel,
		)
	modal_layer.z_index = 200
	loading_layer.z_index = 210


func _show_title() -> void:
	_stop_ai()
	_stop_network()
	if modal_layer and modal_layer.visible:
		_close_modal()
	_hide_loading()
	current_screen = SCREEN_TITLE
	battle_screen = null
	if audio_director:
		audio_director.play_music("title")
	var page := _mount_screen(TITLE_SCENE) as TitlePage
	if title_full_bleed_backdrop:
		title_full_bleed_backdrop.visible = true
	page.set_embedded_backdrop_visible(false)
	page.configure("v%s" % AppState.APP_VERSION)
	page.mode_selected.connect(_show_deck_select)
	page.network_selected.connect(_show_network_setup)
	page.settings_requested.connect(_show_settings)
	page.help_requested.connect(_show_help)


func show_title() -> void:
	_show_title()


func show_network_setup(kind: String) -> void:
	_show_network_setup(kind)


func show_deck_select(mode: String = MODE_LOCAL) -> void:
	_show_deck_select(mode)


func show_settings() -> void:
	_show_settings()


func show_choice(request: ChoiceRequest) -> void:
	_show_choice_overlay(request)


func _show_network_setup(kind: String) -> void:
	_play_click()
	_stop_network()
	network_kind = kind if kind in ["lan", "relay"] else "lan"
	game_mode = MODE_NETWORK
	current_screen = SCREEN_NETWORK
	var page := _mount_screen(NETWORK_LOBBY_SCENE) as NetworkLobbyPage
	current_network_page = page
	page.configure(catalog, network_kind, AppSettings.relay_url)
	page.back_requested.connect(_show_title)
	page.kind_changed.connect(_on_network_kind_changed)
	page.connect_requested.connect(_on_network_connect_requested)


func _on_network_kind_changed(kind: String) -> void:
	if kind not in ["lan", "relay"]:
		return
	_stop_network()
	network_kind = kind

func _on_network_connect_requested(
	kind: String,
	role: String,
	address: String,
	port: int,
	room_code: String,
	deck_key: String,
) -> void:
	if (
		current_screen != SCREEN_NETWORK
		or current_network_page == null
		or not is_instance_valid(current_network_page)
		or kind not in ["lan", "relay"]
		or kind != current_network_page.kind
		or role not in ["host", "client"]
		or catalog.get_deck(deck_key).is_empty()
	):
		_set_network_page_state(
			NetworkLobbyPage.ConnectionState.ERROR,
			"连接参数无效，请重新检查身份与牌组。",
		)
		return
	var normalized_address := address.strip_edges()
	var normalized_room_code := room_code.strip_edges()
	if not _network_connection_fields_valid(
		kind,
		role,
		normalized_address,
		normalized_room_code,
	):
		_set_network_page_state(
			NetworkLobbyPage.ConnectionState.ERROR,
			"连接地址或房间码无效。",
		)
		return
	network_kind = kind
	var error := ERR_INVALID_PARAMETER
	if kind == "lan":
		if port <= 0 or port > 65535:
			_set_network_page_state(
				NetworkLobbyPage.ConnectionState.ERROR,
				"端口无效。",
			)
			return
		if role == "host":
			error = network_controller.host_lan(port, deck_key)
		else:
			error = network_controller.join_lan(normalized_address, port, deck_key)
	else:
		AppSettings.set_relay_url(normalized_address)
		if role == "host":
			error = network_controller.host_relay(normalized_address, deck_key)
		else:
			error = network_controller.join_relay(
				normalized_address,
				normalized_room_code,
				deck_key,
			)
	if error != OK:
		_set_network_page_state(
			NetworkLobbyPage.ConnectionState.ERROR,
			"无法启动连接：%s" % error_string(error),
		)
		return
	_set_network_page_state(
		(
			NetworkLobbyPage.ConnectionState.WAITING
			if role == "host"
			else NetworkLobbyPage.ConnectionState.CONNECTING
		),
		"等待挑战者连接……" if role == "host" else "正在连接房主……",
	)
	_refresh_process_state()


func _network_connection_fields_valid(
	kind: String,
	role: String,
	address: String,
	room_code: String,
) -> bool:
	if kind not in ["lan", "relay"] or role not in ["host", "client"]:
		return false
	var normalized_address := address.strip_edges()
	var address_required := kind == "relay" or role == "client"
	if address_required and normalized_address.is_empty():
		return false
	if (
		kind == "relay"
		and not (
			normalized_address.begins_with("ws://")
			or normalized_address.begins_with("wss://")
		)
	):
		return false
	return not (
		kind == "relay"
		and role == "client"
		and room_code.strip_edges().is_empty()
	)


func _poll_network() -> void:
	for event in network_controller.poll():
		match str(event.get("type", "")):
			"room_created":
				_set_network_page_state(
					NetworkLobbyPage.ConnectionState.WAITING,
					"分享房间码，等待挑战者加入。",
					str(event.get("room_id", "")),
				)
			"connected":
				network_player_idx = int(event.get("player_idx", network_player_idx))
				_set_network_page_state(
					NetworkLobbyPage.ConnectionState.CONNECTED,
					"对手已连接，正在同步牌组和对局……",
				)
			"state":
				var view_value: Variant = event.get("view", {})
				if view_value is Dictionary:
					_apply_network_view(
						view_value,
						int(event.get("player_idx", network_player_idx)),
					)
				else:
					_show_toast("收到的联机局面无效，正在请求重新同步。", true)
					network_controller.request_resync()
			"error", "connection_failed", "transport_error":
				var event_type := str(event.get("type", ""))
				var message := str(event.get(
					"message",
					event.get("code", "网络连接失败。"),
				))
				_set_network_page_state(
					NetworkLobbyPage.ConnectionState.ERROR,
					message,
				)
				_show_toast(message, true)
				if event_type == "error" and current_screen == SCREEN_GAME:
					network_controller.request_resync()
				# These transport events are terminal. Clear the controller now so the
				# lobby can immediately start a clean retry; protocol-level "error"
				# events may still be recoverable and keep their existing session.
				if event_type in ["connection_failed", "transport_error"]:
					_stop_network()
			"disconnected":
				_handle_network_disconnected(str(event.get("reason", "")))


func _handle_network_disconnected(reason: String = "") -> void:
	var was_lobby := current_screen == SCREEN_NETWORK
	var was_game := current_screen == SCREEN_GAME
	var lobby_already_showing_error := (
		was_lobby
		and current_network_page != null
		and is_instance_valid(current_network_page)
		and current_network_page.connection_state
		== NetworkLobbyPage.ConnectionState.ERROR
	)
	_stop_network()
	if was_lobby:
		# A transport error or schema error may already have supplied a more
		# useful message immediately before the synthetic disconnect event.
		if lobby_already_showing_error:
			return
		var message := (
			"连接超时，请检查网络后重新尝试。"
			if reason == "timeout"
			else "连接已断开，请检查网络后重新尝试。"
		)
		_set_network_page_state(NetworkLobbyPage.ConnectionState.ERROR, message)
		_show_toast(message, true)
	elif was_game:
		_show_toast("对手已断开连接，对局结束。", true)
		state = null
		_show_title()


func _set_network_page_state(
	state_value: NetworkLobbyPage.ConnectionState,
	message: String = "",
	room_code: String = "",
) -> void:
	if (
		current_screen != SCREEN_NETWORK
		or current_network_page == null
		or not is_instance_valid(current_network_page)
		or not current_network_page.is_inside_tree()
	):
		return
	current_network_page.set_connection_state(state_value, message, room_code)


func _apply_network_view(view: Dictionary, player: int) -> void:
	if view.is_empty() or not _network_view_is_valid(view):
		_show_toast("收到的联机局面无效，正在请求重新同步。", true)
		network_controller.request_resync()
		return
	var had_game_screen := current_screen == SCREEN_GAME and battle_screen != null
	var presentation_snapshot := (
		battle_screen.capture_presentation_snapshot()
		if had_game_screen
		else {}
	)
	game_mode = MODE_NETWORK
	network_player_idx = player
	current_view_player = player
	var state_payload: Dictionary = view["state"]
	state = StateSerializer.from_player_view(state_payload, player)
	network_legal_actions.clear()
	var legal_rows: Array = view.get("legal_actions", [])
	for row in legal_rows:
		if row is Dictionary:
			network_legal_actions.append(GameAction.from_dict(row))
	network_choice_request = (
		ChoiceRequest.from_dict(view["choice_request"])
		if view.get("choice_request") is Dictionary
		else null
	)
	if current_screen != SCREEN_GAME and current_screen != SCREEN_END:
		_build_game_screen()
	else:
		_refresh_game()
	if battle_screen:
		var presentation_events: Array = view.get("presentation_events", [])
		if had_game_screen and not presentation_events.is_empty():
			battle_screen.play_presentation(
				presentation_events,
				state.revision,
				state.active_player_idx,
				presentation_snapshot,
			)
	if (
		network_choice_request != null
		and (
			active_request == null
			or active_request.request_id != network_choice_request.request_id
		)
	):
		_show_choice_overlay(network_choice_request)


func _network_view_is_valid(view: Dictionary) -> bool:
	return bool(ProtocolV3.validate_payload(
		ProtocolV3.STATE_UPDATE,
		view,
	).get("ok", false))


func _stop_network() -> void:
	network_controller.close()
	network_legal_actions.clear()
	network_choice_request = null
	network_player_idx = -1
	_refresh_process_state()


func _show_deck_select(mode: String = MODE_LOCAL) -> void:
	_play_click()
	game_mode = mode
	current_screen = SCREEN_DECKS
	var page := _mount_screen(DECK_SELECT_SCENE) as DeckSelectPage
	page.configure(catalog, game_mode)
	page.back_requested.connect(_show_title)
	page.deck_details_requested.connect(_show_deck_details)
	page.start_requested.connect(_on_match_start_requested)

func _on_match_start_requested(
	mode: String,
	first_key: String,
	second_key: String,
	forced_first: int,
) -> void:
	game_mode = mode
	if mode == MODE_LOCAL:
		start_local_match_for_test(first_key, second_key)
		return
	if mode == MODE_DEEP:
		_start_deep_match_with_loading(
			first_key,
			second_key,
			forced_first,
		)
	else:
		start_ai_match_for_test(
			mode,
			first_key,
			second_key,
			forced_first,
		)


func _start_deep_match_with_loading(
	human_key: String,
	opponent_key: String,
	forced_first: int,
) -> void:
	_deep_start_generation += 1
	var request_generation := _deep_start_generation
	var source_page := (
		screen_host.get_child(0)
		if screen_host and screen_host.get_child_count() > 0
		else null
	)
	_show_loading("正在校验并加载 Deep AI 模型…")
	await get_tree().process_frame
	if (
		request_generation != _deep_start_generation
		or current_screen != SCREEN_DECKS
		or game_mode != MODE_DEEP
		or source_page == null
		or not is_instance_valid(source_page)
		or source_page.get_parent() != screen_host
	):
		if request_generation == _deep_start_generation:
			_hide_loading()
		return
	start_ai_match_for_test(
		MODE_DEEP,
		human_key,
		opponent_key,
		forced_first,
	)
	_hide_loading()


func start_local_match_for_test(
	first_key: String,
	second_key: String,
	match_seed: int = -1,
	forced_first: int = -1,
) -> bool:
	game_mode = MODE_LOCAL
	return _start_match(first_key, second_key, match_seed, forced_first)


func start_ai_match_for_test(
	mode: String,
	human_key: String,
	opponent_key: String,
	forced_first: int = -1,
	match_seed: int = -1,
) -> bool:
	game_mode = mode if mode in [MODE_CHALLENGE, MODE_DEEP] else MODE_CHALLENGE
	ai_deck_key = opponent_key
	return _start_match(human_key, opponent_key, match_seed, forced_first)


func _start_match(
	first_key: String,
	second_key: String,
	match_seed: int,
	forced_first: int,
) -> bool:
	_play_click()
	_stop_ai()
	state = GameState.new()
	state.public_deck_keys = [first_key, second_key]
	var actual_seed := match_seed
	if actual_seed < 0:
		actual_seed = PortableRandomSource.fresh_seed()
	last_match_seed = actual_seed
	rng = PortableRandomSource.new(actual_seed)
	var result := engine.setup_game(
		state,
		catalog.expand_deck(first_key),
		catalog.expand_deck(second_key),
		rng,
		forced_first,
	)
	if not result.success:
		_show_toast(result.message, true)
		return false
	if game_mode != MODE_LOCAL:
		state.players[0].name = "玩家 1"
		state.players[1].name = "Deep AI" if game_mode == MODE_DEEP else "Challenge AI"
		if game_mode == MODE_DEEP:
			if deep_runtime.load_for_deck(second_key):
				ai_inference = deep_runtime.get_backend()
			else:
				ai_inference = null
		else:
			deep_runtime.unload()
			ai_inference = null
	current_view_player = 0
	selected_entity_key = ""
	_build_game_screen()
	if game_mode == MODE_DEEP and ai_inference == null:
		_show_toast(
			"Deep AI 模型不可用，将自动回退 Challenge AI：%s" % deep_runtime.last_error,
			true,
		)
	if game_mode == MODE_LOCAL:
		_show_pass_overlay(0, "准备阶段", "玩家 1 放置战斗宝可梦，可继续放置备战宝可梦。")
	else:
		_refresh_game()
		_maybe_start_ai()
	return true


func _build_game_screen() -> void:
	current_screen = SCREEN_GAME
	_clear_screen()
	battle_screen = BATTLE_SCENE.instantiate() as BattleScreen
	battle_screen.name = "GameScreen"
	battle_screen.menu_requested.connect(_show_pause_overlay)
	battle_screen.hand_card_selected.connect(_select_hand_card)
	battle_screen.pokemon_selected.connect(_on_battle_pokemon_selected)
	battle_screen.action_requested.connect(_execute_action)
	battle_screen.card_drop_requested.connect(_on_battle_card_dropped)
	battle_screen.inspect_card_requested.connect(_show_card_inspector)
	battle_screen.inspect_zone_requested.connect(_show_zone_inspector)
	battle_screen.choice_target_selected.connect(_on_battle_choice_target_selected)
	screen_host.add_child(battle_screen)
	battle_screen.initialize_ui()
	action_list = battle_screen.action_list
	log_label = battle_screen.log_label
	detail_image = battle_screen.detail_image
	detail_title = battle_screen.detail_title
	detail_text = battle_screen.detail_text
	if battle_screen.director and audio_director:
		battle_screen.director.audio_requested.connect(audio_director.play_cue)
	if audio_director:
		audio_director.play_music("battle")
	_refresh_game()


func _refresh_game() -> void:
	if state == null or current_screen != SCREEN_GAME:
		return
	if battle_screen:
		var rows := _current_action_rows()
		battle_screen.update_view(
			state,
			current_view_player,
			rows,
			selected_entity_key,
			ai_thinking,
			game_mode,
		)
	if state.winner >= 0:
		_show_end_screen()


func _current_action_rows() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	if state == null:
		return rows
	var actions: Array[GameAction] = []
	var actor := _current_actor()
	if game_mode == MODE_NETWORK:
		if actor == network_player_idx:
			actions = network_legal_actions
	elif game_mode == MODE_LOCAL or actor == 0:
		actions = engine.legal_actions(state, actor, true)
	for action in actions:
		rows.append({
			"action": action,
			"label": _action_label(action),
		})
	return rows


func _on_battle_pokemon_selected(
	player_idx: int,
	slot: String,
	card_id: String,
) -> void:
	if selected_entity_key.begins_with("hand:"):
		var hand_index := selected_entity_key.trim_prefix("hand:").to_int()
		var candidates := _matching_drop_actions(hand_index, player_idx, slot)
		if candidates.size() == 1:
			_execute_action(candidates[0])
			return
	elif selected_entity_key.begins_with("pokemon:"):
		var candidates := _matching_selected_pokemon_target_actions(
			player_idx,
			slot,
		)
		if candidates.size() == 1:
			_execute_action(candidates[0])
			return
	_select_pokemon(player_idx, slot, card_id)


func _on_battle_card_dropped(
	hand_index: int,
	_card_id: String,
	target_player: int,
	target_slot: String,
) -> void:
	var candidates := _matching_drop_actions(hand_index, target_player, target_slot)
	if candidates.size() == 1:
		_execute_action(candidates[0])
		return
	if candidates.size() > 1:
		selected_entity_key = "hand:%d" % hand_index
		_refresh_game()
		return
	# BattleTable/CardView only emit drops for legal targets. Keep this branch as
	# a silent stale-state guard for network revisions racing with a drag.
	_refresh_game()


func _matching_drop_actions(
	hand_index: int,
	target_player: int,
	target_slot: String,
) -> Array[GameAction]:
	var result: Array[GameAction] = []
	for row in _current_action_rows():
		var action: GameAction = row.get("action")
		if action == null or int(action.params.get("hand_idx", -1)) != hand_index:
			continue
		if (
			target_slot == "stadium"
			and action.action == "PLAY_TRAINER"
			and action.actor == target_player
			and action.actor in [0, 1]
			and hand_index >= 0
		):
			var actor_hand := state.get_player(action.actor).hand
			if (
				hand_index < actor_hand.size()
				and catalog.is_stadium(str(actor_hand[hand_index]))
			):
				result.append(action)
			continue
		var action_slot := str(action.params.get(
			"target_slot",
			action.params.get("target", action.params.get("slot", "")),
		))
		var action_player := action.actor
		if action.target:
			action_player = action.target.player
			if action_slot.is_empty():
				action_slot = action.target.slot
		if action_player == target_player and action_slot == target_slot:
			result.append(action)
	return result


func _matching_selected_pokemon_target_actions(
	target_player: int,
	target_slot: String,
) -> Array[GameAction]:
	var result: Array[GameAction] = []
	var parts := selected_entity_key.split(":")
	if parts.size() < 3:
		return result
	var selected_player := int(parts[1])
	var selected_slot := str(parts[2])
	for row in _current_action_rows():
		var action: GameAction = row.get("action")
		if action == null or action.target == null:
			continue
		if (
			action.target.player != target_player
			or action.target.slot != target_slot
		):
			continue
		var belongs_to_selected := (
			action.source
			and action.source.player == selected_player
			and action.source.slot == selected_slot
		)
		if (
			action.action == "RETREAT"
			and selected_player == action.actor
			and selected_slot == "active"
		):
			belongs_to_selected = true
		if belongs_to_selected:
			result.append(action)
	return result


func _execute_action(action: GameAction) -> StepResult:
	if action.action == "RETREAT":
		_show_retreat_confirmation(action)
		return StepResult.new(true, "等待确认撤退。")
	if action.action == "END_TURN" and not _remaining_turn_action_labels().is_empty():
		_show_end_turn_confirmation(action)
		return StepResult.new(true, "等待确认结束回合。")
	return _execute_action_now(action)


func _execute_action_now(action: GameAction) -> StepResult:
	if game_mode == MODE_NETWORK:
		_play_click()
		var accepted := network_controller.submit_action(action)
		if not accepted:
			_show_toast("动作未发送或被房主拒绝。", true)
		else:
			selected_entity_key = ""
			_refresh_game()
		return StepResult.new(accepted, "动作已提交。" if accepted else "动作提交失败。")
	if game_mode != MODE_LOCAL and _current_actor() == 1:
		return StepResult.new(false, "AI 回合不能由玩家操作。")
	_play_click()
	action_sequence += 1
	action.action_id = "local:%d:%d" % [state.revision, action_sequence]
	var previous_active := state.active_player_idx
	var previous_phase := state.phase
	var presentation_snapshot := (
		battle_screen.capture_presentation_snapshot()
		if battle_screen
		else {}
	)
	var result := engine.apply_action(state, action, rng)
	if not result.success:
		_show_toast(result.message, true)
		_refresh_game()
		return result
	selected_entity_key = ""
	_show_toast(result.message if not result.message.is_empty() else "动作完成。")
	_refresh_game()
	if battle_screen and not result.events.is_empty():
		battle_screen.play_presentation(
			result.events,
			state.revision,
			action.actor,
			presentation_snapshot,
		)
	var pending_choice := _step_pending_choice(result)
	if pending_choice:
		if game_mode != MODE_LOCAL and pending_choice.player == 1:
			_schedule_ai_choice(pending_choice)
		else:
			_show_choice_overlay(pending_choice)
	else:
		_after_step(previous_active, previous_phase)
	return result


func _after_step(previous_active: int, previous_phase: String) -> void:
	if state.winner >= 0:
		_refresh_game()
		return
	if game_mode != MODE_LOCAL:
		current_view_player = 0
		_refresh_game()
		if _current_actor() == 1:
			_schedule_ai_action()
		return
	if state.phase == "SETUP":
		if state.setup_ready[current_view_player]:
			var next_setup := 1 - current_view_player
			current_view_player = next_setup
			_refresh_game()
			_show_pass_overlay(next_setup, "准备阶段", "轮到玩家 %d 放置宝可梦。" % (next_setup + 1))
			return
	elif (
		state.active_player_idx != previous_active
		or (previous_phase == "SETUP" and state.phase == "MAIN")
	):
		current_view_player = state.active_player_idx
		_refresh_game()
		_show_pass_overlay(
			current_view_player,
			"回合交接",
			"请将设备交给玩家 %d。" % (current_view_player + 1),
		)
		return
	elif not state.pending_promotions.is_empty():
		var promote_actor := int(state.pending_promotions[0])
		if promote_actor != current_view_player:
			current_view_player = promote_actor
			_refresh_game()
			_show_pass_overlay(promote_actor, "晋升", "请选择新的战斗宝可梦。")
			return
	_refresh_game()


func _show_choice_overlay(request: ChoiceRequest) -> void:
	active_request = request
	active_choice_panel = null
	selected_choice_ids.clear()
	option_buttons.clear()
	if battle_screen:
		battle_screen.clear_choice_targets()
	if request.request_type == "coin_flip":
		_show_coin_flip_choice(request)
		return
	var field_targets := _choice_field_target_options(request)
	if not field_targets.is_empty() and battle_screen:
		selected_entity_key = ""
		battle_screen.set_choice_targets(field_targets, request.prompt)
		_refresh_game()
		return
	var energy_cards := _choice_energy_cards(request)
	var revealed_cards := _choice_revealed_cards(request)
	var has_card_preview := not energy_cards.is_empty() or not revealed_cards.is_empty()
	var pure_empty_choice := (
		request.options.is_empty()
		and energy_cards.is_empty()
		and revealed_cards.is_empty()
	)
	for option in request.options:
		if not _choice_option_card_id(option).is_empty():
			has_card_preview = true
			break
	_open_modal(
		request.prompt,
		_choice_confirm_cta(request, 0),
		_choice_cancel_cta(request),
		false,
		ModalSpec.battle(_choice_modal_size(has_card_preview, pure_empty_choice)),
	)
	if pure_empty_choice:
		if modal_scroll:
			var compact_scroll_minimum := modal_scroll.custom_minimum_size
			compact_scroll_minimum.y = 150.0
			modal_scroll.custom_minimum_size = compact_scroll_minimum
		# ModalHost intentionally maintains a 480 px general-purpose floor. An
		# empty result has no scrolling content, so override that floor only for
		# this request; _open_modal restores the shared defaults next time.
		modal_panel.custom_minimum_size = _choice_modal_size(false, true)
	modal_title.text = _choice_title(request)
	var metadata_text := _choice_metadata_text(request)
	var panel := CHOICE_PANEL_SCENE.instantiate() as ChoicePanel
	modal_body.add_child(panel)
	active_choice_panel = panel
	panel.configure(
		metadata_text,
		not request.options.is_empty(),
		catalog,
		{
			"prompt": request.prompt,
			"min_select": request.min_select,
			"max_select": request.max_select,
			"request_type": request.request_type,
			"can_cancel": request.can_cancel,
			"allow_duplicates": request.allow_duplicates,
		},
	)
	panel.option_toggled.connect(_toggle_choice)
	panel.energy_index_requested.connect(_rewind_energy_distribution)
	panel.undo_requested.connect(_undo_energy_distribution)
	panel.clear_requested.connect(_clear_energy_distribution)
	if not energy_cards.is_empty():
		panel.add_energy_preview(energy_cards, catalog)
	elif not revealed_cards.is_empty():
		panel.add_revealed_cards(revealed_cards, catalog)
	for option in request.options:
		var option_id := str(option.get("option_id", ""))
		var option_card_id := _choice_option_card_id(option)
		if option_id.is_empty():
			continue
		if not option_card_id.is_empty():
			panel.add_card_option(
				option_id,
				option_card_id,
				_choice_option_caption(option),
				request.player,
			)
		else:
			option_buttons.append(
				panel.add_text_option(
					option_id,
					str(option.get("label", option_id)),
				)
			)
	modal_confirm.pressed.connect(_confirm_choice, CONNECT_ONE_SHOT)
	if request.can_cancel:
		modal_cancel.pressed.connect(_cancel_choice, CONNECT_ONE_SHOT)
	_refresh_choice_buttons()


func _show_coin_flip_choice(request: ChoiceRequest) -> void:
	_open_modal(
		request.prompt,
		"继续结算",
		"",
		false,
		ModalSpec.battle(Vector2(640, 420)),
	)
	modal_title.text = "硬币结算"
	var results: Array = request.metadata.get("predetermined_flips", [])
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 18)
	modal_body.add_child(content)
	var coins := HBoxContainer.new()
	coins.alignment = BoxContainer.ALIGNMENT_CENTER
	coins.add_theme_constant_override("separation", 14)
	content.add_child(coins)
	var heads := 0
	for index in range(results.size()):
		var is_heads := bool(results[index])
		if is_heads:
			heads += 1
		var coin := Label.new()
		coin.custom_minimum_size = Vector2(76.0, 76.0)
		coin.text = "正" if is_heads else "反"
		coin.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		coin.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		coin.add_theme_font_size_override("font_size", 24)
		coin.add_theme_color_override("font_color", DesignTokens.BG_DEEP)
		coin.add_theme_stylebox_override(
			"normal",
			DesignTokens.panel_style(
				DesignTokens.GOLD if is_heads else DesignTokens.CYAN,
				38,
				Color(1, 1, 1, 0.82),
				2,
				0,
			),
		)
		coins.add_child(coin)
		if not AppSettings.reduced_motion:
			coin.scale = Vector2(0.2, 1.0)
			coin.modulate.a = 0.0
			var tween := coin.create_tween()
			tween.tween_interval(float(index) * 0.10)
			tween.tween_property(coin, "modulate:a", 1.0, 0.08)
			tween.parallel().tween_property(coin, "scale", Vector2.ONE, 0.34).set_trans(
				Tween.TRANS_BACK,
			).set_ease(Tween.EASE_OUT)
	var summary := Label.new()
	summary.text = "正面 %d · 反面 %d" % [heads, results.size() - heads]
	summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	summary.add_theme_font_size_override("font_size", 18)
	summary.add_theme_color_override("font_color", DesignTokens.TEXT)
	content.add_child(summary)
	modal_confirm.disabled = false
	modal_confirm.text = "继续结算"
	modal_confirm.pressed.connect(_confirm_choice, CONNECT_ONE_SHOT)


func _choice_modal_size(has_preview: bool, compact_empty: bool = false) -> Vector2:
	# ModalHost resolves this preferred size against the safe content area, not
	# the raw sub-viewport. Headless and embedded viewports can report a tiny
	# placeholder rect even while the safe root layout has its final size.
	var viewport_size := _safe_content_size() if is_inside_tree() else Vector2.ZERO
	if viewport_size.x <= 1.0 or viewport_size.y <= 1.0:
		var tree := Engine.get_main_loop() as SceneTree
		if tree and tree.root:
			viewport_size = Vector2(tree.root.size)
	if viewport_size.x <= 1.0 or viewport_size.y <= 1.0:
		viewport_size = Vector2(1280, 720)
	var target := (
		Vector2(640, 360)
		if compact_empty
		else Vector2(980, 660) if has_preview else Vector2(720, 620)
	)
	var compact := (
		viewport_size.x / maxf(viewport_size.y, 1.0) < 1.5
		or viewport_size.x < 1360.0
	)
	var inset := Vector2(24, 24) if compact else Vector2(96, 72)
	var available := Vector2(
		maxf(1.0, viewport_size.x - inset.x),
		maxf(1.0, viewport_size.y - inset.y),
	)
	return Vector2(
		minf(target.x, available.x),
		minf(target.y, available.y),
	)


func _choice_option_card_id(option: Dictionary) -> String:
	var value_variant: Variant = option.get("value")
	if value_variant is Dictionary:
		var value: Dictionary = value_variant
		if not str(value.get("card_id", "")).is_empty():
			return str(value["card_id"])
	var ref_variant: Variant = option.get("ref")
	if ref_variant is Dictionary:
		return str(Dictionary(ref_variant).get("card_id", ""))
	return ""


func _choice_option_caption(option: Dictionary) -> String:
	var label_text := str(option.get("label", ""))
	var value_variant: Variant = option.get("value")
	var value_data: Dictionary = {}
	if value_variant is Dictionary:
		value_data = value_variant
	var ref_variant: Variant = option.get("ref")
	var ref_data: Dictionary = {}
	if ref_variant is Dictionary:
		ref_data = ref_variant
	var is_attachment := (
		str(ref_data.get("kind", "")) == "attachment"
		or str(option.get("option_id", "")).begins_with("attachment:")
	)
	if is_attachment:
		var attachment_slot := str(value_data.get("slot", ref_data.get("slot", "")))
		var attachment_index := int(value_data.get("index", ref_data.get("index", -1)))
		var attachment_label := label_text.replace(" - ", " · ")
		if attachment_label.is_empty() and catalog != null:
			attachment_label = catalog.card_name(_choice_option_card_id(option))
		var attachment_parts: Array[String] = []
		if not attachment_slot.is_empty():
			attachment_parts.append(_slot_name(attachment_slot))
		if not attachment_label.is_empty():
			attachment_parts.append(attachment_label)
		if attachment_index >= 0:
			attachment_parts.append("第%d张" % (attachment_index + 1))
		return " · ".join(attachment_parts)
	var value_slot := str(value_data.get("slot", ""))
	var base_name := str(value_data.get("base_name", ""))
	var evolution_name := str(value_data.get("evolution_name", ""))
	if not value_slot.is_empty() and not base_name.is_empty() and not evolution_name.is_empty():
		return "%s · %s → %s" % [_slot_name(value_slot), base_name, evolution_name]
	if not value_slot.is_empty():
		return _slot_name(value_slot)
	if not ref_data.is_empty():
		var ref: Dictionary = ref_data
		var ref_slot := str(ref.get("slot", ""))
		if not ref_slot.is_empty():
			return _slot_name(ref_slot)
		var zone := str(ref.get("zone", ""))
		if not zone.is_empty():
			var zone_text := _zone_name(zone)
			var index := int(ref.get("index", -1))
			if index >= 0:
				return "%s %d" % [zone_text, index + 1]
			return zone_text
	if value_variant is Dictionary and value_data.has("index"):
		return "#%d" % (int(value_data.get("index", -1)) + 1)
	return label_text


func _choice_field_target_options(request: ChoiceRequest) -> Dictionary:
	var result: Dictionary = {}
	if (
		request == null
		or request.min_select != 1
		or request.max_select != 1
		or request.allow_duplicates
		or request.can_cancel
		or request.request_type == "select_attachment"
	):
		return result
	for option in request.options:
		var option_id := str(option.get("option_id", ""))
		var player_idx := request.player
		var slot := ""
		var ref_value: Variant = option.get("ref")
		if ref_value is Dictionary:
			var ref := ref_value as Dictionary
			if str(ref.get("kind", "")) == "pokemon":
				player_idx = int(ref.get("player", player_idx))
				slot = str(ref.get("slot", ""))
		var option_value: Variant = option.get("value")
		if slot.is_empty() and option_value is Dictionary:
			var value := option_value as Dictionary
			player_idx = int(value.get("player", player_idx))
			slot = str(value.get("slot", ""))
		if (
			option_id.is_empty()
			or player_idx not in [0, 1]
			or slot.is_empty()
			or state == null
			or state.get_player(player_idx).get_pokemon(slot) == null
		):
			return {}
		var key := CardInteractionRouter.pokemon_key(player_idx, slot)
		# Attachment choices may expose several energies on one Pokémon; in that
		# case the card alone is not a unique option, so keep the card grid panel.
		if result.has(key):
			return {}
		result[key] = option_id
	return result


func _on_battle_choice_target_selected(option_id: String) -> void:
	if active_request == null or option_id.is_empty():
		return
	var is_valid_option := false
	for option in active_request.options:
		if str(option.get("option_id", "")) == option_id:
			is_valid_option = true
			break
	if not is_valid_option:
		return
	if battle_screen:
		battle_screen.clear_choice_targets()
	selected_choice_ids.assign([option_id])
	_confirm_choice()


func _choice_energy_cards(request: ChoiceRequest) -> Array[String]:
	var result: Array[String] = []
	if request == null or request.request_type not in ["distribute_energy", "select_energy_target"]:
		return result
	if state == null or state.resolution_stack.is_empty():
		return result
	var stack := ResolutionStack.from_dict(state.resolution_stack)
	if stack.frames.is_empty():
		return result
	var frame: Dictionary = stack.frames[-1]
	var data: Dictionary = frame.get("data", {})
	for value in data.get("card_ids", []):
		var card_id := str(value)
		if not card_id.is_empty():
			result.append(card_id)
	if not result.is_empty():
		return result
	var source_slot := str(data.get("source_slot", ""))
	var player_idx := int(data.get("player_idx", request.player))
	var amount := int(data.get("amount", 0))
	if source_slot.is_empty() or amount <= 0:
		return result
	var pokemon := state.get_player(player_idx).get_pokemon(source_slot)
	if pokemon == null:
		return result
	for index in range(mini(amount, pokemon.energy_card_ids.size())):
		result.append(pokemon.energy_card_ids[index])
	return result


func _show_retreat_confirmation(action: GameAction) -> void:
	_play_click()
	_open_modal(
		"确认撤退",
		"确认撤退",
		"取消",
		false,
		ModalSpec.battle(Vector2(640, 420)),
	)
	var lines := _retreat_confirmation_lines(action)
	var body := Label.new()
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_theme_font_size_override("font_size", 18)
	body.add_theme_color_override("font_color", DesignTokens.TEXT)
	body.text = "\n".join(lines)
	modal_body.add_child(body)
	var payment_card_ids := _retreat_energy_card_ids(action)
	if not payment_card_ids.is_empty():
		var payment_hint := Label.new()
		payment_hint.text = "请点选下列附着能量，确认撤退支付："
		payment_hint.add_theme_font_size_override("font_size", 15)
		payment_hint.add_theme_color_override("font_color", DesignTokens.CYAN)
		modal_body.add_child(payment_hint)
		var payment_row := HBoxContainer.new()
		payment_row.alignment = BoxContainer.ALIGNMENT_CENTER
		payment_row.add_theme_constant_override("separation", 10)
		modal_body.add_child(payment_row)
		var selected_payments: Dictionary = {}
		for payment_position in range(payment_card_ids.size()):
			var energy_card_id := payment_card_ids[payment_position]
			var energy_view := CARD_SCENE.instantiate() as CardView
			energy_view.custom_minimum_size = Vector2(92.0, 128.0)
			energy_view.configure(energy_card_id, null, false, -1, action.actor, "", true)
			energy_view.set_interaction_state(false)
			payment_row.add_child(energy_view)
			energy_view.activated.connect(_toggle_retreat_payment_card.bind(
				payment_position,
				energy_view,
				selected_payments,
				payment_card_ids.size(),
			))
			energy_view.detail_requested.connect(_inspect_retreat_payment_card.bind(action))
		modal_confirm.disabled = true
	modal_confirm.pressed.connect(func() -> void:
		_play_click()
		_close_modal()
		_execute_action_now(action)
	, CONNECT_ONE_SHOT)
	modal_cancel.pressed.connect(func() -> void:
		_play_click()
		_close_modal()
	, CONNECT_ONE_SHOT)


func _retreat_confirmation_lines(action: GameAction) -> Array[String]:
	var actor := action.actor if action.actor != null else _current_actor()
	var player := state.get_player(actor)
	var bench_idx := int(action.params.get("bench_idx", -1))
	var target_name := "备战宝可梦"
	if bench_idx >= 0 and bench_idx < player.bench.size() and player.bench[bench_idx]:
		target_name = catalog.card_name(player.bench[bench_idx].card_id)
	var energy_names := _retreat_energy_names(action)
	var active_name := catalog.card_name(player.active.card_id) if player.active else "战斗宝可梦"
	var cost_text := "无需丢弃能量" if energy_names.is_empty() else "将丢弃：%s" % "、".join(energy_names)
	return [
		"%s 将撤退，%s 将进入战斗区。" % [active_name, target_name],
		cost_text,
	]


func _retreat_energy_names(action: GameAction) -> Array[String]:
	var result: Array[String] = []
	var actor := action.actor if action.actor != null else _current_actor()
	if state == null or actor not in [0, 1]:
		return result
	var active := state.get_player(actor).active
	if active == null:
		return result
	for raw_index in action.params.get("energy_indices", []):
		var index := int(raw_index)
		if index >= 0 and index < active.energy_card_ids.size():
			result.append(catalog.card_name(str(active.energy_card_ids[index])))
	return result


func _retreat_energy_suffix(action: GameAction) -> String:
	var names := _retreat_energy_names(action)
	if names.is_empty():
		return "（无需丢弃能量）"
	return "（丢弃：%s）" % "、".join(names)


func _choice_revealed_cards(request: ChoiceRequest) -> Array[String]:
	var result: Array[String] = []
	if request == null:
		return result
	for value in request.metadata.get("revealed_card_ids", []):
		var card_id := str(value)
		if not card_id.is_empty():
			result.append(card_id)
	if result.is_empty():
		var top_card_id := str(request.metadata.get("top_card_id", ""))
		if not top_card_id.is_empty():
			result.append(top_card_id)
	return result


func _choice_option_by_id(request: ChoiceRequest, option_id: String) -> Dictionary:
	if request == null or option_id.is_empty():
		return {}
	for option_value in request.options:
		var option: Dictionary = option_value
		if str(option.get("option_id", "")) == option_id:
			return option
	return {}


func _choice_continuation_data() -> Dictionary:
	if state == null or state.resolution_stack.is_empty():
		return {}
	var stack := ResolutionStack.from_dict(state.resolution_stack)
	for index in range(stack.frames.size() - 1, -1, -1):
		var frame: Dictionary = stack.frames[index]
		if str(frame.get("kind", "")) == "continuation":
			var data: Variant = frame.get("data", {})
			return Dictionary(data) if data is Dictionary else {}
	return {}


func _choice_has_cancel_action_checkpoint() -> bool:
	if state == null or state.resolution_stack.is_empty():
		return false
	var stack := ResolutionStack.from_dict(state.resolution_stack)
	var checkpoint: Variant = stack.context.get("cancel_action_checkpoint")
	if checkpoint is Dictionary and not Dictionary(checkpoint).is_empty():
		return true
	return stack.context.get("cancel_action_snapshot") is Dictionary


func _choice_cancel_cta(request: ChoiceRequest) -> String:
	if request == null or not request.can_cancel:
		return ""
	return "取消使用此卡" if _choice_has_cancel_action_checkpoint() else "取消"


func _choice_confirm_cta(request: ChoiceRequest, selected_count: int) -> String:
	if request == null:
		return "确认选择"
	if request.max_select == 0:
		return "继续结算"
	if request.min_select == 0 and selected_count == 0:
		return "不选择并继续"
	if request.request_type == "confirm":
		if selected_count == 1:
			var selected_option := _choice_option_by_id(
				request,
				selected_choice_ids[0] if not selected_choice_ids.is_empty() else "",
			)
			var selected_label := str(selected_option.get("label", ""))
			if not selected_label.is_empty():
				return "确认“%s”" % selected_label
		return "确认决定"
	if request.request_type == "distribute_energy":
		return "确认能量分配（%d/%d）" % [selected_count, request.max_select]
	return "确认选择（%d/%d）" % [selected_count, request.max_select]


func _choice_option_category(option: Dictionary) -> String:
	if option.is_empty() or catalog == null:
		return ""
	var card_id := _choice_option_card_id(option)
	if card_id.is_empty():
		return ""
	if catalog.is_tool(card_id):
		return "tool"
	if catalog.is_item(card_id):
		return "item"
	if catalog.is_pokemon(card_id):
		return "pokemon"
	if catalog.is_basic_energy(card_id):
		return "basic_energy"
	return ""


func _choice_selected_category_count(request: ChoiceRequest, category: String) -> int:
	var count := 0
	for selected_id in selected_choice_ids:
		if _choice_option_category(_choice_option_by_id(request, selected_id)) == category:
			count += 1
	return count


func _choice_selected_option_count(option_id: String) -> int:
	var count := 0
	for selected_id in selected_choice_ids:
		if selected_id == option_id:
			count += 1
	return count


func _choice_addition_blocked_reason(request: ChoiceRequest, option_id: String) -> String:
	var option := _choice_option_by_id(request, option_id)
	if option.is_empty():
		return "该选择项已失效，请重新选择"
	var already_selected := selected_choice_ids.find(option_id) >= 0
	if already_selected and not request.allow_duplicates:
		# Existing exclusive selections must always remain available so they can
		# be removed, even while every unselected option is at capacity.
		return ""
	if not request.allow_duplicates and request.max_select == 1:
		# A radio-style request replaces the old selection atomically. It is not
		# blocked merely because the one available slot is already occupied.
		return ""

	var category := _choice_option_category(option)
	if request.request_type == "arven":
		if category == "item" and _choice_selected_category_count(request, "item") >= 1:
			return "物品和宝可梦道具各最多选择1张，请先取消已选物品卡"
		if category == "tool" and _choice_selected_category_count(request, "tool") >= 1:
			return "物品和宝可梦道具各最多选择1张，请先取消已选宝可梦道具"
	elif request.request_type == "clara":
		var clara_data := _choice_continuation_data()
		var pokemon_limit := int(request.metadata.get(
			"pokemon_count",
			clara_data.get("pokemon_count", request.max_select),
		))
		var energy_limit := int(request.metadata.get(
			"energy_count",
			clara_data.get("energy_count", request.max_select),
		))
		if (
			category == "pokemon"
			and _choice_selected_category_count(request, "pokemon") >= pokemon_limit
		):
			return "宝可梦最多选择%d张，请先取消一张宝可梦" % pokemon_limit
		if (
			category == "basic_energy"
			and _choice_selected_category_count(request, "basic_energy") >= energy_limit
		):
			return "基本能量最多选择%d张，请先取消一张基本能量" % energy_limit
	elif request.request_type == "distribute_energy":
		var distribution_data := _choice_continuation_data()
		if (
			bool(request.metadata.get(
				"same_target",
				distribution_data.get("same_target", false),
			))
			and not selected_choice_ids.is_empty()
			and option_id != selected_choice_ids[0]
		):
			return "此效果要求所有能量分配到同一目标"
		var max_per_target := int(request.metadata.get(
			"max_per_target",
			distribution_data.get("max_per_target", 99),
		))
		if _choice_selected_option_count(option_id) >= max_per_target:
			return "该目标最多可分配 %d张能量" % max_per_target

	if selected_choice_ids.size() >= request.max_select:
		return "已达到选择上限，请先取消一张"
	return ""


func _choice_option_disabled_reasons(request: ChoiceRequest) -> Dictionary:
	var reasons: Dictionary = {}
	if request == null:
		return reasons
	for option_value in request.options:
		var option: Dictionary = option_value
		var option_id := str(option.get("option_id", ""))
		if option_id.is_empty():
			continue
		var reason := _choice_addition_blocked_reason(request, option_id)
		if not reason.is_empty():
			reasons[option_id] = reason
	return reasons


func _show_choice_blocked_reason(reason: String) -> void:
	if reason.is_empty() or active_choice_panel == null:
		return
	active_choice_panel.show_blocked_reason(reason)


func _toggle_choice(option_id: String) -> void:
	_play_click()
	if active_request == null:
		return
	var existing := selected_choice_ids.find(option_id)
	if not active_request.allow_duplicates and existing >= 0:
		selected_choice_ids.remove_at(existing)
	else:
		var blocked_reason := _choice_addition_blocked_reason(active_request, option_id)
		if not blocked_reason.is_empty():
			_refresh_choice_buttons()
			_show_choice_blocked_reason(blocked_reason)
			return
		if active_request.allow_duplicates:
			selected_choice_ids.append(option_id)
		elif active_request.max_select == 1:
			# Single-choice panels behave like a radio group: choosing another
			# option replaces the previous selection in one refresh. Choosing the
			# selected option above still clears it, preserving the existing toggle.
			selected_choice_ids.assign([option_id])
		else:
			selected_choice_ids.append(option_id)
	_refresh_choice_buttons()


func _rewind_energy_distribution(index: int) -> void:
	if active_request == null or active_request.request_type != "distribute_energy":
		return
	if index < 0 or index >= selected_choice_ids.size():
		return
	_play_click()
	while selected_choice_ids.size() > index:
		selected_choice_ids.pop_back()
	_refresh_choice_buttons()


func _undo_energy_distribution() -> void:
	if active_request == null or active_request.request_type != "distribute_energy":
		return
	if selected_choice_ids.is_empty():
		return
	_play_click()
	selected_choice_ids.pop_back()
	_refresh_choice_buttons()


func _clear_energy_distribution() -> void:
	if active_request == null or active_request.request_type != "distribute_energy":
		return
	if selected_choice_ids.is_empty():
		return
	_play_click()
	selected_choice_ids.clear()
	_refresh_choice_buttons()


func _refresh_choice_buttons() -> void:
	if active_request == null:
		return
	if active_choice_panel:
		active_choice_panel.refresh_selection(
			selected_choice_ids,
			active_request.max_select,
			active_request.allow_duplicates,
		)
		active_choice_panel.set_option_disabled_reasons(
			_choice_option_disabled_reasons(active_request),
		)
	modal_confirm.disabled = not (
		selected_choice_ids.size() >= active_request.min_select
		and selected_choice_ids.size() <= active_request.max_select
	)
	modal_confirm.text = _choice_confirm_cta(active_request, selected_choice_ids.size())
	if active_request.can_cancel:
		modal_cancel.text = _choice_cancel_cta(active_request)


func _confirm_choice() -> void:
	if active_request == null:
		return
	_play_click()
	var request := active_request
	var confirmed_ids: Array[String] = selected_choice_ids.duplicate()
	if battle_screen:
		battle_screen.clear_choice_targets()
	_close_modal()
	if game_mode == MODE_NETWORK:
		active_request = null
		if not network_controller.submit_choice(
			ChoiceResponse.new(request.request_id, confirmed_ids)
		):
			_show_toast("选择未发送或被房主拒绝。", true)
			return
		_show_toast("选择已提交，等待房主同步。")
		return
	var previous_active := state.active_player_idx
	var previous_phase := state.phase
	var presentation_snapshot := (
		battle_screen.capture_presentation_snapshot()
		if battle_screen
		else {}
	)
	var result := engine.apply_choice(
		state,
		request,
		ChoiceResponse.new(request.request_id, confirmed_ids),
		rng,
	)
	active_request = null
	if not result.success:
		_show_toast(result.message, true)
		_refresh_game()
		return
	_refresh_game()
	if battle_screen and not result.events.is_empty():
		battle_screen.play_presentation(
			result.events,
			state.revision,
			request.player,
			presentation_snapshot,
		)
	var pending_choice := _step_pending_choice(result)
	if pending_choice:
		if game_mode != MODE_LOCAL and pending_choice.player == 1:
			_schedule_ai_choice(pending_choice)
		else:
			_show_choice_overlay(pending_choice)
	else:
		_show_toast(result.message if not result.message.is_empty() else "选择已结算。")
		_after_step(previous_active, previous_phase)


func _cancel_choice() -> void:
	if active_request == null:
		return
	_play_click()
	var request := active_request
	if battle_screen:
		battle_screen.clear_choice_targets()
	_close_modal()
	if game_mode == MODE_NETWORK:
		active_request = null
		if not network_controller.submit_choice(
			ChoiceResponse.new(request.request_id, [], true)
		):
			_show_toast("取消请求未发送。", true)
			return
		_show_toast("取消请求已提交，等待房主同步。")
		return
	var result := engine.apply_choice(
		state,
		request,
		ChoiceResponse.new(request.request_id, [], true),
		rng,
	)
	active_request = null
	_show_toast(result.message if result.success else result.message, not result.success)
	_refresh_game()


func _step_pending_choice(result: StepResult) -> ChoiceRequest:
	if result != null and result.pending_choice != null:
		return result.pending_choice
	if state == null or state.resolution_stack.is_empty():
		return null
	return ResolutionStack.from_dict(state.resolution_stack).pending_request


func _show_pass_overlay(player_idx: int, heading: String, body: String) -> void:
	var privacy_spec := ModalSpec.battle(Vector2(720, 620), true)
	privacy_spec.cancellable = false
	_open_modal(
		heading,
		"显示玩家 %d 手牌" % (player_idx + 1),
		"",
		true,
		privacy_spec,
	)
	var privacy := PRIVACY_PANEL_SCENE.instantiate() as PrivacyPanel
	modal_body.add_child(privacy)
	privacy.configure(body)
	modal_confirm.pressed.connect(func() -> void:
		_play_click()
		_close_modal()
		_refresh_game()
	, CONNECT_ONE_SHOT)


func _show_pause_overlay() -> void:
	if game_mode in [MODE_CHALLENGE, MODE_DEEP]:
		ai_coordinator.cancel_and_wait()
		ai_thinking = false
		_refresh_game()
	_open_modal("对局菜单", "继续对局", "返回标题", true)
	var pause_panel := PAUSE_PANEL_SCENE.instantiate() as PausePanel
	modal_body.add_child(pause_panel)
	pause_panel.configure(
		(
			"返回标题会断开当前联机对局。"
			if game_mode == MODE_NETWORK
			else "返回标题会结束当前本地对局。"
		)
	)
	pause_panel.help_requested.connect(func() -> void:
		_play_click()
		_close_modal()
		_show_help(game_mode in [MODE_CHALLENGE, MODE_DEEP])
	)
	modal_confirm.pressed.connect(func() -> void:
		_play_click()
		_close_modal()
		if game_mode != MODE_NETWORK:
			_maybe_start_ai()
	, CONNECT_ONE_SHOT)
	modal_cancel.pressed.connect(func() -> void:
		_play_click()
		_close_modal()
		if game_mode == MODE_NETWORK:
			_surrender_network_and_show_title()
		else:
			state = null
			_show_title()
	, CONNECT_ONE_SHOT)


func _show_end_turn_confirmation(action: GameAction) -> void:
	var remaining := _remaining_turn_action_labels()
	if remaining.is_empty():
		_execute_action_now(action)
		return
	_play_click()
	_open_modal(
		"确认结束回合",
		"结束回合",
		"继续操作",
		false,
		ModalSpec.battle(Vector2(580, 380)),
	)
	var body := Label.new()
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_theme_font_size_override("font_size", 17)
	body.add_theme_color_override("font_color", DesignTokens.TEXT)
	body.text = "仍可执行：\n\n• %s\n\n结束回合后将无法执行这些动作。" % "\n• ".join(remaining)
	modal_body.add_child(body)
	modal_confirm.pressed.connect(func() -> void:
		_play_click()
		_close_modal()
		_execute_action_now(action)
	, CONNECT_ONE_SHOT)
	modal_cancel.pressed.connect(func() -> void:
		_play_click()
		_close_modal()
	, CONNECT_ONE_SHOT)


func _remaining_turn_action_labels() -> Array[String]:
	var result: Array[String] = []
	for row in _current_action_rows():
		var action := row.get("action") as GameAction
		if action == null or action.action in ["END_TURN", "SETUP_DONE"]:
			continue
		var label := str({
			"PLAY_BASIC": "放置基础宝可梦",
			"EVOLVE": "进化宝可梦",
			"ATTACH_ENERGY": "附加能量",
			"PLAY_TRAINER": "使用训练家卡",
			"USE_ABILITY": "发动特性",
			"USE_STADIUM": "发动竞技场效果",
			"RETREAT": "撤退",
			"DECLARE_ATTACK": "发动攻击",
			"PROMOTE": "晋升备战宝可梦",
		}.get(action.action, "执行%s" % action.action))
		if label not in result:
			result.append(label)
	return result


func _retreat_energy_card_ids(action: GameAction) -> Array[String]:
	var result: Array[String] = []
	var actor := action.actor if action.actor != null else _current_actor()
	if state == null or actor not in [0, 1]:
		return result
	var active := state.get_player(actor).active
	if active == null:
		return result
	for raw_index in action.params.get("energy_indices", []):
		var index := int(raw_index)
		if index >= 0 and index < active.energy_card_ids.size():
			result.append(active.energy_card_ids[index])
	return result


func _toggle_retreat_payment_card(
	_card_id: String,
	_hand_index: int,
	_player: int,
	_slot: String,
	payment_position: int,
	energy_view: CardView,
	selected_payments: Dictionary,
	required_count: int,
) -> void:
	_play_click()
	if selected_payments.has(payment_position):
		selected_payments.erase(payment_position)
	else:
		selected_payments[payment_position] = true
	energy_view.set_selected(selected_payments.has(payment_position))
	modal_confirm.disabled = selected_payments.size() < required_count


func _inspect_retreat_payment_card(
	inspected_card_id: String,
	action: GameAction,
) -> void:
	_show_card_inspector({
		"card_id": inspected_card_id,
		"location": "撤退支付",
		"player": action.actor,
	}, _show_retreat_confirmation.bind(action), "返回撤退确认")


func _surrender_network_and_show_title() -> void:
	network_controller.surrender()
	# Give ENet/WebSocket two process turns to flush the surrender/final state
	# before the title route closes the transport.
	await get_tree().process_frame
	await get_tree().process_frame
	if game_mode != MODE_NETWORK or current_screen not in [SCREEN_GAME, SCREEN_END]:
		return
	state = null
	_show_title()


func _show_help(resume_ai_on_close: bool = false) -> void:
	_play_click()
	_open_modal(
		"规则与操作帮助",
		"关闭",
		"",
		current_screen == SCREEN_GAME,
		ModalSpec.frontend(Vector2(900, 700)),
	)
	var panel := HELP_PANEL_SCENE.instantiate() as HelpPanel
	modal_body.add_child(panel)
	panel.configure()
	modal_confirm.pressed.connect(func() -> void:
		_close_modal()
		if resume_ai_on_close:
			_maybe_start_ai()
	, CONNECT_ONE_SHOT)


func _show_card_inspector(
	context: Dictionary,
	return_action: Callable = Callable(),
	return_label: String = "",
) -> void:
	var card_id := str(context.get("card_id", ""))
	if card_id.is_empty():
		return
	_play_click()
	var card := catalog.get_card(card_id)
	var title := str(card.get("name", card_id))
	var card_spec := (
		ModalSpec.battle(Vector2(860, 700), current_screen == SCREEN_GAME)
		if current_screen == SCREEN_GAME
		else ModalSpec.frontend(Vector2(860, 700))
	)
	if return_action.is_valid():
		card_spec.stack_behavior = ModalSpec.StackBehavior.RESTORE_PARENT
	_open_modal(title, "关闭", "", current_screen == SCREEN_GAME, card_spec)
	var panel := CARD_INSPECTOR_PANEL_SCENE.instantiate() as CardInspectorPanel
	modal_body.add_child(panel)
	panel.configure(catalog, context)
	panel.card_requested.connect(_show_card_inspector.bind(return_action, return_label))
	_modal_back_action = return_action
	if return_action.is_valid():
		modal_confirm.text = return_label if not return_label.is_empty() else "返回上一界面"
		modal_confirm.pressed.connect(return_action, CONNECT_ONE_SHOT)
	else:
		modal_confirm.pressed.connect(_close_modal, CONNECT_ONE_SHOT)


func _show_zone_inspector(context: Dictionary) -> void:
	_play_click()
	var title := "%s · %s" % [
		_player_name_for_context(int(context.get("player", -1))),
		str(context.get("title", context.get("zone", "区域"))),
	]
	var zone_spec := (
		ModalSpec.battle(Vector2(820, 680), current_screen == SCREEN_GAME)
		if current_screen == SCREEN_GAME
		else ModalSpec.frontend(Vector2(820, 680))
	)
	_open_modal(
		title.strip_edges(),
		"关闭",
		"",
		current_screen == SCREEN_GAME,
		zone_spec,
	)
	var panel := ZONE_INSPECTOR_PANEL_SCENE.instantiate() as ZoneInspectorPanel
	modal_body.add_child(panel)
	panel.configure(catalog, context)
	panel.card_requested.connect(_show_card_inspector)
	modal_confirm.pressed.connect(_close_modal, CONNECT_ONE_SHOT)


func _show_deck_details(
	deck_key: String,
	restore_scroll: int = -1,
) -> void:
	_play_click()
	var deck := catalog.get_deck(deck_key)
	if deck.is_empty():
		_show_toast("找不到牌组：%s" % deck_key, true)
		return
	_open_modal(
		"牌组详情",
		"关闭",
		"",
		false,
		ModalSpec.frontend(Vector2(980, 720)),
	)
	var panel := DECK_DETAIL_PANEL_SCENE.instantiate() as DeckDetailPanel
	modal_body.add_child(panel)
	panel.configure(catalog, deck_key)
	panel.card_requested.connect(_show_deck_card_inspector.bind(deck_key))
	modal_confirm.pressed.connect(_close_modal, CONNECT_ONE_SHOT)
	if restore_scroll >= 0:
		_restore_deck_detail_modal_state(
			_modal_generation,
			restore_scroll,
		)


func _show_deck_card_inspector(context: Dictionary, deck_key: String) -> void:
	var scroll_position := modal_scroll.scroll_vertical if modal_scroll else 0
	_show_card_inspector(
		context,
		_show_deck_details.bind(deck_key, scroll_position),
		"返回牌组详情",
	)


func _restore_deck_detail_modal_state(
	generation: int,
	scroll_position: int,
) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if generation != _modal_generation or not modal_layer.visible:
		return
	if modal_scroll and scroll_position >= 0:
		modal_scroll.scroll_vertical = scroll_position


func _show_settings() -> void:
	_play_click()
	_open_modal(
		"设置",
		"保存设置",
		"取消",
		current_screen == SCREEN_GAME,
		ModalSpec.frontend(Vector2(900, 760)),
	)
	var panel := SETTINGS_PANEL_SCENE.instantiate() as SettingsPanel
	modal_body.add_child(panel)
	panel.configure()
	panel.save_requested.connect(_save_settings_values)
	# Keep the save action connected while the modal remains open so a transient
	# filesystem failure can be corrected and retried without reopening Settings.
	modal_confirm.pressed.connect(panel.request_save)
	modal_cancel.pressed.connect(_close_modal, CONNECT_ONE_SHOT)


func _save_settings_values(values: Dictionary) -> void:
	AppSettings.update(
		float(values.get("master_volume", AppSettings.master_volume)),
		bool(values.get("muted", AppSettings.muted)),
		bool(values.get("reduced_motion", AppSettings.reduced_motion)),
		int(values.get("card_cache_size", AppSettings.card_cache_size)),
		str(values.get("animation_mode", AppSettings.animation_mode)),
		str(values.get("quality_profile", AppSettings.quality_profile)),
		float(values.get("music_volume", AppSettings.music_volume)),
		float(values.get("sfx_volume", AppSettings.sfx_volume)),
	)
	if not AppSettings.save_settings():
		_show_toast("设置保存失败。", true)
		return
	_close_modal()
	Engine.max_fps = AppSettings.target_fps()
	_show_toast("设置已保存。")


func _show_end_screen() -> void:
	if state == null or state.winner < 0:
		return
	if current_screen == SCREEN_END:
		return
	current_screen = SCREEN_END
	if modal_layer.visible:
		_close_modal()
	battle_screen = null
	var victory := _mount_screen(VICTORY_SCENE) as VictoryScreen
	var winner_player := state.get_player(state.winner)
	var winner_card_id := winner_player.active.card_id if winner_player.active else ""
	var winner_deck_key: String = str(
		state.public_deck_keys[state.winner]
		if state.winner >= 0 and state.winner < state.public_deck_keys.size()
		else ""
	)
	var winner_deck := catalog.get_deck(winner_deck_key)
	var mode_label: String = str({
		MODE_LOCAL: "本地双人",
		MODE_CHALLENGE: "Challenge AI",
		MODE_DEEP: "Deep AI",
		MODE_NETWORK: "Relay 联机" if network_kind == "relay" else "LAN 联机",
	}.get(game_mode, "自定义对局"))
	victory.configure(
		state.winner,
		state.turn_number,
		winner_player.name,
		winner_card_id,
		{
			"mode": game_mode,
			"mode_label": mode_label,
			"winner_deck": winner_deck_key,
			"winner_deck_name": winner_deck.get("name", winner_deck_key),
			"winner_card_name": catalog.card_name(winner_card_id),
		},
	)
	victory.rematch_requested.connect(func() -> void:
		state = null
		if game_mode == MODE_NETWORK:
			_show_network_setup(network_kind)
		else:
			_show_deck_select(game_mode)
	)
	victory.title_requested.connect(func() -> void:
		state = null
		_show_title()
	)
	if audio_director:
		audio_director.play_music("victory")
	_play_success()

func _show_loading(message: String) -> void:
	if loading_layer == null:
		return
	loading_label.text = message
	loading_layer.visible = true


func _hide_loading() -> void:
	if loading_layer:
		loading_layer.visible = false


func _open_modal(
	title_text: String,
	confirm_text: String,
	cancel_text: String,
	opaque_shade: bool = false,
	spec: ModalSpec = null,
) -> void:
	if battle_screen:
		battle_screen.hide_card_detail()
	if modal_scroll:
		var default_scroll_minimum := modal_scroll.custom_minimum_size
		default_scroll_minimum.y = 420.0
		modal_scroll.custom_minimum_size = default_scroll_minimum
	var viewport := get_viewport()
	var text_owner := viewport.gui_get_focus_owner() if viewport else null
	if text_owner is LineEdit:
		(text_owner as LineEdit).release_focus()
	_modal_back_action = Callable()
	var resolved_spec := spec
	if resolved_spec == null:
		resolved_spec = (
			ModalSpec.battle(Vector2(720, 620), opaque_shade)
			if current_screen == SCREEN_GAME
			else ModalSpec.frontend(Vector2(820, 680))
		)
	resolved_spec.opaque_shade = opaque_shade or resolved_spec.opaque_shade
	_modal_generation += 1
	_disconnect_button(modal_confirm)
	_disconnect_button(modal_cancel)
	if modal_host_controller:
		modal_host_controller.clear_body()
	else:
		_free_children_immediate(modal_body)
	if modal_host_controller:
		modal_host_controller.begin(
			resolved_spec,
			_safe_content_size(),
		)
	else:
		modal_panel.custom_minimum_size = resolved_spec.preferred_size
	modal_title.text = title_text
	var frontend_modal := resolved_spec.surface == ModalSpec.Surface.FRONTEND
	modal_title.theme_type_variation = &"FrontModalTitle" if frontend_modal else &""
	modal_confirm.text = confirm_text
	modal_confirm.disabled = false
	modal_confirm.theme_type_variation = &"FrontPrimaryButton" if frontend_modal else &""
	modal_cancel.text = cancel_text
	modal_cancel.visible = resolved_spec.cancellable and not cancel_text.is_empty()
	modal_cancel.theme_type_variation = &"FrontSecondaryButton" if frontend_modal else &""
	modal_shade.color.a = (
		MODAL_SHADE_OPAQUE_ALPHA
		if resolved_spec.opaque_shade
		else clampf(resolved_spec.shade_alpha, 0.0, 1.0)
	)
	modal_layer.visible = true
	modal_layer.move_to_front()
	if not FrontendMotion.decorative_motion_enabled():
		shell_animations.stop()
		shell_animations.speed_scale = 1.0
		modal_panel.modulate.a = 1.0
		modal_panel.scale = Vector2.ONE
		return
	var open_duration := FrontendMotion.duration(0.16)
	shell_animations.speed_scale = 0.16 / maxf(open_duration, 0.001)
	shell_animations.play("modal_open")


func _close_modal() -> void:
	_modal_generation += 1
	var close_generation := _modal_generation
	active_request = null
	active_choice_panel = null
	selected_choice_ids.clear()
	option_buttons.clear()
	_modal_back_action = Callable()
	if not modal_layer.visible:
		_finish_modal_close(close_generation)
		return
	if (
		not is_inside_tree()
		or not FrontendMotion.decorative_motion_enabled()
		or shell_animations == null
	):
		_finish_modal_close(close_generation)
		return
	var close_animation := shell_animations.get_animation("modal_close")
	if close_animation == null:
		_finish_modal_close(close_generation)
		return
	var close_duration := FrontendMotion.duration(close_animation.length)
	shell_animations.speed_scale = close_animation.length / maxf(close_duration, 0.001)
	shell_animations.play("modal_close")
	_finish_modal_close_after_delay(close_generation, close_duration)


func _finish_modal_close_after_delay(generation: int, delay: float) -> void:
	await get_tree().create_timer(delay, true, false, true).timeout
	_finish_modal_close(generation)


func _finish_modal_close(generation: int) -> void:
	if generation != _modal_generation:
		return
	modal_layer.visible = false
	if modal_body:
		_free_children_immediate(modal_body)
	modal_shade.color.a = MODAL_SHADE_ALPHA
	modal_panel.modulate = Color.WHITE
	modal_panel.scale = Vector2.ONE
	if shell_animations:
		shell_animations.stop()
		shell_animations.speed_scale = 1.0
	if modal_host_controller:
		modal_host_controller.reset_surface()
		modal_host_controller.finish()


func _select_hand_card(index: int, card_id: String) -> void:
	_play_click()
	var key := "hand:%d" % index
	selected_entity_key = "" if selected_entity_key == key else key
	if battle_screen:
		if selected_entity_key.is_empty():
			battle_screen.hide_card_detail()
		else:
			battle_screen.show_card_detail(card_id)
	_refresh_game()


func _select_pokemon(player_idx: int, slot: String, card_id: String) -> void:
	_play_click()
	var key := "pokemon:%d:%s" % [player_idx, slot]
	selected_entity_key = "" if selected_entity_key == key else key
	if battle_screen:
		if selected_entity_key.is_empty():
			battle_screen.hide_card_detail()
		else:
			battle_screen.show_card_detail(
				card_id,
				state.get_player(player_idx).get_pokemon(slot) if state else null,
			)
	_refresh_game()


func _show_card_detail(card_id: String) -> void:
	if battle_screen:
		var pokemon: PokemonState
		if selected_entity_key.begins_with("pokemon:"):
			var parts := selected_entity_key.split(":")
			if parts.size() >= 3:
				pokemon = state.get_player(int(parts[1])).get_pokemon(str(parts[2]))
		battle_screen.show_card_detail(card_id, pokemon)
		return
	if card_id.is_empty():
		detail_title.text = "空位"
		detail_text.text = "此位置没有宝可梦。"
		detail_image.texture = null
		return
	var card := catalog.get_card(card_id)
	detail_title.text = str(card.get("name", card_id))
	var rows: Array[String] = []
	rows.append("[color=#9cacc5]%s[/color]" % _card_type_text(card))
	if int(card.get("hp", 0)) > 0:
		rows.append("HP %d · 撤退 %d" % [
			int(card.get("hp", 0)), int(card.get("retreat_cost", 0))])
	for ability_value in card.get("abilities", []):
		var ability: Dictionary = ability_value
		rows.append("[color=#45a6ff]特性 · %s[/color]\n%s" % [
			ability.get("name", ""), ability.get("text", "")])
	for attack_value in card.get("attacks", []):
		var attack: Dictionary = attack_value
		var damage_label := str(attack.get("damage_text", ""))
		if damage_label.is_empty() and int(attack.get("damage", 0)) > 0:
			damage_label = str(attack.get("damage", 0))
		rows.append("[color=#f4c84a]%s · %s[/color]\n%s" % [
			attack.get("name", ""),
			damage_label,
			attack.get("text", ""),
		])
	if not str(card.get("trainer_text", "")).is_empty():
		rows.append(str(card.get("trainer_text", "")))
	detail_text.text = "\n\n".join(rows)
	var image_path := str(card.get("image_path", ""))
	detail_image.texture = CardTextureCache.get_texture(image_path)


func _modal_label(text_value: String, font_size: int = 15, color: Color = Color.WHITE) -> Label:
	var label := Label.new()
	label.text = text_value
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_constant_override("outline_size", 0)
	label.add_theme_color_override("font_outline_color", Color.TRANSPARENT)
	return label


func _add_card_grid_section(
	parent: VBoxContainer,
	title_text: String,
	card_ids: Array,
	is_hidden: bool,
) -> void:
	parent.add_child(_modal_label(title_text, 20, DesignTokens.GOLD))
	var grid := GridContainer.new()
	grid.columns = 6
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	parent.add_child(grid)
	if card_ids.is_empty():
		grid.add_child(_modal_label("无", 14, DesignTokens.TEXT_MUTED))
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
				_show_card_inspector({"card_id": card_id, "location": title_text})
			)
		grid.add_child(card_view)


func _hidden_card_rows(count: int) -> Array[String]:
	var result: Array[String] = []
	for _index in range(mini(maxi(0, count), 24)):
		result.append("")
	return result


func _player_name_for_context(player_idx: int) -> String:
	if player_idx < 0 or state == null:
		return ""
	return state.get_player(player_idx).name


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
		var damage_label := str(attack.get("damage_text", ""))
		if damage_label.is_empty() and int(attack.get("damage", 0)) > 0:
			damage_label = str(attack.get("damage", 0))
		rows.append("[color=#f4c84a]%s · %s[/color]\n%s" % [
			str(attack.get("name", "")),
			damage_label,
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


func _action_label(action: GameAction) -> String:
	match action.action:
		"PLAY_BASIC":
			return "上场 · %s → %s" % [
				_source_card_name(action), _slot_name(str(action.params.get("target", "")))]
		"EVOLVE":
			return "进化 · %s → %s" % [
				_source_card_name(action), _slot_name(str(action.params.get("slot", "")))]
		"ATTACH_ENERGY":
			return "附能 · %s → %s" % [
				_source_card_name(action), _slot_name(str(action.params.get("target_slot", "")))]
		"PLAY_TRAINER":
			var target := str(action.params.get("target_slot", ""))
			return "使用 · %s%s" % [
				_source_card_name(action),
				" → %s" % _slot_name(target) if not target.is_empty() else "",
			]
		"USE_ABILITY":
			return "特性 · %s · %s" % [
				action.params.get("ability_name", ""),
				_slot_name(str(action.params.get("slot", ""))),
			]
		"USE_STADIUM":
			return "发动竞技场"
		"RETREAT":
			return "撤退 → 备战区 %d%s" % [
				int(action.params.get("bench_idx", 0)) + 1,
				_retreat_energy_suffix(action),
			]
		"DECLARE_ATTACK":
			var active := state.get_player(action.actor).active
			var attacks: Array = catalog.get_card(active.card_id).get("attacks", []) if active else []
			var attack_idx := int(action.params.get("attack_idx", 0))
			var attack_name := "招式 %d" % (attack_idx + 1)
			if attack_idx >= 0 and attack_idx < attacks.size():
				attack_name = str(attacks[attack_idx].get("name", attack_name))
			return "攻击 · %s" % attack_name
		"END_TURN":
			return "结束回合"
		"SETUP_DONE":
			return "完成准备"
		"PROMOTE":
			return "晋升 · 备战区 %d" % (int(action.params.get("bench_idx", 0)) + 1)
		_:
			return action.action


func _source_card_name(action: GameAction) -> String:
	if action.source:
		return catalog.card_name(action.source.card_id)
	var hand_idx := int(action.params.get("hand_idx", -1))
	var player := state.get_player(action.actor)
	if hand_idx >= 0 and hand_idx < player.hand.size():
		return catalog.card_name(player.hand[hand_idx])
	return "卡牌"


func _choice_title(request: ChoiceRequest) -> String:
	return {
		"coin_flip": "硬币结算",
		"confirm": "确认操作",
		"discard_cards": "选择要丢弃的卡",
		"discard_then_draw": "丢弃手牌后抽牌",
		"zinnia": "选择要丢弃的手牌",
		"houb": "选择放回牌库底的卡",
		"hand_bottom_draw": "整理手牌",
		"search_move": "搜寻卡牌",
		"arven": "搜寻物品与宝可梦道具",
		"look_top": "查看牌库顶",
		"look_top_attach_energy": "选择基本能量",
		"clara": "从弃牌区回收卡牌",
		"shuffle_from_discard": "将卡牌洗回牌库",
		"distribute_energy": "分配能量",
		"select_energy_target": "选择附能目标",
		"select_energy_source": "选择能量来源",
		"select_attachment": "选择附着能量",
		"evolve_skip_stage": "选择进化目标",
		"select_heal_target": "选择回复目标",
		"damage_target": "选择伤害目标",
		"bench_damage_target": "选择备战区伤害目标",
		"place_counters_self_ko": "选择伤害指示物目标",
		"select_bench": "选择替换上场的宝可梦",
		"select_opponent_bench": "选择对手替换上场的宝可梦",
	}.get(
		request.request_type,
		"选择卡牌" if _choice_request_has_card_options(request) else "选择",
	)


func _choice_metadata_text(request: ChoiceRequest) -> String:
	if request.request_type == "coin_flip":
		var results: Array = request.metadata.get("predetermined_flips", [])
		var labels: Array[String] = []
		for result in results:
			labels.append("正面" if bool(result) else "反面")
		return "结果：" + "、".join(labels)
	if request.max_select == 0:
		return "本次无需选择，点击继续结算。"
	if request.request_type == "distribute_energy":
		var distribution_lines: Array[String] = []
		if request.min_select == request.max_select:
			distribution_lines.append("需要分配 %d 张能量。" % request.max_select)
		elif request.min_select == 0:
			distribution_lines.append(
				"最多可分配 %d 张能量，也可以不分配。" % request.max_select
			)
		else:
			distribution_lines.append("请分配 %d 至 %d 张能量。" % [
				request.min_select,
				request.max_select,
			])
		var distribution_data := _choice_continuation_data()
		if bool(request.metadata.get(
			"same_target",
			distribution_data.get("same_target", false),
		)):
			distribution_lines.append("所有能量必须分配到同一目标。")
		var max_per_target := int(request.metadata.get(
			"max_per_target",
			distribution_data.get("max_per_target", 99),
		))
		if max_per_target < 99:
			distribution_lines.append(
				"每个目标最多可分配 %d 张能量。" % max_per_target
			)
		return " ".join(distribution_lines)
	var unit := _choice_count_unit(request)
	if request.min_select == request.max_select:
		return "请选择 %d %s。" % [request.max_select, unit]
	if request.min_select == 0:
		return "最多选择 %d %s，也可以不选择。" % [request.max_select, unit]
	return "请选择 %d 至 %d %s。" % [
		request.min_select,
		request.max_select,
		unit,
	]


func _choice_request_has_card_options(request: ChoiceRequest) -> bool:
	if request == null:
		return false
	for option_value in request.options:
		if not _choice_option_card_id(Dictionary(option_value)).is_empty():
			return true
	return false


func _choice_count_unit(request: ChoiceRequest) -> String:
	if request.request_type == "select_attachment":
		return "个附着物"
	if request.request_type in [
		"distribute_energy",
		"select_energy_target",
		"select_energy_source",
		"evolve_skip_stage",
		"select_heal_target",
		"damage_target",
		"bench_damage_target",
		"place_counters_self_ko",
		"select_bench",
		"select_opponent_bench",
	]:
		return "个目标"
	return "张卡牌" if _choice_request_has_card_options(request) else "项"


func _refresh_log() -> void:
	if log_label == null:
		return
	var rows: Array[String] = []
	for index in range(state.action_log.size()):
		rows.append("• " + state.action_log[index])
	log_label.text = "\n".join(rows)
	log_label.scroll_to_line(max(0, rows.size() - 1))


func _current_actor() -> int:
	if state == null:
		return 0
	if not state.pending_promotions.is_empty():
		return int(state.pending_promotions[0])
	if state.phase == "SETUP":
		if game_mode != MODE_LOCAL:
			return 0 if not state.setup_ready[0] else 1
		return current_view_player
	return state.active_player_idx


func _schedule_ai_action() -> void:
	if (
		state == null
		or current_screen != SCREEN_GAME
		or game_mode == MODE_LOCAL
		or ai_thinking
		or _current_actor() != 1
	):
		return
	var actions := engine.legal_actions(state, 1, true)
	if actions.is_empty():
		_show_toast("AI 没有合法动作。", true)
		return
	var rows: Array = []
	for action in actions:
		rows.append(action.to_dict())
	ai_request_sequence += 1
	active_ai_request_id = "ai:%d:%d" % [state.revision, ai_request_sequence]
	var gameplay_budget := NativeChallengeAI.gameplay_action_budget(state, actions)
	var simulation_budget := int(gameplay_budget["simulation_budget"])
	var seconds := float(gameplay_budget["seconds"])
	var max_depth := int(gameplay_budget["max_depth"])
	var dynamic_budget: Variant = gameplay_budget.get("dynamic_budget", {})
	if game_mode == MODE_DEEP:
		simulation_budget = NativeChallengeAI.DEEP_DEFAULT_SIMULATIONS
		seconds = NativeChallengeAI.DEEP_DEFAULT_SECONDS
		max_depth = NativeChallengeAI.DEEP_DEFAULT_DEPTH
		dynamic_budget = {}
	var request := {
		"kind": "action",
		"state": state.snapshot(),
		"actor": 1,
		"revision": state.revision,
		"request_id": active_ai_request_id,
		"mode": game_mode,
		"deck_key": ai_deck_key,
		"seed": int(rng.next_u32()),
		"simulation_budget": simulation_budget,
		"seconds": seconds,
		"max_depth": max_depth,
		"dynamic_budget": dynamic_budget,
		"actions": rows,
	}
	ai_thinking = ai_coordinator.start_request(request, ai_inference)
	_refresh_process_state()
	if not ai_thinking:
		_apply_ai_fallback_action("无法启动 AI 后台线程。")
		return
	_refresh_game()


func _schedule_ai_choice(request: ChoiceRequest) -> void:
	if state == null or game_mode == MODE_LOCAL or ai_thinking:
		return
	ai_request_sequence += 1
	active_ai_request_id = "ai-choice:%d:%d" % [state.revision, ai_request_sequence]
	var payload := {
		"kind": "choice",
		"state": state.snapshot(),
		"choice": request.to_dict(),
		"actor": 1,
		"revision": state.revision,
		"request_id": active_ai_request_id,
		"mode": game_mode,
		"deck_key": ai_deck_key,
		"seed": int(rng.next_u32()),
	}
	ai_thinking = ai_coordinator.start_request(payload, ai_inference)
	_refresh_process_state()
	if not ai_thinking:
		_apply_ai_fallback_choice(request, "无法启动 AI 选择线程。")
		return
	_refresh_game()


func _apply_ai_result(result: Dictionary) -> void:
	ai_thinking = false
	_refresh_process_state()
	if state == null or current_screen != SCREEN_GAME:
		return
	if bool(result.get("cancelled", false)):
		return
	if (
		str(result.get("request_id", "")) != active_ai_request_id
		or int(result.get("revision", -1)) != state.revision
	):
		_maybe_start_ai()
		return
	if not bool(result.get("success", false)):
		var pending_on_failure := ResolutionStack.from_dict(
			state.resolution_stack).pending_request
		if pending_on_failure != null and pending_on_failure.player == 1:
			_apply_ai_fallback_choice(
				pending_on_failure,
				"AI 决策失败：%s" % result.get("error", "unknown"),
			)
		else:
			_apply_ai_fallback_action(
				"AI 决策失败：%s" % result.get("error", "unknown"))
		return
	if bool(result.get("deep_fallback", false)):
		_show_toast(
			"Deep AI 已回退 Challenge AI：%s" % result.get("fallback_reason", ""),
			true,
		)
	var previous_active := state.active_player_idx
	var previous_phase := state.phase
	var presentation_snapshot := (
		battle_screen.capture_presentation_snapshot()
		if battle_screen
		else {}
	)
	var step: StepResult
	if str(result.get("kind", "")) == "choice":
		var stack_request := ResolutionStack.from_dict(state.resolution_stack).pending_request
		if stack_request == null:
			_maybe_start_ai()
			return
		var response := ChoiceResponse.from_dict(result["choice_response"])
		if response.request_id != stack_request.request_id:
			_maybe_start_ai()
			return
		step = engine.apply_choice(state, stack_request, response, rng)
	else:
		var action := GameAction.from_dict(result["action"])
		ai_request_sequence += 1
		action.action_id = "ai-action:%d:%d" % [state.revision, ai_request_sequence]
		step = engine.apply_action(state, action, rng)
	if not step.success:
		var pending_after_reject := ResolutionStack.from_dict(
			state.resolution_stack).pending_request
		if pending_after_reject != null and pending_after_reject.player == 1:
			_apply_ai_fallback_choice(
				pending_after_reject,
				"AI 选择被规则拒绝：%s" % step.message,
			)
		else:
			_apply_ai_fallback_action("AI 动作被规则拒绝：%s" % step.message)
		return
	_refresh_game()
	if battle_screen and not step.events.is_empty():
		battle_screen.play_presentation(
			step.events,
			state.revision,
			1,
			presentation_snapshot,
		)
	_show_toast(step.message if not step.message.is_empty() else "AI 完成动作。")
	_continue_after_ai_step(step, previous_active, previous_phase)


func _apply_ai_fallback_action(reason: String) -> void:
	if state == null or current_screen != SCREEN_GAME or _current_actor() != 1:
		return
	var actions := engine.legal_actions(state, 1, true)
	if actions.is_empty():
		_show_toast("%s AI 没有合法动作。" % reason, true)
		_refresh_game()
		return
	for action in _ordered_ai_fallback_actions(actions):
		var previous_active := state.active_player_idx
		var previous_phase := state.phase
		var presentation_snapshot := (
			battle_screen.capture_presentation_snapshot()
			if battle_screen
			else {}
		)
		ai_request_sequence += 1
		action.action_id = "ai-fallback:%d:%d" % [state.revision, ai_request_sequence]
		var step := engine.apply_action(state, action, rng)
		if not step.success:
			continue
		_refresh_game()
		if battle_screen and not step.events.is_empty():
			battle_screen.play_presentation(
				step.events,
				state.revision,
				1,
				presentation_snapshot,
			)
		var message := step.message if not step.message.is_empty() else "AI 完成兜底动作。"
		_show_toast("%s %s" % [reason, message], true)
		_continue_after_ai_step(step, previous_active, previous_phase)
		return
	_show_toast("%s AI 兜底动作全部被规则拒绝。" % reason, true)
	_refresh_game()


func _ordered_ai_fallback_actions(actions: Array[GameAction]) -> Array[GameAction]:
	var ordered: Array[GameAction] = []
	for action_name in [
		"PROMOTE",
		"SETUP_DONE",
		"DECLARE_ATTACK",
		"END_TURN",
		"PLAY_BASIC",
		"ATTACH_ENERGY",
		"EVOLVE",
		"PLAY_TRAINER",
		"USE_ABILITY",
		"USE_STADIUM",
		"RETREAT",
	]:
		for action in actions:
			if action.action == action_name and action not in ordered:
				ordered.append(action)
	for action in actions:
		if action not in ordered:
			ordered.append(action)
	return ordered


func _apply_ai_fallback_choice(request: ChoiceRequest, reason: String) -> void:
	if state == null or current_screen != SCREEN_GAME:
		return
	var response := _fallback_choice_response(request)
	var previous_active := state.active_player_idx
	var previous_phase := state.phase
	var presentation_snapshot := (
		battle_screen.capture_presentation_snapshot()
		if battle_screen
		else {}
	)
	var step := engine.apply_choice(state, request, response, rng)
	if not step.success:
		_show_toast("%s AI 兜底选择被规则拒绝：%s" % [reason, step.message], true)
		_refresh_game()
		return
	_refresh_game()
	if battle_screen and not step.events.is_empty():
		battle_screen.play_presentation(
			step.events,
			state.revision,
			request.player,
			presentation_snapshot,
		)
	var message := step.message if not step.message.is_empty() else "AI 完成兜底选择。"
	_show_toast("%s %s" % [reason, message], true)
	_continue_after_ai_step(step, previous_active, previous_phase)


func _fallback_choice_response(request: ChoiceRequest) -> ChoiceResponse:
	if request.options.is_empty():
		return ChoiceResponse.new(request.request_id, [], request.can_cancel)
	var count: int = maxi(request.min_select, request.max_select)
	if not request.allow_duplicates:
		count = mini(request.options.size(), count)
	var selected: Array[String] = []
	if request.allow_duplicates and count > 0:
		for _index in range(count):
			selected.append(str(request.options[0]["option_id"]))
	else:
		for index in range(count):
			selected.append(str(request.options[index]["option_id"]))
	return ChoiceResponse.new(request.request_id, selected)


func _continue_after_ai_step(
	step: StepResult,
	_previous_active: int,
	_previous_phase: String,
) -> void:
	current_view_player = 0
	if state.winner >= 0:
		_refresh_game()
		return
	var pending := _step_pending_choice(step)
	if pending:
		if pending.player == 1:
			_schedule_ai_choice(pending)
		else:
			_refresh_game()
			_show_choice_overlay(pending)
		return
	_refresh_game()
	if _current_actor() == 1:
		_schedule_ai_action()


func _maybe_start_ai() -> void:
	if (
		state != null
		and current_screen == SCREEN_GAME
		and game_mode != MODE_LOCAL
		and _current_actor() == 1
	):
		_schedule_ai_action()


func _stop_ai() -> void:
	ai_coordinator.cancel_and_wait()
	deep_runtime.unload()
	ai_inference = null
	ai_thinking = false
	active_ai_request_id = ""
	_refresh_process_state()


func _show_toast(message: String, is_error: bool = false) -> void:
	if message.strip_edges().is_empty():
		return
	_toast_generation += 1
	toast_label.theme = FRONTEND_THEME if current_screen != SCREEN_GAME else null
	toast_label.theme_type_variation = (
		&"FrontToastLabel" if current_screen != SCREEN_GAME else &""
	)
	toast_label.set("accessibility_live", 2 if is_error else 1)
	var toast_generation := _toast_generation
	if _toast_tween and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast_tween = null
	toast_label.text = message
	toast_label.modulate = Color.WHITE
	if is_error:
		toast_label.add_theme_color_override("font_color", Color("#ff9aa4"))
	else:
		toast_label.remove_theme_color_override("font_color")
	_layout_toast()
	# The battle rail finishes its container layout at the end of the frame.
	# Re-evaluate once so a toast shown while entering battle uses the final rail rect.
	call_deferred("_layout_toast")
	toast_label.visible = true
	if not FrontendMotion.decorative_motion_enabled():
		toast_label.modulate.a = 1.0
		get_tree().create_timer(2.0).timeout.connect(
			func() -> void:
				if (
					toast_generation == _toast_generation
					and toast_label
					and toast_label.text == message
				):
					toast_label.visible = false
		)
		return
	toast_label.modulate.a = 0.0
	_toast_tween = create_tween()
	_toast_tween.tween_property(toast_label, "modulate:a", 1.0, 0.12)
	_toast_tween.tween_interval(2.0)
	_toast_tween.tween_property(toast_label, "modulate:a", 0.0, 0.2)
	_toast_tween.tween_callback(func() -> void:
		if toast_generation == _toast_generation and toast_label:
			toast_label.visible = false
		_toast_tween = null
	)


func _show_title_from_game() -> void:
	state = null
	_show_title()

func _clear_screen() -> void:
	current_network_page = null
	if title_full_bleed_backdrop:
		title_full_bleed_backdrop.visible = false
	if screen_router:
		screen_router.clear_screen()
		return
	for child in screen_host.get_children():
		screen_host.remove_child(child)
		child.queue_free()


func _mount_screen(scene: PackedScene) -> Node:
	current_network_page = null
	if title_full_bleed_backdrop:
		title_full_bleed_backdrop.visible = false
	if screen_router:
		return screen_router.mount(scene)
	_clear_screen()
	var page := scene.instantiate()
	screen_host.add_child(page)
	return page

func _play_click() -> void:
	if audio_director:
		audio_director.play_ui("click")
		return
	if sound_player == null or not sound_player.is_inside_tree():
		return
	sound_player.stream = click_stream
	sound_player.play()


func _play_success() -> void:
	if audio_director:
		audio_director.play_ui("success")
		return
	if sound_player == null or not sound_player.is_inside_tree():
		return
	sound_player.stream = success_stream
	sound_player.play()


func _apply_runtime_settings() -> void:
	if sound_player:
		sound_player.volume_db = AppSettings.volume_db()
	if audio_director:
		audio_director.apply_settings()
	Engine.max_fps = AppSettings.target_fps()


func _safe_insets_to_canvas(
	window_position: Vector2i,
	window_size: Vector2i,
	safe_rect: Rect2i,
	logical_size: Vector2,
) -> Vector4:
	if (
		window_size.x <= 0
		or window_size.y <= 0
		or safe_rect.size.x <= 0
		or safe_rect.size.y <= 0
		or logical_size.x <= 0.0
		or logical_size.y <= 0.0
	):
		return Vector4.ZERO
	var window_rect := Rect2i(window_position, window_size)
	var visible_safe_rect := window_rect.intersection(safe_rect)
	if visible_safe_rect.size.x <= 0 or visible_safe_rect.size.y <= 0:
		return Vector4.ZERO
	var canvas_per_pixel := Vector2(
		logical_size.x / float(window_size.x),
		logical_size.y / float(window_size.y),
	)
	return Vector4(
		maxf(0.0, float(visible_safe_rect.position.x - window_position.x))
			* canvas_per_pixel.x,
		maxf(0.0, float(visible_safe_rect.position.y - window_position.y))
			* canvas_per_pixel.y,
		maxf(0.0, float(window_rect.end.x - visible_safe_rect.end.x))
			* canvas_per_pixel.x,
		maxf(0.0, float(window_rect.end.y - visible_safe_rect.end.y))
			* canvas_per_pixel.y,
	)


func _safe_content_size() -> Vector2:
	var full_size := size
	if safe_margin and safe_margin.size.x > 0.0 and safe_margin.size.y > 0.0:
		full_size = safe_margin.size
	if full_size.x <= 0.0 or full_size.y <= 0.0:
		full_size = get_viewport_rect().size if is_inside_tree() else Vector2(1280, 720)
	if safe_margin == null:
		return full_size
	return Vector2(
		maxf(1.0, full_size.x
			- safe_margin.get_theme_constant("margin_left")
			- safe_margin.get_theme_constant("margin_right")),
		maxf(1.0, full_size.y
			- safe_margin.get_theme_constant("margin_top")
			- safe_margin.get_theme_constant("margin_bottom")),
	)


func _apply_safe_area() -> void:
	if safe_margin == null:
		return
	var left := 18
	var top := 14
	var right := 18
	var bottom := 14
	var window := get_window()
	if window == null:
		safe_margin.add_theme_constant_override("margin_left", left)
		safe_margin.add_theme_constant_override("margin_top", top)
		safe_margin.add_theme_constant_override("margin_right", right)
		safe_margin.add_theme_constant_override("margin_bottom", bottom)
		return
	var window_size := window.size
	var logical_size := size
	if logical_size.x <= 0.0 or logical_size.y <= 0.0:
		logical_size = get_viewport_rect().size
	var safe_rect := DisplayServer.get_display_safe_area()
	var safe_insets := _safe_insets_to_canvas(
		window.position,
		window_size,
		safe_rect,
		logical_size,
	)
	left = maxi(left, ceili(safe_insets.x))
	top = maxi(top, ceili(safe_insets.y))
	right = maxi(right, ceili(safe_insets.z))
	bottom = maxi(bottom, ceili(safe_insets.w))
	safe_margin.add_theme_constant_override("margin_left", left)
	safe_margin.add_theme_constant_override("margin_top", top)
	safe_margin.add_theme_constant_override("margin_right", right)
	safe_margin.add_theme_constant_override("margin_bottom", bottom)
	for path in ["ModalLayer/Center", "LoadingLayer/Center"]:
		var safe_center := get_node_or_null(path) as Control
		if safe_center:
			safe_center.offset_left = left
			safe_center.offset_top = top
			safe_center.offset_right = -right
			safe_center.offset_bottom = -bottom
	_layout_toast(logical_size, left, top, right, bottom)
	if (
		modal_host_controller
		and modal_layer
		and modal_layer.visible
		and modal_host_controller.active_spec
	):
		modal_host_controller.update_available_size(_safe_content_size())


func _layout_toast(
	logical_size: Vector2 = Vector2.ZERO,
	left: int = -1,
	top: int = -1,
	right: int = -1,
	bottom: int = -1,
) -> void:
	if toast_label == null:
		return
	if logical_size.x <= 0.0 or logical_size.y <= 0.0:
		logical_size = size
		if logical_size.x <= 0.0 or logical_size.y <= 0.0:
			logical_size = get_viewport_rect().size if is_inside_tree() else Vector2(1280, 720)
	if safe_margin:
		if left < 0:
			left = safe_margin.get_theme_constant("margin_left")
		if top < 0:
			top = safe_margin.get_theme_constant("margin_top")
		if right < 0:
			right = safe_margin.get_theme_constant("margin_right")
		if bottom < 0:
			bottom = safe_margin.get_theme_constant("margin_bottom")
	left = maxi(left, 0)
	top = maxi(top, 0)
	right = maxi(right, 0)
	bottom = maxi(bottom, 0)

	toast_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	if current_screen == SCREEN_GAME and battle_screen and is_instance_valid(battle_screen):
		var rail := battle_screen.log_panel as Control
		if rail and rail.size.x >= 180.0 and rail.size.y >= 80.0:
			var rail_position := rail.global_position - global_position
			var battle_width := clampf(rail.size.x - 16.0, 200.0, 264.0)
			var battle_height := _toast_content_height(battle_width, 48.0, 76.0)
			toast_label.position = rail_position + Vector2(8.0, 8.0)
			toast_label.size = Vector2(battle_width, minf(battle_height, rail.size.y - 16.0))
			return

	# Front-end pages have no command rail, so retain a centered safe-area status chip.
	var available_width := maxf(1.0, logical_size.x - left - right - 32.0)
	var toast_width := minf(560.0, available_width)
	var toast_height := _toast_content_height(toast_width, 48.0, 72.0)
	toast_label.position = Vector2(
		clampf((logical_size.x - toast_width) * 0.5, float(left + 16), logical_size.x - right - toast_width - 16.0),
		float(top + 12),
	)
	toast_label.size = Vector2(toast_width, toast_height)


func _toast_content_height(width: float, minimum: float, maximum: float) -> float:
	if toast_label == null or toast_label.text.is_empty():
		return minimum
	var usable_width := maxf(80.0, width - 28.0)
	# Chinese glyphs are close to one font-height wide. This estimate keeps short
	# confirmations on one line and reserves up to three lines for network errors.
	var characters_per_line := maxi(6, floori(usable_width / 15.0))
	var line_count := 0
	for paragraph in toast_label.text.split("\n", true):
		line_count += maxi(1, ceili(float(paragraph.length()) / float(characters_per_line)))
	return clampf(16.0 + float(line_count) * 20.0, minimum, maximum)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		if battle_screen:
			battle_screen.clear_presentation_for_resync()
		CardTextureCache.clear()
		if game_mode in [MODE_CHALLENGE, MODE_DEEP]:
			ai_coordinator.cancel_and_wait()
			ai_thinking = false
			_refresh_process_state()
		elif game_mode == MODE_NETWORK and current_screen in [
			SCREEN_NETWORK,
			SCREEN_GAME,
			SCREEN_END,
		]:
			lifecycle_network_interrupted = true
			_stop_network()
			state = null
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		if lifecycle_network_interrupted:
			lifecycle_network_interrupted = false
			_show_title()
			_show_toast("应用进入后台时已安全断开联机对局。", true)
		elif game_mode in [MODE_CHALLENGE, MODE_DEEP]:
			_maybe_start_ai()
	elif what == NOTIFICATION_OS_MEMORY_WARNING:
		CardTextureCache.clear()
		_show_toast("系统内存紧张，已释放卡图缓存。")
	elif what == NOTIFICATION_WM_SIZE_CHANGED:
		_apply_safe_area()
	elif what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if modal_layer and modal_layer.visible:
			if active_request:
				if active_request.can_cancel:
					_cancel_choice()
				return
			elif (
				modal_host_controller
				and modal_host_controller.active_spec
				and not modal_host_controller.active_spec.cancellable
			):
				return
			elif _modal_back_action.is_valid():
				var return_action := _modal_back_action
				_modal_back_action = Callable()
				return_action.call()
			elif current_screen == SCREEN_GAME:
				_close_modal()
				if game_mode in [MODE_CHALLENGE, MODE_DEEP]:
					_maybe_start_ai()
			else:
				_close_modal()
			return
		match current_screen:
			SCREEN_TITLE:
				get_tree().quit()
			SCREEN_DECKS:
				var deck_page := (
					screen_host.get_child(0) as DeckSelectPage
					if screen_host and screen_host.get_child_count() > 0
					else null
				)
				if deck_page == null or not deck_page.handle_back():
					_show_title()
			SCREEN_NETWORK:
				if (
					current_network_page == null
					or not is_instance_valid(current_network_page)
					or not current_network_page.handle_back()
				):
					_show_title()
			SCREEN_GAME:
				_show_pause_overlay()
			SCREEN_END:
				_show_title()


func _disconnect_button(button: Button) -> void:
	for connection in button.pressed.get_connections():
		button.pressed.disconnect(connection["callable"])


func _refresh_process_state() -> void:
	set_process(ai_thinking or network_controller.needs_poll())


func _free_children_immediate(parent: Node) -> void:
	for child in parent.get_children():
		parent.remove_child(child)
		child.free()


func _button(text_value: String, height: float) -> Button:
	var result := Button.new()
	result.text = text_value
	result.custom_minimum_size.y = height
	result.focus_mode = Control.FOCUS_NONE
	return result


func _slot_name(slot: String) -> String:
	if slot == "active":
		return "战斗区"
	if slot.begins_with("bench_"):
		return "备战区 %d" % (slot.trim_prefix("bench_").to_int() + 1)
	return slot


func _zone_name(zone: String) -> String:
	return {
		"hand": "手牌",
		"deck": "牌库",
		"discard": "弃牌区",
		"prizes": "奖品区",
		"lost_zone": "放逐区",
	}.get(zone, zone)


func _phase_name(phase: String) -> String:
	return {
		"SETUP": "准备",
		"DRAW": "抽牌",
		"MAIN": "主要阶段",
		"ATTACK": "攻击结算",
		"POKEMON_CHECKUP": "宝可梦检查",
		"GAME_OVER": "对局结束",
	}.get(phase, phase)


func _card_type_text(card: Dictionary) -> String:
	var subtypes: Array = card.get("subtypes", [])
	return "%s · %s" % [
		card.get("supertype", ""),
		" / ".join(subtypes),
	]

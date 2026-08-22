extends Control

const RuntimeStateProjection = preload("res://ai/runtime_state_projection.gd")

const BATTLE_SCENE := preload("res://scenes/battle/components/battle_table.tscn")
const CARD_SCENE := preload("res://ui/card_view.tscn")
const VICTORY_SCENE := preload("res://scenes/end/victory_screen.tscn")
const TITLE_SCENE := preload("res://scenes/title/title_page.tscn")
const DECK_SELECT_SCENE := preload("res://scenes/decks/deck_select_page.tscn")
const NETWORK_LOBBY_SCENE := preload("res://scenes/network/network_lobby_page.tscn")
const SETTINGS_PANEL_SCENE := preload("res://ui/dialogs/settings_panel.tscn")
const CHOICE_PANEL_SCENE := preload("res://ui/dialogs/choice_panel.tscn")
const COIN_SHOWCASE := preload("res://scenes/battle/components/coin_showcase.gd")
const PRIVACY_PANEL_SCENE := preload("res://ui/dialogs/privacy_panel.tscn")
const COIN_PRESENTATION_TOMBSTONE_TTL_MSEC := 120000
const COIN_PRESENTATION_TOMBSTONE_LIMIT := 64
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
const TOAST_Z_INDEX := 350
const DESIGN_CANVAS_SIZE := Vector2i(1600, 900)
const MIN_RESPONSIVE_WINDOW_SIZE := Vector2i(640, 360)

var catalog: CardCatalog = CardDatabase.catalog
var native_rules := NativeRulesSessionAdapter.new(catalog)
var state: GameState
var rng := PortableRandomSource.new(1)
var last_match_seed := 0

var current_screen := SCREEN_TITLE
var current_view_player := 0
var action_sequence := 0
var selected_entity_key := ""
var selected_entity_identity := ""
var selected_choice_ids: Array[String] = []
var option_buttons: Array[Button] = []
var game_mode := MODE_LOCAL
var ai_deck_key := ""
var ai_thinking := false
var ai_request_sequence := 0
var ai_emergency_fallback_count := 0
var active_ai_request_id := ""
var ai_match_generation := 0
var ai_match_instance_id := ""
var ai_coordinator := AICoordinator.new()
var ai_inference: Variant
var deep_runtime := DeepAIRuntime.new()
var network_controller := NetworkMatchController.new(catalog)
var network_legal_actions: Array[GameAction] = []
var network_choice_view: ChoiceView
var network_wait_context: Dictionary = {}
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
var _network_recovery_phase := ""
var screen_router: ScreenRouter
var modal_host_controller: ModalHost
var current_network_page: NetworkLobbyPage

var action_list: VBoxContainer
var log_label: RichTextLabel
var battle_screen: BattleTable

var modal_layer: Control
var modal_shade: ColorRect
var modal_panel: PanelContainer
var modal_title: Label
var modal_body: VBoxContainer
var modal_scroll: ScrollContainer
var modal_confirm: Button
var modal_cancel: Button
var active_request: ChoiceView
var active_choice_panel: ChoicePanel
var ui_initialized := false
var _modal_generation := 0
var _modal_back_action := Callable()
var _modal_close_completion := Callable()
var _modal_close_completion_generation := -1
var _modal_closing := false
var _toast_tween: Tween
var _toast_generation := 0
var _deep_start_generation := 0
var _presented_coin_request_ids: Dictionary = {}
var _pending_ai_resume_revision := -1
var _pending_ai_runtime_unload := false
var _startup_choreography_generation := 0
var _startup_choreography_running := false
var _responsive_canvas_window: Window
var _original_content_scale_size := Vector2i.ZERO
var _last_responsive_content_scale_size := Vector2i.ZERO


func _ready() -> void:
	set_process(false)
	_configure_responsive_canvas()
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
	elif ExportSmokeRunner.CANDIDATE_RUNTIME_FLAG in user_args:
		_run_export_smoke(ExportSmokeRunner.CANDIDATE_RUNTIME_FLAG)
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
	var evidence_value: Variant = result.get("evidence_payload", null)
	if evidence_value is Dictionary:
		var encoded := Marshalls.utf8_to_base64(
			JSON.stringify(evidence_value))
		var chunk_size := 1800
		var chunk_count := maxi(1, ceili(
			float(encoded.length()) / float(chunk_size)))
		for index in range(chunk_count):
			print(
				"CANDIDATE_RUNTIME_EVIDENCE_CHUNK %d/%d %s"
				% [
					index + 1,
					chunk_count,
					encoded.substr(index * chunk_size, chunk_size),
				]
			)
	var message := str(result.get("message", "EXPORT_SMOKE_FAILED"))
	if bool(result.get("success", false)):
		print(message)
	else:
		push_error(message)
	get_tree().quit(int(result.get("exit_code", 1)))


func _process(_delta: float) -> void:
	if network_controller.needs_poll():
		_poll_network()
	if ai_coordinator.needs_poll():
		var result := ai_coordinator.poll_result()
		if ai_thinking and not result.is_empty():
			_apply_ai_result(result)
	_finalize_ai_runtime_unload_if_idle()
	_refresh_process_state()


func _exit_tree() -> void:
	if _toast_tween and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast_tween = null
	_stop_ai()
	_stop_network()
	_restore_responsive_canvas()


func initialize_ui() -> void:
	if ui_initialized:
		return
	_configure_responsive_canvas()
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
	toast_label.z_index = TOAST_Z_INDEX
	toast_label.z_as_relative = false
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
			modal_scroll,
		)
	modal_layer.z_index = 400
	loading_layer.z_index = 500


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


func show_choice(request: ChoiceView) -> void:
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
	apply_type_matchups: bool,
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
			error = network_controller.host_lan(
				port, deck_key, -1, apply_type_matchups)
		else:
			error = network_controller.join_lan(normalized_address, port, deck_key)
	else:
		AppSettings.set_relay_url(normalized_address)
		if role == "host":
			error = network_controller.host_relay(
				normalized_address, deck_key, -1, apply_type_matchups)
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
				if (
					current_network_page != null
					and is_instance_valid(current_network_page)
					and event.get("rules_options") is Dictionary
				):
					current_network_page.show_locked_rules_options(
						event["rules_options"])
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
						str(event.get("origin_action_id", "")),
						str(event.get("origin_request_id", "")),
						bool(event.get("is_resync", false)),
					)
				else:
					_show_toast("收到的联机局面无效，正在请求重新同步。", true)
					network_controller.request_resync()
			"error", "connection_failed", "transport_error":
				var event_type := str(event.get("type", ""))
				_presented_coin_request_ids.erase(str(event.get(
					"origin_request_id",
					"",
				)))
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
					# Only the rejection correlated to our in-flight submission owns its
					# parked visual. An unrelated or delayed ERROR must not tear down the
					# current drag/presentation batch or start a recovery snapshot that
					# could accidentally release that submission. Protocol-level stale /
					# sequence errors already request resync inside the controller.
					if bool(event.get("matched_pending", false)):
						if battle_screen:
							battle_screen.clear_pending_drag("network_error")
						network_controller.request_resync()
				# These transport events are terminal. Clear the controller now so the
				# lobby can immediately start a clean retry; protocol-level "error"
				# events may still be recoverable and keep their existing session.
				if event_type in ["connection_failed", "transport_error"]:
					_stop_network()
			"reconnecting":
				_network_recovery_phase = "reconnecting"
				if current_screen == SCREEN_GAME and battle_screen != null:
					battle_screen.cancel_presentations("network_reconnecting")
					battle_screen.set_recovery_blocked(true)
					_refresh_game()
				_show_toast("连接中断，正在尝试恢复对局…", true)
			"reconnected":
				_network_recovery_phase = "resync"
				if current_screen == SCREEN_GAME and battle_screen != null:
					battle_screen.set_recovery_blocked(true)
					_refresh_game()
				_show_toast("连接已恢复，正在同步局面…")
			"disconnected":
				_handle_network_disconnected(str(event.get("reason", "")))
			"pending_timeout":
				# Preserve the request tombstone until the matching recovery state or
				# error arrives; otherwise its public coin event is played twice.
				_prune_coin_presentation_tombstones()
				_show_toast("动作确认超时，正在重新同步局面。", true)
				if battle_screen:
					battle_screen.clear_pending_drag("network_timeout")


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


func _apply_network_view(
	view: Dictionary,
	player: int,
	origin_action_id: String = "",
	origin_request_id: String = "",
	is_resync: bool = false,
) -> void:
	if view.is_empty() or not _network_view_is_valid(view):
		_show_toast("收到的联机局面无效，正在请求重新同步。", true)
		network_controller.request_resync()
		return
	var had_game_screen := current_screen == SCREEN_GAME and battle_screen != null
	game_mode = MODE_NETWORK
	network_player_idx = player
	current_view_player = player
	var state_payload: Dictionary = view["state"]
	state = StateSerializer.from_player_view(state_payload, player)
	var incoming_presentation_events: Array = view.get("presentation_events", [])
	network_legal_actions.clear()
	var legal_rows: Array = view.get("legal_action_groups", [])
	for row in legal_rows:
		if row is Dictionary:
			var group := LegalActionGroup.from_dict(row)
			network_legal_actions.append_array(group.concrete_actions())
	network_choice_view = (
		ChoiceView.from_dict(view["choice_request"])
		if view.get("choice_request") is Dictionary
		else null
	)
	network_wait_context = (
		Dictionary(view["wait_context"]).duplicate(true)
		if view.get("wait_context") is Dictionary
		else {}
	)
	if current_screen != SCREEN_GAME and current_screen != SCREEN_END:
		_build_game_screen()
		if _network_view_is_fresh_match_start():
			_begin_startup_choreography(
				Callable(self, "_continue_after_network_transition"),
				incoming_presentation_events,
			)
		else:
			_continue_after_network_transition()
	elif had_game_screen and battle_screen:
		var presentation_events: Array = incoming_presentation_events
		_prune_coin_presentation_tombstones()
		if _presented_coin_request_ids.has(origin_request_id):
			presentation_events = _without_coin_flip_events(presentation_events)
			_presented_coin_request_ids.erase(origin_request_id)
		if is_resync:
			_network_recovery_phase = ""
			battle_screen.set_recovery_blocked(false)
			battle_screen.snap_to_authoritative_view(
				_capture_battle_view_model(),
				"resync",
			)
			_continue_after_network_transition()
			return
		var drag_session_id := battle_screen.drag_session_id_for_origin(
			origin_action_id)
		var handle := _submit_battle_transition(
			presentation_events,
			state.active_player_idx,
			BattleTransitionRequest.CAUSE_NETWORK,
			origin_action_id,
			origin_request_id,
			drag_session_id,
		)
		_continue_when_presented(
			handle,
			state.revision,
			Callable(self, "_continue_after_network_transition"),
		)


func _continue_after_network_transition() -> void:
	if state == null or current_screen != SCREEN_GAME:
		return
	_refresh_game()
	if state.is_terminal():
		return
	if (
		network_choice_view != null
		and (
			active_request == null
			or active_request.request_id != network_choice_view.request_id
		)
	):
		_show_choice_overlay(network_choice_view)


func _network_view_is_fresh_match_start() -> bool:
	return (
		state != null
		and state.phase == "SETUP"
		and state.turn_number in [0, 1]
		and state.revision == 0
		and state.setup_ready.size() >= 2
		and not state.setup_ready[0]
		and not state.setup_ready[1]
	)


func _network_view_is_valid(view: Dictionary) -> bool:
	return bool(ProtocolV6.validate_payload(
		ProtocolV6.STATE_UPDATE,
		view,
	).get("ok", false))


func _remember_coin_presentation_tombstone(request_id: String) -> void:
	if request_id.is_empty():
		return
	_prune_coin_presentation_tombstones()
	_presented_coin_request_ids[request_id] = Time.get_ticks_msec()
	if _presented_coin_request_ids.size() <= COIN_PRESENTATION_TOMBSTONE_LIMIT:
		return
	var rows: Array[Dictionary] = []
	for key_value in _presented_coin_request_ids.keys():
		var key := str(key_value)
		rows.append({
			"request_id": key,
			"created_msec": int(_presented_coin_request_ids.get(key, 0)),
		})
	rows.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return int(left.get("created_msec", 0)) < int(right.get("created_msec", 0))
	)
	while rows.size() > COIN_PRESENTATION_TOMBSTONE_LIMIT:
		_presented_coin_request_ids.erase(str(rows.pop_front().get("request_id", "")))


func _prune_coin_presentation_tombstones() -> void:
	var now := Time.get_ticks_msec()
	for key_value in _presented_coin_request_ids.keys():
		var key := str(key_value)
		var created := int(_presented_coin_request_ids.get(key, now))
		if now - created > COIN_PRESENTATION_TOMBSTONE_TTL_MSEC:
			_presented_coin_request_ids.erase(key)


func _stop_network() -> void:
	network_controller.close()
	_network_recovery_phase = ""
	network_legal_actions.clear()
	network_choice_view = null
	network_wait_context.clear()
	network_player_idx = -1
	_presented_coin_request_ids.clear()
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
	apply_type_matchups: bool,
) -> void:
	game_mode = mode
	if mode == MODE_LOCAL:
		start_local_match_for_test(
			first_key, second_key, -1, forced_first, true, apply_type_matchups)
		return
	if mode == MODE_DEEP:
		_start_deep_match_with_loading(
			first_key,
			second_key,
			forced_first,
			apply_type_matchups,
		)
	else:
		start_ai_match_for_test(
			mode,
			first_key,
			second_key,
			forced_first,
			-1,
			true,
			apply_type_matchups,
		)


func _start_deep_match_with_loading(
	human_key: String,
	opponent_key: String,
	forced_first: int,
	apply_type_matchups: bool = false,
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
		-1,
		true,
		apply_type_matchups,
	)
	_hide_loading()


func start_local_match_for_test(
	first_key: String,
	second_key: String,
	match_seed: int = -1,
	forced_first: int = -1,
	play_startup: bool = false,
	apply_type_matchups: bool = false,
) -> bool:
	game_mode = MODE_LOCAL
	return _start_match(
		first_key,
		second_key,
		match_seed,
		forced_first,
		play_startup,
		apply_type_matchups,
	)


func start_ai_match_for_test(
	mode: String,
	human_key: String,
	opponent_key: String,
	forced_first: int = -1,
	match_seed: int = -1,
	play_startup: bool = false,
	apply_type_matchups: bool = false,
) -> bool:
	game_mode = mode if mode in [MODE_CHALLENGE, MODE_DEEP] else MODE_CHALLENGE
	ai_deck_key = opponent_key
	return _start_match(
		human_key,
		opponent_key,
		match_seed,
		forced_first,
		play_startup,
		apply_type_matchups,
	)


func match_journal() -> Dictionary:
	return native_rules.journal()


func _canonical_type_matchups_for_mode(mode: String, requested: bool) -> bool:
	if mode in [MODE_CHALLENGE, MODE_DEEP]:
		return false
	return requested


func _start_match(
	first_key: String,
	second_key: String,
	match_seed: int,
	forced_first: int,
	play_startup: bool = true,
	apply_type_matchups: bool = false,
) -> bool:
	_play_click()
	_stop_ai()
	var actual_seed := match_seed
	if actual_seed < 0:
		actual_seed = PortableRandomSource.fresh_seed()
	last_match_seed = actual_seed
	ai_match_generation += 1
	ai_match_instance_id = "runtime:%d:%d" % [ai_match_generation, actual_seed]
	ai_request_sequence = 0
	ai_emergency_fallback_count = 0
	native_rules = NativeRulesSessionAdapter.new(catalog)
	if not native_rules.is_available():
		_show_toast("原生规则会话不可用。", true)
		return false
	var type_matchups := _canonical_type_matchups_for_mode(
		game_mode, apply_type_matchups)
	var player_names: Array[String] = ["玩家 1", "玩家 2"]
	if game_mode != MODE_LOCAL:
		player_names[1] = "Deep AI" if game_mode == MODE_DEEP else "Challenge AI"
	var result := native_rules.start_match(
		first_key,
		second_key,
		actual_seed,
		forced_first,
		{"apply_type_matchups": type_matchups},
		player_names,
	)
	state = native_rules.state
	rng = PortableRandomSource.new(native_rules.rng_state)
	if not result.success:
		_show_toast(result.message, true)
		return false
	if game_mode != MODE_LOCAL:
		if game_mode == MODE_DEEP:
			if _pending_ai_runtime_unload:
				# A cancelled native worker may still own the previous backend. Do
				# not mutate it; this match safely uses the Challenge fallback.
				ai_inference = null
			elif deep_runtime.load_for_deck(second_key):
				ai_inference = deep_runtime.get_backend()
			else:
				ai_inference = null
		else:
			if not _pending_ai_runtime_unload:
				deep_runtime.unload()
			ai_inference = null
	current_view_player = 0
	selected_entity_key = ""
	selected_entity_identity = ""
	_build_game_screen()
	if game_mode == MODE_DEEP and ai_inference == null:
		_show_toast(
			"Deep AI 模型不可用，将自动回退 Challenge AI：%s" % deep_runtime.last_error,
			true,
		)
	if play_startup:
		_begin_startup_choreography(
			Callable(self, "_continue_after_fresh_match_start"),
			result.events,
		)
	else:
		_continue_after_fresh_match_start()
	return true


func _continue_after_fresh_match_start() -> void:
	if state == null or current_screen != SCREEN_GAME:
		return
	var pending := _step_pending_choice(null)
	if game_mode == MODE_LOCAL:
		var setup_player := pending.player if pending != null else state.setup_actor_idx
		current_view_player = setup_player
		_refresh_game()
		_show_pass_overlay(
			setup_player,
			"开局选择" if pending != null else "准备阶段",
			(
				"硬币胜者请选择先攻或后攻。"
				if pending != null
				else "玩家 %d 放置战斗宝可梦，可继续放置备战宝可梦。" % (
					setup_player + 1)
			),
			_show_choice_overlay.bind(pending) if pending != null else Callable(),
		)
	else:
		_refresh_game()
		if pending != null and pending.player == 0:
			_show_choice_overlay(pending)
		else:
			_maybe_start_ai()


func _begin_startup_choreography(
	completion: Callable,
	startup_events: Array = [],
) -> void:
	_startup_choreography_generation += 1
	var generation := _startup_choreography_generation
	if (
		battle_screen == null
		or state == null
		or not battle_screen.has_method("play_startup_shuffle")
	):
		_startup_choreography_running = false
		if battle_screen != null and is_instance_valid(battle_screen):
			battle_screen.set_startup_blocked(false)
		if completion.is_valid():
			completion.call_deferred()
		return
	_startup_choreography_running = true
	battle_screen.set_startup_blocked(true)
	# This is only the one physical shuffle performed before the turn-order
	# choice.  Mulligan counts do not exist yet; each later mulligan round is
	# presented by the serialized reveal/return/shuffle/redraw event chain.
	var handle: MotionHandle = battle_screen.call(
		"play_startup_shuffle",
		[],
	) as MotionHandle
	if handle == null or handle.is_finished():
		_finish_startup_choreography(generation, completion, startup_events)
		return
	handle.completed.connect(
		_on_startup_choreography_completed.bind(
			generation,
			completion,
			startup_events.duplicate(true),
		),
		CONNECT_ONE_SHOT,
	)


func _on_startup_choreography_completed(
	_handle: MotionHandle,
	generation: int,
	completion: Callable,
	startup_events: Array,
) -> void:
	_finish_startup_choreography(generation, completion, startup_events)


func _finish_startup_choreography(
	generation: int,
	completion: Callable,
	startup_events: Array = [],
) -> void:
	if generation != _startup_choreography_generation:
		return
	if not startup_events.is_empty():
		var setup_handle := _submit_battle_transition(
			startup_events,
			0,
			BattleTransitionRequest.CAUSE_INITIAL,
		)
		if setup_handle != null and not setup_handle.is_completed():
			setup_handle.completed.connect(
				_on_startup_result_presentation_completed.bind(
					generation,
					completion,
				),
				CONNECT_ONE_SHOT,
			)
			return
	_startup_choreography_running = false
	if battle_screen != null and is_instance_valid(battle_screen):
		battle_screen.set_startup_blocked(false)
	_complete_startup_when_presentations_idle(generation, completion)


func _on_startup_result_presentation_completed(
	_handle: PresentationHandle,
	generation: int,
	completion: Callable,
) -> void:
	_finish_startup_choreography(generation, completion)


func _complete_startup_when_presentations_idle(
	generation: int,
	completion: Callable,
) -> void:
	if generation != _startup_choreography_generation:
		return
	if (
		battle_screen != null
		and is_instance_valid(battle_screen)
		and battle_screen.is_presentation_busy()
	):
		var callback := _on_startup_presentation_busy_changed.bind(
			generation,
			completion,
		)
		if not battle_screen.presentation_busy_changed.is_connected(callback):
			battle_screen.presentation_busy_changed.connect(callback)
		return
	if completion.is_valid():
		completion.call()


func _on_startup_presentation_busy_changed(
	busy: bool,
	generation: int,
	completion: Callable,
) -> void:
	if busy:
		return
	var callback := _on_startup_presentation_busy_changed.bind(
		generation,
		completion,
	)
	if (
		battle_screen != null
		and is_instance_valid(battle_screen)
		and battle_screen.presentation_busy_changed.is_connected(callback)
	):
		battle_screen.presentation_busy_changed.disconnect(callback)
	_complete_startup_when_presentations_idle(generation, completion)


func _build_game_screen() -> void:
	current_screen = SCREEN_GAME
	_clear_screen()
	battle_screen = BATTLE_SCENE.instantiate() as BattleTable
	battle_screen.name = "GameScreen"
	battle_screen.menu_requested.connect(_show_pause_overlay)
	battle_screen.selection_clear_requested.connect(_on_selection_clear_requested)
	battle_screen.hand_card_selected.connect(_select_hand_card)
	battle_screen.pokemon_selected.connect(_on_battle_pokemon_selected)
	battle_screen.action_requested.connect(_execute_action)
	battle_screen.card_drop_requested.connect(_on_battle_card_dropped)
	battle_screen.inspect_card_requested.connect(_show_card_inspector)
	battle_screen.inspect_zone_requested.connect(_show_zone_inspector)
	battle_screen.choice_target_selected.connect(_on_battle_choice_target_selected)
	battle_screen.choice_option_toggled.connect(_toggle_choice)
	battle_screen.choice_selection_confirmed.connect(_confirm_choice)
	battle_screen.choice_cancel_requested.connect(_cancel_choice)
	screen_host.add_child(battle_screen)
	battle_screen.initialize_ui()
	# Hot-seat hands are private from the first rendered frame. Opening shuffle
	# and the pass-device gate can both outlive the synchronous table mount.
	battle_screen.set_local_hand_privacy_hidden(game_mode == MODE_LOCAL)
	action_list = battle_screen.action_list
	log_label = battle_screen.log_label
	if battle_screen.director and audio_director:
		battle_screen.director.audio_requested.connect(audio_director.play_cue)
	if audio_director:
		audio_director.play_music("battle")
	_refresh_game()


func _refresh_game() -> void:
	if state == null or current_screen != SCREEN_GAME:
		return
	_sanitize_battle_selection()
	if battle_screen:
		_render_battle_view_model(_capture_battle_view_model())
		_apply_network_wait_hint()
	if (
		state.is_terminal()
		and (battle_screen == null or not battle_screen.is_presentation_busy())
	):
		_show_end_screen()


func _apply_network_wait_hint() -> void:
	if battle_screen == null or battle_screen.header == null:
		return
	if not _network_recovery_phase.is_empty():
		battle_screen.header.set_task_hint(
			"连接中断，正在恢复对局…"
			if _network_recovery_phase == "reconnecting"
			else "连接已恢复，正在同步权威局面…"
		)
		return
	if (
		game_mode != MODE_NETWORK
		or network_choice_view != null
		or network_wait_context.is_empty()
	):
		battle_screen.header.clear_task_hint()
		return
	var waiting_player := int(network_wait_context.get("waiting_for_player", -1))
	var actor_label := "对手" if waiting_player != current_view_player else "当前玩家"
	var activity: String = str({
		"attachment": "选择附着能量",
		"energy": "处理能量",
		"coin": "确认硬币结果",
		"choice": "完成选择",
	}.get(str(network_wait_context.get("choice_kind", "choice")), "完成选择"))
	battle_screen.header.set_task_hint("等待%s%s…" % [actor_label, activity])


func _sanitize_battle_selection() -> void:
	# Network revisions and completed actions can invalidate a selected hand
	# index or field slot before the next frame. Clear both halves together.
	if _selected_entity_is_valid(selected_entity_key):
		return
	selected_entity_key = ""
	selected_entity_identity = ""
	if battle_screen:
		battle_screen.hide_card_detail()


func _capture_battle_view_model() -> BattleViewModel:
	if state == null:
		return null
	_sanitize_battle_selection()
	return BattleViewModel.capture_player_view(
		state,
		current_view_player,
		_current_action_rows(),
		selected_entity_key,
		ai_thinking,
		game_mode,
	)


func _render_battle_view_model(view: BattleViewModel) -> void:
	if view == null or battle_screen == null:
		return
	var render_state := view.state_for_render()
	if render_state == null:
		return
	battle_screen.update_view(
		render_state,
		view.view_player,
		view.action_rows,
		view.selected_entity_key,
		view.ai_thinking,
		view.game_mode,
	)


func _submit_battle_transition(
	events: Array,
	fallback_actor: int,
	cause: String,
	origin_action_id: String = "",
	origin_request_id: String = "",
	drag_session_id: String = "",
) -> PresentationHandle:
	if battle_screen == null:
		return null
	var target_view := _capture_battle_view_model()
	if target_view == null:
		return null
	return _submit_battle_transition_to_view(
		target_view,
		events,
		fallback_actor,
		cause,
		origin_action_id,
		origin_request_id,
		drag_session_id,
	)


func _submit_battle_transition_to_view(
	target_view: BattleViewModel,
	events: Array,
	fallback_actor: int,
	cause: String,
	origin_action_id: String = "",
	origin_request_id: String = "",
	drag_session_id: String = "",
) -> PresentationHandle:
	if battle_screen == null or target_view == null:
		return null
	# A transition without presentation events has no visual barrier to wait for.
	# Applying it through the deferred coordinator briefly renders the committed
	# state before its flow continuation runs.  In local setup that intermediate
	# state is the outgoing player marked ready with every action disabled; if the
	# deferred pump/continuation is interrupted, hot-seat play is stranded on the
	# "waiting for opponent" surface.  Commit idle, non-drag views synchronously so
	# ownership handoffs and pending-choice routing happen in the same call stack.
	# Busy transitions and drag sessions still use the coordinator to preserve
	# ordering and proxy cleanup.
	if (
		events.is_empty()
		and drag_session_id.is_empty()
		and not battle_screen.is_presentation_busy()
	):
		_render_battle_view_model(target_view)
		return null
	var request := BattleTransitionRequest.create(
		target_view,
		events,
		fallback_actor,
		cause,
		origin_action_id,
		origin_request_id,
		drag_session_id,
		true,
	)
	return battle_screen.submit_transition(request)


func _continue_when_presented(
	handle: PresentationHandle,
	expected_revision: int,
	continuation: Callable,
) -> void:
	if handle == null:
		continuation.call()
		return
	if handle.is_completed():
		if handle.status in [PresentationHandle.COMPLETED, PresentationHandle.SNAPPED]:
			call_deferred("_run_presentation_continuation", expected_revision, continuation)
		elif handle.status == PresentationHandle.CANCELLED:
			call_deferred(
				"_recover_cancelled_presentation",
				expected_revision,
				continuation,
			)
		return
	handle.completed.connect(
		_on_presentation_handle_completed.bind(expected_revision, continuation),
		CONNECT_ONE_SHOT,
	)


func _on_presentation_handle_completed(
	_handle: PresentationHandle,
	expected_revision: int,
	continuation: Callable,
) -> void:
	if _handle.status in [PresentationHandle.COMPLETED, PresentationHandle.SNAPPED]:
		# Handle completion may be emitted from inside coordinator cancellation,
		# before its active row and busy flag have been cleared.
		call_deferred("_run_presentation_continuation", expected_revision, continuation)
	elif _handle.status == PresentationHandle.CANCELLED:
		call_deferred(
			"_recover_cancelled_presentation",
			expected_revision,
			continuation,
		)


func _recover_cancelled_presentation(
	expected_revision: int,
	continuation: Callable,
) -> void:
	if (
		state == null
		or current_screen != SCREEN_GAME
		or battle_screen == null
		or not is_instance_valid(battle_screen)
		or (expected_revision >= 0 and state.revision != expected_revision)
	):
		return
	# Network cancellation during a resync is reconciled by the incoming
	# authoritative view. Local/AI queued batches have no such future state, so
	# snap the table to the already-committed rules state before continuing flow.
	if game_mode == MODE_NETWORK and network_controller.resync_in_progress:
		return
	_refresh_game()
	_run_presentation_continuation(expected_revision, continuation)


func _run_presentation_continuation(
	expected_revision: int,
	continuation: Callable,
) -> void:
	if state == null or current_screen != SCREEN_GAME:
		return
	# A newer network view supersedes continuations belonging to an older batch.
	if expected_revision >= 0 and state.revision != expected_revision:
		return
	if continuation.is_valid():
		continuation.call()


func _rules_legal_actions(actor: int) -> LegalActionQueryResult:
	return native_rules.legal_actions(actor)


func _rules_pending_choice(viewer: int) -> ChoiceView:
	return native_rules.pending_choice(viewer)


func _rules_apply_action(action: GameAction) -> StepResult:
	var result := native_rules.apply_action(action.to_dict())
	state = native_rules.state
	if state != null:
		rng.set_state(native_rules.rng_state)
	return result


func _rules_apply_choice(response: ChoiceResponse) -> StepResult:
	var result := native_rules.apply_choice(response.to_dict())
	state = native_rules.state
	if state != null:
		rng.set_state(native_rules.rng_state)
	return result


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
		var query := _rules_legal_actions(actor)
		if query.success:
			actions = query.concrete_actions()
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
	# Re-selecting the source is an explicit UI toggle, never a target choice.
	# This keeps cancellation deterministic even for actions that can target the
	# source Pokemon itself.
	if selected_entity_key == "pokemon:%d:%s" % [player_idx, slot]:
		_select_pokemon(player_idx, slot, card_id)
		return
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
	card_id: String,
	target_player: int,
	target_slot: String,
) -> void:
	if state == null or hand_index < 0:
		if battle_screen:
			battle_screen.clear_pending_drag("invalid_drop")
		return
	var actor := _current_actor()
	var actor_hand := state.get_player(actor).hand if actor in [0, 1] else []
	var drag_context := battle_screen.active_drag_context() if battle_screen else {}
	var identity_valid := (
		hand_index < actor_hand.size()
		and str(actor_hand[hand_index]) == card_id
		and (
			drag_context.is_empty()
			or (
				int(drag_context.get("revision", -1)) == state.revision
				and int(drag_context.get("hand_index", -1)) == hand_index
				and str(drag_context.get("card_id", "")) == card_id
			)
		)
	)
	if not identity_valid:
		if battle_screen:
			battle_screen.clear_pending_drag("stale_drag")
		_show_toast("手牌状态已经变化，请重新拖动。", true)
		return
	var candidates := _matching_drop_actions(hand_index, target_player, target_slot)
	if candidates.size() == 1:
		_execute_action(candidates[0])
		return
	if candidates.size() > 1:
		# BattleTable owns the variant popover and keeps the drag proxy parked.
		return
	# BattleTable/CardView only emit drops for legal targets. Keep this branch as
	# a silent stale-state guard for network revisions racing with a drag.
	if battle_screen:
		battle_screen.clear_pending_drag("illegal_drop")


func _matching_drop_actions(
	hand_index: int,
	target_player: int,
	target_slot: String,
) -> Array[GameAction]:
	var result: Array[GameAction] = []
	for row in _current_action_rows():
		var action: GameAction = row.get("action")
		if action == null or action.hand_index() != hand_index:
			continue
		if (
			target_slot == "stadium"
			and action.kind == "PLAY_TRAINER"
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
		var action_slot := action.target_slot(action.primary_slot())
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
			action.kind == "RETREAT"
			and selected_player == action.actor
			and selected_slot == "active"
		):
			belongs_to_selected = true
		if belongs_to_selected:
			result.append(action)
	return result


func _execute_action(action: GameAction) -> StepResult:
	if _battle_submission_locked():
		var locked_message := "动画或局面同步尚未完成，请稍候。"
		if battle_screen:
			battle_screen.clear_pending_drag("submission_locked")
		_show_toast(locked_message, true)
		return StepResult.new(false, locked_message)
	if action.kind == "RETREAT":
		_show_retreat_confirmation(action)
		return StepResult.new(true, "等待确认撤退。")
	if action.kind == "END_TURN" and not _remaining_turn_action_labels().is_empty():
		_show_end_turn_confirmation(action)
		return StepResult.new(true, "等待确认结束回合。")
	return _execute_action_now(action)


func _execute_action_now(action: GameAction) -> StepResult:
	if _battle_submission_locked():
		var locked_message := "动画或局面同步尚未完成，请稍候。"
		if battle_screen:
			battle_screen.clear_pending_drag("submission_locked")
		_show_toast(locked_message, true)
		return StepResult.new(false, locked_message)
	var drag_context := battle_screen.active_drag_context() if battle_screen else {}
	var action_hand_index := action.hand_index()
	var action_uses_drag := (
		not drag_context.is_empty()
		and action_hand_index >= 0
		and action_hand_index == int(drag_context.get("hand_index", -1))
	)
	if game_mode == MODE_NETWORK:
		_play_click()
		var accepted := network_controller.submit_action(action)
		if not accepted:
			_show_toast("动作未发送或被房主拒绝。", true)
			if action_uses_drag and battle_screen:
				battle_screen.clear_pending_drag("network_submit_rejected")
		else:
			selected_entity_key = ""
			selected_entity_identity = ""
			if battle_screen:
				battle_screen.hide_card_detail()
			if action_uses_drag and battle_screen:
				battle_screen.mark_drag_pending(action.action_id, true)
			# The host settles authoritatively in submit_action() and queues its own
			# state event. Drain it now so submit_transition() makes the Main-level
			# busy guard effective before another pointer event can submit again.
			if network_controller.host:
				_poll_network()
		return StepResult.new(accepted, "动作已提交。" if accepted else "动作提交失败。")
	if game_mode != MODE_LOCAL and _current_actor() == 1:
		return StepResult.new(false, "AI 回合不能由玩家操作。")
	_play_click()
	action_sequence += 1
	action.action_id = "local:%d:%d" % [state.revision, action_sequence]
	var previous_active := state.active_player_idx
	var previous_phase := state.phase
	# Reserve the live drag proxy while the table still renders the action's base
	# revision. GameState is settled in place and increments revision before this
	# method regains control; marking it afterwards makes a valid drag look stale
	# and forces Presentation to create a second card from the old hand snapshot.
	var drag_session_id := ""
	if action_uses_drag and battle_screen:
		drag_session_id = battle_screen.mark_drag_pending(action.action_id, false)
	var result := _rules_apply_action(action)
	if not result.success:
		_show_toast(result.message, true)
		if action_uses_drag and battle_screen:
			battle_screen.clear_pending_drag("rules_rejected")
		_refresh_game()
		return result
	selected_entity_key = ""
	selected_entity_identity = ""
	if battle_screen:
		battle_screen.hide_card_detail()
	_show_toast(result.message if not result.message.is_empty() else "动作完成。")
	var presented_revision := state.revision
	var local_handoff := _build_local_handoff_plan(
		result.events,
		previous_active,
		previous_phase,
	)
	if not local_handoff.is_empty():
		var prefix_handle := _submit_battle_transition_to_view(
			local_handoff.get("outgoing_view") as BattleViewModel,
			local_handoff.get("prefix_events", []),
			action.actor,
			BattleTransitionRequest.CAUSE_LOCAL_ACTION,
			action.action_id,
			"",
			drag_session_id,
		)
		_continue_when_presented(
			prefix_handle,
			presented_revision,
			_open_local_handoff_gate.bind(
				result,
				local_handoff,
				previous_active,
				previous_phase,
				action.action_id,
				"",
				BattleTransitionRequest.CAUSE_LOCAL_ACTION,
			),
		)
		return result
	var handle := _submit_battle_transition(
		result.events,
		action.actor,
		BattleTransitionRequest.CAUSE_LOCAL_ACTION,
		action.action_id,
		"",
		drag_session_id,
	)
	_continue_when_presented(
		handle,
		presented_revision,
		_continue_after_player_transition.bind(
			result,
			previous_active,
			previous_phase,
		),
	)
	return result


func _battle_submission_locked() -> bool:
	if _startup_choreography_running:
		return true
	if battle_screen != null and battle_screen.is_presentation_busy():
		return true
	return game_mode == MODE_NETWORK and network_controller.submission_locked()


func _continue_after_player_transition(
	result: StepResult,
	previous_active: int,
	previous_phase: String,
) -> void:
	if _route_step_pending_choice(result):
		return
	_after_step(previous_active, previous_phase)


func _route_step_pending_choice(result: StepResult) -> bool:
	var pending_choice := _step_pending_choice(result)
	if pending_choice == null:
		return false
	if game_mode != MODE_LOCAL and pending_choice.player == 1:
		_schedule_ai_choice(pending_choice)
		return true
	if game_mode == MODE_LOCAL and pending_choice.player != current_view_player:
		current_view_player = pending_choice.player
		# Establish the opaque privacy gate before rendering the next owner's view.
		# Chained KO/Prize/trigger choices can change owner without a turn_start
		# boundary, so every continuation path must use this same handoff barrier.
		_show_pass_overlay(
			pending_choice.player,
			"规则选择",
			"请将设备交给玩家 %d 完成选择。" % (pending_choice.player + 1),
			_show_choice_overlay.bind(pending_choice),
		)
		_refresh_game()
		return true
	_show_choice_overlay(pending_choice)
	return true


func _build_local_handoff_plan(
	raw_events: Array,
	previous_active: int,
	previous_phase: String = "",
) -> Dictionary:
	var opening_turn_after_setup := (
		previous_phase == "SETUP"
		and state != null
		and state.phase == "MAIN"
	)
	if (
		game_mode != MODE_LOCAL
		or state == null
		or state.is_terminal()
	):
		return {}
	var incoming_player := state.active_player_idx
	var presents_incoming_turn := false
	for event_value in raw_events:
		if not event_value is Dictionary:
			continue
		var event: Dictionary = event_value
		var event_type := PresentationEvent.canonical_event_type(
			str(event.get("event_type", "")),
		)
		var data: Dictionary = event.get("data", {})
		var actor := int(event.get("actor", data.get("player", -1)))
		if event_type == "turn_start" and actor == incoming_player:
			presents_incoming_turn = true
			break
	var returning_view_to_incoming := (
		presents_incoming_turn
		and current_view_player != incoming_player
	)
	if (
		state.active_player_idx == previous_active
		and not opening_turn_after_setup
		and not returning_view_to_incoming
	):
		return {}
	var events: Array[Dictionary] = []
	for index in range(raw_events.size()):
		if not raw_events[index] is Dictionary:
			continue
		var event: Dictionary = Dictionary(raw_events[index]).duplicate(true)
		var event_type := PresentationEvent.canonical_event_type(
			str(event.get("event_type", "")),
		)
		if str(event.get("event_id", "")).is_empty():
			event["event_id"] = "presentation:%d:%d:%s" % [
				state.revision,
				index,
				event_type,
			]
		events.append(event)
	events = PresentationEvent.order_for_presentation(events)
	var boundary := -1
	for index in range(events.size()):
		var event: Dictionary = events[index]
		var event_type := PresentationEvent.canonical_event_type(
			str(event.get("event_type", "")),
		)
		var data: Dictionary = event.get("data", {})
		var actor := int(event.get("actor", data.get("player", -1)))
		if actor == incoming_player and event_type == "turn_start":
			boundary = index
			break
	if boundary < 0:
		for index in range(events.size()):
			var event: Dictionary = events[index]
			var event_type := PresentationEvent.canonical_event_type(
				str(event.get("event_type", "")),
			)
			var data: Dictionary = event.get("data", {})
			var actor := int(event.get("actor", data.get("player", -1)))
			if actor == incoming_player and event_type == "cards_drawn":
				boundary = index
				break
	if boundary < 0:
		return {}
	var prefix_events: Array[Dictionary] = []
	var suffix_events: Array[Dictionary] = []
	for index in range(events.size()):
		if index < boundary:
			prefix_events.append(events[index])
		else:
			suffix_events.append(events[index])
	var pre_draw_state := _state_before_handoff_draw(suffix_events, incoming_player)
	if pre_draw_state == null:
		return {}
	var outgoing_view := BattleViewModel.capture_player_view(
		pre_draw_state,
		current_view_player,
		[],
		"",
		ai_thinking,
		game_mode,
	)
	var incoming_view := BattleViewModel.capture_player_view(
		pre_draw_state,
		incoming_player,
		[],
		"",
		ai_thinking,
		game_mode,
	)
	return {
		"incoming_player": incoming_player,
		"prefix_events": prefix_events,
		"suffix_events": suffix_events,
		"outgoing_view": outgoing_view,
		"incoming_view": incoming_view,
	}


func _state_before_handoff_draw(
	suffix_events: Array[Dictionary],
	incoming_player: int,
) -> GameState:
	if state == null or incoming_player not in [0, 1]:
		return null
	var result := state.clone_state()
	var player := result.get_player(incoming_player)
	for event_index in range(suffix_events.size() - 1, -1, -1):
		var event: Dictionary = suffix_events[event_index]
		if PresentationEvent.canonical_event_type(
			str(event.get("event_type", "")),
		) != "cards_drawn":
			continue
		var data: Dictionary = event.get("data", {})
		var actor := int(event.get("actor", data.get("player", -1)))
		if actor != incoming_player:
			continue
		var raw_card_ids: Variant = data.get("card_ids", data.get("cards", []))
		var card_ids: Array[String] = []
		if raw_card_ids is Array:
			for value in raw_card_ids:
				card_ids.append(str(value))
		var amount := maxi(0, int(event.get(
			"amount",
			data.get("count", card_ids.size()),
		)))
		for offset in range(amount):
			var expected_id := (
				card_ids[card_ids.size() - 1 - offset]
				if offset < card_ids.size()
				else ""
			)
			var restored_id := _pop_last_matching_card(player.hand, expected_id)
			if not restored_id.is_empty():
				player.deck.append(restored_id)
	result.phase = "DRAW"
	if (
		not result.action_log.is_empty()
		and str(result.action_log[-1]).begins_with("—— ")
	):
		result.action_log.pop_back()
	return result


func _pop_last_matching_card(cards: Array[String], card_id: String) -> String:
	if cards.is_empty():
		return ""
	if card_id.is_empty() or cards[-1] == card_id:
		return cards.pop_back()
	for index in range(cards.size() - 1, -1, -1):
		if cards[index] == card_id:
			return cards.pop_at(index)
	return cards.pop_back()


func _open_local_handoff_gate(
	result: StepResult,
	plan: Dictionary,
	previous_active: int,
	previous_phase: String,
	origin_action_id: String,
	origin_request_id: String,
	transition_cause: String,
) -> void:
	var incoming_player := int(plan.get("incoming_player", state.active_player_idx))
	current_view_player = incoming_player
	_show_pass_overlay(
		incoming_player,
		"回合交接",
		"请将设备交给玩家 %d。" % (incoming_player + 1),
		_resume_local_handoff.bind(
			result,
			plan,
			previous_active,
			previous_phase,
			origin_action_id,
			origin_request_id,
			transition_cause,
		),
		false,
	)
	var incoming_view := plan.get("incoming_view") as BattleViewModel
	_render_battle_view_model(incoming_view)
	modal_confirm.disabled = false


func _resume_local_handoff(
	result: StepResult,
	plan: Dictionary,
	previous_active: int,
	previous_phase: String,
	origin_action_id: String,
	origin_request_id: String,
	transition_cause: String,
) -> void:
	var suffix_events: Array = plan.get("suffix_events", [])
	var handle := _submit_battle_transition(
		suffix_events,
		int(plan.get("incoming_player", state.active_player_idx)),
		transition_cause,
		origin_action_id,
		origin_request_id,
	)
	_continue_when_presented(
		handle,
		state.revision,
		_continue_after_local_handoff.bind(
			result,
			previous_active,
			previous_phase,
		),
	)


func _continue_after_local_handoff(
	result: StepResult,
	_previous_active: int,
	_previous_phase: String,
) -> void:
	if _route_step_pending_choice(result):
		return
	_refresh_game()


func _after_step(previous_active: int, previous_phase: String) -> void:
	if state.is_terminal():
		_refresh_game()
		return
	if game_mode != MODE_LOCAL:
		current_view_player = 0
		_refresh_game()
		if _current_actor() == 1:
			_schedule_ai_action()
		return
	if state.phase == "SETUP":
		var next_setup := state.setup_actor_idx
		if next_setup in [0, 1] and next_setup != current_view_player:
			current_view_player = next_setup
			_show_pass_overlay(next_setup, "准备阶段", "轮到玩家 %d 放置宝可梦。" % (next_setup + 1))
			return
	elif (
		state.active_player_idx != previous_active
		or (previous_phase == "SETUP" and state.phase == "MAIN")
	):
		current_view_player = state.active_player_idx
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
			_show_pass_overlay(promote_actor, "晋升", "请选择新的战斗宝可梦。")
			return
	_refresh_game()


func _show_choice_overlay(request: ChoiceView) -> void:
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
		selected_entity_identity = ""
		battle_screen.set_choice_targets(field_targets, _choice_field_prompt(request))
		_refresh_game()
		return
	var energy_cards := _choice_energy_cards(request)
	var energy_distribution_view := _choice_energy_distribution_view(
		request,
		energy_cards,
	)
	if not energy_distribution_view.is_empty():
		energy_cards.assign(energy_distribution_view.get("card_ids", energy_cards))
	var energy_target_models: Array[Dictionary] = []
	for target_value in energy_distribution_view.get("targets", []):
		if target_value is Dictionary:
			energy_target_models.append(Dictionary(target_value))
	var revealed_cards := _choice_revealed_cards(request)
	var has_card_preview := not energy_cards.is_empty() or not revealed_cards.is_empty()
	var pure_empty_choice := (
		request.options.is_empty()
		and energy_cards.is_empty()
		and revealed_cards.is_empty()
	)
	for option in request.options:
		if not _choice_option_display_card_id(option, request).is_empty():
			has_card_preview = true
			break
	var choice_spec := ModalSpec.battle(
		_choice_modal_size(has_card_preview, pure_empty_choice),
		false,
		(
			ModalSpec.SizeMode.FIT_CONTENT
			if pure_empty_choice
			else ModalSpec.SizeMode.PREFERRED
		),
	)
	_open_modal(
		request.prompt,
		_choice_confirm_cta(request, 0),
		_choice_cancel_cta(request),
		false,
		choice_spec,
	)
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
	if not energy_target_models.is_empty():
		panel.configure_energy_distribution(
			energy_cards,
			energy_target_models,
			catalog,
		)
	elif not energy_cards.is_empty():
		panel.add_energy_preview(energy_cards, catalog)
	elif not revealed_cards.is_empty():
		panel.add_revealed_cards(revealed_cards, catalog)
	for option in request.options:
		if not energy_target_models.is_empty():
			break
		var option_id := str(option.get("option_id", ""))
		var option_card_id := _choice_option_display_card_id(option, request)
		if option_id.is_empty():
			continue
		if not option_card_id.is_empty():
			panel.add_card_option(
				option_id,
				option_card_id,
				_choice_option_caption(option),
				_choice_option_owner(option, request.player),
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


func _show_coin_flip_choice(request: ChoiceView) -> void:
	_open_modal(
		request.prompt,
		"继续结算",
		"",
		false,
		ModalSpec.battle(Vector2(680, 500)),
	)
	modal_title.text = "硬币结算"
	var results: Array = _choice_presentation(request).get("predetermined_flips", [])
	var showcase := COIN_SHOWCASE.new() as CoinShowcase
	showcase.name = "CoinShowcase"
	showcase.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	showcase.custom_minimum_size = Vector2(540, 300)
	if audio_director:
		showcase.audio_requested.connect(audio_director.play_cue)
	modal_body.add_child(showcase)
	var reveal_generation := _modal_generation
	var playback := showcase.play(results, true, "硬币结果")
	modal_confirm.disabled = not playback.is_finished()
	if not playback.is_finished():
		playback.completed.connect(
			_on_coin_choice_playback_completed.bind(
				reveal_generation,
				request.request_id,
			),
			CONNECT_ONE_SHOT,
		)
	modal_confirm.text = "继续结算"
	modal_confirm.pressed.connect(_confirm_choice, CONNECT_ONE_SHOT)


func _on_coin_choice_playback_completed(
	_handle: MotionHandle,
	generation: int,
	request_id: String,
) -> void:
	_finish_coin_flip_reveal(generation, request_id)


func _finish_coin_flip_reveal(generation: int, request_id: String) -> void:
	if (
		generation != _modal_generation
		or not modal_layer.visible
		or active_request == null
		or active_request.request_id != request_id
	):
		return
	modal_confirm.disabled = false


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


func _choice_distribution_energy_card_id(option: Dictionary) -> String:
	var option_id := str(option.get("option_id", ""))
	if not option_id.begins_with("energy:"):
		return ""
	var index_separator := option_id.find(":", "energy:".length())
	var target_separator := option_id.find("->", index_separator + 1)
	if index_separator < 0 or target_separator <= index_separator + 1:
		return ""
	return option_id.substr(
		index_separator + 1,
		target_separator - index_separator - 1,
	)


func _choice_distribution_energy_index(option: Dictionary) -> int:
	var option_id := str(option.get("option_id", ""))
	if not option_id.begins_with("energy:"):
		return -1
	var index_separator := option_id.find(":", "energy:".length())
	if index_separator < 0:
		return -1
	var index_text := option_id.substr(
		"energy:".length(),
		index_separator - "energy:".length(),
	)
	return index_text.to_int() if index_text.is_valid_int() else -1


func _choice_option_card_id(option: Dictionary) -> String:
	var distribution_energy := _choice_distribution_energy_card_id(option)
	if not distribution_energy.is_empty():
		return distribution_energy
	var ref_variant: Variant = option.get("ref")
	if ref_variant is Dictionary:
		return str(Dictionary(ref_variant).get("card_id", ""))
	return ""


func _choice_option_target_card_id(option: Dictionary) -> String:
	var ref_variant: Variant = option.get("ref")
	if ref_variant is Dictionary:
		return str(Dictionary(ref_variant).get("card_id", ""))
	return ""


func _choice_option_display_card_id(
	option: Dictionary,
	request: ChoiceView = null,
) -> String:
	if request != null and request.request_type == "distribute_energy":
		var target_card_id := _choice_option_target_card_id(option)
		if not target_card_id.is_empty():
			return target_card_id
	return _choice_option_card_id(option)


func _choice_energy_distribution_view(
	request: ChoiceView,
	presentation_card_ids: Array[String],
) -> Dictionary:
	if request == null or request.request_type != "distribute_energy":
		return {}
	var source_card_ids: Array[String] = []
	source_card_ids.assign(presentation_card_ids)
	var targets_by_key: Dictionary = {}
	var target_order: Array[String] = []
	for option_value in request.options:
		var option := Dictionary(option_value)
		var option_id := str(option.get("option_id", ""))
		var ref_value: Variant = option.get("ref")
		if option_id.is_empty() or not ref_value is Dictionary:
			continue
		var ref := Dictionary(ref_value)
		if str(ref.get("kind", "")) != "pokemon":
			continue
		var player_idx := int(ref.get("player", request.player))
		var slot := str(ref.get("slot", ""))
		if player_idx not in [0, 1] or slot.is_empty() or state == null:
			continue
		var pokemon := state.get_player(player_idx).get_pokemon(slot)
		if pokemon == null:
			continue
		var target_key := "%d:%s" % [player_idx, slot]
		if not targets_by_key.has(target_key):
			var pokemon_name := (
				catalog.card_name(pokemon.card_id)
				if catalog != null
				else pokemon.card_id
			)
			var owner_text := "己方" if player_idx == current_view_player else "对手"
			targets_by_key[target_key] = {
				"target_key": target_key,
				"player": player_idx,
				"slot": slot,
				"card_id": pokemon.card_id,
				"pokemon": pokemon.clone_state(),
				"name": pokemon_name,
				"location": "%s · %s" % [owner_text, _slot_name(slot)],
				"label": "%s · %s · %s" % [
					owner_text,
					_slot_name(slot),
					pokemon_name,
				],
				"assignment_label": "%s · %s" % [
					_slot_name(slot),
					pokemon_name,
				],
				"option_ids_by_energy_index": {},
				"fallback_option_id": "",
			}
			target_order.append(target_key)
		var model: Dictionary = targets_by_key[target_key]
		var energy_index := _choice_distribution_energy_index(option)
		if energy_index >= 0:
			var source_card_id := _choice_distribution_energy_card_id(option)
			while source_card_ids.size() <= energy_index:
				source_card_ids.append("")
			if source_card_ids[energy_index].is_empty():
				source_card_ids[energy_index] = source_card_id
			var option_ids: Dictionary = model.get(
				"option_ids_by_energy_index", {})
			option_ids[energy_index] = option_id
			model["option_ids_by_energy_index"] = option_ids
		elif str(model.get("fallback_option_id", "")).is_empty():
			model["fallback_option_id"] = option_id
		targets_by_key[target_key] = model
	if target_order.is_empty():
		return {}
	while source_card_ids.size() < request.max_select:
		source_card_ids.append("")
	var targets: Array[Dictionary] = []
	for target_key in target_order:
		targets.append(Dictionary(targets_by_key[target_key]))
	return {
		"card_ids": source_card_ids,
		"targets": targets,
	}


func _choice_option_owner(option: Dictionary, fallback_player: int) -> int:
	var ref_value: Variant = option.get("ref")
	if ref_value is Dictionary:
		return int(Dictionary(ref_value).get("player", fallback_player))
	return fallback_player


func _choice_attachment_ref(option: Dictionary) -> Dictionary:
	var ref_value: Variant = option.get("ref")
	if ref_value is Dictionary:
		var ref := Dictionary(ref_value)
		if (
			str(ref.get("kind", "")) == "attachment"
			or not str(ref.get("attachment_type", "")).is_empty()
		):
			return ref
	return {}


func _choice_option_caption(option: Dictionary) -> String:
	var label_text := str(option.get("label", ""))
	var ref_variant: Variant = option.get("ref")
	var ref_data: Dictionary = {}
	if ref_variant is Dictionary:
		ref_data = ref_variant
	var is_attachment := (
		str(ref_data.get("kind", "")) == "attachment"
		or str(option.get("option_id", "")).begins_with("attachment:")
	)
	if is_attachment:
		var attachment_player := int(ref_data.get(
			"player", active_request.player if active_request else current_view_player))
		var attachment_slot := str(ref_data.get("slot", ""))
		var attachment_index := int(ref_data.get("index", -1))
		var attachment_label := label_text.replace(" - ", " · ")
		if attachment_label.is_empty() and catalog != null:
			attachment_label = catalog.card_name(_choice_option_card_id(option))
		var attachment_parts: Array[String] = []
		attachment_parts.append("己方" if attachment_player == current_view_player else "对手")
		if not attachment_slot.is_empty():
			attachment_parts.append(_slot_name(attachment_slot))
		if not attachment_label.is_empty():
			attachment_parts.append(attachment_label)
		if attachment_index >= 0:
			attachment_parts.append("第%d张" % (attachment_index + 1))
		if (
			active_request != null
			and active_request.request_type == "select_retreat_payment"
		):
			var provided_units := _retreat_payment_option_units(
				active_request, str(option.get("option_id", "")))
			if provided_units > 0:
				attachment_parts.append("提供%d点" % provided_units)
		return " · ".join(attachment_parts)
	var option_id := str(option.get("option_id", ""))
	if option_id.begins_with("energy:"):
		var energy_id := _choice_distribution_energy_card_id(option)
		if not energy_id.is_empty():
			var energy_name := (
				catalog.card_name(energy_id)
				if catalog != null
				else energy_id
			)
			var target_slot := str(ref_data.get("slot", ""))
			if not target_slot.is_empty():
				return "%s → %s" % [energy_name, _slot_name(target_slot)]
	if option_id.begins_with("rare_candy:"):
		var parts := option_id.split(":")
		if parts.size() >= 2:
			return "%s · %s" % [_slot_name(str(parts[1])), label_text]
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
	return label_text


func _choice_field_target_options(request: ChoiceView) -> Dictionary:
	var result: Dictionary = {}
	if request != null and request.request_type == "select_prize":
		for option_value in request.options:
			var option := Dictionary(option_value)
			var option_id := str(option.get("option_id", ""))
			if not option_id.begins_with("prize:"):
				return {}
			var prize_index := int(option_id.trim_prefix("prize:"))
			result["prize:%d:%d" % [request.player, prize_index]] = option_id
		return result
	if request != null and request.request_type == "select_attachment":
		return _choice_attachment_target_groups(request)
	if (
		request == null
		or request.min_select != 1
		or request.max_select != 1
		or request.allow_duplicates
		or request.can_cancel
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


func _choice_attachment_target_groups(request: ChoiceView) -> Dictionary:
	var result: Dictionary = {}
	if request == null or request.options.is_empty() or state == null:
		return result
	var disabled_reasons := _choice_option_disabled_reasons(request)
	for option_value in request.options:
		var option := Dictionary(option_value)
		var option_id := str(option.get("option_id", ""))
		var ref := _choice_attachment_ref(option)
		var player_idx := int(ref.get("player", request.player))
		var slot := str(ref.get("slot", ""))
		if (
			option_id.is_empty()
			or player_idx not in [0, 1]
			or slot.is_empty()
			or state.get_player(player_idx).get_pokemon(slot) == null
		):
			return {}
		var key := CardInteractionRouter.pokemon_key(player_idx, slot)
		if not result.has(key):
			result[key] = {
				"kind": "attachment_group",
				"player": player_idx,
				"slot": slot,
				"source_label": _choice_attachment_source_label(player_idx, slot),
				"options": [],
				"selected_ids": selected_choice_ids.duplicate(),
				"disabled_reasons": disabled_reasons.duplicate(true),
				"min_select": request.min_select,
				"max_select": request.max_select,
				"can_cancel": request.can_cancel,
			}
		var group: Dictionary = result[key]
		var group_options: Array = group.get("options", [])
		group_options.append(option.duplicate(true))
		group["options"] = group_options
		result[key] = group
	return result


func _choice_attachment_source_label(player_idx: int, slot: String) -> String:
	var pokemon := state.get_player(player_idx).get_pokemon(slot) if state != null else null
	var owner_text := "己方" if player_idx == current_view_player else "对手"
	var pokemon_name := (
		catalog.card_name(pokemon.card_id)
		if pokemon != null and catalog != null
		else "宝可梦"
	)
	return "%s · %s · %s" % [owner_text, _slot_name(slot), pokemon_name]


func _choice_field_prompt(request: ChoiceView) -> String:
	if request == null:
		return "请选择目标"
	if request.request_type not in ["select_energy_target", "distribute_energy"]:
		return request.prompt
	var presentation := _choice_presentation(request)
	var source_slot := str(presentation.get("source_slot", ""))
	var source_player := int(presentation.get("source_player", request.player))
	var card_names: Array[String] = []
	for value in presentation.get("card_ids", []):
		var card_name := catalog.card_name(str(value)) if catalog != null else str(value)
		if not card_name.is_empty() and card_name not in card_names:
			card_names.append(card_name)
	if source_slot.is_empty() or card_names.is_empty():
		return request.prompt
	return "从「%s」移动「%s」；请选择目标" % [
		_choice_attachment_source_label(source_player, source_slot),
		"、".join(card_names),
	]


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


func _choice_energy_cards(request: ChoiceView) -> Array[String]:
	var result: Array[String] = []
	if request == null or request.request_type not in ["distribute_energy", "select_energy_target"]:
		return result
	var presentation := _choice_presentation(request)
	for value in presentation.get("card_ids", []):
		var metadata_card_id := str(value)
		if not metadata_card_id.is_empty():
			result.append(metadata_card_id)
	if result.is_empty():
		for ref_value in presentation.get("attachment_refs", []):
			if not ref_value is Dictionary:
				continue
			var ref_card_id := str(Dictionary(ref_value).get("card_id", ""))
			if not ref_card_id.is_empty():
				result.append(ref_card_id)
	if not result.is_empty():
		return result
	return result


func _show_retreat_confirmation(action: GameAction) -> void:
	_play_click()
	_open_modal(
		"确认撤退",
		"确认撤退",
		"取消",
		false,
		ModalSpec.battle(
			Vector2(640, 420),
			false,
			ModalSpec.SizeMode.FIT_CONTENT,
		),
	)
	var lines := _retreat_confirmation_lines(action)
	var body := Label.new()
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_theme_font_size_override("font_size", 18)
	body.add_theme_color_override("font_color", DesignTokens.TEXT)
	body.text = "\n".join(lines)
	modal_body.add_child(body)
	modal_confirm.pressed.connect(func() -> void:
		_play_click()
		_close_modal(_execute_action_now.bind(action))
	, CONNECT_ONE_SHOT)
	modal_cancel.pressed.connect(func() -> void:
		_play_click()
		_close_modal()
	, CONNECT_ONE_SHOT)


func _retreat_confirmation_lines(action: GameAction) -> Array[String]:
	var actor := action.actor if action.actor != null else _current_actor()
	var player := state.get_player(actor)
	var bench_idx := action.bench_index()
	var target_name := "备战宝可梦"
	if bench_idx >= 0 and bench_idx < player.bench.size() and player.bench[bench_idx]:
		target_name = catalog.card_name(player.bench[bench_idx].card_id)
	var energy_names := _retreat_energy_names(action)
	var active_name := catalog.card_name(player.active.card_id) if player.active else "战斗宝可梦"
	var cost_text := ""
	if not energy_names.is_empty():
		cost_text = "将丢弃：%s" % "、".join(energy_names)
	elif _retreat_explicitly_requires_no_energy(action):
		cost_text = "无需丢弃能量"
	else:
		var printed_cost := _retreat_printed_cost(action)
		cost_text = (
			"卡面撤退费用：%d 点。确认后按当前效果结算；如需支付，下一步选择要丢弃的附着能量。"
			% printed_cost
			if printed_cost > 0
			else "确认后按当前效果结算撤退费用；如需支付，下一步选择要丢弃的附着能量。"
		)
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
	for raw_index in action.payload.get("energy_indices", []):
		var index := int(raw_index)
		if index >= 0 and index < active.energy_card_ids.size():
			result.append(catalog.card_name(str(active.energy_card_ids[index])))
	return result


func _retreat_explicitly_requires_no_energy(action: GameAction) -> bool:
	if action == null or not action.payload.has("energy_indices"):
		return false
	var indices: Variant = action.payload.get("energy_indices")
	return indices is Array and Array(indices).is_empty()


func _retreat_printed_cost(action: GameAction) -> int:
	var actor := action.actor if action.actor != null else _current_actor()
	if state == null or actor not in [0, 1]:
		return -1
	var active := state.get_player(actor).active
	if active == null:
		return -1
	return maxi(0, int(catalog.get_card(active.card_id).get("retreat_cost", 0)))


func _retreat_energy_suffix(action: GameAction) -> String:
	var names := _retreat_energy_names(action)
	if not names.is_empty():
		return "（丢弃：%s）" % "、".join(names)
	if _retreat_explicitly_requires_no_energy(action):
		return "（无需丢弃能量）"
	var printed_cost := _retreat_printed_cost(action)
	return (
		"（撤退费 %d，确认后结算）" % printed_cost
		if printed_cost > 0
		else "（确认后结算撤退费用）"
	)


func _choice_revealed_cards(request: ChoiceView) -> Array[String]:
	var result: Array[String] = []
	if request == null:
		return result
	var presentation := _choice_presentation(request)
	for value in presentation.get("revealed_card_ids", []):
		var card_id := str(value)
		if not card_id.is_empty():
			result.append(card_id)
	if result.is_empty():
		var top_card_id := str(presentation.get("top_card_id", ""))
		if not top_card_id.is_empty():
			result.append(top_card_id)
	return result


func _choice_option_by_id(request: ChoiceView, option_id: String) -> Dictionary:
	if request == null or option_id.is_empty():
		return {}
	for option_value in request.options:
		var option: Dictionary = option_value
		if str(option.get("option_id", "")) == option_id:
			return option
	return {}


func _choice_presentation(request: ChoiceView = null) -> Dictionary:
	# Production UI consumes only ChoiceView v2. A raw authoritative
	# ChoiceView intentionally carries no presentation contract here.
	var source := request if request != null else active_request
	if source is ChoiceView:
		return (source as ChoiceView).presentation.duplicate(true)
	return {}


func _choice_has_cancel_action_checkpoint(request: ChoiceView = null) -> bool:
	# Player views deliberately omit the private resolution stack. The request
	# metadata is the authoritative, protocol-safe way to describe whether
	# cancelling rewinds the enclosing card/action.
	if request != null and bool(_choice_presentation(request).get(
		"cancels_action", false)):
		return true
	return false


func _choice_cancel_cta(request: ChoiceView) -> String:
	if request == null or not request.can_cancel:
		return ""
	return "取消使用此卡" if _choice_has_cancel_action_checkpoint(request) else "取消"


func _choice_confirm_cta(request: ChoiceView, selected_count: int) -> String:
	if request == null:
		return "确认选择"
	if request.max_select == 0:
		return "继续结算"
	if request.min_select == 0 and selected_count == 0:
		return "不选择并继续"
	if request.request_type == "select_retreat_payment":
		var required_units := int(_choice_presentation(request).get(
			"required_units", 0))
		var paid_units := _retreat_payment_selected_units(
			request, selected_choice_ids)
		return "确认支付（%d/%d 点）" % [paid_units, required_units]
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
		return "energy"
	return ""


func _choice_selected_category_count(request: ChoiceView, category: String) -> int:
	var count := 0
	for selected_id in selected_choice_ids:
		if _choice_option_category(_choice_option_by_id(request, selected_id)) == category:
			count += 1
	return count


func _choice_option_target_key(option: Dictionary) -> String:
	var ref_value: Variant = option.get("ref")
	if ref_value is Dictionary:
		var ref := Dictionary(ref_value)
		var slot := str(ref.get("slot", ""))
		if not slot.is_empty():
			return "%d:%s" % [int(ref.get("player", -1)), slot]
	return "option:%s" % str(option.get("option_id", ""))


func _choice_selected_target_count(
	request: ChoiceView,
	target_key: String,
) -> int:
	var count := 0
	for selected_id in selected_choice_ids:
		var selected_option := _choice_option_by_id(request, selected_id)
		if _choice_option_target_key(selected_option) == target_key:
			count += 1
	return count


func _retreat_payment_option_units(
	request: ChoiceView,
	option_id: String,
) -> int:
	if (
		request == null
		or request.request_type != "select_retreat_payment"
		or state == null
		or request.player not in [0, 1]
		or catalog == null
	):
		return 0
	var option := _choice_option_by_id(request, option_id)
	var ref_value: Variant = option.get("ref")
	if not ref_value is Dictionary:
		return 0
	var ref := Dictionary(ref_value)
	var active := state.get_player(request.player).active
	var attachment_index := int(ref.get("index", -1))
	if (
		active == null
		or str(ref.get("kind", "")) != "attachment"
		or str(ref.get("attachment_type", "")) != "energy"
		or int(ref.get("player", -1)) != request.player
		or str(ref.get("slot", "")) != "active"
		or attachment_index < 0
		or attachment_index >= active.energy_card_ids.size()
	):
		return 0
	var card_id := str(active.energy_card_ids[attachment_index])
	var ref_card_id := str(ref.get("card_id", ""))
	if not ref_card_id.is_empty() and ref_card_id != card_id:
		return 0
	return catalog.provides_energy(card_id).size()


func _retreat_payment_selected_units(
	request: ChoiceView,
	selected_ids: Array[String],
) -> int:
	var result := 0
	for option_id in selected_ids:
		result += _retreat_payment_option_units(request, option_id)
	return result


func _retreat_payment_selection_is_minimal(
	request: ChoiceView,
	selected_ids: Array[String],
) -> bool:
	var required_units := int(_choice_presentation(request).get(
		"required_units", 0))
	if required_units <= 0:
		return selected_ids.is_empty()
	var paid_units := _retreat_payment_selected_units(request, selected_ids)
	if paid_units < required_units:
		return false
	for option_id in selected_ids:
		var units := _retreat_payment_option_units(request, option_id)
		if units <= 0 or paid_units - units >= required_units:
			return false
	return true


func _choice_selection_is_complete(
	request: ChoiceView,
	selected_ids: Array[String],
) -> bool:
	if request == null:
		return false
	if (
		selected_ids.size() < request.min_select
		or selected_ids.size() > request.max_select
	):
		return false
	if request.request_type == "select_retreat_payment":
		return _retreat_payment_selection_is_minimal(request, selected_ids)
	return true


func _choice_category_label(category: String) -> String:
	return str({
		"energy": "基本能量",
		"item": "物品",
		"pokemon": "宝可梦",
		"tool": "宝可梦道具",
	}.get(category, category))


func _choice_addition_blocked_reason(request: ChoiceView, option_id: String) -> String:
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
	var presentation := _choice_presentation(request)
	if request.request_type == "select_retreat_payment":
		var candidate_units := _retreat_payment_option_units(request, option_id)
		if candidate_units <= 0:
			return "无法读取这张附着能量提供的点数"
		var projected_ids: Array[String] = []
		projected_ids.assign(selected_choice_ids)
		projected_ids.append(option_id)
		var required_units := int(presentation.get("required_units", 0))
		var projected_units := _retreat_payment_selected_units(
			request, projected_ids)
		if (
			required_units > 0
			and projected_units >= required_units
			and not _retreat_payment_selection_is_minimal(
				request, projected_ids)
		):
			return "该组合会多丢弃能量，请先取消不必要的能量"
	var category_limits_value: Variant = presentation.get("category_limits", {})
	var category_limits := (
		Dictionary(category_limits_value)
		if category_limits_value is Dictionary
		else {}
	)
	if category_limits.has(category):
		var category_limit := maxi(0, int(category_limits.get(category, 0)))
		if _choice_selected_category_count(request, category) >= category_limit:
			return "%s最多选择%d张，请先取消一张" % [
				_choice_category_label(category),
				category_limit,
			]
	elif request.request_type == "arven" and category_limits.is_empty():
		if category == "item" and _choice_selected_category_count(request, "item") >= 1:
			return "物品和宝可梦道具各最多选择1张，请先取消已选物品卡"
		if category == "tool" and _choice_selected_category_count(request, "tool") >= 1:
			return "物品和宝可梦道具各最多选择1张，请先取消已选宝可梦道具"
	elif request.request_type == "clara" and category_limits.is_empty():
		var pokemon_limit := int(presentation.get(
			"pokemon_count", request.max_select))
		var energy_limit := int(presentation.get(
			"energy_count", request.max_select))
		if (
			category == "pokemon"
			and _choice_selected_category_count(request, "pokemon") >= pokemon_limit
		):
			return "宝可梦最多选择%d张，请先取消一张宝可梦" % pokemon_limit
		if (
			category == "energy"
			and _choice_selected_category_count(request, "energy") >= energy_limit
		):
			return "基本能量最多选择%d张，请先取消一张基本能量" % energy_limit
	elif request.request_type == "distribute_energy":
		var target_key := _choice_option_target_key(option)
		if (
			bool(presentation.get("same_target", false))
			and not selected_choice_ids.is_empty()
			and target_key != _choice_option_target_key(
				_choice_option_by_id(request, selected_choice_ids[0]),
			)
		):
			return "此效果要求所有能量分配到同一目标"
		var max_per_target := int(presentation.get("max_per_target", 99))
		if _choice_selected_target_count(request, target_key) >= max_per_target:
			return "该目标最多可分配 %d张能量" % max_per_target
	elif request.request_type == "select_attachment":
		var same_source := bool(presentation.get("same_source", false))
		if same_source and not selected_choice_ids.is_empty():
			var candidate_ref := _choice_attachment_ref(option)
			var selected_ref := _choice_attachment_ref(
				_choice_option_by_id(request, selected_choice_ids[0]),
			)
			if (
				int(candidate_ref.get("player", -1))
				!= int(selected_ref.get("player", -1))
				or str(candidate_ref.get("slot", ""))
				!= str(selected_ref.get("slot", ""))
			):
				return "此效果要求所选能量来自同一只宝可梦"

	if selected_choice_ids.size() >= request.max_select:
		return "已达到选择上限，请先取消一张"
	return ""


func _choice_option_disabled_reasons(request: ChoiceView) -> Dictionary:
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
	var disabled_reasons := _choice_option_disabled_reasons(active_request)
	if active_choice_panel:
		active_choice_panel.refresh_selection(
			selected_choice_ids,
			active_request.max_select,
			active_request.allow_duplicates,
		)
		active_choice_panel.set_option_disabled_reasons(
			disabled_reasons,
		)
	elif battle_screen:
		battle_screen.set_choice_targets(
			_choice_field_target_options(active_request),
			_choice_field_prompt(active_request),
		)
		battle_screen.update_choice_selection(selected_choice_ids, disabled_reasons)
	modal_confirm.disabled = not _choice_selection_is_complete(
		active_request, selected_choice_ids)
	modal_confirm.text = _choice_confirm_cta(active_request, selected_choice_ids.size())
	if active_request.can_cancel:
		modal_cancel.text = _choice_cancel_cta(active_request)


func _confirm_choice() -> void:
	if active_request == null:
		return
	if _battle_submission_locked():
		_show_toast("动画或局面同步尚未完成，请稍候。", true)
		return
	_play_click()
	var request := active_request
	var confirmed_ids: Array[String] = selected_choice_ids.duplicate()
	if battle_screen:
		battle_screen.clear_choice_targets()
	_close_modal(_submit_confirmed_choice.bind(request, confirmed_ids))


func _submit_confirmed_choice(
	request: ChoiceView,
	confirmed_ids: Array[String],
) -> void:
	if game_mode == MODE_NETWORK:
		if request.request_type == "coin_flip":
			_remember_coin_presentation_tombstone(request.request_id)
		var choice_sent := network_controller.submit_choice(
			ChoiceResponse.new(request.request_id, confirmed_ids)
		)
		if not choice_sent:
			_presented_coin_request_ids.erase(request.request_id)
			_show_toast("选择未发送或被房主拒绝。", true)
			return
		if network_controller.host:
			_poll_network()
		_show_toast("选择已提交，等待房主同步。")
		return
	var previous_active := state.active_player_idx
	var previous_phase := state.phase
	var result := _rules_apply_choice(
		ChoiceResponse.new(request.request_id, confirmed_ids))
	if not result.success:
		_show_toast(result.message, true)
		_refresh_game()
		return
	var presentation_events: Array = _choice_presentation_events(request, result.events)
	var presented_revision := state.revision
	var local_handoff := _build_local_handoff_plan(
		presentation_events,
		previous_active,
		previous_phase,
	)
	if not local_handoff.is_empty():
		var prefix_handle := _submit_battle_transition_to_view(
			local_handoff.get("outgoing_view") as BattleViewModel,
			local_handoff.get("prefix_events", []),
			request.player,
			BattleTransitionRequest.CAUSE_CHOICE,
			"",
			request.request_id,
		)
		_continue_when_presented(
			prefix_handle,
			presented_revision,
			_open_local_handoff_gate.bind(
				result,
				local_handoff,
				previous_active,
				previous_phase,
				"",
				request.request_id,
				BattleTransitionRequest.CAUSE_CHOICE,
			),
		)
		return
	var handle := _submit_battle_transition(
		presentation_events,
		request.player,
		BattleTransitionRequest.CAUSE_CHOICE,
		"",
		request.request_id,
	)
	_continue_when_presented(
		handle,
		presented_revision,
		_continue_after_choice_transition.bind(
			result,
			previous_active,
			previous_phase,
		),
	)


func _choice_presentation_events(request: ChoiceView, events: Array) -> Array:
	if request == null or request.request_type != "coin_flip":
		return events
	return _without_coin_flip_events(events)


func _without_coin_flip_events(events: Array) -> Array:
	var filtered: Array = []
	for event_value in events:
		if not event_value is Dictionary:
			filtered.append(event_value)
			continue
		var event := event_value as Dictionary
		if PresentationEvent.canonical_event_type(
			str(event.get("event_type", "")),
		) == "coin_flip":
			continue
		filtered.append(event_value)
	return filtered


func _continue_after_choice_transition(
	result: StepResult,
	previous_active: int,
	previous_phase: String,
) -> void:
	if _route_step_pending_choice(result):
		return
	_show_toast(result.message if not result.message.is_empty() else "选择已结算。")
	_after_step(previous_active, previous_phase)


func _cancel_choice() -> void:
	if active_request == null:
		return
	if _battle_submission_locked():
		_show_toast("动画或局面同步尚未完成，请稍候。", true)
		return
	_play_click()
	var request := active_request
	if battle_screen:
		battle_screen.clear_choice_targets()
	_close_modal(_submit_cancelled_choice.bind(request))


func _submit_cancelled_choice(request: ChoiceView) -> void:
	if game_mode == MODE_NETWORK:
		var cancellation_sent := network_controller.submit_choice(
			ChoiceResponse.new(request.request_id, [], true)
		)
		if not cancellation_sent:
			_show_toast("取消请求未发送。", true)
			return
		if network_controller.host:
			_poll_network()
		_show_toast("取消请求已提交，等待房主同步。")
		return
	var previous_active := state.active_player_idx
	var previous_phase := state.phase
	var result := _rules_apply_choice(
		ChoiceResponse.new(request.request_id, [], true))
	_show_toast(result.message if result.success else result.message, not result.success)
	if not result.success:
		_refresh_game()
		return
	var local_handoff := _build_local_handoff_plan(
		result.events,
		previous_active,
		previous_phase,
	)
	if not local_handoff.is_empty():
		var prefix_handle := _submit_battle_transition_to_view(
			local_handoff.get("outgoing_view") as BattleViewModel,
			local_handoff.get("prefix_events", []),
			request.player,
			BattleTransitionRequest.CAUSE_CHOICE,
			"",
			request.request_id,
		)
		_continue_when_presented(
			prefix_handle,
			state.revision,
			_open_local_handoff_gate.bind(
				result,
				local_handoff,
				previous_active,
				previous_phase,
				"",
				request.request_id,
				BattleTransitionRequest.CAUSE_CHOICE,
			),
		)
		return
	var handle := _submit_battle_transition(
		result.events,
		request.player,
		BattleTransitionRequest.CAUSE_CHOICE,
		"",
		request.request_id,
	)
	_continue_when_presented(
		handle,
		state.revision,
		_continue_after_choice_transition.bind(
			result,
			previous_active,
			previous_phase,
		),
	)


func _step_pending_choice(result: StepResult) -> ChoiceView:
	if result != null and result.pending_choice != null:
		return result.pending_choice
	return _query_any_pending_choice()


func _query_any_pending_choice() -> ChoiceView:
	if state == null:
		return null
	var player_zero := _rules_pending_choice(0)
	return player_zero if player_zero != null else _rules_pending_choice(1)


func _show_pass_overlay(
	player_idx: int,
	heading: String,
	body: String,
	confirmed: Callable = Callable(),
	confirm_enabled: bool = true,
) -> void:
	if battle_screen != null and is_instance_valid(battle_screen):
		battle_screen.set_local_hand_privacy_hidden(true)
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
	modal_confirm.disabled = not confirm_enabled
	modal_confirm.pressed.connect(func() -> void:
		_play_click()
		_close_modal(
			_complete_pass_overlay.bind(confirmed),
		)
	, CONNECT_ONE_SHOT)


func _complete_pass_overlay(confirmed: Callable) -> void:
	if battle_screen != null and is_instance_valid(battle_screen):
		battle_screen.set_local_hand_privacy_hidden(false)
	if confirmed.is_valid():
		confirmed.call()
	else:
		_refresh_game()


func _show_pause_overlay(resume_choice_context: Dictionary = {}) -> void:
	if game_mode in [MODE_CHALLENGE, MODE_DEEP]:
		ai_coordinator.cancel_request()
		ai_thinking = false
		_refresh_game()
	var field_choice_context := resume_choice_context
	if field_choice_context.is_empty():
		field_choice_context = _suspend_field_choice_for_auxiliary_modal()
	var pause_spec := ModalSpec.battle(
		Vector2(720, 400),
		true,
		ModalSpec.SizeMode.FIT_CONTENT,
	)
	pause_spec.with_button_roles(
		ModalSpec.ButtonRole.PRIMARY,
		ModalSpec.ButtonRole.DANGER,
	)
	_open_modal("对局菜单", "继续对局", "返回标题", true, pause_spec)
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
		_show_help(
			game_mode in [MODE_CHALLENGE, MODE_DEEP],
			field_choice_context,
		)
	)
	var resume_action := _complete_auxiliary_modal.bind(
		field_choice_context,
		Callable(self, "_resume_after_pause"),
	)
	if not field_choice_context.is_empty():
		_modal_back_action = _close_modal.bind(resume_action)
	modal_confirm.pressed.connect(func() -> void:
		_play_click()
		_close_modal(resume_action)
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
		ModalSpec.battle(
			Vector2(580, 380),
			false,
			ModalSpec.SizeMode.FIT_CONTENT,
		).with_button_roles(
			ModalSpec.ButtonRole.DANGER,
			ModalSpec.ButtonRole.SECONDARY,
		),
	)
	var body := Label.new()
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_theme_font_size_override("font_size", 17)
	body.add_theme_color_override("font_color", DesignTokens.TEXT)
	body.text = "仍可执行：\n\n• %s\n\n结束回合后将无法执行这些动作。" % "\n• ".join(remaining)
	modal_body.add_child(body)
	modal_confirm.pressed.connect(func() -> void:
		_play_click()
		_close_modal(_execute_action_now.bind(action))
	, CONNECT_ONE_SHOT)
	modal_cancel.pressed.connect(func() -> void:
		_play_click()
		_close_modal()
	, CONNECT_ONE_SHOT)


func _resume_after_pause() -> void:
	if game_mode != MODE_NETWORK:
		_maybe_start_ai()


func _remaining_turn_action_labels() -> Array[String]:
	var result: Array[String] = []
	for row in _current_action_rows():
		var action := row.get("action") as GameAction
		if action == null or action.kind in ["END_TURN", "SETUP_DONE"]:
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
		}.get(action.kind, "执行%s" % action.kind))
		if label not in result:
			result.append(label)
	return result


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


func _show_help(
	resume_ai_on_close: bool = false,
	resume_choice_context: Dictionary = {},
) -> void:
	var field_choice_context := resume_choice_context
	if field_choice_context.is_empty():
		field_choice_context = _suspend_field_choice_for_auxiliary_modal()
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
	var resume_action := _complete_auxiliary_modal.bind(
		field_choice_context,
		(
			Callable(self, "_resume_after_pause")
			if resume_ai_on_close
			else Callable()
		),
	)
	if not field_choice_context.is_empty():
		_modal_back_action = _close_modal.bind(resume_action)
	modal_confirm.pressed.connect(func() -> void:
		_close_modal(resume_action)
	, CONNECT_ONE_SHOT)


func _show_card_inspector(
	context: Dictionary,
	return_action: Callable = Callable(),
	return_label: String = "",
	resume_choice_context: Dictionary = {},
) -> void:
	var card_id := str(context.get("card_id", ""))
	if card_id.is_empty():
		return
	var field_choice_context := resume_choice_context
	if field_choice_context.is_empty():
		field_choice_context = _suspend_field_choice_for_auxiliary_modal()
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
	panel.card_requested.connect(_show_card_inspector.bind(
		return_action,
		return_label,
		field_choice_context,
	))
	_modal_back_action = return_action
	if return_action.is_valid():
		modal_confirm.text = return_label if not return_label.is_empty() else "返回上一界面"
		modal_confirm.pressed.connect(return_action, CONNECT_ONE_SHOT)
	elif not field_choice_context.is_empty():
		var resume_action := _complete_auxiliary_modal.bind(
			field_choice_context,
			Callable(),
		)
		_modal_back_action = _close_modal.bind(resume_action)
		modal_confirm.pressed.connect(
			_close_modal.bind(resume_action),
			CONNECT_ONE_SHOT,
		)
	else:
		modal_confirm.pressed.connect(_close_modal, CONNECT_ONE_SHOT)


func _show_zone_inspector(
	context: Dictionary,
	resume_choice_context: Dictionary = {},
) -> void:
	var field_choice_context := resume_choice_context
	if field_choice_context.is_empty():
		field_choice_context = _suspend_field_choice_for_auxiliary_modal()
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
	if field_choice_context.is_empty():
		panel.card_requested.connect(_show_card_inspector)
		modal_confirm.pressed.connect(_close_modal, CONNECT_ONE_SHOT)
		return
	panel.card_requested.connect(_show_zone_card_inspector.bind(
		context.duplicate(true),
		field_choice_context,
	))
	var resume_action := _complete_auxiliary_modal.bind(
		field_choice_context,
		Callable(),
	)
	# The system-back path calls _modal_back_action directly. Close the inspector
	# first so its full-screen shade cannot keep intercepting the restored field
	# choice after the request has been re-established.
	_modal_back_action = _close_modal.bind(resume_action)
	modal_confirm.pressed.connect(
		_close_modal.bind(resume_action),
		CONNECT_ONE_SHOT,
	)


func _show_zone_card_inspector(
	card_context: Dictionary,
	zone_context: Dictionary,
	field_choice_context: Dictionary,
) -> void:
	_show_card_inspector(
		card_context,
		_show_zone_inspector.bind(zone_context, field_choice_context),
		"返回区域查看",
		field_choice_context,
	)


func _suspend_field_choice_for_auxiliary_modal() -> Dictionary:
	if active_request == null or active_choice_panel != null:
		return {}
	if _choice_field_target_options(active_request).is_empty():
		return {}
	var context := {
		"request": active_request,
		"selected_ids": selected_choice_ids.duplicate(),
	}
	active_request = null
	selected_choice_ids.clear()
	option_buttons.clear()
	if battle_screen:
		battle_screen.clear_choice_targets()
	return context


func _complete_auxiliary_modal(
	context: Dictionary,
	completion: Callable = Callable(),
) -> void:
	_resume_field_choice_after_auxiliary_modal(context)
	if completion.is_valid():
		completion.call()


func _resume_field_choice_after_auxiliary_modal(context: Dictionary) -> void:
	if context.is_empty() or current_screen != SCREEN_GAME:
		return
	var suspended_request := context.get("request") as ChoiceView
	if suspended_request == null:
		return
	var request := suspended_request
	if game_mode == MODE_NETWORK:
		if network_choice_view == null:
			_refresh_game()
			return
		request = network_choice_view
	elif (
		state != null
		and suspended_request.base_revision >= 0
		and state.revision != suspended_request.base_revision
	):
		# Local inspector modals freeze battle input, so the captured request stays
		# authoritative while the revision is unchanged. Only a resync/lifecycle
		# replacement needs another native pending-choice lookup.
		var pending_request := _query_any_pending_choice()
		if pending_request == null:
			_refresh_game()
			return
		request = pending_request
	if request.request_id != suspended_request.request_id:
		# A network resync may replace the request while an inspector is open. Route
		# the current authoritative request instead of reviving a stale ChoiceView.
		_route_step_pending_choice(StepResult.new(true, "", request))
		return
	_show_choice_overlay(request)
	var valid_option_ids: Dictionary = {}
	for option in request.options:
		valid_option_ids[str(option.get("option_id", ""))] = true
	var restored_ids: Array[String] = []
	for value in context.get("selected_ids", []):
		var option_id := str(value)
		if (
			not valid_option_ids.has(option_id)
			or (not request.allow_duplicates and option_id in restored_ids)
			or restored_ids.size() >= request.max_select
		):
			continue
		restored_ids.append(option_id)
	selected_choice_ids.assign(restored_ids)
	_refresh_choice_buttons()


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


func _show_settings(resume_choice_context: Dictionary = {}) -> void:
	var field_choice_context := resume_choice_context
	if field_choice_context.is_empty():
		field_choice_context = _suspend_field_choice_for_auxiliary_modal()
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
	panel.save_requested.connect(_save_settings_values.bind(field_choice_context))
	# Keep the save action connected while the modal remains open so a transient
	# filesystem failure can be corrected and retried without reopening Settings.
	modal_confirm.pressed.connect(panel.request_save)
	var resume_action := _complete_auxiliary_modal.bind(
		field_choice_context,
		Callable(),
	)
	if not field_choice_context.is_empty():
		_modal_back_action = _close_modal.bind(resume_action)
	modal_cancel.pressed.connect(
		_close_modal.bind(resume_action),
		CONNECT_ONE_SHOT,
	)


func _save_settings_values(
	values: Dictionary,
	resume_choice_context: Dictionary = {},
) -> void:
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
	_close_modal(_complete_auxiliary_modal.bind(
		resume_choice_context,
		Callable(),
	))
	Engine.max_fps = AppSettings.target_fps()
	_show_toast("设置已保存。")


func _show_end_screen() -> void:
	if state == null or not state.is_terminal():
		return
	if current_screen == SCREEN_END:
		return
	current_screen = SCREEN_END
	if modal_layer.visible:
		_close_modal()
	battle_screen = null
	var victory := _mount_screen(VICTORY_SCENE) as VictoryScreen
	var is_draw := state.result_status == GameState.RESULT_DRAW
	var winner_player: PlayerState = (
		null if is_draw else state.get_player(state.winner))
	var winner_card_id := (
		winner_player.active.card_id
		if winner_player != null and winner_player.active
		else ""
	)
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
		winner_player.name if winner_player != null else "",
		winner_card_id,
		{
			"mode": game_mode,
			"mode_label": mode_label,
			"winner_deck": winner_deck_key,
			"winner_deck_name": winner_deck.get("name", winner_deck_key),
			"winner_card_name": catalog.card_name(winner_card_id),
			"result_status": state.result_status,
			"result_reason": state.result_reason,
			"result_conditions": state.result_conditions.duplicate(true),
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
	if battle_screen and battle_screen.hud is BattlePhaseHud:
		(battle_screen.hud as BattlePhaseHud).close_log_drawer()
	_clear_battle_selection("", false)
	# Refresh even if Main already considers the key empty: a modal is a hard
	# interaction boundary and must also reconcile any stale Table highlight.
	if current_screen == SCREEN_GAME and state:
		_refresh_game()
	if modal_scroll:
		modal_scroll.custom_minimum_size = Vector2(
			modal_scroll.custom_minimum_size.x,
			0.0,
		)
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
	_modal_closing = false
	_modal_close_completion = Callable()
	_modal_close_completion_generation = -1
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
	modal_confirm.theme_type_variation = _modal_button_variation(
		resolved_spec.surface,
		resolved_spec.confirm_role,
	)
	modal_cancel.text = cancel_text
	modal_cancel.disabled = false
	modal_cancel.visible = resolved_spec.cancellable and not cancel_text.is_empty()
	modal_cancel.theme_type_variation = _modal_button_variation(
		resolved_spec.surface,
		resolved_spec.cancel_role,
	)
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


func _modal_button_variation(surface: int, role: int) -> StringName:
	if role == ModalSpec.ButtonRole.DEFAULT:
		return &""
	if surface == ModalSpec.Surface.FRONTEND:
		return {
			ModalSpec.ButtonRole.PRIMARY: &"FrontPrimaryButton",
			ModalSpec.ButtonRole.SECONDARY: &"FrontSecondaryButton",
			ModalSpec.ButtonRole.DANGER: &"FrontDangerButton",
		}.get(role, &"")
	return {
		ModalSpec.ButtonRole.PRIMARY: &"BattlePrimaryButton",
		ModalSpec.ButtonRole.SECONDARY: &"BattleSecondaryButton",
		ModalSpec.ButtonRole.DANGER: &"BattleDangerButton",
	}.get(role, &"")


func _close_modal(completion: Callable = Callable()) -> void:
	# A close animation is an in-flight transaction. Android back, a second
	# button signal or a delayed callback must not replace the completion that
	# submits/cancels the authoritative action.
	if _modal_closing:
		return
	_modal_closing = true
	_modal_generation += 1
	var close_generation := _modal_generation
	_modal_close_completion = completion
	_modal_close_completion_generation = close_generation
	active_request = null
	active_choice_panel = null
	selected_choice_ids.clear()
	option_buttons.clear()
	_modal_back_action = Callable()
	if modal_confirm:
		modal_confirm.disabled = true
	if modal_cancel:
		modal_cancel.disabled = true
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
	if generation != _modal_generation or not _modal_closing:
		return
	_modal_closing = false
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
	var completion := Callable()
	if _modal_close_completion_generation == generation:
		completion = _modal_close_completion
	_modal_close_completion = Callable()
	_modal_close_completion_generation = -1
	if completion.is_valid():
		completion.call()


func _select_hand_card(index: int, card_id: String) -> void:
	_play_click()
	var key := "hand:%d" % index
	if selected_entity_key == key:
		selected_entity_key = ""
		selected_entity_identity = ""
	else:
		selected_entity_key = key
		selected_entity_identity = _entity_identity_for_key(key)
	# Synchronize the authoritative key into BattleTable before asking it to
	# position the detail surface. Otherwise the first layout frame can still be
	# anchored to the previous card (or no source at all).
	_refresh_game()
	if battle_screen:
		if selected_entity_key.is_empty():
			battle_screen.hide_card_detail()
		else:
			battle_screen.show_card_detail(card_id)


func _on_selection_clear_requested(expected_key: String) -> void:
	_clear_battle_selection(expected_key)


func _clear_battle_selection(
	expected_key: String = "",
	refresh_view: bool = true,
) -> bool:
	if not expected_key.is_empty() and expected_key != selected_entity_key:
		# Table may already have dismissed its local popover for this stale event.
		# Re-apply Main's authoritative selection without clearing the newer key.
		if refresh_view and current_screen == SCREEN_GAME and state:
			_refresh_game()
		return false
	var changed := not selected_entity_key.is_empty()
	selected_entity_key = ""
	selected_entity_identity = ""
	if battle_screen:
		battle_screen.hide_card_detail()
	if refresh_view and current_screen == SCREEN_GAME and state:
		_refresh_game()
	return changed


func _selected_entity_is_valid(key: String) -> bool:
	if key.is_empty():
		return true
	var current_identity := _entity_identity_for_key(key)
	if current_identity.is_empty():
		return false
	return (
		selected_entity_identity.is_empty()
		or selected_entity_identity == current_identity
	)


func _entity_identity_for_key(key: String) -> String:
	if state == null or key.is_empty():
		return ""
	if key.begins_with("hand:"):
		var index_text := key.trim_prefix("hand:")
		if not index_text.is_valid_int() or current_view_player not in [0, 1]:
			return ""
		var hand_index := index_text.to_int()
		var hand := state.get_player(current_view_player).hand
		if hand_index < 0 or hand_index >= hand.size():
			return ""
		return "hand:%d:%d:%s" % [
			current_view_player,
			hand_index,
			str(hand[hand_index]),
		]
	if key.begins_with("pokemon:"):
		var parts := key.split(":")
		if parts.size() != 3 or not str(parts[1]).is_valid_int():
			return ""
		var player_idx := int(parts[1])
		if player_idx not in [0, 1]:
			return ""
		var slot_name := str(parts[2])
		var pokemon := state.get_player(player_idx).get_pokemon(slot_name)
		if pokemon == null:
			return ""
		return "pokemon:%d:%s:%s" % [player_idx, slot_name, pokemon.card_id]
	if key == "stadium":
		return (
			"stadium:%s" % state.stadium_card_id
			if not state.stadium_card_id.is_empty()
			else ""
		)
	return ""


func _select_pokemon(player_idx: int, slot: String, card_id: String) -> void:
	_play_click()
	var key := "pokemon:%d:%s" % [player_idx, slot]
	if selected_entity_key == key:
		selected_entity_key = ""
		selected_entity_identity = ""
	else:
		selected_entity_key = key
		selected_entity_identity = _entity_identity_for_key(key)
	_refresh_game()
	if battle_screen:
		if selected_entity_key.is_empty():
			battle_screen.hide_card_detail()
		else:
			battle_screen.show_card_detail(
				card_id,
				state.get_player(player_idx).get_pokemon(slot) if state else null,
			)


func _player_name_for_context(player_idx: int) -> String:
	if player_idx < 0 or state == null:
		return ""
	return state.get_player(player_idx).name


func _action_label(action: GameAction) -> String:
	match action.kind:
		"PLAY_BASIC":
			return "上场 · %s → %s" % [
				_source_card_name(action), _slot_name(str(action.target_slot()))]
		"EVOLVE":
			return "进化 · %s → %s" % [
				_source_card_name(action), _slot_name(str(action.primary_slot()))]
		"ATTACH_ENERGY":
			return "附能 · %s → %s" % [
				_source_card_name(action), _slot_name(str(action.target_slot()))]
		"PLAY_TRAINER":
			var target := str(action.target_slot())
			return "使用 · %s%s" % [
				_source_card_name(action),
				" → %s" % _slot_name(target) if not target.is_empty() else "",
			]
		"USE_ABILITY":
			return "特性 · %s · %s" % [
				action.ability_name(),
				_slot_name(str(action.primary_slot())),
			]
		"USE_STADIUM":
			return "发动竞技场"
		"RETREAT":
			return "撤退 → 备战区 %d%s" % [
				action.bench_index(0) + 1,
				_retreat_energy_suffix(action),
			]
		"DECLARE_ATTACK":
			var active := state.get_player(action.actor).active
			var attacks: Array = catalog.get_card(active.card_id).get("attacks", []) if active else []
			var attack_idx := action.attack_index(0)
			var attack_name := "招式 %d" % (attack_idx + 1)
			if attack_idx >= 0 and attack_idx < attacks.size():
				attack_name = str(attacks[attack_idx].get("name", attack_name))
			return "攻击 · %s" % attack_name
		"END_TURN":
			return "结束回合"
		"SETUP_DONE":
			return "完成准备"
		"PROMOTE":
			return "晋升 · 备战区 %d" % (action.bench_index(0) + 1)
		_:
			return action.kind


func _source_card_name(action: GameAction) -> String:
	if action.source:
		return catalog.card_name(action.source.card_id)
	var hand_idx := action.hand_index()
	var player := state.get_player(action.actor)
	if hand_idx >= 0 and hand_idx < player.hand.size():
		return catalog.card_name(player.hand[hand_idx])
	return "卡牌"


func _choice_title(request: ChoiceView) -> String:
	var presentation := _choice_presentation(request)
	var purpose := str(presentation.get("purpose", ""))
	if purpose in ["discard_hand_then_draw", "discard_cards", "zinnia"]:
		return "选择要弃置的手牌"
	if purpose in ["discard_energy", "discard_energy_attachments", "discard_attachment"]:
		return "选择要弃置的附着能量"
	if purpose in ["energy_relocate_attachments", "relocate_energy_attachments"]:
		return "选择要转附的能量"
	if purpose in ["energy_relocate_target", "relocate_energy_target"]:
		return "选择能量转附目标"
	return {
		"coin_flip": "硬币结算",
		"choose_turn_order": "选择先后攻",
		"choose_mulligan_draw_count": "选择再战奖励抽牌数",
		"select_prize": "选择奖赏卡",
		"choose_trigger_order": "选择效果结算顺序",
		"confirm_trigger": "确认是否使用效果",
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
		"select_retreat_payment": "支付撤退费用",
		"evolve_skip_stage": "选择进化目标",
		"select_heal_target": "选择回复目标",
		"damage_target": "选择伤害目标",
		"bench_damage_target": "选择备战区伤害目标",
		"place_counters_self_discard": "选择伤害指示物目标",
		"select_bench": "选择替换上场的宝可梦",
		"select_opponent_bench": "选择对手替换上场的宝可梦",
	}.get(
		request.request_type,
		"选择卡牌" if _choice_view_has_card_options(request) else "选择",
	)


func _choice_metadata_text(request: ChoiceView) -> String:
	var presentation := _choice_presentation(request)
	if request.request_type == "coin_flip":
		var results: Array = presentation.get("predetermined_flips", [])
		var labels: Array[String] = []
		for result in results:
			labels.append("正面" if bool(result) else "反面")
		return "结果：" + "、".join(labels)
	if request.request_type == "select_retreat_payment":
		var required_units := int(presentation.get("required_units", 0))
		return (
			"需要支付 %d 点撤退费用。请选择要丢弃的附着能量；特殊能量按实际提供点数计算，界面不会允许多丢弃。"
			% required_units
		)
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
		if bool(presentation.get("same_target", false)):
			distribution_lines.append("所有能量必须分配到同一目标。")
		var max_per_target := int(presentation.get("max_per_target", 99))
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


func _choice_view_has_card_options(request: ChoiceView) -> bool:
	if request == null:
		return false
	for option_value in request.options:
		if not _choice_option_card_id(Dictionary(option_value)).is_empty():
			return true
	return false


func _choice_count_unit(request: ChoiceView) -> String:
	if request.request_type == "select_prize":
		return "张奖赏卡"
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
		"place_counters_self_discard",
		"select_bench",
		"select_opponent_bench",
	]:
		return "个目标"
	return "张卡牌" if _choice_view_has_card_options(request) else "项"


func _current_actor() -> int:
	if state == null:
		return 0
	if not state.pending_promotions.is_empty():
		return int(state.pending_promotions[0])
	if state.phase == "SETUP":
		return state.setup_actor_idx
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
	if _defer_ai_until_presentation_idle():
		return
	_pending_ai_resume_revision = -1
	var query := _rules_legal_actions(1)
	if not query.success:
		_show_toast("AI 合法动作查询失败：%s" % query.code, true)
		return
	var actions := query.concrete_actions()
	if actions.is_empty():
		_show_toast("AI 没有合法动作。", true)
		return
	var rows: Array = []
	for action in actions:
		rows.append(action.to_dict())
	ai_request_sequence += 1
	active_ai_request_id = "ai:%d:%d" % [state.revision, ai_request_sequence]
	var request := {
		"kind": "action",
		"engine": NativeChallengeAI.TRADITIONAL_ENGINE_ID,
		"state": _ai_state_snapshot(1),
		"actor": 1,
		"revision": state.revision,
		"request_id": active_ai_request_id,
		"mode": game_mode,
		"deck_key": ai_deck_key,
		"match_seed": last_match_seed,
		"match_instance_id": ai_match_instance_id,
		"seed": AIDecisionSeed.derive(
			last_match_seed,
			state.revision,
			1,
			"action",
			active_ai_request_id,
		),
		"actions": rows,
	}
	ai_thinking = ai_coordinator.start_request(request, ai_inference)
	_refresh_process_state()
	if not ai_thinking:
		_apply_ai_fallback_action(
			"无法启动 AI 后台线程（%s）。" % ai_coordinator.last_start_error)
		return
	_refresh_game()


func _schedule_ai_choice(request: ChoiceView) -> void:
	if state == null or game_mode == MODE_LOCAL or ai_thinking:
		return
	if _defer_ai_until_presentation_idle():
		return
	_pending_ai_resume_revision = -1
	ai_request_sequence += 1
	active_ai_request_id = "ai-choice:%d:%d" % [state.revision, ai_request_sequence]
	var payload := {
		"kind": "choice",
		"engine": NativeChallengeAI.TRADITIONAL_ENGINE_ID,
		"state": _ai_state_snapshot(1),
		"choice": request.to_dict(),
		"actor": 1,
		"revision": state.revision,
		"request_id": active_ai_request_id,
		"mode": game_mode,
		"deck_key": ai_deck_key,
		"match_seed": last_match_seed,
		"match_instance_id": ai_match_instance_id,
		"seed": AIDecisionSeed.derive(
			last_match_seed,
			state.revision,
			1,
			request.request_type,
			active_ai_request_id,
		),
	}
	ai_thinking = ai_coordinator.start_request(payload, ai_inference)
	_refresh_process_state()
	if not ai_thinking:
		_apply_ai_fallback_choice(
			request,
			"无法启动 AI 选择线程（%s）。" % ai_coordinator.last_start_error,
		)
		return
	_refresh_game()


func _ai_state_snapshot(player_idx: int) -> Dictionary:
	return RuntimeStateProjection.project(state, player_idx)


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
		var pending_on_failure := _rules_pending_choice(1)
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
	var step: StepResult
	var origin_action_id := ""
	var origin_request_id := ""
	if str(result.get("kind", "")) == "choice":
		var stack_request := _rules_pending_choice(1)
		if stack_request == null:
			_maybe_start_ai()
			return
		var response := ChoiceResponse.from_dict(result["choice_response"])
		if response.request_id != stack_request.request_id:
			_maybe_start_ai()
			return
		step = _rules_apply_choice(response)
		origin_request_id = response.request_id
	else:
		var action := GameAction.from_dict(result["action"])
		ai_request_sequence += 1
		action.action_id = "ai-action:%d:%d" % [state.revision, ai_request_sequence]
		origin_action_id = action.action_id
		step = _rules_apply_action(action)
	if not step.success:
		var pending_after_reject := _rules_pending_choice(1)
		if pending_after_reject != null and pending_after_reject.player == 1:
			_apply_ai_fallback_choice(
				pending_after_reject,
				"AI 选择被规则拒绝：%s" % step.message,
			)
		else:
			_apply_ai_fallback_action("AI 动作被规则拒绝：%s" % step.message)
		return
	_show_toast(step.message if not step.message.is_empty() else "AI 完成动作。")
	var handle := _submit_battle_transition(
		step.events,
		1,
		BattleTransitionRequest.CAUSE_AI_ACTION,
		origin_action_id,
		origin_request_id,
	)
	_continue_when_presented(
		handle,
		state.revision,
		_continue_after_ai_step.bind(step, previous_active, previous_phase),
	)


func _apply_ai_fallback_action(reason: String) -> void:
	if state == null or current_screen != SCREEN_GAME or _current_actor() != 1:
		return
	ai_emergency_fallback_count += 1
	var query := _rules_legal_actions(1)
	if not query.success:
		_show_toast("%s 合法动作查询失败：%s" % [reason, query.code], true)
		_refresh_game()
		return
	var actions := query.concrete_actions()
	if actions.is_empty():
		_show_toast("%s AI 没有合法动作。" % reason, true)
		_refresh_game()
		return
	for action in _ordered_ai_fallback_actions(actions):
		var previous_active := state.active_player_idx
		var previous_phase := state.phase
		ai_request_sequence += 1
		action.action_id = "ai-fallback:%d:%d" % [state.revision, ai_request_sequence]
		var step := _rules_apply_action(action)
		if not step.success:
			continue
		var message := step.message if not step.message.is_empty() else "AI 完成兜底动作。"
		_show_toast("%s %s" % [reason, message], true)
		var handle := _submit_battle_transition(
			step.events,
			1,
			BattleTransitionRequest.CAUSE_AI_ACTION,
			action.action_id,
		)
		_continue_when_presented(
			handle,
			state.revision,
			_continue_after_ai_step.bind(step, previous_active, previous_phase),
		)
		return
	_show_toast("%s AI 兜底动作全部被规则拒绝。" % reason, true)
	_refresh_game()


func _ordered_ai_fallback_actions(actions: Array[GameAction]) -> Array[GameAction]:
	return NativeChallengeAI.ordered_tactical_fallback_actions(
		state, 1, actions, ai_deck_key, catalog)


func _apply_ai_fallback_choice(request: ChoiceView, reason: String) -> void:
	if state == null or current_screen != SCREEN_GAME:
		return
	ai_emergency_fallback_count += 1
	var response := _fallback_choice_response(request)
	var previous_active := state.active_player_idx
	var previous_phase := state.phase
	var step := _rules_apply_choice(response)
	if not step.success:
		_show_toast("%s AI 兜底选择被规则拒绝：%s" % [reason, step.message], true)
		_refresh_game()
		return
	var message := step.message if not step.message.is_empty() else "AI 完成兜底选择。"
	_show_toast("%s %s" % [reason, message], true)
	var handle := _submit_battle_transition(
		step.events,
		request.player,
		BattleTransitionRequest.CAUSE_CHOICE,
		"",
		request.request_id,
	)
	_continue_when_presented(
		handle,
		state.revision,
		_continue_after_ai_step.bind(step, previous_active, previous_phase),
	)


func _fallback_choice_response(request: ChoiceView) -> ChoiceResponse:
	if request.options.is_empty():
		return ChoiceResponse.new(request.request_id, [], request.can_cancel)
	if request.request_type == "select_retreat_payment":
		return NativeChallengeAI.retreat_payment_response(state, request, catalog)
	if request.request_type == "choose_turn_order":
		return ChoiceResponse.new(request.request_id, ["turn:first"])
	if request.request_type == "choose_mulligan_draw_count":
		return ChoiceResponse.new(
			request.request_id,
			["draw:%d" % maxi(0, request.options.size() - 1)],
		)
	if request.request_type == "select_prize":
		return ChoiceResponse.new(request.request_id, ["prize:0"])
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
	if state.is_terminal():
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
		var pending := _step_pending_choice(null)
		if pending != null and pending.player == 1:
			_schedule_ai_choice(pending)
		else:
			_schedule_ai_action()


func _defer_ai_until_presentation_idle() -> bool:
	if (
		battle_screen == null
		or not is_instance_valid(battle_screen)
		or not battle_screen.is_presentation_busy()
	):
		return false
	_pending_ai_resume_revision = state.revision if state != null else -1
	var callback := Callable(self, "_on_ai_presentation_busy_changed")
	if not battle_screen.presentation_busy_changed.is_connected(callback):
		battle_screen.presentation_busy_changed.connect(callback)
	return true


func _on_ai_presentation_busy_changed(busy: bool) -> void:
	if busy or _pending_ai_resume_revision < 0:
		return
	var expected_revision := _pending_ai_resume_revision
	_pending_ai_resume_revision = -1
	call_deferred("_resume_ai_after_presentation", expected_revision)


func _resume_ai_after_presentation(expected_revision: int) -> void:
	if (
		state == null
		or state.revision != expected_revision
		or current_screen != SCREEN_GAME
		or game_mode == MODE_LOCAL
		or _current_actor() != 1
		or (modal_layer != null and modal_layer.visible)
	):
		return
	_maybe_start_ai()


func _stop_ai() -> void:
	ai_coordinator.cancel_request()
	_pending_ai_runtime_unload = true
	_finalize_ai_runtime_unload_if_idle()
	ai_thinking = false
	active_ai_request_id = ""
	_pending_ai_resume_revision = -1
	_refresh_process_state()


func _finalize_ai_runtime_unload_if_idle() -> void:
	if not _pending_ai_runtime_unload or ai_coordinator.needs_poll():
		return
	deep_runtime.unload()
	ai_inference = null
	_pending_ai_runtime_unload = false


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
	# The battle header finishes its container layout at the end of the frame.
	# Re-evaluate once so a toast shown while entering battle uses the final header gap.
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


func _clear_screen() -> void:
	_startup_choreography_generation += 1
	_startup_choreography_running = false
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


func _configure_responsive_canvas() -> void:
	var window := get_window()
	if window == null:
		return
	if _responsive_canvas_window == null:
		_responsive_canvas_window = window
		_original_content_scale_size = window.content_scale_size
	if not window.size_changed.is_connected(_on_responsive_window_size_changed):
		window.size_changed.connect(_on_responsive_window_size_changed)
	_apply_responsive_canvas()


func _apply_responsive_canvas() -> void:
	var window := get_window()
	if window == null:
		return
	var target := _responsive_content_scale_size(
		window.size,
		DESIGN_CANVAS_SIZE,
	)
	if target.x <= 0 or target.y <= 0:
		return
	if window.content_scale_size != target:
		window.content_scale_size = target
	_last_responsive_content_scale_size = target


func _restore_responsive_canvas() -> void:
	if (
		_responsive_canvas_window == null
		or not is_instance_valid(_responsive_canvas_window)
		or _original_content_scale_size.x <= 0
		or _original_content_scale_size.y <= 0
	):
		return
	# Tests and editor previews can mount Main transiently. Only restore a value
	# still owned by this instance so another live shell cannot be overwritten.
	if (
		_last_responsive_content_scale_size != Vector2i.ZERO
		and _responsive_canvas_window.content_scale_size
		== _last_responsive_content_scale_size
	):
		_responsive_canvas_window.content_scale_size = _original_content_scale_size
	if _responsive_canvas_window.size_changed.is_connected(
		_on_responsive_window_size_changed
	):
		_responsive_canvas_window.size_changed.disconnect(
			_on_responsive_window_size_changed
		)
	_responsive_canvas_window = null


func _on_responsive_window_size_changed() -> void:
	_apply_responsive_canvas()
	# content_scale_size changes the logical Control tree in the same frame. Safe
	# insets and modal budgets must be recomputed after that resize has propagated.
	call_deferred("_apply_safe_area")


func _responsive_content_scale_size(
	window_size: Vector2i,
	design_size: Vector2i = DESIGN_CANVAS_SIZE,
) -> Vector2i:
	if (
		window_size.x <= 0
		or window_size.y <= 0
		or design_size.x <= 0
		or design_size.y <= 0
	):
		return design_size
	# Script-only headless contracts use a synthetic 64×64 root. It is not a
	# supported display and must retain the design canvas so UI can be inspected.
	if (
		window_size.x < MIN_RESPONSIVE_WINDOW_SIZE.x
		or window_size.y < MIN_RESPONSIVE_WINDOW_SIZE.y
	):
		return design_size
	var fit_scale := minf(
		float(window_size.x) / float(design_size.x),
		float(window_size.y) / float(design_size.y),
	)
	# canvas_items is retained for ultrawide/large displays, but it must never
	# downsample the UI below 1 physical pixel per logical pixel. Besides keeping
	# 48 px targets touchable, this lets compact pages observe their real space.
	return window_size if fit_scale < 1.0 else design_size


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
		# The log is now a drawer layered over the right edge of the table. Anchoring
		# battle feedback to that legacy panel puts confirmations over the deck and
		# discard zones even while the drawer is closed. Use the reserved header gap
		# between the menu and phase status instead; it remains outside card play.
		var menu_button := (
			battle_screen.header.menu_button as Control
			if battle_screen.header
			else null
		)
		var turn_status := (
			battle_screen.header.turn_label as Control
			if battle_screen.header
			else null
		)
		if menu_button and turn_status:
			var menu_rect := menu_button.get_global_rect()
			var status_rect := turn_status.get_global_rect()
			var gap_left := menu_rect.end.x + 12.0
			var gap_right := status_rect.position.x - 12.0
			var gap_width := gap_right - gap_left
			if gap_width >= 180.0:
				var battle_width := minf(300.0, gap_width)
				var battle_height := _toast_content_height(battle_width, 44.0, 52.0)
				var header_rect := Rect2(
					Vector2(
						gap_left + (gap_width - battle_width) * 0.5,
						menu_rect.get_center().y - battle_height * 0.5,
					),
					Vector2(battle_width, battle_height),
				)
				# This is a scene-reserved header lane and is already outside the
				# tabletop. Preserve its exact coordinates; compact layouts without
				# this lane use the obstacle-aware fallback below.
				toast_label.position = header_rect.position - global_position
				toast_label.size = header_rect.size
				return
		# On compact layouts the header has no 180 px gap. Keep the toast out of
		# the fanned opponent hand instead of falling back to the screen centre,
		# where it can cover the card backs at 900x540.
		var battle_safe_rect := _battle_toast_safe_rect(
			logical_size, left, top, right, bottom)
		var compact_width := minf(360.0, battle_safe_rect.size.x)
		var compact_height := _toast_content_height(compact_width, 44.0, 64.0)
		_apply_battle_toast_rect(
			Rect2(
				Vector2(
					battle_safe_rect.get_center().x - compact_width * 0.5,
					battle_safe_rect.position.y + 4.0,
				),
				Vector2(compact_width, compact_height),
			),
			battle_safe_rect,
		)
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


func _battle_toast_safe_rect(
	logical_size: Vector2,
	left: int,
	top: int,
	right: int,
	bottom: int,
) -> Rect2:
	var origin := global_position + Vector2(left + 12, top + 8)
	return Rect2(
		origin,
		Vector2(
			maxf(1.0, logical_size.x - left - right - 24.0),
			maxf(1.0, logical_size.y - top - bottom - 16.0),
		),
	)


func _apply_battle_toast_rect(preferred: Rect2, safe_rect: Rect2) -> void:
	var resolved := _clamp_rect_to_rect(preferred, safe_rect)
	var opponent_hand_rect := _opponent_hand_visual_rect()
	if (
		opponent_hand_rect.size.x > 1.0
		and opponent_hand_rect.size.y > 1.0
		and resolved.intersects(opponent_hand_rect)
	):
		resolved = _toast_rect_outside_obstacle(resolved, opponent_hand_rect, safe_rect)
	toast_label.position = resolved.position - global_position
	toast_label.size = resolved.size


func _opponent_hand_visual_rect() -> Rect2:
	if battle_screen == null or not is_instance_valid(battle_screen):
		return Rect2()
	var controls: Array[Control] = []
	if battle_screen.opponent_hand_surface:
		controls.append(battle_screen.opponent_hand_surface)
	for view_value in battle_screen.opponent_hand_views:
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


func _toast_rect_outside_obstacle(
	preferred: Rect2,
	obstacle: Rect2,
	safe_rect: Rect2,
) -> Rect2:
	const GAP := 10.0
	var candidates: Array[Rect2] = []
	var above := Rect2(
		Vector2(preferred.position.x, obstacle.position.y - GAP - preferred.size.y),
		preferred.size,
	)
	if safe_rect.encloses(above):
		candidates.append(above)
	var left_width := obstacle.position.x - GAP - safe_rect.position.x
	var right_width := safe_rect.end.x - obstacle.end.x - GAP
	var add_side := func(on_right: bool, available_width: float) -> void:
		if available_width < 180.0:
			return
		var width := minf(preferred.size.x, available_width)
		var x := obstacle.end.x + GAP if on_right else obstacle.position.x - GAP - width
		var y := clampf(
			preferred.position.y,
			safe_rect.position.y,
			maxf(safe_rect.position.y, safe_rect.end.y - preferred.size.y),
		)
		candidates.append(Rect2(Vector2(x, y), Vector2(width, preferred.size.y)))
	if right_width >= left_width:
		add_side.call(true, right_width)
		add_side.call(false, left_width)
	else:
		add_side.call(false, left_width)
		add_side.call(true, right_width)
	var below := Rect2(
		Vector2(preferred.position.x, obstacle.end.y + GAP),
		preferred.size,
	)
	below = _clamp_rect_to_rect(below, safe_rect)
	if not below.intersects(obstacle):
		candidates.append(below)
	for candidate in candidates:
		var fitted := _clamp_rect_to_rect(candidate, safe_rect)
		if not fitted.intersects(obstacle):
			return fitted
	return _clamp_rect_to_rect(preferred, safe_rect)


func _clamp_rect_to_rect(rect: Rect2, bounds: Rect2) -> Rect2:
	var fitted := rect
	fitted.size.x = minf(fitted.size.x, bounds.size.x)
	fitted.size.y = minf(fitted.size.y, bounds.size.y)
	fitted.position.x = clampf(
		fitted.position.x,
		bounds.position.x,
		maxf(bounds.position.x, bounds.end.x - fitted.size.x),
	)
	fitted.position.y = clampf(
		fitted.position.y,
		bounds.position.y,
		maxf(bounds.position.y, bounds.end.y - fitted.size.y),
	)
	return fitted


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
		CardTextureCache.clear()
		if game_mode in [MODE_CHALLENGE, MODE_DEEP]:
			if battle_screen:
				battle_screen.clear_presentation_for_resync()
			ai_coordinator.cancel_request()
			ai_thinking = false
			_refresh_process_state()
		elif (
			game_mode == MODE_NETWORK
			and state != null
			and current_screen in [SCREEN_GAME, SCREEN_END]
		):
			lifecycle_network_interrupted = true
			_network_recovery_phase = "reconnecting"
			if battle_screen:
				battle_screen.cancel_presentations("application_paused")
				battle_screen.set_recovery_blocked(true)
			network_controller.begin_reconnect("application_paused")
			_refresh_process_state()
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		if lifecycle_network_interrupted:
			lifecycle_network_interrupted = false
			if not network_controller.reconnecting:
				network_controller.begin_reconnect("application_resumed")
			_show_toast("正在恢复联机对局…")
			_refresh_process_state()
		elif game_mode in [MODE_CHALLENGE, MODE_DEEP]:
			_maybe_start_ai()
	elif what == NOTIFICATION_OS_MEMORY_WARNING:
		CardTextureCache.clear()
		_show_toast("系统内存紧张，已释放卡图缓存。")
	elif what == NOTIFICATION_WM_SIZE_CHANGED:
		_apply_responsive_canvas()
		_apply_safe_area()
	elif what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if modal_layer and modal_layer.visible:
			if _modal_closing:
				return
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
				_close_modal(
					Callable(self, "_resume_after_pause")
					if game_mode in [MODE_CHALLENGE, MODE_DEEP]
					else Callable()
				)
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
	set_process(
		ai_thinking
		or ai_coordinator.needs_poll()
		or network_controller.needs_poll()
	)


func _free_children_immediate(parent: Node) -> void:
	for child in parent.get_children():
		parent.remove_child(child)
		child.free()


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
		"prizes": "奖赏卡区",
		"lost_zone": "放逐区",
	}.get(zone, zone)

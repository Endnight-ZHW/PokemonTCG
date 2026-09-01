extends Control

const ChoiceSelectionModelScript = preload(
	"res://scenes/main/choice_selection_model.gd"
)

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
const NETWORK_GRACEFUL_CLOSE_TIMEOUT_MSEC := 2000
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
const MODE_NETWORK := "network"
const MODAL_SHADE_ALPHA := 0.72
const MODAL_SHADE_OPAQUE_ALPHA := 1.0
const TOAST_Z_INDEX := 350
const DESIGN_CANVAS_SIZE := Vector2i(1600, 900)
const MIN_RESPONSIVE_LANDSCAPE_SIZE := Vector2i(900, 540)
const MIN_RESPONSIVE_PORTRAIT_SIZE := Vector2i(640, 960)
const SYNTHETIC_WINDOW_FLOOR := Vector2i(320, 240)
const MAX_AI_PUBLIC_HISTORY := 4096

var catalog: CardCatalog = CardDatabase.catalog
var native_rules := NativeRulesSessionAdapter.new(catalog)
var choice_model = ChoiceSelectionModelScript.new()
var state: GameState
var rng := PortableRandomSource.new(1)
var last_match_seed := 0

var current_screen := SCREEN_TITLE
var current_view_player := 0
var action_sequence := 0
var selected_entity_key := ""
var selected_entity_identity := ""
var selected_choice_ids: Array[String]:
	get:
		return choice_model.selected_ids
	set(value):
		choice_model.replace(value)
var option_buttons: Array[Button] = []
var game_mode := MODE_LOCAL
var ai_deck_key := ""
var ai_thinking := false
var ai_request_sequence := 0
var active_ai_request_id := ""
var ai_match_generation := 0
var ai_match_instance_id := ""
var ai_public_history: Array[Dictionary] = []
var ai_coordinator := AICoordinator.new()
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
var shell_view: Variant
var modal_host_controller: ModalHost
var current_network_page: NetworkLobbyPage

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
var _presented_coin_request_ids: Dictionary = {}
var _pending_ai_resume_revision := -1
var _startup_choreography_generation := 0
var _startup_choreography_running := false

func _ready() -> void:
	set_process(false)
	shell_view = get_node_or_null("ShellView")
	shell_view.configure(self)
	choice_model.bind_owner(self)
	shell_view.configure_responsive_canvas()
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
	if ai_coordinator.needs_poll():
		var result := ai_coordinator.poll_result()
		if ai_thinking and not result.is_empty():
			_apply_ai_result(result)
	_refresh_process_state()

func _exit_tree() -> void:
	_stop_ai()
	_stop_network()
	if shell_view:
		shell_view.restore_responsive_canvas()

func initialize_ui() -> void:
	if ui_initialized:
		return
	if shell_view == null:
		shell_view = get_node_or_null("ShellView")
	if shell_view == null:
		push_error("MainShellView is missing from main.tscn")
		return
	shell_view.configure(self)
	choice_model.bind_owner(self)
	shell_view.configure_responsive_canvas()
	ui_initialized = true
	click_stream = UISound.make_tone(620.0, 0.055, 0.12)
	success_stream = UISound.make_tone(880.0, 0.11, 0.14)
	_build_shell()
	if not AppSettings.changed.is_connected(_apply_runtime_settings):
		AppSettings.changed.connect(_apply_runtime_settings)
	_apply_runtime_settings()
	shell_view.show_title()
	shell_view.apply_safe_area()
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
	shell_view.configure(self)
	modal_host_controller = modal_layer as ModalHost
	modal_host_controller.configure(self)
	modal_layer.z_index = 400
	loading_layer.z_index = 500

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
					shell_view.show_toast("收到的联机局面无效，正在请求重新同步。", true)
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
				shell_view.show_toast(message, true)
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
				shell_view.show_toast("连接中断，正在尝试恢复对局…", true)
			"reconnected":
				_network_recovery_phase = "resync"
				if current_screen == SCREEN_GAME and battle_screen != null:
					battle_screen.set_recovery_blocked(true)
					_refresh_game()
				shell_view.show_toast("连接已恢复，正在同步局面…")
			"disconnected":
				_handle_network_disconnected(str(event.get("reason", "")))
			"pending_timeout":
				# Preserve the request tombstone until the matching recovery state or
				# error arrives; otherwise its public coin event is played twice.
				_prune_coin_presentation_tombstones()
				shell_view.show_toast("动作确认超时，正在重新同步局面。", true)
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
		shell_view.show_toast(message, true)
	elif was_game:
		shell_view.show_toast("对手已断开连接，对局结束。", true)
		state = null
		shell_view.show_title()

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
		shell_view.show_toast("收到的联机局面无效，正在请求重新同步。", true)
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
		shell_view.build_game_screen()
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

func _on_match_start_requested(
	mode: String,
	first_key: String,
	second_key: String,
	forced_first: int,
	apply_type_matchups: bool,
) -> void:
	game_mode = mode
	if mode == MODE_LOCAL:
		_start_local_match(
			first_key, second_key, -1, forced_first, true, apply_type_matchups)
		return
	_start_ai_match(
		MODE_CHALLENGE,
		first_key,
		second_key,
		forced_first,
		-1,
		true,
		apply_type_matchups,
	)

func _start_local_match(
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

func _start_ai_match(
	mode: String,
	human_key: String,
	opponent_key: String,
	forced_first: int = -1,
	match_seed: int = -1,
	play_startup: bool = false,
	apply_type_matchups: bool = false,
) -> bool:
	game_mode = MODE_CHALLENGE if mode != MODE_LOCAL else MODE_LOCAL
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
	if mode == MODE_CHALLENGE:
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
	ai_public_history.clear()
	native_rules = NativeRulesSessionAdapter.new(catalog)
	if not native_rules.is_available():
		shell_view.show_toast("原生规则会话不可用。", true)
		return false
	var type_matchups := _canonical_type_matchups_for_mode(
		game_mode, apply_type_matchups)
	var player_names: Array[String] = ["玩家 1", "玩家 2"]
	if game_mode != MODE_LOCAL:
		player_names[1] = "Challenge AI"
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
		shell_view.show_toast(result.message, true)
		return false
	_record_ai_public_history(result.events, state.revision, -1)
	current_view_player = 0
	selected_entity_key = ""
	selected_entity_identity = ""
	shell_view.build_game_screen()
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
		shell_view.show_end_screen()

func _apply_network_wait_hint() -> void:
	if battle_screen == null:
		return
	if not _network_recovery_phase.is_empty():
		battle_screen.set_task_hint(
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
		battle_screen.clear_task_hint()
		return
	var waiting_player := int(network_wait_context.get("waiting_for_player", -1))
	var actor_label := "对手" if waiting_player != current_view_player else "当前玩家"
	var activity: String = str({
		"attachment": "选择附着能量",
		"energy": "处理能量",
		"coin": "确认硬币结果",
		"choice": "完成选择",
	}.get(str(network_wait_context.get("choice_kind", "choice")), "完成选择"))
	battle_screen.set_task_hint("等待%s%s…" % [actor_label, activity])

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
	var fallback_actor := action.actor
	var result := native_rules.apply_action(action.to_dict())
	state = native_rules.state
	if state != null:
		rng.set_state(native_rules.rng_state)
	if result.success and state != null:
		_record_ai_public_history(
			result.events,
			state.revision,
			fallback_actor,
		)
	return result

func _rules_apply_choice(response: ChoiceResponse) -> StepResult:
	var fallback_actor := _current_actor()
	var result := native_rules.apply_choice(response.to_dict())
	state = native_rules.state
	if state != null:
		rng.set_state(native_rules.rng_state)
	if result.success and state != null:
		_record_ai_public_history(
			result.events,
			state.revision,
			fallback_actor,
		)
	return result

func _record_ai_public_history(
	raw_events: Array,
	revision: int,
	fallback_actor: int,
) -> void:
	if game_mode != MODE_CHALLENGE:
		return
	for event in PresentationEvent.normalize_all(
		raw_events,
		revision,
		fallback_actor,
	):
		var visible_event := PresentationEvent.for_player(event, 1)
		if not visible_event.is_empty():
			ai_public_history.append(visible_event)
	while ai_public_history.size() > MAX_AI_PUBLIC_HISTORY:
		ai_public_history.pop_front()

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
			"label": choice_model._action_label(action),
		})
	return rows

func _on_battle_pokemon_selected(
	player_idx: int,
	slot: String,
	card_id: String,
) -> void:
	if _battle_card_inspection_is_read_only():
		if battle_screen == null or state == null:
			return
		var pokemon := state.get_player(player_idx).get_pokemon(slot)
		if pokemon != null and not card_id.is_empty():
			battle_screen.show_read_only_card_detail(
				card_id,
				pokemon,
				player_idx,
				slot,
			)
		return
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

func _battle_card_inspection_is_read_only() -> bool:
	if state == null:
		return true
	if battle_screen != null and battle_screen.is_presentation_busy():
		return true
	var actor := _current_actor()
	if game_mode == MODE_LOCAL:
		return false
	if game_mode == MODE_NETWORK:
		return actor != network_player_idx
	return actor != 0 or ai_thinking

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
		shell_view.show_toast("手牌状态已经变化，请重新拖动。", true)
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
		shell_view.show_toast(locked_message, true)
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
		shell_view.show_toast(locked_message, true)
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
			shell_view.show_toast("动作未发送或被房主拒绝。", true)
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
		shell_view.show_toast(result.message, true)
		if action_uses_drag and battle_screen:
			battle_screen.clear_pending_drag("rules_rejected")
		_refresh_game()
		return result
	selected_entity_key = ""
	selected_entity_identity = ""
	if battle_screen:
		battle_screen.hide_card_detail()
	shell_view.show_toast(result.message if not result.message.is_empty() else "动作完成。")
	var presented_revision := state.revision
	var local_handoff := choice_model._build_local_handoff_plan(
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
	elif not state.pending_promotions.is_empty():
		var promote_actor := int(state.pending_promotions[0])
		if promote_actor != current_view_player:
			current_view_player = promote_actor
			_show_pass_overlay(promote_actor, "晋升", "请选择新的战斗宝可梦。")
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
	_refresh_game()

func _show_choice_overlay(request: ChoiceView) -> void:
	active_request = request
	active_choice_panel = null
	choice_model.configure(request, state, catalog, current_view_player)
	option_buttons.clear()
	if battle_screen:
		battle_screen.clear_choice_targets()
	if request.request_type == "coin_flip":
		_show_coin_flip_choice(request)
		return
	var field_targets := choice_model._choice_field_target_options(request)
	if not field_targets.is_empty() and battle_screen:
		selected_entity_key = ""
		selected_entity_identity = ""
		battle_screen.set_choice_targets(field_targets, choice_model._choice_field_prompt(request))
		_refresh_game()
		return
	var energy_cards := choice_model._choice_energy_cards(request)
	var energy_distribution_view := choice_model._choice_energy_distribution_view(
		request,
		energy_cards,
	)
	if not energy_distribution_view.is_empty():
		energy_cards.assign(energy_distribution_view.get("card_ids", energy_cards))
	var energy_target_models: Array[Dictionary] = []
	for target_value in energy_distribution_view.get("targets", []):
		if target_value is Dictionary:
			energy_target_models.append(Dictionary(target_value))
	var revealed_cards := choice_model._choice_revealed_cards(request)
	var has_card_preview := not energy_cards.is_empty() or not revealed_cards.is_empty()
	var pure_empty_choice := (
		request.options.is_empty()
		and energy_cards.is_empty()
		and revealed_cards.is_empty()
	)
	for option in request.options:
		if not choice_model._choice_option_display_card_id(option, request).is_empty():
			has_card_preview = true
			break
	var choice_spec := ModalSpec.battle(
		modal_host_controller.choice_size(has_card_preview, pure_empty_choice),
		false,
		(
			ModalSpec.SizeMode.FIT_CONTENT
			if pure_empty_choice
			else ModalSpec.SizeMode.PREFERRED
		),
	)
	var display_prompt := choice_model._choice_prompt_text(request)
	modal_host_controller.open(
		display_prompt,
		choice_model._choice_confirm_cta(request, 0),
		choice_model._choice_cancel_cta(request),
		false,
		choice_spec,
	)
	modal_title.text = choice_model._choice_title(request)
	var metadata_text := choice_model._choice_metadata_text(request)
	var panel := CHOICE_PANEL_SCENE.instantiate() as ChoicePanel
	modal_body.add_child(panel)
	active_choice_panel = panel
	panel.configure(
		metadata_text,
		not request.options.is_empty(),
		catalog,
		{
			"prompt": display_prompt,
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
		var option_card_id := choice_model._choice_option_display_card_id(option, request)
		if option_id.is_empty():
			continue
		if not option_card_id.is_empty():
			panel.add_card_option(
				option_id,
				option_card_id,
				choice_model._choice_option_caption(option),
				choice_model._choice_option_owner(option, request.player),
			)
		else:
			option_buttons.append(
				panel.add_text_option(
					option_id,
					choice_model._choice_text_option_label(option, request),
				)
			)
	modal_confirm.pressed.connect(_confirm_choice, CONNECT_ONE_SHOT)
	if request.can_cancel:
		modal_cancel.pressed.connect(_cancel_choice, CONNECT_ONE_SHOT)
	_refresh_choice_buttons()

func _show_coin_flip_choice(request: ChoiceView) -> void:
	modal_host_controller.open(
		request.prompt,
		"继续结算",
		"",
		false,
		ModalSpec.battle(Vector2(680, 500)),
	)
	modal_title.text = "硬币结算"
	var results: Array = choice_model._choice_presentation(request).get("predetermined_flips", [])
	var showcase := COIN_SHOWCASE.new() as CoinShowcase
	showcase.name = "CoinShowcase"
	showcase.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	showcase.custom_minimum_size = Vector2(540, 300)
	if audio_director:
		showcase.audio_requested.connect(audio_director.play_cue)
	modal_body.add_child(showcase)
	var reveal_generation := modal_host_controller.generation
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
		generation != modal_host_controller.generation
		or not modal_layer.visible
		or active_request == null
		or active_request.request_id != request_id
	):
		return
	modal_confirm.disabled = false

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

func _show_retreat_confirmation(action: GameAction) -> void:
	_play_click()
	modal_host_controller.open(
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
	var lines := choice_model._retreat_confirmation_lines(action)
	var body := Label.new()
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_theme_font_size_override("font_size", 18)
	body.add_theme_color_override("font_color", DesignTokens.TEXT)
	body.text = "\n".join(lines)
	modal_body.add_child(body)
	modal_confirm.pressed.connect(func() -> void:
		_play_click()
		modal_host_controller.close(_execute_action_now.bind(action))
	, CONNECT_ONE_SHOT)
	modal_cancel.pressed.connect(func() -> void:
		_play_click()
		modal_host_controller.close()
	, CONNECT_ONE_SHOT)

func _show_choice_blocked_reason(reason: String) -> void:
	if reason.is_empty() or active_choice_panel == null:
		return
	active_choice_panel.show_blocked_reason(reason)

func _toggle_choice(option_id: String) -> void:
	_play_click()
	if active_request == null:
		return
	var blocked_reason := choice_model._choice_addition_blocked_reason(active_request, option_id)
	var rejection := choice_model.toggle(option_id, blocked_reason)
	if not rejection.is_empty():
		_refresh_choice_buttons()
		_show_choice_blocked_reason(rejection)
		return
	_refresh_choice_buttons()

func _rewind_energy_distribution(index: int) -> void:
	if active_request == null or active_request.request_type != "distribute_energy":
		return
	if not choice_model.rewind(index):
		return
	_play_click()
	_refresh_choice_buttons()

func _undo_energy_distribution() -> void:
	if active_request == null or active_request.request_type != "distribute_energy":
		return
	if not choice_model.undo():
		return
	_play_click()
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
	var disabled_reasons := choice_model._choice_option_disabled_reasons(active_request)
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
			choice_model._choice_field_target_options(active_request),
			choice_model._choice_field_prompt(active_request),
		)
		battle_screen.update_choice_selection(selected_choice_ids, disabled_reasons)
	modal_confirm.disabled = not choice_model._choice_selection_is_complete(
		active_request, selected_choice_ids)
	modal_confirm.text = choice_model._choice_confirm_cta(active_request, selected_choice_ids.size())
	if active_request.can_cancel:
		modal_cancel.text = choice_model._choice_cancel_cta(active_request)

func _confirm_choice() -> void:
	if active_request == null:
		return
	if _battle_submission_locked():
		shell_view.show_toast("动画或局面同步尚未完成，请稍候。", true)
		return
	_play_click()
	var request := active_request
	var confirmed_ids: Array[String] = selected_choice_ids.duplicate()
	if battle_screen:
		battle_screen.clear_choice_targets()
	var response := ChoiceResponse.new(request.request_id, confirmed_ids)
	modal_host_controller.close(_submit_choice_response.bind(request, response))

func _submit_choice_response(
	request: ChoiceView,
	response: ChoiceResponse,
) -> void:
	if game_mode == MODE_NETWORK:
		if request.request_type == "coin_flip" and not response.cancelled:
			_remember_coin_presentation_tombstone(request.request_id)
		var choice_sent := network_controller.submit_choice(response)
		if not choice_sent:
			_presented_coin_request_ids.erase(request.request_id)
			shell_view.show_toast(
				"取消请求未发送。" if response.cancelled else "选择未发送或被房主拒绝。",
				true,
			)
			return
		if network_controller.host:
			_poll_network()
		shell_view.show_toast(
			"取消请求已提交，等待房主同步。"
			if response.cancelled
			else "选择已提交，等待房主同步。"
		)
		return
	var previous_active := state.active_player_idx
	var previous_phase := state.phase
	var result := _rules_apply_choice(response)
	if not result.success:
		shell_view.show_toast(result.message, true)
		_refresh_game()
		return
	if response.cancelled:
		shell_view.show_toast(result.message, false)
	var presentation_events: Array = _choice_presentation_events(request, result.events)
	var presented_revision := state.revision
	var local_handoff := choice_model._build_local_handoff_plan(
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
	shell_view.show_toast(result.message if not result.message.is_empty() else "选择已结算。")
	_after_step(previous_active, previous_phase)

func _cancel_choice() -> void:
	if active_request == null:
		return
	if _battle_submission_locked():
		shell_view.show_toast("动画或局面同步尚未完成，请稍候。", true)
		return
	_play_click()
	var request := active_request
	if battle_screen:
		battle_screen.clear_choice_targets()
	var response := ChoiceResponse.new(request.request_id, [], true)
	modal_host_controller.close(_submit_choice_response.bind(request, response))

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
	modal_host_controller.open(
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
		modal_host_controller.close(
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
	if game_mode == MODE_CHALLENGE:
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
	modal_host_controller.open("对局菜单", "继续对局", "返回标题", true, pause_spec)
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
			game_mode == MODE_CHALLENGE,
			field_choice_context,
		)
	)
	var resume_action := _complete_auxiliary_modal.bind(
		field_choice_context,
		Callable(self, "_resume_after_pause"),
	)
	if not field_choice_context.is_empty():
		modal_host_controller.back_action = modal_host_controller.close.bind(resume_action)
	modal_confirm.pressed.connect(func() -> void:
		_play_click()
		modal_host_controller.close(resume_action)
	, CONNECT_ONE_SHOT)
	modal_cancel.pressed.connect(func() -> void:
		_play_click()
		modal_host_controller.close()
		if game_mode == MODE_NETWORK:
			_surrender_network_and_show_title()
		else:
			state = null
			shell_view.show_title()
	, CONNECT_ONE_SHOT)

func _show_end_turn_confirmation(action: GameAction) -> void:
	var remaining := _remaining_turn_action_labels()
	if remaining.is_empty():
		_execute_action_now(action)
		return
	_play_click()
	modal_host_controller.open(
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
		modal_host_controller.close(_execute_action_now.bind(action))
	, CONNECT_ONE_SHOT)
	modal_cancel.pressed.connect(func() -> void:
		_play_click()
		modal_host_controller.close()
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
	# Wait for the authoritative terminal snapshot and its acknowledgement instead
	# of assuming two render frames are enough to flush a WAN/WebSocket exchange.
	var deadline := Time.get_ticks_msec() + NETWORK_GRACEFUL_CLOSE_TIMEOUT_MSEC
	while (
		Time.get_ticks_msec() < deadline
		and network_controller.connection_phase
		!= NetworkMatchController.ConnectionPhase.CLOSED
	):
		await get_tree().process_frame
	if game_mode != MODE_NETWORK or current_screen not in [SCREEN_GAME, SCREEN_END]:
		return
	state = null
	shell_view.show_title()

func _show_help(
	resume_ai_on_close: bool = false,
	resume_choice_context: Dictionary = {},
) -> void:
	var field_choice_context := resume_choice_context
	if field_choice_context.is_empty():
		field_choice_context = _suspend_field_choice_for_auxiliary_modal()
	_play_click()
	modal_host_controller.open(
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
		modal_host_controller.back_action = modal_host_controller.close.bind(resume_action)
	modal_confirm.pressed.connect(func() -> void:
		modal_host_controller.close(resume_action)
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
	modal_host_controller.open(title, "关闭", "", current_screen == SCREEN_GAME, card_spec)
	var panel := CARD_INSPECTOR_PANEL_SCENE.instantiate() as CardInspectorPanel
	modal_body.add_child(panel)
	panel.configure(catalog, context)
	panel.card_requested.connect(_show_card_inspector.bind(
		return_action,
		return_label,
		field_choice_context,
	))
	modal_host_controller.back_action = return_action
	if return_action.is_valid():
		modal_confirm.text = return_label if not return_label.is_empty() else "返回上一界面"
		modal_confirm.pressed.connect(return_action, CONNECT_ONE_SHOT)
	elif not field_choice_context.is_empty():
		var resume_action := _complete_auxiliary_modal.bind(
			field_choice_context,
			Callable(),
		)
		modal_host_controller.back_action = modal_host_controller.close.bind(resume_action)
		modal_confirm.pressed.connect(
			modal_host_controller.close.bind(resume_action),
			CONNECT_ONE_SHOT,
		)
	else:
		modal_confirm.pressed.connect(modal_host_controller.close, CONNECT_ONE_SHOT)

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
	modal_host_controller.open(
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
		modal_confirm.pressed.connect(modal_host_controller.close, CONNECT_ONE_SHOT)
		return
	panel.card_requested.connect(_show_zone_card_inspector.bind(
		context.duplicate(true),
		field_choice_context,
	))
	var resume_action := _complete_auxiliary_modal.bind(
		field_choice_context,
		Callable(),
	)
	# The system-back path calls modal_host_controller.back_action directly. Close the inspector
	# first so its full-screen shade cannot keep intercepting the restored field
	# choice after the request has been re-established.
	modal_host_controller.back_action = modal_host_controller.close.bind(resume_action)
	modal_confirm.pressed.connect(
		modal_host_controller.close.bind(resume_action),
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
	if choice_model._choice_field_target_options(active_request).is_empty():
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
		shell_view.show_toast("找不到牌组：%s" % deck_key, true)
		return
	modal_host_controller.open(
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
	modal_confirm.pressed.connect(modal_host_controller.close, CONNECT_ONE_SHOT)
	if restore_scroll >= 0:
		_restore_deck_detail_modal_state(
			modal_host_controller.generation,
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
	if generation != modal_host_controller.generation or not modal_layer.visible:
		return
	if modal_scroll and scroll_position >= 0:
		modal_scroll.scroll_vertical = scroll_position

func _show_settings(resume_choice_context: Dictionary = {}) -> void:
	var field_choice_context := resume_choice_context
	if field_choice_context.is_empty():
		field_choice_context = _suspend_field_choice_for_auxiliary_modal()
	_play_click()
	modal_host_controller.open(
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
		modal_host_controller.back_action = modal_host_controller.close.bind(resume_action)
	modal_cancel.pressed.connect(
		modal_host_controller.close.bind(resume_action),
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
		shell_view.show_toast("设置保存失败。", true)
		return
	modal_host_controller.close(_complete_auxiliary_modal.bind(
		resume_choice_context,
		Callable(),
	))
	Engine.max_fps = AppSettings.target_fps()
	shell_view.show_toast("设置已保存。")

func _select_hand_card(index: int, card_id: String) -> void:
	_play_click()
	if battle_screen:
		battle_screen.release_read_only_card_detail()
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
	if battle_screen:
		battle_screen.release_read_only_card_detail()
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
		shell_view.show_toast("AI 合法动作查询失败：%s" % query.code, true)
		return
	var actions := query.concrete_actions()
	if actions.is_empty():
		shell_view.show_toast("AI 没有合法动作。", true)
		return
	var rows: Array = []
	for action in actions:
		rows.append(action.to_dict())
	ai_request_sequence += 1
	active_ai_request_id = "ai:%d:%d" % [state.revision, ai_request_sequence]
	var request := {
		"kind": "action",
		"engine": ChallengeAIClient.TRADITIONAL_ENGINE_ID,
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
		"public_history": ai_public_history.duplicate(true),
	}
	ai_thinking = ai_coordinator.start_request(request)
	_refresh_process_state()
	if not ai_thinking:
		_show_ai_failure(
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
		"engine": ChallengeAIClient.TRADITIONAL_ENGINE_ID,
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
		"public_history": ai_public_history.duplicate(true),
	}
	ai_thinking = ai_coordinator.start_request(payload)
	_refresh_process_state()
	if not ai_thinking:
		_show_ai_failure(
			"无法启动 AI 选择线程（%s）。" % ai_coordinator.last_start_error,
		)
		return
	_refresh_game()

func _ai_state_snapshot(player_idx: int) -> Dictionary:
	return native_rules.ai_observation_for(player_idx) if native_rules != null else {}

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
		_show_ai_failure("AI 决策失败：%s" % result.get("error", "unknown"))
		return
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
		_show_ai_failure("AI 决策被规则拒绝：%s" % step.message)
		return
	shell_view.show_toast(step.message if not step.message.is_empty() else "AI 完成动作。")
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

func _show_ai_failure(reason: String) -> void:
	# Native Challenge is the only product policy. A failed request remains
	# visible and recoverable through match restart instead of executing a
	# second, divergent policy inside Main.
	shell_view.show_toast(reason, true)
	_refresh_game()

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
	ai_thinking = false
	active_ai_request_id = ""
	_pending_ai_resume_revision = -1
	_refresh_process_state()

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

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		CardTextureCache.clear()
		if game_mode == MODE_CHALLENGE:
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
			shell_view.show_toast("正在恢复联机对局…")
			_refresh_process_state()
		elif game_mode == MODE_CHALLENGE:
			_maybe_start_ai()
	elif what == NOTIFICATION_OS_MEMORY_WARNING:
		CardTextureCache.clear()
		shell_view.show_toast("系统内存紧张，已释放卡图缓存。")
	elif what == NOTIFICATION_WM_SIZE_CHANGED:
		shell_view.apply_responsive_canvas()
		shell_view.apply_safe_area()
	elif what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if modal_host_controller and modal_host_controller.handle_back():
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
					shell_view.show_title()
			SCREEN_NETWORK:
				if (
					current_network_page == null
					or not is_instance_valid(current_network_page)
					or not current_network_page.handle_back()
				):
					shell_view.show_title()
			SCREEN_GAME:
				_show_pause_overlay()
			SCREEN_END:
				shell_view.show_title()

func _refresh_process_state() -> void:
	set_process(
		ai_thinking
		or ai_coordinator.needs_poll()
		or network_controller.needs_poll()
	)

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

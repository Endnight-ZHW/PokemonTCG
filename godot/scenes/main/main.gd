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

const SCREEN_TITLE := "title"
const SCREEN_DECKS := "decks"
const SCREEN_NETWORK := "network"
const SCREEN_GAME := "game"
const SCREEN_END := "end"
const MODE_LOCAL := "local"
const MODE_CHALLENGE := "challenge"
const MODE_DEEP := "deep"
const MODE_NETWORK := "network"

var catalog := CardCatalog.new()
var engine := GameEngine.new(catalog)
var state: GameState
var rng := PortableRandomSource.new(1)

var current_screen := SCREEN_TITLE
var current_view_player := 0
var action_sequence := 0
var selected_entity_key := ""
var selected_choice_ids: Array[String] = []
var option_buttons: Array[Button] = []
var game_mode := MODE_LOCAL
var ai_difficulty := "standard"
var ai_deck_key := ""
var ai_thinking := false
var ai_request_sequence := 0
var active_ai_request_id := ""
var ai_coordinator := AICoordinator.new()
var ai_inference: Variant
var deep_runtime := DeepAIRuntime.new()
var network_controller := NetworkMatchController.new()
var network_legal_actions: Array[GameAction] = []
var network_choice_request: ChoiceRequest
var network_kind := "lan"
var network_player_idx := -1

var safe_margin: MarginContainer
var screen_host: Control
var toast_label: Label
var sound_player: AudioStreamPlayer
var audio_director: AudioDirector
var click_stream: AudioStreamWAV
var success_stream: AudioStreamWAV
var loading_layer: Control
var loading_label: Label
var shell_animations: AnimationPlayer
var lifecycle_network_interrupted := false

var deck_one_option: OptionButton
var deck_two_option: OptionButton
var mode_description: Label
var difficulty_option: OptionButton
var first_player_option: OptionButton
var network_role_option: OptionButton
var network_address_input: LineEdit
var network_port_input: LineEdit
var network_room_input: LineEdit
var network_deck_option: OptionButton
var network_status_label: Label
var settings_volume_slider: HSlider
var settings_muted_toggle: CheckButton
var settings_motion_toggle: CheckButton
var settings_cache_option: OptionButton
var settings_animation_option: OptionButton
var settings_quality_option: OptionButton
var settings_music_slider: HSlider
var settings_sfx_slider: HSlider

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
var modal_confirm: Button
var modal_cancel: Button
var active_request: ChoiceRequest
var ui_initialized := false
var _modal_generation := 0


func _ready() -> void:
	initialize_ui()
	if "--phase4-ai-smoke" in OS.get_cmdline_user_args():
		_run_phase_four_export_smoke()
	elif "--phase5-network-smoke" in OS.get_cmdline_user_args():
		_run_phase_five_export_smoke()
	elif "--phase6-release-smoke" in OS.get_cmdline_user_args():
		_run_phase_six_export_smoke()


func _run_phase_four_export_smoke() -> void:
	var loaded := deep_runtime.load_for_deck("fire")
	if not loaded:
		push_error("PHASE4_EXPORT_AI_FAILED %s" % deep_runtime.last_error)
		get_tree().quit(2)
		return
	var backend: Variant = deep_runtime.get_backend()
	print(
		"PHASE4_EXPORT_AI_OK provider=%s runtime=%s"
		% [
			backend.call("get_execution_provider"),
			backend.call("get_runtime_version"),
		]
	)
	deep_runtime.unload()
	get_tree().quit()


func _run_phase_five_export_smoke() -> void:
	var probe := ProtocolV3.envelope(ProtocolV3.PING, "smoke", 0, 1)
	var validation := ProtocolV3.validate(probe, "smoke", 0, 0)
	if not bool(validation.get("ok", false)):
		push_error("PHASE5_EXPORT_NETWORK_FAILED")
		get_tree().quit(3)
		return
	print("PHASE5_EXPORT_NETWORK_OK protocol=3 transports=enet,websocket")
	get_tree().quit()


func _run_phase_six_export_smoke() -> void:
	var settings_ok := AppSettings.card_cache_size >= 8
	var license_ok := FileAccess.file_exists("res://third_party/onnxruntime/LICENSE")
	CardTextureCache.clear()
	var cache_ok := int(CardTextureCache.stats().get("entries", -1)) == 0
	if not settings_ok or not license_ok or not cache_ok:
		push_error("PHASE6_EXPORT_RELEASE_FAILED")
		get_tree().quit(4)
		return
	print(
		"PHASE6_EXPORT_RELEASE_OK version=%s settings=1 cache=1 licenses=1"
		% AppState.APP_VERSION
	)
	get_tree().quit()


func _process(_delta: float) -> void:
	_poll_network()
	if not ai_thinking:
		return
	var result := ai_coordinator.poll_result()
	if not result.is_empty():
		_apply_ai_result(result)


func _exit_tree() -> void:
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
	toast_label = get_node("Toast") as Label
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
	modal_cancel = get_node(
		"ModalLayer/Center/ModalPanel/Margin/Content/Buttons/ModalCancel"
	) as Button
	modal_confirm = get_node(
		"ModalLayer/Center/ModalPanel/Margin/Content/Buttons/ModalConfirm"
	) as Button
	loading_layer = get_node("LoadingLayer") as Control
	loading_label = get_node(
		"LoadingLayer/Center/Panel/Margin/LoadingLabel"
	) as Label
	shell_animations = get_node("ShellAnimations") as AnimationPlayer


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
	_clear_screen()
	var page := TITLE_SCENE.instantiate() as TitlePage
	screen_host.add_child(page)
	page.configure("Client %s · Rules v%d · Protocol v%d" % [
		AppState.APP_VERSION,
		AppState.RULES_SCHEMA_VERSION,
		AppState.PROTOCOL_VERSION,
	])
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
	network_kind = kind
	game_mode = MODE_NETWORK
	current_screen = SCREEN_NETWORK
	_clear_screen()
	var page := NETWORK_LOBBY_SCENE.instantiate() as NetworkLobbyPage
	screen_host.add_child(page)
	page.configure(catalog, kind, AppSettings.relay_url)
	page.back_requested.connect(_show_title)
	page.connect_requested.connect(_on_network_connect_requested)
	network_role_option = page.role_option
	network_address_input = page.address_input
	network_port_input = page.port_input
	network_room_input = page.room_input
	network_deck_option = page.deck_option
	network_status_label = page.status_label

func _on_network_connect_requested(
	kind: String,
	role: String,
	address: String,
	port: int,
	room_code: String,
	deck_key: String,
) -> void:
	network_kind = kind
	var error := ERR_INVALID_PARAMETER
	if kind == "lan":
		if port <= 0 or port > 65535:
			network_status_label.text = "端口无效。"
			return
		if role == "host":
			error = network_controller.host_lan(port, deck_key)
		else:
			error = network_controller.join_lan(address, port, deck_key)
	else:
		AppSettings.set_relay_url(address)
		if role == "host":
			error = network_controller.host_relay(address, deck_key)
		else:
			error = network_controller.join_relay(address, room_code, deck_key)
	if error != OK:
		network_status_label.text = "无法启动连接：%s" % error_string(error)
		return
	network_status_label.text = (
		"等待挑战者连接……"
		if role == "host"
		else "正在连接房主……"
	)


func _poll_network() -> void:
	for event in network_controller.poll():
		match str(event.get("type", "")):
			"room_created":
				if network_status_label:
					network_status_label.text = (
						"房间码：%s\n等待挑战者加入……"
						% event.get("room_id", "")
					)
			"connected":
				network_player_idx = int(event.get("player_idx", network_player_idx))
				if network_status_label:
					network_status_label.text = "对手已连接，正在同步牌组和对局……"
			"state":
				_apply_network_view(
					event.get("view", {}),
					int(event.get("player_idx", network_player_idx)),
				)
			"error", "connection_failed", "transport_error":
				var message := str(event.get(
					"message",
					event.get("code", "网络连接失败。"),
				))
				if network_status_label:
					network_status_label.text = message
				_show_toast(message, true)
			"disconnected":
				_show_toast("对手已断开连接，对局结束。", true)
				_stop_network()
				if current_screen == SCREEN_GAME:
					state = null
					_show_title()


func _apply_network_view(view: Dictionary, player: int) -> void:
	if view.is_empty() or not view.get("state") is Dictionary:
		return
	game_mode = MODE_NETWORK
	network_player_idx = player
	current_view_player = player
	state = StateSerializer.from_player_view(view["state"], player)
	network_legal_actions.clear()
	for row in view.get("legal_actions", []):
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
		if not presentation_events.is_empty():
			battle_screen.play_presentation(
				presentation_events,
				state.revision,
				state.active_player_idx,
			)
	if (
		network_choice_request != null
		and (
			active_request == null
			or active_request.request_id != network_choice_request.request_id
		)
	):
		_show_choice_overlay(network_choice_request)


func _stop_network() -> void:
	network_controller.close()
	network_legal_actions.clear()
	network_choice_request = null
	network_player_idx = -1


func _show_deck_select(mode: String = MODE_LOCAL) -> void:
	_play_click()
	game_mode = mode
	current_screen = SCREEN_DECKS
	_clear_screen()
	var page := DECK_SELECT_SCENE.instantiate() as DeckSelectPage
	screen_host.add_child(page)
	page.configure(catalog, game_mode)
	page.back_requested.connect(_show_title)
	page.deck_details_requested.connect(_show_deck_details)
	page.start_requested.connect(_on_match_start_requested)
	deck_one_option = page.deck_one_option
	deck_two_option = page.deck_two_option
	mode_description = page.mode_description
	difficulty_option = page.difficulty_option
	first_player_option = page.first_player_option

func _on_match_start_requested(
	mode: String,
	first_key: String,
	second_key: String,
	difficulty: String,
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
			difficulty,
			forced_first,
		)
	else:
		start_ai_match_for_test(
			mode,
			first_key,
			second_key,
			difficulty,
			forced_first,
		)


func _start_deep_match_with_loading(
	human_key: String,
	opponent_key: String,
	difficulty: String,
	forced_first: int,
) -> void:
	_show_loading("正在校验并加载 Deep AI 模型…")
	await get_tree().process_frame
	start_ai_match_for_test(
		MODE_DEEP,
		human_key,
		opponent_key,
		difficulty,
		forced_first,
	)
	_hide_loading()


func start_local_match_for_test(
	first_key: String,
	second_key: String,
	seed: int = -1,
) -> bool:
	game_mode = MODE_LOCAL
	return _start_match(first_key, second_key, seed, -1)


func start_ai_match_for_test(
	mode: String,
	human_key: String,
	opponent_key: String,
	difficulty: String = "standard",
	forced_first: int = -1,
	seed: int = 20260621,
) -> bool:
	game_mode = mode if mode in [MODE_CHALLENGE, MODE_DEEP] else MODE_CHALLENGE
	ai_difficulty = difficulty if difficulty in NativeChallengeAI.DIFFICULTIES else "standard"
	ai_deck_key = opponent_key
	return _start_match(human_key, opponent_key, seed, forced_first)


func _start_match(
	first_key: String,
	second_key: String,
	seed: int,
	forced_first: int,
) -> bool:
	_play_click()
	_stop_ai()
	state = GameState.new()
	state.public_deck_keys = [first_key, second_key]
	var actual_seed := seed
	if actual_seed < 0:
		actual_seed = int(Time.get_ticks_msec()) ^ 0x4A7C2026
	rng = PortableRandomSource.new(actual_seed)
	var result := engine.setup_game(
		state,
		catalog.expand_deck(first_key),
		catalog.expand_deck(second_key),
		rng,
	)
	if not result.success:
		_show_toast(result.message, true)
		return false
	if forced_first in [0, 1]:
		state.first_player_idx = forced_first
		state.active_player_idx = forced_first
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
	_show_pass_overlay(0, "准备阶段", "玩家 1 放置战斗宝可梦，可继续放置备战宝可梦。")
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
	battle_screen.detail_requested.connect(_show_card_detail)
	battle_screen.inspect_card_requested.connect(_show_card_inspector)
	battle_screen.inspect_zone_requested.connect(_show_zone_inspector)
	screen_host.add_child(battle_screen)
	battle_screen.initialize_ui()
	action_list = VBoxContainer.new()
	action_list.name = "ActionCompatibility"
	action_list.visible = false
	battle_screen.add_child(action_list)
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
		_free_children(action_list)
		var compatibility_rows := _current_action_rows()
		if not compatibility_rows.is_empty():
			action_list.add_child(Label.new())
		battle_screen.update_view(
			state,
			current_view_player,
			_current_action_rows(),
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
		_show_toast("该目标有多个可用动作，请在卡牌上的操作按钮中选择。")
		return
	_show_toast("这张卡不能放到该位置。", true)
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
	if game_mode == MODE_NETWORK:
		_play_click()
		var accepted := network_controller.submit_action(action)
		if not accepted:
			_show_toast("动作未发送或被房主拒绝。", true)
		return StepResult.new(accepted, "动作已提交。" if accepted else "动作提交失败。")
	if game_mode != MODE_LOCAL and _current_actor() == 1:
		return StepResult.new(false, "AI 回合不能由玩家操作。")
	_play_click()
	action_sequence += 1
	action.action_id = "local:%d:%d" % [state.revision, action_sequence]
	var previous_active := state.active_player_idx
	var previous_phase := state.phase
	var result := engine.apply_action(state, action, rng)
	if not result.success:
		_show_toast(result.message, true)
		_refresh_game()
		return result
	selected_entity_key = ""
	_show_toast(result.message if not result.message.is_empty() else "动作完成。")
	if battle_screen and not result.events.is_empty():
		battle_screen.play_presentation(result.events, state.revision, action.actor)
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
	selected_choice_ids.clear()
	option_buttons.clear()
	_open_modal(request.prompt, "确认选择", "取消" if request.can_cancel else "")
	modal_title.text = _choice_title(request)
	var metadata_text := _choice_metadata_text(request)
	var panel := CHOICE_PANEL_SCENE.instantiate() as ChoicePanel
	modal_body.add_child(panel)
	panel.configure(metadata_text, not request.options.is_empty())
	var energy_cards := _choice_energy_cards(request)
	if not energy_cards.is_empty():
		_add_choice_energy_preview(panel, energy_cards)
	var card_grid := panel.card_grid
	var visual_count := 0
	for option in request.options:
		var option_id := str(option.get("option_id", ""))
		var option_card_id := _choice_option_card_id(option)
		if option_card_id.is_empty() or visual_count >= 10:
			continue
		var card_view := CARD_SCENE.instantiate() as CardView
		card_view.custom_minimum_size = Vector2(86, 121)
		card_view.configure(option_card_id, null, false, -1, request.player, "", true)
		card_view.tooltip_text = str(option.get("label", option_card_id))
		card_view.activated.connect(func(
			_card_id: String,
			_hand_index: int,
			_player: int,
			_slot: String,
		) -> void:
			_toggle_choice(option_id)
		)
		card_grid.add_child(card_view)
		visual_count += 1
	if visual_count > 0:
		card_grid.visible = true
	else:
		card_grid.visible = false
	for option in request.options:
		var option_id := str(option.get("option_id", ""))
		var option_button := _button(str(option.get("label", option_id)), 52)
		option_button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		option_button.set_meta("option_id", option_id)
		option_button.pressed.connect(_toggle_choice.bind(option_id))
		option_buttons.append(option_button)
		panel.option_list.add_child(option_button)
	modal_confirm.pressed.connect(_confirm_choice, CONNECT_ONE_SHOT)
	if request.can_cancel:
		modal_cancel.pressed.connect(_cancel_choice, CONNECT_ONE_SHOT)
	_refresh_choice_buttons()


func _choice_option_card_id(option: Dictionary) -> String:
	if option.get("value") is Dictionary:
		var value: Dictionary = option["value"]
		if not str(value.get("card_id", "")).is_empty():
			return str(value["card_id"])
	if option.get("ref") is Dictionary:
		return str(option["ref"].get("card_id", ""))
	return ""


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


func _add_choice_energy_preview(panel: ChoicePanel, card_ids: Array[String]) -> void:
	var note := _modal_label(
		"待分配能量。若需要把多张能量放到同一目标，可以重复点击同一个目标按钮。",
		14,
		DesignTokens.TEXT_MUTED,
	)
	var grid := GridContainer.new()
	grid.columns = 6
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	for card_id in card_ids:
		var card := CARD_SCENE.instantiate() as CardView
		card.custom_minimum_size = Vector2(70, 99)
		card.configure(card_id, null, false, -1, -1, "", true)
		card.tooltip_text = catalog.card_name(card_id)
		grid.add_child(card)
	panel.add_child(note)
	panel.add_child(grid)
	panel.move_child(note, 1)
	panel.move_child(grid, 2)


func _toggle_choice(option_id: String) -> void:
	_play_click()
	if active_request == null:
		return
	if active_request.allow_duplicates:
		if selected_choice_ids.size() < active_request.max_select:
			selected_choice_ids.append(option_id)
	else:
		var existing := selected_choice_ids.find(option_id)
		if existing >= 0:
			selected_choice_ids.remove_at(existing)
		elif selected_choice_ids.size() < active_request.max_select:
			selected_choice_ids.append(option_id)
	_refresh_choice_buttons()


func _refresh_choice_buttons() -> void:
	if active_request == null:
		return
	for button in option_buttons:
		var option_id := str(button.get_meta("option_id", ""))
		var count := selected_choice_ids.count(option_id)
		var base_text := button.text.split("  ×")[0]
		button.text = "%s  ×%d" % [base_text, count] if count > 0 else base_text
		if count > 0:
			button.add_theme_stylebox_override(
				"normal",
				GameUITheme.panel_style(
					Color("#29435a"), 10, GameUITheme.COLOR_ACCENT, 3),
			)
		else:
			button.remove_theme_stylebox_override("normal")
	modal_confirm.disabled = not (
		selected_choice_ids.size() >= active_request.min_select
		and selected_choice_ids.size() <= active_request.max_select
	)
	modal_confirm.text = "确认选择（%d/%d）" % [
		selected_choice_ids.size(), active_request.max_select]


func _confirm_choice() -> void:
	if active_request == null:
		return
	_play_click()
	var request := active_request
	var confirmed_ids: Array[String] = selected_choice_ids.duplicate()
	_close_modal()
	if game_mode == MODE_NETWORK:
		active_request = null
		if not network_controller.submit_choice(
			ChoiceResponse.new(request.request_id, confirmed_ids)
		):
			_show_toast("选择未发送或被房主拒绝。", true)
		return
	var previous_active := state.active_player_idx
	var previous_phase := state.phase
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
	if battle_screen and not result.events.is_empty():
		battle_screen.play_presentation(result.events, state.revision, request.player)
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
	_close_modal()
	if game_mode == MODE_NETWORK:
		active_request = null
		if not network_controller.submit_choice(
			ChoiceResponse.new(request.request_id, [], true)
		):
			_show_toast("取消请求未发送。", true)
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
	_open_modal(heading, "显示玩家 %d 手牌" % (player_idx + 1), "")
	modal_shade.color.a = 1.0
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
	_open_modal("对局菜单", "继续对局", "返回标题")
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
			network_controller.surrender()
		state = null
		_show_title()
	, CONNECT_ONE_SHOT)


func _show_help(resume_ai_on_close: bool = false) -> void:
	_play_click()
	_open_modal("规则与操作帮助", "关闭", "")
	modal_panel.custom_minimum_size = Vector2(760, 680)
	var intro := _modal_label(
		"对战目标是在规则允许的动作中击倒对手宝可梦、拿完奖品，或让对手场上没有宝可梦。",
		16,
		DesignTokens.TEXT_MUTED,
	)
	modal_body.add_child(intro)
	var sections := [
		{
			"title": "对局流程",
			"rows": [
				"准备阶段：双方放置战斗宝可梦，可继续放置备战宝可梦。",
				"主要阶段：打出宝可梦、进化、附能、使用训练家、撤退或发动特性。",
				"攻击后会自动结束回合；宝可梦检查会处理特殊状态和击倒。",
			],
		},
		{
			"title": "查看局面",
			"rows": [
				"点击卡牌会选中并显示可用操作；长按卡牌会打开完整检查器。",
				"弃牌区和竞技场可查看公开卡牌；牌库和奖品只显示数量。",
				"能量、道具、进化链和特殊状态会在检查器中集中显示。",
			],
		},
		{
			"title": "触控与联机",
			"rows": [
				"手牌可以点击选择，也可以拖到高亮牌位。",
				"本地双人交接时会遮挡手牌；联网时只显示自己视角可见的信息。",
				"返回键会打开对局菜单，进入后台会安全中止联机或 AI 搜索。",
			],
		},
	]
	for section in sections:
		modal_body.add_child(_modal_label(str(section["title"]), 20, DesignTokens.GOLD))
		for row in section["rows"]:
			modal_body.add_child(_modal_label("· " + str(row), 15, DesignTokens.TEXT))
	modal_confirm.pressed.connect(func() -> void:
		_close_modal()
		if resume_ai_on_close:
			_maybe_start_ai()
	, CONNECT_ONE_SHOT)


func _show_card_inspector(context: Dictionary) -> void:
	var card_id := str(context.get("card_id", ""))
	if card_id.is_empty():
		return
	_play_click()
	var card := catalog.get_card(card_id)
	var title := str(card.get("name", card_id))
	_open_modal(title, "关闭", "")
	modal_panel.custom_minimum_size = Vector2(860, 700)
	var location := str(context.get("location", ""))
	if not location.is_empty():
		modal_body.add_child(_modal_label(location, 15, DesignTokens.TEXT_MUTED))
	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 18)
	modal_body.add_child(top_row)
	var image := TextureRect.new()
	image.custom_minimum_size = Vector2(210, 294)
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	image.texture = CardTextureCache.get_texture(str(card.get("image_path", "")))
	top_row.add_child(image)
	var detail := RichTextLabel.new()
	detail.custom_minimum_size = Vector2(540, 294)
	detail.fit_content = true
	detail.bbcode_enabled = true
	detail.text = _card_detail_bbcode(card_id, context.get("pokemon") as PokemonState)
	top_row.add_child(detail)
	var pokemon := context.get("pokemon") as PokemonState
	if pokemon:
		_add_card_grid_section(
			modal_body,
			"进化链",
			_pokemon_evolution_cards(pokemon),
			false,
		)
		_add_card_grid_section(modal_body, "附着能量", pokemon.energy_card_ids, false)
		if not pokemon.attached_tool_id.is_empty():
			_add_card_grid_section(modal_body, "宝可梦道具", [pokemon.attached_tool_id], false)
	modal_confirm.pressed.connect(_close_modal, CONNECT_ONE_SHOT)


func _show_zone_inspector(context: Dictionary) -> void:
	_play_click()
	var title := "%s · %s" % [
		_player_name_for_context(int(context.get("player", -1))),
		str(context.get("title", context.get("zone", "区域"))),
	]
	_open_modal(title.strip_edges(), "关闭", "")
	modal_panel.custom_minimum_size = Vector2(820, 680)
	var hidden := bool(context.get("hidden", false))
	var count := int(context.get("count", 0))
	if hidden:
		modal_body.add_child(_modal_label(
			"这是隐藏区域。这里只显示数量，不显示具体卡牌身份。",
			16,
			DesignTokens.TEXT_MUTED,
		))
		_add_card_grid_section(modal_body, "隐藏卡牌（%d）" % count, _hidden_card_rows(count), true)
	else:
		var card_ids: Array[String] = []
		for value in context.get("card_ids", []):
			var card_id := str(value)
			if not card_id.is_empty():
				card_ids.append(card_id)
		if card_ids.is_empty():
			modal_body.add_child(_modal_label("这里没有公开卡牌。", 16, DesignTokens.TEXT_MUTED))
		else:
			_add_card_grid_section(modal_body, "公开卡牌（%d）" % card_ids.size(), card_ids, false)
	modal_confirm.pressed.connect(_close_modal, CONNECT_ONE_SHOT)


func _show_deck_details(deck_key: String) -> void:
	_play_click()
	var deck := catalog.get_deck(deck_key)
	if deck.is_empty():
		_show_toast("找不到牌组：%s" % deck_key, true)
		return
	_open_modal(str(deck.get("name", deck_key)), "关闭", "")
	modal_panel.custom_minimum_size = Vector2(880, 700)
	var rows: Array = deck.get("cards", [])
	var counts := {"Pokémon": 0, "Trainer": 0, "Energy": 0}
	var core_cards: Array[String] = []
	for row_value in rows:
		var row: Dictionary = row_value
		var card_id := str(row.get("card_id", ""))
		var count := int(row.get("count", 0))
		var card := catalog.get_card(card_id)
		var supertype := str(card.get("supertype", ""))
		counts[supertype] = int(counts.get(supertype, 0)) + count
		if supertype == "Pokémon" and core_cards.size() < 6:
			core_cards.append(card_id)
	modal_body.add_child(_modal_label(
		"牌组 key：%s · 属性：%s · 共 %d 张" % [
			deck_key,
			str(deck.get("energy_type", "")),
			int(deck.get("card_count", 0)),
		],
		16,
		DesignTokens.TEXT_MUTED,
	))
	modal_body.add_child(_modal_label(
		"Pokémon %d · Trainer %d · Energy %d" % [
			int(counts.get("Pokémon", 0)),
			int(counts.get("Trainer", 0)),
			int(counts.get("Energy", 0)),
		],
		17,
		DesignTokens.GOLD,
	))
	_add_card_grid_section(modal_body, "核心宝可梦预览", core_cards, false)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 4)
	modal_body.add_child(_modal_label("完整构成", 20, DesignTokens.GOLD))
	modal_body.add_child(list)
	for row_value in rows:
		var row: Dictionary = row_value
		var card_id := str(row.get("card_id", ""))
		var card := catalog.get_card(card_id)
		var label := _modal_label(
			"%2d × %s  [%s]" % [
				int(row.get("count", 0)),
				str(card.get("name", card_id)),
				card_id,
			],
			14,
			DesignTokens.TEXT,
		)
		list.add_child(label)
	modal_confirm.pressed.connect(_close_modal, CONNECT_ONE_SHOT)


func _show_settings() -> void:
	_play_click()
	_open_modal("设置", "保存", "取消")
	var panel := SETTINGS_PANEL_SCENE.instantiate() as SettingsPanel
	modal_body.add_child(panel)
	panel.configure()
	settings_volume_slider = panel.master_volume_slider
	settings_music_slider = panel.music_volume_slider
	settings_sfx_slider = panel.sfx_volume_slider
	settings_muted_toggle = panel.muted_toggle
	settings_motion_toggle = panel.reduced_motion_toggle
	settings_animation_option = panel.animation_mode_option
	settings_quality_option = panel.quality_profile_option
	settings_cache_option = panel.card_cache_option
	panel.save_requested.connect(_save_settings_values)
	modal_confirm.pressed.connect(panel.request_save, CONNECT_ONE_SHOT)
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
	_clear_screen()
	battle_screen = null
	var victory := VICTORY_SCENE.instantiate() as VictoryScreen
	var winner_player := state.get_player(state.winner)
	var winner_card_id := winner_player.active.card_id if winner_player.active else ""
	victory.configure(
		state.winner,
		state.turn_number,
		winner_player.name,
		winner_card_id,
	)
	victory.rematch_requested.connect(func() -> void:
		state = null
		if game_mode == MODE_NETWORK:
			_show_title()
		else:
			_show_deck_select(game_mode)
	)
	victory.title_requested.connect(func() -> void:
		state = null
		_show_title()
	)
	screen_host.add_child(victory)
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


func _open_modal(title_text: String, confirm_text: String, cancel_text: String) -> void:
	_modal_generation += 1
	_disconnect_button(modal_confirm)
	_disconnect_button(modal_cancel)
	_free_children_immediate(modal_body)
	modal_panel.custom_minimum_size = Vector2(720, 620)
	modal_title.text = title_text
	modal_confirm.text = confirm_text
	modal_confirm.disabled = false
	modal_cancel.text = cancel_text
	modal_cancel.visible = not cancel_text.is_empty()
	modal_shade.color.a = 0.86
	modal_layer.visible = true
	if AppSettings.reduced_motion:
		modal_panel.modulate.a = 1.0
		modal_panel.scale = Vector2.ONE
		return
	shell_animations.play("modal_open")


func _close_modal() -> void:
	_modal_generation += 1
	var close_generation := _modal_generation
	active_request = null
	selected_choice_ids.clear()
	option_buttons.clear()
	if not modal_layer.visible:
		_finish_modal_close(close_generation)
		return
	if (
		not is_inside_tree()
		or AppSettings.reduced_motion
		or shell_animations == null
	):
		_finish_modal_close(close_generation)
		return
	var close_animation := shell_animations.get_animation("modal_close")
	if close_animation == null:
		_finish_modal_close(close_generation)
		return
	shell_animations.play("modal_close")
	_finish_modal_close_after_delay(close_generation, close_animation.length)


func _finish_modal_close_after_delay(generation: int, delay: float) -> void:
	await get_tree().create_timer(delay, true, false, true).timeout
	_finish_modal_close(generation)


func _finish_modal_close(generation: int) -> void:
	if generation != _modal_generation:
		return
	modal_layer.visible = false
	if modal_body:
		_free_children_immediate(modal_body)
	modal_panel.modulate = Color.WHITE
	modal_panel.scale = Vector2.ONE


func _select_hand_card(index: int, card_id: String) -> void:
	_play_click()
	var key := "hand:%d" % index
	selected_entity_key = "" if selected_entity_key == key else key
	_show_card_detail(card_id)
	_refresh_game()


func _select_pokemon(player_idx: int, slot: String, card_id: String) -> void:
	_play_click()
	var key := "pokemon:%d:%s" % [player_idx, slot]
	selected_entity_key = "" if selected_entity_key == key else key
	_show_card_detail(card_id)
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
		rows.append("[color=#f4c84a]%s · %s[/color]\n%s" % [
			attack.get("name", ""),
			str(attack.get("damage", 0)),
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
	return label


func _add_card_grid_section(
	parent: VBoxContainer,
	title_text: String,
	card_ids: Array,
	hidden: bool,
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
		card_view.configure(card_id, null, hidden, -1, -1, "", true)
		card_view.tooltip_text = (
			"隐藏卡牌"
			if hidden
			else str(catalog.get_card(card_id).get("name", card_id))
		)
		if not hidden and not card_id.is_empty():
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
		rows.append("[color=#f4c84a]%s · %s[/color]\n%s" % [
			str(attack.get("name", "")),
			str(attack.get("damage", "")),
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
			return "撤退 → 备战区 %d" % (int(action.params.get("bench_idx", 0)) + 1)
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
		"distribute_energy": "分配能量",
	}.get(request.request_type, "选择")


func _choice_metadata_text(request: ChoiceRequest) -> String:
	if request.request_type == "coin_flip":
		var results: Array = request.metadata.get("predetermined_flips", [])
		var labels: Array[String] = []
		for result in results:
			labels.append("正面" if bool(result) else "反面")
		return "结果：" + "、".join(labels)
	return "请选择 %d–%d 项。" % [request.min_select, request.max_select]


func _refresh_log() -> void:
	if log_label == null:
		return
	var start: int = max(0, state.action_log.size() - 6)
	var rows: Array[String] = []
	for index in range(start, state.action_log.size()):
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
	var preset: Dictionary = NativeChallengeAI.DIFFICULTIES.get(
		ai_difficulty,
		NativeChallengeAI.DIFFICULTIES["standard"],
	)
	var request := {
		"kind": "action",
		"state": state.snapshot(),
		"actor": 1,
		"revision": state.revision,
		"request_id": active_ai_request_id,
		"mode": game_mode,
		"difficulty": ai_difficulty,
		"deck_key": ai_deck_key,
		"seed": int(rng.next_u32()),
		"simulation_budget": int(preset["simulations"]),
		"seconds": float(preset["seconds"]),
		"max_depth": int(preset["depth"]),
		"actions": rows,
	}
	ai_thinking = ai_coordinator.start_request(request, ai_inference)
	if not ai_thinking:
		_show_toast("无法启动 AI 后台线程。", true)
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
		"difficulty": ai_difficulty,
		"deck_key": ai_deck_key,
		"seed": int(rng.next_u32()),
	}
	ai_thinking = ai_coordinator.start_request(payload, ai_inference)
	if not ai_thinking:
		_show_toast("无法启动 AI 选择线程。", true)
	_refresh_game()


func _apply_ai_result(result: Dictionary) -> void:
	ai_thinking = false
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
		_show_toast("AI 决策失败：%s" % result.get("error", "unknown"), true)
		return
	if bool(result.get("deep_fallback", false)):
		_show_toast(
			"Deep AI 已回退 Challenge AI：%s" % result.get("fallback_reason", ""),
			true,
		)
	var previous_active := state.active_player_idx
	var previous_phase := state.phase
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
		_show_toast("AI 动作被规则拒绝：%s" % step.message, true)
		_maybe_start_ai()
		return
	if battle_screen and not step.events.is_empty():
		battle_screen.play_presentation(step.events, state.revision, 1)
	_show_toast(step.message if not step.message.is_empty() else "AI 完成动作。")
	_continue_after_ai_step(step, previous_active, previous_phase)


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


func _show_toast(message: String, is_error: bool = false) -> void:
	if message.strip_edges().is_empty():
		return
	toast_label.text = message
	toast_label.modulate = GameUITheme.COLOR_DANGER if is_error else Color.WHITE
	toast_label.visible = true
	if AppSettings.reduced_motion:
		toast_label.modulate.a = 1.0
		get_tree().create_timer(2.0).timeout.connect(
			func() -> void:
				if toast_label and toast_label.text == message:
					toast_label.visible = false
		)
		return
	toast_label.modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property(toast_label, "modulate:a", 1.0, 0.12)
	tween.tween_interval(2.0)
	tween.tween_property(toast_label, "modulate:a", 0.0, 0.2)
	tween.tween_callback(func() -> void: toast_label.visible = false)


func _show_title_from_game() -> void:
	state = null
	_show_title()

func _clear_screen() -> void:
	for child in screen_host.get_children():
		screen_host.remove_child(child)
		child.queue_free()

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
	var safe_rect := DisplayServer.get_display_safe_area()
	if safe_rect.size.x > 0 and safe_rect.size.y > 0 and window_size.x > 0 and window_size.y > 0:
		left = max(left, safe_rect.position.x)
		top = max(top, safe_rect.position.y)
		right = max(right, window_size.x - safe_rect.end.x)
		bottom = max(bottom, window_size.y - safe_rect.end.y)
	safe_margin.add_theme_constant_override("margin_left", left)
	safe_margin.add_theme_constant_override("margin_top", top)
	safe_margin.add_theme_constant_override("margin_right", right)
	safe_margin.add_theme_constant_override("margin_bottom", bottom)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		if battle_screen:
			battle_screen.clear_presentation_for_resync()
		CardTextureCache.clear()
		if game_mode in [MODE_CHALLENGE, MODE_DEEP]:
			ai_coordinator.cancel_and_wait()
			ai_thinking = false
		elif game_mode == MODE_NETWORK and (
			current_screen == SCREEN_NETWORK or current_screen == SCREEN_GAME
		):
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
			if active_request and active_request.can_cancel:
				_cancel_choice()
			elif current_screen == SCREEN_GAME:
				_close_modal()
			else:
				_close_modal()
			return
		match current_screen:
			SCREEN_TITLE:
				get_tree().quit()
			SCREEN_DECKS:
				_show_title()
			SCREEN_NETWORK:
				_show_title()
			SCREEN_GAME:
				_show_pause_overlay()
			SCREEN_END:
				_show_title()


func _disconnect_button(button: Button) -> void:
	for connection in button.pressed.get_connections():
		button.pressed.disconnect(connection["callable"])


func _free_children(parent: Node) -> void:
	for child in parent.get_children():
		parent.remove_child(child)
		child.queue_free()


func _free_children_immediate(parent: Node) -> void:
	for child in parent.get_children():
		parent.remove_child(child)
		child.free()


func _button(text_value: String, height: float) -> Button:
	var result := Button.new()
	result.text = text_value
	result.custom_minimum_size.y = height
	result.focus_mode = Control.FOCUS_ALL
	return result


func _slot_name(slot: String) -> String:
	if slot == "active":
		return "战斗区"
	if slot.begins_with("bench_"):
		return "备战区 %d" % (slot.trim_prefix("bench_").to_int() + 1)
	return slot


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

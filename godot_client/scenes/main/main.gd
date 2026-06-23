extends Control

const BATTLE_SCENE := preload("res://scenes/battle/battle_screen.tscn")
const CARD_SCENE := preload("res://ui/card_view.tscn")
const VICTORY_SCENE := preload("res://scenes/end/victory_screen.tscn")

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

var game_title: Label
var turn_label: Label
var opponent_summary: Label
var opponent_active: Button
var opponent_bench: HBoxContainer
var own_summary: Label
var own_active: Button
var own_bench: HBoxContainer
var hand_row: HBoxContainer
var action_list: VBoxContainer
var log_label: RichTextLabel
var detail_image: TextureRect
var detail_title: Label
var detail_text: RichTextLabel
var clear_filter_button: Button
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
	theme = GameUITheme.create()
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
	var background := ColorRect.new()
	background.name = "Background"
	background.color = GameUITheme.COLOR_BG
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)

	var glow := ColorRect.new()
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow.color = Color(0.05, 0.22, 0.42, 0.22)
	glow.position = Vector2(-120, -160)
	glow.size = Vector2(820, 420)
	background.add_child(glow)

	safe_margin = MarginContainer.new()
	safe_margin.name = "SafeArea"
	safe_margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(safe_margin)

	screen_host = Control.new()
	screen_host.name = "ScreenHost"
	screen_host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	safe_margin.add_child(screen_host)

	toast_label = Label.new()
	toast_label.name = "Toast"
	toast_label.visible = false
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	toast_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	toast_label.add_theme_stylebox_override(
		"normal",
		GameUITheme.panel_style(Color("#1b2e49"), 12, GameUITheme.COLOR_ACCENT_BLUE, 2),
	)
	toast_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	toast_label.position = Vector2(-280, 26)
	toast_label.size = Vector2(560, 58)
	add_child(toast_label)

	sound_player = AudioStreamPlayer.new()
	sound_player.name = "UISound"
	add_child(sound_player)
	audio_director = AudioDirector.new()
	audio_director.name = "AudioDirector"
	add_child(audio_director)

	_build_modal()
	_build_loading_overlay()


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
	var backdrop := TitleBackdrop.new()
	backdrop.name = "TitleBackdrop"
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen_host.add_child(backdrop)

	var layout := HBoxContainer.new()
	layout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layout.add_theme_constant_override("separation", 36)
	screen_host.add_child(layout)
	var hero_margin := _margin(46, 44)
	hero_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layout.add_child(hero_margin)
	var hero := VBoxContainer.new()
	hero.alignment = BoxContainer.ALIGNMENT_END
	hero.add_theme_constant_override("separation", 10)
	hero_margin.add_child(hero)
	var hero_eyebrow := _label(
		"MODERN TABLETOP EDITION",
		17,
		DesignTokens.CYAN,
	)
	hero.add_child(hero_eyebrow)
	var hero_title := _label("宝可梦卡牌对战", 58, DesignTokens.GOLD)
	hero_title.name = "TitleLabel"
	hero.add_child(hero_title)
	var hero_subtitle := _label(
		"真实卡图 · 原生规则 · 离线 AI · 跨平台联机",
		22,
		DesignTokens.TEXT,
	)
	hero.add_child(hero_subtitle)
	var hero_description := _label(
		"在现代实体牌桌上完成每一次抽牌、进化与攻击。",
		17,
		DesignTokens.TEXT_MUTED,
	)
	hero.add_child(hero_description)
	var hero_space := Control.new()
	hero_space.custom_minimum_size.y = 92
	hero.add_child(hero_space)

	var right_center := CenterContainer.new()
	right_center.custom_minimum_size.x = 620
	right_center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layout.add_child(right_center)

	var panel := PanelContainer.new()
	panel.name = "TitlePanel"
	panel.custom_minimum_size = Vector2(560, 650)
	panel.add_theme_stylebox_override(
		"panel",
		DesignTokens.panel_style(
			Color(0.035, 0.065, 0.11, 0.94),
			22,
			Color(0.25, 0.58, 0.85, 0.55),
			1,
			0,
		),
	)
	right_center.add_child(panel)
	var margin := _margin(42, 38)
	panel.add_child(margin)
	var content := VBoxContainer.new()
	content.alignment = BoxContainer.ALIGNMENT_CENTER
	content.add_theme_constant_override("separation", 15)
	margin.add_child(content)

	var eyebrow := _label("GODOT 4.7 · WINDOWS / ANDROID", 15, DesignTokens.CYAN)
	eyebrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(eyebrow)
	var title := _label("选择对战方式", 32, DesignTokens.TEXT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(title)
	var subtitle := _label("所有模式共享同一套原生规则引擎", 16, DesignTokens.TEXT_MUTED)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(subtitle)
	var divider := HSeparator.new()
	content.add_child(divider)

	var local_button := _button("本地双人对战", 62)
	local_button.name = "LocalTwoPlayerButton"
	local_button.pressed.connect(_show_deck_select.bind(MODE_LOCAL))
	content.add_child(local_button)
	var challenge_button := _button("Challenge AI", 56)
	challenge_button.name = "ChallengeAIButton"
	challenge_button.pressed.connect(_show_deck_select.bind(MODE_CHALLENGE))
	content.add_child(challenge_button)
	var deep_button := _button("Deep AI", 56)
	deep_button.name = "DeepAIButton"
	deep_button.pressed.connect(_show_deck_select.bind(MODE_DEEP))
	content.add_child(deep_button)
	var network_row := HBoxContainer.new()
	network_row.add_theme_constant_override("separation", 14)
	content.add_child(network_row)
	var lan_button := _button("局域网联机", 56)
	lan_button.name = "LANButton"
	lan_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lan_button.pressed.connect(_show_network_setup.bind("lan"))
	network_row.add_child(lan_button)
	var relay_button := _button("Relay 联机", 56)
	relay_button.name = "RelayButton"
	relay_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	relay_button.pressed.connect(_show_network_setup.bind("relay"))
	network_row.add_child(relay_button)

	var settings_button := _button("设置与画质", 52)
	settings_button.name = "SettingsButton"
	settings_button.pressed.connect(_show_settings)
	content.add_child(settings_button)

	var version := _label(
		"Client %s · Rules v%d · Protocol v%d" % [
			AppState.APP_VERSION,
			AppState.RULES_SCHEMA_VERSION,
			AppState.PROTOCOL_VERSION,
		],
		15,
		GameUITheme.COLOR_MUTED,
	)
	version.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(version)
	_animate_screen(panel)


func _show_network_setup(kind: String) -> void:
	_play_click()
	_stop_network()
	network_kind = kind
	game_mode = MODE_NETWORK
	current_screen = SCREEN_NETWORK
	_clear_screen()
	var root := VBoxContainer.new()
	root.name = "NetworkLobbyScreen"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 18)
	screen_host.add_child(root)
	root.add_child(_top_bar(
		"局域网联机" if kind == "lan" else "WebSocket Relay 联机",
		_show_title,
	))
	var center := CenterContainer.new()
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(860, 580)
	center.add_child(panel)
	var margin := _margin(42, 34)
	panel.add_child(margin)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 16)
	margin.add_child(content)

	network_role_option = OptionButton.new()
	network_role_option.name = "NetworkRoleOption"
	network_role_option.custom_minimum_size.y = 54
	network_role_option.add_item("创建房间（房主）")
	network_role_option.set_item_metadata(0, "host")
	network_role_option.add_item("加入房间（挑战者）")
	network_role_option.set_item_metadata(1, "client")
	network_role_option.item_selected.connect(_refresh_network_fields)
	content.add_child(_field_row("身份", network_role_option))

	network_address_input = LineEdit.new()
	network_address_input.name = "NetworkAddressInput"
	network_address_input.custom_minimum_size.y = 54
	network_address_input.text = (
		"127.0.0.1" if kind == "lan" else AppSettings.relay_url
	)
	content.add_child(_field_row(
		"主机地址" if kind == "lan" else "Relay URL",
		network_address_input,
	))

	network_port_input = LineEdit.new()
	network_port_input.name = "NetworkPortInput"
	network_port_input.custom_minimum_size.y = 54
	network_port_input.text = "8765"
	network_port_input.visible = kind == "lan"
	var port_row := _field_row("端口", network_port_input)
	port_row.visible = kind == "lan"
	content.add_child(port_row)

	network_room_input = LineEdit.new()
	network_room_input.name = "NetworkRoomInput"
	network_room_input.custom_minimum_size.y = 54
	network_room_input.placeholder_text = "Relay 房间码"
	var room_row := _field_row("房间码", network_room_input)
	room_row.name = "RoomCodeRow"
	room_row.visible = kind == "relay"
	content.add_child(room_row)

	network_deck_option = _deck_option()
	network_deck_option.name = "NetworkDeckOption"
	content.add_child(_field_row("牌组", network_deck_option))

	var start := _button("创建房间", 64)
	start.name = "NetworkConnectButton"
	start.pressed.connect(_start_network_connection)
	content.add_child(start)
	network_status_label = _label(
		"房主运行权威规则；挑战者只提交动作和选择。",
		17,
		GameUITheme.COLOR_MUTED,
	)
	network_status_label.name = "NetworkStatusLabel"
	network_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	network_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(network_status_label)
	_refresh_network_fields(0)
	_animate_screen(panel)


func _field_row(label_text: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	var label := _label(label_text, 18, GameUITheme.COLOR_TEXT)
	label.custom_minimum_size.x = 150
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row


func _deck_option() -> OptionButton:
	var option := OptionButton.new()
	option.custom_minimum_size.y = 54
	var deck_keys: Array = catalog.decks.keys()
	deck_keys.sort()
	for key_value in deck_keys:
		var key := str(key_value)
		var deck := catalog.get_deck(key)
		option.add_item("%s · %s" % [deck.get("name", key), deck.get("energy_type", "")])
		option.set_item_metadata(option.item_count - 1, key)
	return option


func _refresh_network_fields(_selected: int) -> void:
	if network_role_option == null:
		return
	var role := str(network_role_option.get_item_metadata(network_role_option.selected))
	if network_address_input:
		network_address_input.editable = not (network_kind == "lan" and role == "host")
	var room_row := find_child("RoomCodeRow", true, false) as Control
	if room_row:
		room_row.visible = network_kind == "relay" and role == "client"
	var button := find_child("NetworkConnectButton", true, false) as Button
	if button:
		button.text = "创建房间" if role == "host" else "加入房间"


func _start_network_connection() -> void:
	if network_role_option == null or network_deck_option == null:
		return
	var role := str(network_role_option.get_item_metadata(network_role_option.selected))
	var deck_key := str(network_deck_option.get_item_metadata(network_deck_option.selected))
	var error := ERR_INVALID_PARAMETER
	if network_kind == "lan":
		var port := int(network_port_input.text)
		if port <= 0 or port > 65535:
			network_status_label.text = "端口无效。"
			return
		if role == "host":
			error = network_controller.host_lan(port, deck_key)
		else:
			error = network_controller.join_lan(
				network_address_input.text.strip_edges(), port, deck_key)
	else:
		var relay_url := network_address_input.text.strip_edges()
		AppSettings.set_relay_url(relay_url)
		if role == "host":
			error = network_controller.host_relay(relay_url, deck_key)
		else:
			error = network_controller.join_relay(
				relay_url, network_room_input.text.strip_edges(), deck_key)
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
	var root := VBoxContainer.new()
	root.name = "DeckSelectScreen"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 18)
	screen_host.add_child(root)
	var heading := (
		"选择本地双人牌组"
		if game_mode == MODE_LOCAL
		else "选择 Challenge AI 牌组"
		if game_mode == MODE_CHALLENGE
		else "选择 Deep AI 牌组"
	)
	root.add_child(_top_bar(heading, _show_title))

	var center := CenterContainer.new()
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(1080, 560)
	center.add_child(panel)
	var margin := _margin(38, 32)
	panel.add_child(margin)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 22)
	margin.add_child(content)

	mode_description = _label(
		(
			"热座模式：回合交接时会遮挡手牌。双方都使用 Godot 原生规则引擎。"
			if game_mode == MODE_LOCAL
			else "玩家固定为玩家 1，AI 为玩家 2；AI 只能通过公开信息和正常规则接口行动。"
		),
		18,
		GameUITheme.COLOR_MUTED,
	)
	mode_description.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(mode_description)

	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 28)
	content.add_child(columns)
	var first := _deck_column("玩家 1", GameUITheme.COLOR_ACCENT_BLUE)
	deck_one_option = first["option"]
	columns.add_child(first["panel"])
	var second := _deck_column(
		"玩家 2" if game_mode == MODE_LOCAL else "AI",
		GameUITheme.COLOR_ACCENT,
	)
	deck_two_option = second["option"]
	columns.add_child(second["panel"])
	if deck_two_option.item_count > 1:
		deck_two_option.select(1)

	if game_mode != MODE_LOCAL:
		var settings := HBoxContainer.new()
		settings.add_theme_constant_override("separation", 20)
		content.add_child(settings)
		difficulty_option = OptionButton.new()
		difficulty_option.name = "AIDifficultyOption"
		difficulty_option.custom_minimum_size = Vector2(300, 54)
		for row in [
			["快速 · 64 次 / 0.5 秒", "fast"],
			["标准 · 256 次 / 1.5 秒", "standard"],
			["困难 · 768 次 / 4 秒", "hard"],
		]:
			difficulty_option.add_item(row[0])
			difficulty_option.set_item_metadata(difficulty_option.item_count - 1, row[1])
		difficulty_option.select(1)
		settings.add_child(difficulty_option)
		first_player_option = OptionButton.new()
		first_player_option.name = "FirstPlayerOption"
		first_player_option.custom_minimum_size = Vector2(300, 54)
		for row in [["先后手随机", -1], ["玩家 1 先攻", 0], ["AI 先攻", 1]]:
			first_player_option.add_item(row[0])
			first_player_option.set_item_metadata(first_player_option.item_count - 1, row[1])
		settings.add_child(first_player_option)

	var start := _button("开始对战", 68)
	start.name = "StartLocalMatchButton" if game_mode == MODE_LOCAL else "StartAIMatchButton"
	start.pressed.connect(_start_selected_match)
	content.add_child(start)
	_animate_screen(panel)


func _deck_column(title_text: String, accent: Color) -> Dictionary:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override(
		"panel",
		GameUITheme.panel_style(GameUITheme.COLOR_PANEL_ALT, 14, accent, 2),
	)
	var margin := _margin(24, 24)
	panel.add_child(margin)
	var content := VBoxContainer.new()
	margin.add_child(content)
	var title := _label(title_text, 28, accent)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(title)
	var option := OptionButton.new()
	option.custom_minimum_size = Vector2(360, 58)
	var deck_keys: Array = catalog.decks.keys()
	deck_keys.sort()
	for key_value in deck_keys:
		var key := str(key_value)
		var deck := catalog.get_deck(key)
		option.add_item("%s · %s" % [deck.get("name", key), deck.get("energy_type", "")])
		option.set_item_metadata(option.item_count - 1, key)
	content.add_child(option)
	var preview := HBoxContainer.new()
	preview.name = "DeckPreview"
	preview.alignment = BoxContainer.ALIGNMENT_CENTER
	preview.add_theme_constant_override("separation", 8)
	content.add_child(preview)
	option.item_selected.connect(func(_index: int) -> void:
		_refresh_deck_preview(option, preview)
	)
	_refresh_deck_preview(option, preview)
	var info := _label("60 张 · 发布牌组 · 离线可用", 16, GameUITheme.COLOR_MUTED)
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(info)
	return {"panel": panel, "option": option}


func _refresh_deck_preview(option: OptionButton, preview: HBoxContainer) -> void:
	if option == null or preview == null or option.item_count == 0:
		return
	_free_children(preview)
	var deck_key := str(option.get_item_metadata(option.selected))
	var deck := catalog.get_deck(deck_key)
	var shown := 0
	for row_value in deck.get("cards", []):
		if shown >= 4:
			break
		var row: Dictionary = row_value
		var card_id := str(row.get("card_id", ""))
		var card := catalog.get_card(card_id)
		if str(card.get("supertype", "")) != "Pokémon":
			continue
		var image := TextureRect.new()
		image.custom_minimum_size = Vector2(72, 101)
		image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		image.texture = CardTextureCache.get_texture(str(card.get("image_path", "")))
		image.tooltip_text = str(card.get("name", card_id))
		preview.add_child(image)
		shown += 1


func _start_local_match() -> void:
	if deck_one_option == null or deck_two_option == null:
		return
	var first_key := str(deck_one_option.get_item_metadata(deck_one_option.selected))
	var second_key := str(deck_two_option.get_item_metadata(deck_two_option.selected))
	start_local_match_for_test(first_key, second_key)


func _start_selected_match() -> void:
	if game_mode == MODE_LOCAL:
		_start_local_match()
		return
	if deck_one_option == null or deck_two_option == null:
		return
	var human_key := str(deck_one_option.get_item_metadata(deck_one_option.selected))
	var opponent_key := str(deck_two_option.get_item_metadata(deck_two_option.selected))
	var difficulty := str(difficulty_option.get_item_metadata(difficulty_option.selected))
	var forced_first := int(
		first_player_option.get_item_metadata(first_player_option.selected))
	if game_mode == MODE_DEEP:
		_start_deep_match_with_loading(
			human_key,
			opponent_key,
			difficulty,
			forced_first,
		)
	else:
		start_ai_match_for_test(
			game_mode, human_key, opponent_key, difficulty, forced_first)


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
	_animate_screen(battle_screen)


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


func _fill_bench(
	container: HBoxContainer,
	player: PlayerState,
	player_idx: int,
	hidden_side: bool,
) -> void:
	_free_children(container)
	for index in range(player.bench.size()):
		var button := _slot_button("空位 %d" % (index + 1))
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.custom_minimum_size = Vector2(112, 92)
		_configure_pokemon_button(
			button, player.bench[index], player_idx, "bench_%d" % index, hidden_side)
		container.add_child(button)


func _fill_hand(player: PlayerState) -> void:
	_free_children(hand_row)
	for index in range(player.hand.size()):
		var card_id := player.hand[index]
		var card := catalog.get_card(card_id)
		var button := _button(str(card.get("name", card_id)), 132)
		button.custom_minimum_size = Vector2(138, 132)
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		button.tooltip_text = "%s\n%s" % [
			card.get("name", card_id),
			_card_type_text(card),
		]
		button.pressed.connect(_select_hand_card.bind(index, card_id))
		if selected_entity_key == "hand:%d" % index:
			button.add_theme_stylebox_override(
				"normal",
				GameUITheme.panel_style(
					Color("#29435a"), 10, GameUITheme.COLOR_ACCENT, 3),
			)
		hand_row.add_child(button)
	if player.hand.is_empty():
		hand_row.add_child(_label("手牌为空", 18, GameUITheme.COLOR_MUTED))


func _fill_actions() -> void:
	_free_children(action_list)
	var actor := _current_actor()
	if game_mode == MODE_NETWORK:
		if actor != network_player_idx:
			action_list.add_child(_label(
				"等待对手行动…",
				18,
				GameUITheme.COLOR_MUTED,
			))
			return
		var network_visible_count := 0
		for action in network_legal_actions:
			if not _action_matches_filter(action):
				continue
			network_visible_count += 1
			var network_button := _button(_action_label(action), 52)
			network_button.name = "NetworkAction_%s_%d" % [
				action.action, network_visible_count]
			network_button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			network_button.pressed.connect(_execute_action.bind(action))
			action_list.add_child(network_button)
		if network_visible_count == 0:
			action_list.add_child(_label(
				"等待房主同步可执行动作…",
				16,
				GameUITheme.COLOR_MUTED,
			))
		return
	if game_mode != MODE_LOCAL and actor == 1:
		action_list.add_child(_label(
			"AI 正在思考…" if ai_thinking else "等待 AI 行动…",
			18,
			GameUITheme.COLOR_MUTED,
		))
		return
	var actions := engine.legal_actions(state, actor, true)
	var visible_count := 0
	for action in actions:
		if not _action_matches_filter(action):
			continue
		visible_count += 1
		var button := _button(_action_label(action), 52)
		button.name = "Action_%s_%d" % [action.action, visible_count]
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		button.pressed.connect(_execute_action.bind(action))
		action_list.add_child(button)
	if visible_count == 0:
		var empty := _label(
			"当前筛选没有动作。点击“显示全部”。"
			if not selected_entity_key.is_empty()
			else "当前没有可执行动作。",
			16,
			GameUITheme.COLOR_MUTED,
		)
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		action_list.add_child(empty)


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
	if not metadata_text.is_empty():
		var metadata_label := _label(metadata_text, 17, GameUITheme.COLOR_ACCENT)
		metadata_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		modal_body.add_child(metadata_label)
	if request.options.is_empty():
		modal_body.add_child(_label("点击确认继续结算。", 18, GameUITheme.COLOR_MUTED))
	var card_grid := GridContainer.new()
	card_grid.columns = 5
	card_grid.add_theme_constant_override("h_separation", 8)
	card_grid.add_theme_constant_override("v_separation", 8)
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
		modal_body.add_child(card_grid)
	else:
		card_grid.free()
	for option in request.options:
		var option_id := str(option.get("option_id", ""))
		var option_button := _button(str(option.get("label", option_id)), 52)
		option_button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		option_button.set_meta("option_id", option_id)
		option_button.pressed.connect(_toggle_choice.bind(option_id))
		option_buttons.append(option_button)
		modal_body.add_child(option_button)
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
	modal_body.add_child(_label(body, 21, GameUITheme.COLOR_TEXT))
	var privacy := _label(
		"隐私遮挡已启用。确认前不会显示该玩家手牌。",
		17,
		GameUITheme.COLOR_MUTED,
	)
	privacy.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	modal_body.add_child(privacy)
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
	modal_body.add_child(_label(
		(
			"返回标题会断开当前联机对局。"
			if game_mode == MODE_NETWORK
			else "返回标题会结束当前本地对局。"
		),
		18,
		GameUITheme.COLOR_MUTED,
	))
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


func _show_settings() -> void:
	_play_click()
	_open_modal("设置", "保存", "取消")
	var volume_row := _field_row(
		"音量",
		HSlider.new(),
	)
	settings_volume_slider = volume_row.get_child(1) as HSlider
	settings_volume_slider.name = "MasterVolumeSlider"
	settings_volume_slider.min_value = 0.0
	settings_volume_slider.max_value = 1.0
	settings_volume_slider.step = 0.05
	settings_volume_slider.value = AppSettings.master_volume
	settings_volume_slider.custom_minimum_size.y = 48
	modal_body.add_child(volume_row)

	var music_row := _field_row("音乐", HSlider.new())
	settings_music_slider = music_row.get_child(1) as HSlider
	settings_music_slider.name = "MusicVolumeSlider"
	settings_music_slider.min_value = 0.0
	settings_music_slider.max_value = 1.0
	settings_music_slider.step = 0.05
	settings_music_slider.value = AppSettings.music_volume
	settings_music_slider.custom_minimum_size.y = 48
	modal_body.add_child(music_row)

	var sfx_row := _field_row("音效", HSlider.new())
	settings_sfx_slider = sfx_row.get_child(1) as HSlider
	settings_sfx_slider.name = "SFXVolumeSlider"
	settings_sfx_slider.min_value = 0.0
	settings_sfx_slider.max_value = 1.0
	settings_sfx_slider.step = 0.05
	settings_sfx_slider.value = AppSettings.sfx_volume
	settings_sfx_slider.custom_minimum_size.y = 48
	modal_body.add_child(sfx_row)

	settings_muted_toggle = CheckButton.new()
	settings_muted_toggle.name = "MutedToggle"
	settings_muted_toggle.text = "静音"
	settings_muted_toggle.button_pressed = AppSettings.muted
	settings_muted_toggle.custom_minimum_size.y = 48
	modal_body.add_child(settings_muted_toggle)

	settings_motion_toggle = CheckButton.new()
	settings_motion_toggle.name = "ReducedMotionToggle"
	settings_motion_toggle.text = "减少界面动画"
	settings_motion_toggle.button_pressed = AppSettings.reduced_motion
	settings_motion_toggle.custom_minimum_size.y = 48
	modal_body.add_child(settings_motion_toggle)

	settings_animation_option = OptionButton.new()
	settings_animation_option.name = "AnimationModeOption"
	settings_animation_option.custom_minimum_size.y = 48
	for row in [
		["电影化", "cinematic"],
		["标准", "standard"],
		["快速", "fast"],
		["减少动画", "reduced"],
	]:
		settings_animation_option.add_item(row[0])
		settings_animation_option.set_item_metadata(
			settings_animation_option.item_count - 1,
			row[1],
		)
		if row[1] == AppSettings.animation_mode:
			settings_animation_option.select(settings_animation_option.item_count - 1)
	modal_body.add_child(_field_row("演出节奏", settings_animation_option))

	settings_quality_option = OptionButton.new()
	settings_quality_option.name = "QualityProfileOption"
	settings_quality_option.custom_minimum_size.y = 48
	for row in [
		["自动", "auto"],
		["高", "high"],
		["中", "medium"],
		["低", "low"],
	]:
		settings_quality_option.add_item(row[0])
		settings_quality_option.set_item_metadata(
			settings_quality_option.item_count - 1,
			row[1],
		)
		if row[1] == AppSettings.quality_profile:
			settings_quality_option.select(settings_quality_option.item_count - 1)
	modal_body.add_child(_field_row("画质档位", settings_quality_option))

	settings_cache_option = OptionButton.new()
	settings_cache_option.name = "CardCacheOption"
	settings_cache_option.custom_minimum_size.y = 48
	for cache_size in [12, 24, 48]:
		settings_cache_option.add_item("%d 张卡图" % cache_size)
		settings_cache_option.set_item_metadata(
			settings_cache_option.item_count - 1,
			cache_size,
		)
		if cache_size == AppSettings.card_cache_size:
			settings_cache_option.select(settings_cache_option.item_count - 1)
	modal_body.add_child(_field_row("卡图缓存", settings_cache_option))

	var hint := _label(
		"设置保存在应用私有目录；内存不足时会自动清空卡图缓存。",
		16,
		GameUITheme.COLOR_MUTED,
	)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	modal_body.add_child(hint)
	modal_confirm.pressed.connect(_save_settings_from_modal, CONNECT_ONE_SHOT)
	modal_cancel.pressed.connect(_close_modal, CONNECT_ONE_SHOT)


func _save_settings_from_modal() -> void:
	if (
		settings_volume_slider == null
		or settings_muted_toggle == null
		or settings_motion_toggle == null
		or settings_cache_option == null
		or settings_animation_option == null
		or settings_quality_option == null
		or settings_music_slider == null
		or settings_sfx_slider == null
	):
		return
	var animation_mode := str(settings_animation_option.get_item_metadata(
		settings_animation_option.selected))
	if settings_motion_toggle.button_pressed:
		animation_mode = "reduced"
	AppSettings.update(
		float(settings_volume_slider.value),
		settings_muted_toggle.button_pressed,
		settings_motion_toggle.button_pressed,
		int(settings_cache_option.get_item_metadata(settings_cache_option.selected)),
		animation_mode,
		str(settings_quality_option.get_item_metadata(settings_quality_option.selected)),
		float(settings_music_slider.value),
		float(settings_sfx_slider.value),
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


func _build_modal() -> void:
	modal_layer = Control.new()
	modal_layer.name = "ModalLayer"
	modal_layer.visible = false
	modal_layer.mouse_filter = Control.MOUSE_FILTER_STOP
	modal_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(modal_layer)
	modal_shade = ColorRect.new()
	modal_shade.color = Color(0.01, 0.02, 0.04, 0.86)
	modal_shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	modal_layer.add_child(modal_shade)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	modal_layer.add_child(center)
	modal_panel = PanelContainer.new()
	modal_panel.custom_minimum_size = Vector2(660, 380)
	center.add_child(modal_panel)
	var margin := _margin(30, 26)
	modal_panel.add_child(margin)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 16)
	margin.add_child(content)
	modal_title = _label("", 28, GameUITheme.COLOR_ACCENT)
	modal_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(modal_title)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(600, 230)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(scroll)
	modal_body = VBoxContainer.new()
	modal_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(modal_body)
	var buttons := HBoxContainer.new()
	content.add_child(buttons)
	modal_cancel = _button("取消", 54)
	modal_cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(modal_cancel)
	modal_confirm = _button("确认", 54)
	modal_confirm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(modal_confirm)


func _build_loading_overlay() -> void:
	loading_layer = Control.new()
	loading_layer.name = "LoadingLayer"
	loading_layer.visible = false
	loading_layer.mouse_filter = Control.MOUSE_FILTER_STOP
	loading_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(loading_layer)
	var shade := ColorRect.new()
	shade.color = Color(0.01, 0.02, 0.04, 0.94)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	loading_layer.add_child(shade)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	loading_layer.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(560, 180)
	center.add_child(panel)
	var margin := _margin(30, 24)
	panel.add_child(margin)
	loading_label = _label("", 23, GameUITheme.COLOR_TEXT)
	loading_label.name = "LoadingLabel"
	loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	loading_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	loading_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	margin.add_child(loading_label)


func _show_loading(message: String) -> void:
	if loading_layer == null:
		return
	loading_label.text = message
	loading_layer.visible = true


func _hide_loading() -> void:
	if loading_layer:
		loading_layer.visible = false


func _open_modal(title_text: String, confirm_text: String, cancel_text: String) -> void:
	_disconnect_button(modal_confirm)
	_disconnect_button(modal_cancel)
	_free_children_immediate(modal_body)
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
	modal_panel.modulate.a = 0.0
	modal_panel.scale = Vector2(0.96, 0.96)
	var tween := create_tween().set_parallel(true)
	tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(modal_panel, "modulate:a", 1.0, 0.16)
	tween.tween_property(modal_panel, "scale", Vector2.ONE, 0.16)


func _close_modal() -> void:
	modal_layer.visible = false
	if modal_body:
		_free_children_immediate(modal_body)
	active_request = null
	selected_choice_ids.clear()
	option_buttons.clear()


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


func _clear_action_filter() -> void:
	_play_click()
	selected_entity_key = ""
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


func _configure_pokemon_button(
	button: Button,
	pokemon: PokemonState,
	player_idx: int,
	slot: String,
	_hidden_side: bool,
) -> void:
	_disconnect_button(button)
	if pokemon == null:
		button.text = "空位"
		button.disabled = false
		button.pressed.connect(_select_pokemon.bind(player_idx, slot, ""))
		return
	var card := catalog.get_card(pokemon.card_id)
	var status := ""
	if not pokemon.status_conditions.is_empty():
		status = "\n%s" % "/".join(pokemon.status_conditions)
	button.text = "%s\nHP %d/%d · 能量 %d%s" % [
		card.get("name", pokemon.card_id),
		pokemon.current_hp(catalog),
		int(card.get("hp", 0)),
		pokemon.energy_card_ids.size(),
		status,
	]
	button.disabled = false
	button.pressed.connect(_select_pokemon.bind(player_idx, slot, pokemon.card_id))


func _action_matches_filter(action: GameAction) -> bool:
	if selected_entity_key.is_empty():
		return true
	if selected_entity_key.begins_with("hand:"):
		var hand_idx := selected_entity_key.trim_prefix("hand:").to_int()
		return int(action.params.get("hand_idx", -1)) == hand_idx
	if selected_entity_key.begins_with("pokemon:"):
		var parts := selected_entity_key.split(":")
		if parts.size() < 3:
			return true
		var player_idx := int(parts[1])
		var slot := str(parts[2])
		return (
			(action.source and action.source.player == player_idx and action.source.slot == slot)
			or (action.target and action.target.player == player_idx and action.target.slot == slot)
			or str(action.params.get("slot", "")) == slot
			or str(action.params.get("target_slot", "")) == slot
		)
	return true


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


func _top_bar(title_text: String, back_callback: Callable) -> Control:
	var bar := HBoxContainer.new()
	bar.custom_minimum_size.y = 56
	var back := _button("返回", 48)
	back.custom_minimum_size.x = 120
	back.pressed.connect(back_callback)
	bar.add_child(back)
	var title := _label(title_text, 29, GameUITheme.COLOR_TEXT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bar.add_child(title)
	var spacer := Control.new()
	spacer.custom_minimum_size.x = 120
	bar.add_child(spacer)
	return bar


func _clear_screen() -> void:
	for child in screen_host.get_children():
		screen_host.remove_child(child)
		child.queue_free()


func _animate_screen(control: Control) -> void:
	if AppSettings.reduced_motion:
		control.modulate.a = 1.0
		return
	control.modulate.a = 0.0
	control.position.y += 10
	var tween := create_tween().set_parallel(true)
	tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(control, "modulate:a", 1.0, 0.2)
	tween.tween_property(control, "position:y", control.position.y - 10, 0.2)


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


func _slot_button(text_value: String) -> Button:
	var result := _button(text_value, 82)
	result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return result


func _label(text_value: String, font_size: int, color: Color) -> Label:
	var result := Label.new()
	result.text = text_value
	result.add_theme_font_size_override("font_size", font_size)
	result.add_theme_color_override("font_color", color)
	return result


func _margin(horizontal: int, vertical: int) -> MarginContainer:
	var result := MarginContainer.new()
	result.add_theme_constant_override("margin_left", horizontal)
	result.add_theme_constant_override("margin_right", horizontal)
	result.add_theme_constant_override("margin_top", vertical)
	result.add_theme_constant_override("margin_bottom", vertical)
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

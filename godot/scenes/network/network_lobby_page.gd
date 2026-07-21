class_name NetworkLobbyPage
extends Control

const FRONTEND_MOTION := preload("res://ui/frontend/frontend_motion.gd")
const LAN_OVERVIEW_ICON := preload("res://assets/ui/icons/lan.svg")
const RELAY_OVERVIEW_ICON := preload("res://assets/ui/icons/globe.svg")

signal back_requested
signal kind_changed(kind: String)
signal connect_requested(
	kind: String,
	role: String,
	address: String,
	port: int,
	room_code: String,
	deck_key: String,
	apply_type_matchups: bool,
)

enum ConnectionState {
	IDLE,
	VALIDATING,
	CONNECTING,
	WAITING,
	CONNECTED,
	ERROR,
}

const COMPACT_ASPECT := 1.5
const COMPACT_WIDTH := 1360.0
const FRONT_ERROR := Color("#ff9aa4")
const LAN_ACCENT := Color("#50c8ff")
const RELAY_ACCENT := Color("#bd8cff")

var kind := "lan"
var connection_state := ConnectionState.IDLE
var _current_room_code := ""
var _compact := false
var _dense_wide := false
var _compact_step := 0
var _address_drafts: Dictionary = {
	"lan": "127.0.0.1",
	"relay": "",
}
var _updating_kind_ui := false
var _received_locked_rules_options := false

@onready var page: VBoxContainer = %Page
@onready var page_scroll: ScrollContainer = get_node("PageMargin/Center") as ScrollContainer
@onready var page_center: HBoxContainer = page_scroll.get_node("PageCenter") as HBoxContainer
@onready var back_button: Button = %BackButton
@onready var intro_panel: PanelContainer = %IntroPanel
@onready var form_panel: PanelContainer = %FormPanel
@onready var steps: HBoxContainer = %Steps
@onready var compact_step_bar: HBoxContainer = %CompactStepBar
@onready var compact_step_label: Label = %CompactStepLabel
@onready var compact_previous_button: Button = %CompactPreviousButton
@onready var compact_next_button: Button = %CompactNextButton
@onready var heading: Label = %Heading
@onready var subtitle: Label = %Subtitle
@onready var kind_label: Label = %KindLabel
@onready var kind_description: Label = %KindDescription
@onready var intro_accent: ColorRect = %IntroAccent
@onready var intro_icon: TextureRect = %IntroIcon
@onready var kind_code: Label = %KindCode
@onready var role_badge_label: Label = %RoleBadgeLabel
@onready var intro_tip: Label = %IntroTip
@onready var intro_feature_icons: Array[TextureRect] = [
	%FeatureOneIcon,
	%FeatureTwoIcon,
	%FeatureThreeIcon,
]
@onready var intro_feature_labels: Array[Label] = [
	%FeatureOne,
	%FeatureTwo,
	%FeatureThree,
]
@onready var kind_control_label: Label = %NetworkKindLabel
@onready var kind_option: OptionButton = %NetworkKindOption
@onready var role_option: OptionButton = %NetworkRoleOption
@onready var role_label: Label = %RoleLabel
@onready var address_label: Label = %AddressLabel
@onready var address_input: LineEdit = %NetworkAddressInput
@onready var port_row: VBoxContainer = %PortRow
@onready var port_input: LineEdit = %NetworkPortInput
@onready var room_row: VBoxContainer = %RoomCodeRow
@onready var room_input: LineEdit = %NetworkRoomInput
@onready var deck_option: OptionButton = %NetworkDeckOption
@onready var deck_label: Label = %DeckLabel
@onready var rules_label: Label = %RulesLabel
@onready var rule_row: HBoxContainer = %RuleRow
@onready var matchup_toggle: CheckButton = %TypeMatchupToggle
@onready var rule_status_badge: Label = %RuleStatusBadge
@onready var status_panel: PanelContainer = %StatusPanel
@onready var status_dot: Label = %StatusDot
@onready var status_label: Label = %NetworkStatusLabel
@onready var room_code_display: LineEdit = %RoomCodeDisplay
@onready var copy_room_button: Button = %CopyRoomButton
@onready var connect_button: Button = %NetworkConnectButton
@onready var address_error: Label = %AddressError
@onready var port_error: Label = %PortError
@onready var room_error: Label = %RoomError


func _ready() -> void:
	_resolve_nodes()
	_ensure_connections()
	status_label.set("accessibility_live", 1)
	resized.connect(_apply_responsive_layout)
	_apply_responsive_layout()


func configure(p_catalog: CardCatalog, p_kind: String, relay_url: String) -> void:
	_resolve_nodes()
	_ensure_connections()
	_clear_room_code()
	room_input.clear()
	_received_locked_rules_options = false
	matchup_toggle.set_pressed_no_signal(false)
	kind = p_kind if p_kind in ["lan", "relay"] else "lan"
	_address_drafts = {
		"lan": "127.0.0.1",
		"relay": relay_url,
	}
	_populate_kind_options()
	role_option.clear()
	role_option.add_item("创建房间（房主）")
	role_option.set_item_metadata(0, "host")
	role_option.add_item("加入房间（挑战者）")
	role_option.set_item_metadata(1, "client")
	deck_option.clear()
	var deck_keys: Array = p_catalog.decks.keys()
	deck_keys.sort()
	for key_value in deck_keys:
		var key := str(key_value)
		var deck := p_catalog.get_deck(key)
		deck_option.add_item("%s · %s" % [
			deck.get("name", key),
			deck.get("energy_type", ""),
		])
		deck_option.set_item_metadata(deck_option.item_count - 1, key)
	_apply_kind_presentation()
	refresh_fields(0)
	set_connection_state(ConnectionState.IDLE)
	_play_enter_motion()


func _resolve_nodes() -> void:
	page = get_node("%Page") as VBoxContainer
	page_scroll = get_node("PageMargin/Center") as ScrollContainer
	page_center = page_scroll.get_node("PageCenter") as HBoxContainer
	back_button = page.get_node("TopBar/BackButton") as Button
	intro_panel = page.get_node("Body/IntroPanel") as PanelContainer
	steps = page.get_node("Steps") as HBoxContainer
	compact_step_bar = page.get_node("CompactStepBar") as HBoxContainer
	compact_step_label = compact_step_bar.get_node("CompactStepLabel") as Label
	compact_previous_button = compact_step_bar.get_node("CompactPreviousButton") as Button
	compact_next_button = compact_step_bar.get_node("CompactNextButton") as Button
	heading = page.get_node("TopBar/TitleGroup/Heading") as Label
	subtitle = page.get_node("TopBar/TitleGroup/Subtitle") as Label
	kind_label = get_node("%KindLabel") as Label
	kind_description = get_node("%KindDescription") as Label
	intro_accent = get_node("%IntroAccent") as ColorRect
	intro_icon = get_node("%IntroIcon") as TextureRect
	kind_code = get_node("%KindCode") as Label
	role_badge_label = get_node("%RoleBadgeLabel") as Label
	intro_tip = get_node("%IntroTip") as Label
	intro_feature_icons = [
		get_node("%FeatureOneIcon") as TextureRect,
		get_node("%FeatureTwoIcon") as TextureRect,
		get_node("%FeatureThreeIcon") as TextureRect,
	]
	intro_feature_labels = [
		get_node("%FeatureOne") as Label,
		get_node("%FeatureTwo") as Label,
		get_node("%FeatureThree") as Label,
	]
	var form := page.get_node("Body/FormPanel/FormMargin/Form") as VBoxContainer
	role_label = form.get_node("RoleLabel") as Label
	role_option = form.get_node("NetworkRoleOption") as OptionButton
	address_label = form.get_node("AddressRow/AddressLabel") as Label
	address_input = form.get_node("AddressRow/NetworkAddressInput") as LineEdit
	address_error = form.get_node("AddressRow/AddressError") as Label
	kind_control_label = form.get_node("NetworkKindLabel") as Label
	kind_option = form.get_node("NetworkKindOption") as OptionButton
	port_row = form.get_node("PortRow") as VBoxContainer
	port_input = port_row.get_node("NetworkPortInput") as LineEdit
	port_error = port_row.get_node("PortError") as Label
	room_row = form.get_node("RoomCodeRow") as VBoxContainer
	room_input = room_row.get_node("NetworkRoomInput") as LineEdit
	room_error = room_row.get_node("RoomError") as Label
	deck_option = form.get_node("NetworkDeckOption") as OptionButton
	deck_label = form.get_node("DeckLabel") as Label
	rules_label = form.get_node("RulesLabel") as Label
	rule_row = form.get_node("RuleRow") as HBoxContainer
	matchup_toggle = rule_row.get_node("TypeMatchupToggle") as CheckButton
	rule_status_badge = rule_row.get_node("RuleStatusBadge") as Label
	for option in [kind_option, role_option, deck_option]:
		option.get_popup().allow_search = false
	status_panel = page.get_node("StatusPanel") as PanelContainer
	var status_content := status_panel.get_node("StatusMargin/StatusContent") as HBoxContainer
	status_dot = status_content.get_node("StatusDot") as Label
	status_label = status_content.get_node("NetworkStatusLabel") as Label
	room_code_display = status_content.get_node("RoomCodeDisplay") as LineEdit
	copy_room_button = status_content.get_node("CopyRoomButton") as Button
	connect_button = page.get_node("NetworkConnectButton") as Button
	kind_option.accessibility_name = "联机方式"
	role_option.accessibility_name = "联机身份"
	address_input.accessibility_name = "连接地址"
	port_input.accessibility_name = "局域网端口"
	room_input.accessibility_name = "Relay 房间码"
	deck_option.accessibility_name = "联机牌组"
	matchup_toggle.accessibility_name = "弱点与抗性规则"
	room_code_display.accessibility_name = "当前房间码"
	port_input.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER


func _ensure_connections() -> void:
	if not back_button.pressed.is_connected(back_requested.emit):
		back_button.pressed.connect(back_requested.emit)
	if not connect_button.pressed.is_connected(_emit_connect_requested):
		connect_button.pressed.connect(_emit_connect_requested)
	if not role_option.item_selected.is_connected(refresh_fields):
		role_option.item_selected.connect(refresh_fields)
	if not kind_option.item_selected.is_connected(_on_kind_selected):
		kind_option.item_selected.connect(_on_kind_selected)
	if not matchup_toggle.toggled.is_connected(_on_matchup_toggled):
		matchup_toggle.toggled.connect(_on_matchup_toggled)
	if not address_input.text_changed.is_connected(_on_address_text_changed):
		address_input.text_changed.connect(_on_address_text_changed)
	if not copy_room_button.pressed.is_connected(_copy_room_code):
		copy_room_button.pressed.connect(_copy_room_code)
	if not compact_previous_button.pressed.is_connected(_show_previous_compact_step):
		compact_previous_button.pressed.connect(_show_previous_compact_step)
	if not compact_next_button.pressed.is_connected(_show_next_compact_step):
		compact_next_button.pressed.connect(_show_next_compact_step)


func _populate_kind_options() -> void:
	kind_option.clear()
	kind_option.add_item("局域网 LAN")
	kind_option.set_item_metadata(0, "lan")
	kind_option.add_item("远程 Relay")
	kind_option.set_item_metadata(1, "relay")
	_select_kind_option(kind)


func _select_kind_option(value: String) -> void:
	for index in range(kind_option.item_count):
		if str(kind_option.get_item_metadata(index)) == value:
			kind_option.select(index)
			return


func _apply_kind_presentation() -> void:
	var relay := kind == "relay"
	var accent := RELAY_ACCENT if relay else LAN_ACCENT
	_updating_kind_ui = true
	_select_kind_option(kind)
	heading.text = "远程 Relay 联机" if relay else "局域网联机"
	subtitle.text = (
		"通过房间码跨网络连接另一名玩家"
		if relay
		else "连接同一局域网内的 Windows 或 Android 设备"
	)
	kind_label.text = "远程中继" if relay else "局域网直连"
	kind_code.text = "RELAY · REMOTE SESSION" if relay else "LAN · LOCAL NETWORK"
	kind_description.text = (
		"通过 Relay 服务跨网络建立房间；双方仍使用同一套权威规则与隐藏信息隔离。"
		if relay
		else "两台设备处于同一网络时，直接建立低延迟对局。对局判定始终由房主负责。"
	)
	intro_accent.color = accent
	intro_icon.texture = RELAY_OVERVIEW_ICON if relay else LAN_OVERVIEW_ICON
	intro_icon.modulate = accent
	kind_code.add_theme_color_override("font_color", accent)
	role_badge_label.add_theme_color_override("font_color", accent)
	var feature_copy := (
		PackedStringArray(["支持跨网络连接", "使用房间码快速加入", "房主继续权威判定"])
		if relay
		else PackedStringArray(["同一 Wi-Fi / 有线网络", "低延迟设备直连", "隐藏信息按玩家隔离"])
	)
	for index in range(intro_feature_labels.size()):
		intro_feature_labels[index].text = feature_copy[index]
		intro_feature_icons[index].modulate = accent
	address_label.text = "Relay URL" if relay else "主机地址"
	address_input.accessibility_name = "Relay URL" if relay else "主机地址"
	address_input.placeholder_text = (
		"例如 wss://relay.example.com"
		if relay
		else "例如 192.168.1.10"
	)
	address_input.virtual_keyboard_type = (
		LineEdit.KEYBOARD_TYPE_URL if relay else LineEdit.KEYBOARD_TYPE_DEFAULT
	)
	address_input.text = str(_address_drafts.get(kind, ""))
	_updating_kind_ui = false
	port_row.visible = not relay
	_refresh_intro_role_copy()


func _on_kind_selected(index: int) -> void:
	if index < 0 or index >= kind_option.item_count:
		_select_kind_option(kind)
		return
	var selected_kind := str(kind_option.get_item_metadata(index))
	if selected_kind == kind:
		return
	if (
		selected_kind not in ["lan", "relay"]
		or connection_state not in [ConnectionState.IDLE, ConnectionState.ERROR]
	):
		_select_kind_option(kind)
		return
	_address_drafts[kind] = address_input.text
	kind = selected_kind
	room_input.clear()
	_clear_room_code()
	_clear_validation()
	_apply_kind_presentation()
	refresh_fields(role_option.selected)
	set_connection_state(ConnectionState.IDLE)
	kind_changed.emit(kind)


func _on_address_text_changed(value: String) -> void:
	if _updating_kind_ui or kind not in ["lan", "relay"]:
		return
	_address_drafts[kind] = value


func refresh_fields(_selected: int) -> void:
	if role_option.item_count == 0:
		return
	_clear_room_code()
	var role := selected_role()
	_received_locked_rules_options = false
	if role != "host":
		# A challenger has no local rule value before the host synchronizes one.
		# Clear a stale checked state left behind when the user changes roles.
		matchup_toggle.set_pressed_no_signal(false)
	address_input.editable = not (kind == "lan" and role == "host")
	room_row.visible = kind == "relay" and role == "client"
	connect_button.text = "创建房间" if role == "host" else "加入房间"
	matchup_toggle.disabled = role != "host"
	_refresh_matchup_toggle_presentation()
	_refresh_intro_role_copy()
	_clear_validation()
	_apply_compact_step_visibility()


func _refresh_intro_role_copy() -> void:
	if role_badge_label == null or intro_tip == null or role_option.item_count == 0:
		return
	var host := selected_role() == "host"
	role_badge_label.text = "房主 · 创建" if host else "挑战者 · 加入"
	if kind == "relay":
		intro_tip.text = (
			"创建后复制房间码，并分享给远端挑战者。"
			if host
			else "输入房主分享的房间码，即可加入远程对局。"
		)
	else:
		intro_tip.text = (
			"创建后，将本机局域网地址与端口告诉挑战者。"
			if host
			else "向房主确认局域网地址与端口，再选择加入房间。"
		)


func selected_role() -> String:
	if role_option.item_count == 0:
		return "host"
	return str(role_option.get_item_metadata(role_option.selected))


func selected_deck_key() -> String:
	if deck_option.item_count == 0:
		return ""
	return str(deck_option.get_item_metadata(deck_option.selected))


func selected_type_matchups() -> bool:
	return matchup_toggle != null and matchup_toggle.button_pressed


func _on_matchup_toggled(_enabled: bool) -> void:
	_refresh_matchup_toggle_presentation()


func _refresh_matchup_toggle_presentation() -> void:
	if matchup_toggle == null or role_option == null or rule_status_badge == null:
		return
	var host := selected_role() == "host"
	var enabled := matchup_toggle.button_pressed
	var state_copy := "已开启" if enabled else "已关闭"
	var state_color := DesignTokens.GREEN if enabled else DesignTokens.TEXT_MUTED
	var connection_locked := connection_state in [
		ConnectionState.VALIDATING,
		ConnectionState.CONNECTING,
		ConnectionState.WAITING,
		ConnectionState.CONNECTED,
	]
	matchup_toggle.text = "启用弱点与抗性"
	if host:
		rule_status_badge.text = "%s · %s" % [
			state_copy, "已锁定" if connection_locked else "可修改",
		]
		matchup_toggle.tooltip_text = (
			"当前已开启；开局后将按中国大陆官方步骤计算弱点与抗性。"
			if enabled
			else "当前已关闭（项目默认）；开局后将不计算弱点与抗性。"
		)
		matchup_toggle.accessibility_name = "弱点与抗性规则，%s，%s" % [
			state_copy,
			"房主已锁定" if connection_locked else "房主可修改",
		]
	elif _received_locked_rules_options:
		rule_status_badge.text = "%s · 房主锁定" % state_copy
		matchup_toggle.tooltip_text = "房主已将弱点与抗性设置为%s；挑战者不可修改。" % state_copy
		matchup_toggle.accessibility_name = "弱点与抗性规则，%s，房主已锁定，只读" % state_copy
	else:
		rule_status_badge.text = "等待同步 · 只读"
		matchup_toggle.tooltip_text = "加入房间后将显示房主锁定的弱点与抗性设置。"
		matchup_toggle.accessibility_name = "弱点与抗性规则，等待房主同步，只读"
		state_color = DesignTokens.CYAN
	_apply_matchup_status_color(state_color)


func _apply_matchup_status_color(color: Color) -> void:
	if matchup_toggle == null or rule_status_badge == null:
		return
	for color_name in [
		&"font_color",
		&"font_hover_color",
		&"font_hover_pressed_color",
		&"font_focus_color",
		&"font_pressed_color",
		&"font_disabled_color",
		&"icon_normal_color",
		&"icon_hover_color",
		&"icon_hover_pressed_color",
		&"icon_focus_color",
		&"icon_pressed_color",
		&"icon_disabled_color",
	]:
		matchup_toggle.remove_theme_color_override(color_name)
	rule_status_badge.add_theme_color_override(&"font_color", color)
	var badge_style := rule_status_badge.get_theme_stylebox(&"normal").duplicate() as StyleBoxFlat
	if badge_style:
		badge_style.border_color = Color(color.r, color.g, color.b, 0.78)
		badge_style.bg_color = Color(color.r, color.g, color.b, 0.12)
		rule_status_badge.add_theme_stylebox_override(&"normal", badge_style)


func show_locked_rules_options(options: Dictionary) -> void:
	if matchup_toggle == null:
		return
	var enabled := bool(options.get("apply_type_matchups", false))
	_received_locked_rules_options = true
	matchup_toggle.set_pressed_no_signal(enabled)
	matchup_toggle.disabled = true
	_refresh_matchup_toggle_presentation()


func set_connection_state(
	state: ConnectionState,
	message: String = "",
	room_code: String = "",
) -> void:
	var previous_state := connection_state
	connection_state = state
	if (
		state == ConnectionState.VALIDATING
		and previous_state in [ConnectionState.IDLE, ConnectionState.ERROR]
		and selected_role() != "host"
	):
		# A retry may target a different room, so do not display or submit the
		# previous host's locked option while the new host is still unknown.
		_received_locked_rules_options = false
		matchup_toggle.set_pressed_no_signal(false)
	if state in [
		ConnectionState.IDLE,
		ConnectionState.VALIDATING,
		ConnectionState.CONNECTING,
		ConnectionState.ERROR,
	] or (state == ConnectionState.WAITING and room_code.is_empty()):
		_clear_room_code()
	elif not room_code.is_empty():
		_current_room_code = room_code
	var locked := state in [
		ConnectionState.VALIDATING,
		ConnectionState.CONNECTING,
		ConnectionState.WAITING,
		ConnectionState.CONNECTED,
	]
	kind_option.disabled = locked
	role_option.disabled = locked
	address_input.editable = not locked and not (kind == "lan" and selected_role() == "host")
	port_input.editable = not locked
	room_input.editable = not locked
	deck_option.disabled = locked
	matchup_toggle.disabled = locked or selected_role() != "host"
	_refresh_matchup_toggle_presentation()
	connect_button.disabled = locked
	compact_previous_button.disabled = locked
	compact_next_button.disabled = locked
	var default_message: String = str({
		ConnectionState.IDLE: "确认身份、连接信息和牌组后即可开始。",
		ConnectionState.VALIDATING: "正在检查连接信息……",
		ConnectionState.CONNECTING: "正在建立连接……",
		ConnectionState.WAITING: "房间已就绪，正在等待另一名玩家……",
		ConnectionState.CONNECTED: "对手已连接，正在同步牌组和对局……",
		ConnectionState.ERROR: "连接失败，请检查信息后重试。",
	}.get(state, ""))
	status_label.text = message if not message.is_empty() else default_message
	var state_color: Color = {
		ConnectionState.IDLE: DesignTokens.TEXT_MUTED,
		ConnectionState.VALIDATING: DesignTokens.CYAN,
		ConnectionState.CONNECTING: DesignTokens.CYAN,
		ConnectionState.WAITING: DesignTokens.GOLD,
		ConnectionState.CONNECTED: DesignTokens.GREEN,
		ConnectionState.ERROR: FRONT_ERROR,
	}.get(state, DesignTokens.TEXT_MUTED)
	status_dot.add_theme_color_override("font_color", state_color)
	status_label.add_theme_color_override(
		"font_color",
		DesignTokens.TEXT if state != ConnectionState.ERROR else FRONT_ERROR,
	)
	var show_code := not _current_room_code.is_empty() and state in [
		ConnectionState.WAITING,
		ConnectionState.CONNECTED,
	]
	room_code_display.visible = show_code
	copy_room_button.visible = show_code
	if show_code:
		room_code_display.text = _current_room_code
	if state == ConnectionState.ERROR:
		connect_button.disabled = false
		connect_button.text = "重新尝试"
	elif locked:
		connect_button.text = str({
			ConnectionState.VALIDATING: "正在检查…",
			ConnectionState.CONNECTING: "正在连接…",
			ConnectionState.WAITING: "等待连接…",
			ConnectionState.CONNECTED: "已连接",
		}.get(state, "处理中…"))
	elif not locked:
		connect_button.text = "创建房间" if selected_role() == "host" else "加入房间"


func _clear_room_code() -> void:
	_current_room_code = ""
	if room_code_display:
		room_code_display.text = ""
		room_code_display.visible = false
	if copy_room_button:
		copy_room_button.visible = false


func _emit_connect_requested() -> void:
	if not _validate_form():
		set_connection_state(ConnectionState.ERROR, "请先修正标出的连接信息。")
		return
	set_connection_state(ConnectionState.VALIDATING)
	connect_requested.emit(
		kind,
		selected_role(),
		address_input.text.strip_edges(),
		int(port_input.text),
		room_input.text.strip_edges(),
		selected_deck_key(),
		selected_type_matchups(),
	)


func _validate_form() -> bool:
	_clear_validation()
	var first_invalid: Control
	var address := address_input.text.strip_edges()
	var role := selected_role()
	var address_required := kind == "relay" or role == "client"
	if (address_required and address.is_empty()) or (kind == "relay" and not (
		address.begins_with("ws://") or address.begins_with("wss://")
	)):
		address_error.text = (
			"Relay URL 必须以 ws:// 或 wss:// 开头。"
			if kind == "relay"
			else "加入局域网房间时必须填写主机地址。"
		)
		address_error.visible = true
		address_input.accessibility_description = address_error.text
		first_invalid = address_input
	if kind == "lan":
		var port_text := port_input.text.strip_edges()
		var port := int(port_text) if port_text.is_valid_int() else -1
		if port <= 0 or port > 65535:
			port_error.text = "端口必须是 1 到 65535 之间的数字。"
			port_error.visible = true
			port_input.accessibility_description = port_error.text
			if first_invalid == null:
				first_invalid = port_input
	if kind == "relay" and role == "client" and room_input.text.strip_edges().is_empty():
		room_error.visible = true
		room_input.accessibility_description = room_error.text
		if first_invalid == null:
			first_invalid = room_input
	if deck_option.item_count == 0:
		if first_invalid == null:
			first_invalid = deck_option
	if first_invalid:
		if _compact:
			if first_invalid == role_option:
				_set_compact_step(0)
			elif first_invalid == deck_option:
				_set_compact_step(2)
			else:
				_set_compact_step(1)
	return first_invalid == null


func _clear_validation() -> void:
	address_error.visible = false
	port_error.visible = false
	room_error.visible = false
	address_input.accessibility_description = ""
	port_input.accessibility_description = ""
	room_input.accessibility_description = ""


func _copy_room_code() -> void:
	if _current_room_code.is_empty():
		return
	DisplayServer.clipboard_set(_current_room_code)
	status_label.text = "房间码已复制：%s" % _current_room_code


func _apply_responsive_layout() -> void:
	if not is_node_ready() or page == null:
		return
	_compact = (
		size.y < 840.0
		or size.x < COMPACT_WIDTH
		or size.x / maxf(size.y, 1.0) < COMPACT_ASPECT
	)
	_dense_wide = not _compact and size.y < 980.0
	intro_panel.visible = not _compact
	form_panel.custom_minimum_size.y = (
		0.0 if _compact else 568.0 if _dense_wide else 620.0
	)
	steps.visible = not _compact
	compact_step_bar.visible = _compact
	var margin := 20 if _compact else 32
	var page_margin := get_node("PageMargin") as MarginContainer
	for side in ["left", "right"]:
		page_margin.add_theme_constant_override("margin_" + side, margin)
	# A resize notification can arrive before MarginContainer has propagated its
	# new side margins into PageScroll. Never let that one-frame stale width make
	# the centered Page wider than the current compact viewport.
	var current_margin_width := maxf(1.0, size.x - margin * 2.0)
	var scroll_width := current_margin_width
	if page_scroll and page_scroll.size.x > 1.0:
		scroll_width = minf(scroll_width, page_scroll.size.x)
	var compact_available_width := maxf(
		1.0,
		scroll_width - _vertical_scrollbar_reserve(),
	)
	page.custom_minimum_size.x = (
		minf(1040.0, maxf(620.0, compact_available_width))
		if _compact
		else 1120.0
	)
	var vertical_margin := 18 if _compact else 10 if _dense_wide else 18
	for side in ["top", "bottom"]:
		page_margin.add_theme_constant_override("margin_" + side, vertical_margin)
	# Room-code controls keep a real 48 px target when a room is locked. One
	# pixel less between the five dense sections keeps that expanded status row
	# inside a 1600×900 safe viewport without shrinking any interactive target.
	page.add_theme_constant_override("separation", 5 if _dense_wide else 12)
	steps.custom_minimum_size.y = 30.0 if _dense_wide else 36.0
	status_panel.custom_minimum_size.y = 60.0 if _dense_wide else 68.0
	connect_button.custom_minimum_size.y = 54.0 if _dense_wide else 58.0
	var status_margin := status_panel.get_node("StatusMargin") as MarginContainer
	for side in ["top", "bottom"]:
		status_margin.add_theme_constant_override(
			"margin_" + side,
			4 if _dense_wide else 8,
		)
	var form_margin := form_panel.get_node("FormMargin") as MarginContainer
	for side in ["top", "bottom"]:
		form_margin.add_theme_constant_override(
			"margin_" + side,
			10 if _dense_wide else 24,
		)
	var form := form_margin.get_node("Form") as VBoxContainer
	form.add_theme_constant_override("separation", 6 if _dense_wide else 10)
	var field_height := 48.0 if _dense_wide else 54.0
	for field in [kind_option, role_option, address_input, port_input, room_input, deck_option]:
		field.custom_minimum_size.y = field_height
	_apply_compact_step_visibility()


func _vertical_scrollbar_reserve() -> float:
	if page_scroll == null:
		return 16.0
	var scrollbar := page_scroll.get_v_scroll_bar()
	if scrollbar == null:
		return 16.0
	return maxf(16.0, scrollbar.get_combined_minimum_size().x)


func handle_back() -> bool:
	if (
		_compact
		and _compact_step > 0
		and connection_state in [ConnectionState.IDLE, ConnectionState.ERROR]
	):
		_show_previous_compact_step()
		return true
	return false


func _show_previous_compact_step() -> void:
	_set_compact_step(_compact_step - 1)


func _show_next_compact_step() -> void:
	_set_compact_step(_compact_step + 1)


func _set_compact_step(value: int) -> void:
	_compact_step = clampi(value, 0, 2)
	_apply_compact_step_visibility()


func _apply_compact_step_visibility() -> void:
	if role_label == null:
		return
	kind_control_label.visible = not _compact or _compact_step == 0
	kind_option.visible = not _compact or _compact_step == 0
	role_label.visible = not _compact or _compact_step == 0
	role_option.visible = not _compact or _compact_step == 0
	address_input.get_parent().visible = not _compact or _compact_step == 1
	port_row.visible = (not _compact or _compact_step == 1) and kind == "lan"
	room_row.visible = (
		(not _compact or _compact_step == 1)
		and kind == "relay"
		and selected_role() == "client"
	)
	deck_label.visible = not _compact or _compact_step == 2
	deck_option.visible = not _compact or _compact_step == 2
	rules_label.visible = not _compact or _compact_step == 2
	rule_row.visible = not _compact or _compact_step == 2
	connect_button.visible = not _compact or _compact_step == 2
	if not _compact:
		return
	compact_step_label.text = [
		"01 / 03  联机方式与身份",
		"02 / 03  连接信息",
		"03 / 03  规则与牌组",
	][_compact_step]
	compact_previous_button.visible = _compact_step > 0
	compact_next_button.visible = _compact_step < 2


func _play_enter_motion() -> void:
	if page == null:
		return
	FRONTEND_MOTION.play_enter(page, 0.22, 0.985)

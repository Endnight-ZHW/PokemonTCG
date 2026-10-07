class_name NetworkLobbyPage
extends Control

const FRONTEND_MOTION := preload("res://ui/frontend/frontend_motion.gd")
const LAN_OVERVIEW_ICON := preload("res://assets/ui/frontend/lan.svg")
const RELAY_OVERVIEW_ICON := preload("res://assets/ui/frontend/globe.svg")

signal deck_picker_requested

var catalog: CardCatalog

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

const FRONT_ERROR := FrontendPalette.DANGER
const LAN_ACCENT := FrontendPalette.GOLD
const RELAY_ACCENT := FrontendPalette.MUTED

var kind := "lan"
var connection_state := ConnectionState.IDLE
var _current_room_code := ""
var _address_drafts: Dictionary = {
	"lan": "127.0.0.1",
	"relay": "",
}
var _updating_kind_ui := false
var _received_locked_rules_options := false

@onready var page: VBoxContainer = %Page
@onready var page_scroll: ScrollContainer = %BodyScroll
@onready var back_button: Button = %BackButton
@onready var form_panel: PanelContainer = %FormPanel
@onready var steps: HBoxContainer = %Steps
@onready var heading: Label = %Heading
@onready var subtitle: Label = %Subtitle
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
	get_node("PageMargin/Page/BodyScroll/Body/DeckPanel").add_theme_stylebox_override("panel", FrontendPalette.panel(Color.WHITE, 24, Color.TRANSPARENT, 0, 20))
	_apply_responsive_layout()


func configure(p_catalog: CardCatalog, p_kind: String, relay_url: String) -> void:
	_resolve_nodes()
	_ensure_connections()
	catalog = p_catalog
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
	role_option.add_item("创建房间")
	role_option.set_item_metadata(0, "host")
	role_option.add_item("加入房间")
	role_option.set_item_metadata(1, "client")
	deck_option.clear()
	var deck_keys: Array = p_catalog.decks.keys()
	deck_keys.sort()
	for key_value in deck_keys:
		var key := str(key_value)
		var deck := p_catalog.get_deck(key)
		deck_option.add_item("%s · %s" % [
			deck.get("name", key),
			EnergyIconCatalog.type_display_name_for(str(deck.get("energy_type", ""))),
		])
		deck_option.set_item_metadata(deck_option.item_count - 1, key)
	_apply_kind_presentation()
	refresh_fields(0)
	set_connection_state(ConnectionState.IDLE)
	_play_enter_motion()


func _resolve_nodes() -> void:
	page = %Page
	page_scroll = %BodyScroll
	back_button = %BackButton
	form_panel = %FormPanel
	steps = %Steps
	heading = %Heading
	subtitle = %Subtitle
	kind_control_label = %NetworkKindLabel
	kind_option = %NetworkKindOption
	role_option = %NetworkRoleOption
	role_label = %RoleLabel
	address_label = %AddressLabel
	address_input = %NetworkAddressInput
	port_row = %PortRow
	port_input = %NetworkPortInput
	room_row = %RoomCodeRow
	room_input = %NetworkRoomInput
	deck_option = %NetworkDeckOption
	deck_label = %DeckLabel
	rules_label = %RulesLabel
	rule_row = %RuleRow
	matchup_toggle = %TypeMatchupToggle
	rule_status_badge = %RuleStatusBadge
	status_panel = %StatusPanel
	status_dot = %StatusDot
	status_label = %NetworkStatusLabel
	room_code_display = %RoomCodeDisplay
	copy_room_button = %CopyRoomButton
	connect_button = %NetworkConnectButton
	address_error = %AddressError
	port_error = %PortError
	room_error = %RoomError
	FrontendPalette.style_scrollbar(page_scroll.get_v_scroll_bar())
	port_input.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER
	for entry in [[kind_option, "联机方式"], [role_option, "联机身份"], [address_input, "连接地址"], [port_input, "局域网端口"], [room_input, "房间码"], [deck_option, "联机牌组"], [%ChangeDeckButton, "更换参战牌组"], [matchup_toggle, "弱点与抗性规则"], [room_code_display, "当前连接信息"]]:
		(entry[0] as Control).accessibility_name = str(entry[1])



func _ensure_connections() -> void:
	if not %ChangeDeckButton.pressed.is_connected(deck_picker_requested.emit):
		%ChangeDeckButton.pressed.connect(deck_picker_requested.emit)
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
	if not deck_option.item_selected.is_connected(_refresh_connection_summary):
		deck_option.item_selected.connect(_refresh_connection_summary)
	if not copy_room_button.pressed.is_connected(_copy_room_code):
		copy_room_button.pressed.connect(_copy_room_code)


func _populate_kind_options() -> void:
	kind_option.clear()
	kind_option.add_item("局域网")
	kind_option.set_item_metadata(0, "lan")
	kind_option.add_item("互联网")
	kind_option.set_item_metadata(1, "relay")
	_select_kind_option(kind)


func _select_kind_option(value: String) -> void:
	for index in range(kind_option.item_count):
		if str(kind_option.get_item_metadata(index)) == value:
			kind_option.select(index)
			return


func _apply_kind_presentation() -> void:
	var relay := kind == "relay"
	_updating_kind_ui = true
	_select_kind_option(kind)
	heading.text = "互联网联机" if relay else "局域网联机"
	subtitle.text = (
		"通过房间码跨网络连接另一名玩家"
		if relay
		else "连接同一局域网内的 Windows 或 Android 设备"
	)
	address_label.text = "服务器地址" if relay else "主机地址"
	address_input.accessibility_name = "服务器地址" if relay else "主机地址"
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
	_apply_form_visibility()


func _refresh_intro_role_copy() -> void:
	_refresh_connection_summary()


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
	_refresh_connection_summary()


func _refresh_matchup_toggle_presentation() -> void:
	if matchup_toggle == null or role_option == null or rule_status_badge == null:
		return
	var host := selected_role() == "host"
	var enabled := matchup_toggle.button_pressed
	var state_copy := "已开启" if enabled else "已关闭"
	var state_color := FrontendPalette.SUCCESS if enabled else FrontendPalette.MUTED
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
			else "当前已关闭；开局后将不计算弱点与抗性。"
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
		state_color = FrontendPalette.GOLD
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
	_refresh_connection_summary()


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
	%ChangeDeckButton.disabled = locked
	matchup_toggle.disabled = locked or selected_role() != "host"
	_refresh_matchup_toggle_presentation()
	connect_button.disabled = locked
	var default_message: String = str({
		ConnectionState.IDLE: "确认身份、连接信息和牌组后即可开始。",
		ConnectionState.VALIDATING: "正在检查连接信息……",
		ConnectionState.CONNECTING: "正在建立连接……",
		ConnectionState.WAITING: "房间已就绪，正在等待另一名玩家……",
		ConnectionState.CONNECTED: "对手已连接，正在同步牌组和对局……",
		ConnectionState.ERROR: "连接失败，请检查信息后重试。",
	}.get(state, ""))
	status_label.text = PlayerFacingText.message(message, state == ConnectionState.ERROR) if not message.is_empty() else default_message
	var state_color: Color = {
		ConnectionState.IDLE: FrontendPalette.MUTED,
		ConnectionState.VALIDATING: FrontendPalette.GOLD,
		ConnectionState.CONNECTING: FrontendPalette.GOLD,
		ConnectionState.WAITING: FrontendPalette.GOLD,
		ConnectionState.CONNECTED: FrontendPalette.SUCCESS,
		ConnectionState.ERROR: FRONT_ERROR,
	}.get(state, FrontendPalette.MUTED)
	status_dot.add_theme_color_override("font_color", state_color)
	status_label.add_theme_color_override(
		"font_color",
		FrontendPalette.TEXT if state != ConnectionState.ERROR else FRONT_ERROR,
	)
	if kind == "lan" and state == ConnectionState.WAITING and _current_room_code.is_empty():
		var addresses: Array[String] = []
		for address in IP.get_local_addresses():
			if address.is_valid_ip_address() and not address.contains(":") and not address.begins_with("127.") and not address.begins_with("169.254."):
				addresses.append("%s:%s" % [address, port_input.text])
		_current_room_code = " / ".join(addresses) if not addresses.is_empty() else "端口 %s" % port_input.text
	var show_code := not _current_room_code.is_empty() and state in [
		ConnectionState.WAITING,
		ConnectionState.CONNECTED,
	]
	room_code_display.visible = show_code
	copy_room_button.visible = show_code
	if show_code:
		room_code_display.text = _current_room_code
		room_code_display.tooltip_text = _current_room_code
		room_code_display.add_theme_font_size_override("font_size", 20 if kind == "lan" else 30)
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

	_sync_segments()


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
		or not RelaySrvResolver.parse_url(address).is_empty()
	)):
		address_error.text = (
			"服务器地址必须以 ws://、wss:// 或 ws+srv:// 开头。"
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
	status_label.text = "连接信息已复制" if kind == "lan" else "房间码已复制：%s" % _current_room_code


func _apply_responsive_layout() -> void:
	if not is_node_ready() or page == null:
		return

	steps.visible = false
	form_panel.custom_minimum_size.y = 0
	page.custom_minimum_size.x = 0

	var margin := UILayoutPolicy.content_margin(size, 1360, 16, 24)
	var page_margin := get_node("PageMargin") as MarginContainer
	for edge in ["left", "right"]:
		page_margin.add_theme_constant_override("margin_" + edge, margin)
	for edge in ["top", "bottom"]:
		page_margin.add_theme_constant_override("margin_" + edge, UILayoutPolicy.fit_int(size, 12, 28))
	page.add_theme_constant_override("separation", UILayoutPolicy.fit_int(size, 10, 18))
	status_panel.custom_minimum_size.y = 64
	%SelectedDeckArt.custom_minimum_size.y = UILayoutPolicy.fit(size, 164, 260)
	rule_status_badge.add_theme_font_size_override("font_size", 14)
	rule_status_badge.add_theme_stylebox_override("normal", FrontendPalette.panel(Color("f1f4f8"), 12, Color.TRANSPARENT, 0, 6))
	connect_button.custom_minimum_size.y = 56
	heading.add_theme_font_size_override("font_size", UILayoutPolicy.fit_int(size, 26, 34))
	subtitle.visible = false
	var form_margin := form_panel.get_node("FormMargin") as MarginContainer
	for edge in ["top", "bottom", "left", "right"]:
		form_margin.add_theme_constant_override("margin_" + edge, UILayoutPolicy.fit_int(size, 10, 18))
	form_margin.get_node("Form").add_theme_constant_override("separation", UILayoutPolicy.fit_int(size, 8, 10))
	for field in [kind_option, role_option, address_input, port_input, room_input, deck_option]:
		field.custom_minimum_size.y = UILayoutPolicy.TOUCH_MIN
	_apply_form_visibility()


func handle_back() -> bool:
	return false


func _apply_form_visibility() -> void:
	if role_label == null:
		return
	for control in [kind_control_label, kind_option, role_label, role_option, address_input.get_parent(), deck_label, rule_row, connect_button]:
		control.visible = true
	kind_control_label.visible = false
	deck_option.visible = false
	rules_label.visible = false
	address_input.get_parent().visible = kind == "relay" or selected_role() == "client"
	_sync_segments()
	port_row.visible = kind == "lan"
	room_row.visible = kind == "relay" and selected_role() == "client"


func _play_enter_motion() -> void:
	if page == null:
		return
	FRONTEND_MOTION.play_enter(page, 0.22, 0.985)


func _sync_segments() -> void:
	_refresh_connection_summary()
	for option in [kind_option, role_option]:
		if option is FrontendSegmentedOption:
			option.refresh_segments()


func _refresh_connection_summary(_index: int = -1) -> void:
	if catalog == null:
		return
	var key := selected_deck_key()
	var deck := catalog.get_deck(key)
	%SelectedDeckArt.texture = FrontendAttributes.card_texture(catalog, DeckVisualCatalog.representative_card(catalog, key))
	%SelectedDeckName.text = str(deck.get("name", key))
	var energy := str(deck.get("energy_type", "Colorless"))
	%SelectedDeckAttribute.texture = FrontendAttributes.texture_for(energy)
	%SelectedDeckMeta.text = "%s · %d 张" % [EnergyIconCatalog.type_display_name_for(energy), int(deck.get("card_count", 0))]


func select_deck(key: String) -> bool:
	if deck_option.disabled:
		return false
	for idx in range(deck_option.item_count):
		if str(deck_option.get_item_metadata(idx)) == key:
			deck_option.select(idx)
			_refresh_connection_summary()
			return true
	return false

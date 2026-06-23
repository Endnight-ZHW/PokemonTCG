class_name NetworkLobbyPage
extends Control

signal back_requested
signal connect_requested(
	kind: String,
	role: String,
	address: String,
	port: int,
	room_code: String,
	deck_key: String,
)

var kind := "lan"

@onready var role_option: OptionButton = %NetworkRoleOption
@onready var address_input: LineEdit = %NetworkAddressInput
@onready var port_input: LineEdit = %NetworkPortInput
@onready var room_input: LineEdit = %NetworkRoomInput
@onready var deck_option: OptionButton = %NetworkDeckOption
@onready var status_label: Label = %NetworkStatusLabel


func _ready() -> void:
	_resolve_nodes()
	_ensure_connections()


func configure(p_catalog: CardCatalog, p_kind: String, relay_url: String) -> void:
	_resolve_nodes()
	_ensure_connections()
	kind = p_kind
	(get_node("Root/TopBar/Heading") as Label).text = (
		"局域网联机" if kind == "lan" else "WebSocket Relay 联机"
	)
	(get_node(
		"Root/Center/Panel/Margin/Content/AddressRow/AddressLabel"
	) as Label).text = "主机地址" if kind == "lan" else "Relay URL"
	address_input.text = "127.0.0.1" if kind == "lan" else relay_url
	(get_node(
		"Root/Center/Panel/Margin/Content/PortRow"
	) as HBoxContainer).visible = kind == "lan"
	(get_node(
		"Root/Center/Panel/Margin/Content/RoomCodeRow"
	) as HBoxContainer).visible = false
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
	refresh_fields(0)
	if not AppSettings.reduced_motion:
		(get_node("AnimationPlayer") as AnimationPlayer).play("enter")


func _resolve_nodes() -> void:
	var content_path := "Root/Center/Panel/Margin/Content/"
	role_option = get_node(content_path + "RoleRow/NetworkRoleOption") as OptionButton
	address_input = get_node(
		content_path + "AddressRow/NetworkAddressInput"
	) as LineEdit
	port_input = get_node(content_path + "PortRow/NetworkPortInput") as LineEdit
	room_input = get_node(
		content_path + "RoomCodeRow/NetworkRoomInput"
	) as LineEdit
	deck_option = get_node(content_path + "DeckRow/NetworkDeckOption") as OptionButton
	status_label = get_node(content_path + "NetworkStatusLabel") as Label


func _ensure_connections() -> void:
	var back_button := get_node("Root/TopBar/BackButton") as Button
	var connect_button := get_node(
		"Root/Center/Panel/Margin/Content/NetworkConnectButton"
	) as Button
	if not back_button.pressed.is_connected(back_requested.emit):
		back_button.pressed.connect(back_requested.emit)
	if not connect_button.pressed.is_connected(_emit_connect_requested):
		connect_button.pressed.connect(_emit_connect_requested)
	if not role_option.item_selected.is_connected(refresh_fields):
		role_option.item_selected.connect(refresh_fields)


func refresh_fields(_selected: int) -> void:
	var role := str(role_option.get_item_metadata(role_option.selected))
	address_input.editable = not (kind == "lan" and role == "host")
	(get_node(
		"Root/Center/Panel/Margin/Content/RoomCodeRow"
	) as HBoxContainer).visible = kind == "relay" and role == "client"
	(get_node(
		"Root/Center/Panel/Margin/Content/NetworkConnectButton"
	) as Button).text = "创建房间" if role == "host" else "加入房间"


func _emit_connect_requested() -> void:
	if role_option.item_count == 0 or deck_option.item_count == 0:
		return
	connect_requested.emit(
		kind,
		str(role_option.get_item_metadata(role_option.selected)),
		address_input.text.strip_edges(),
		int(port_input.text),
		room_input.text.strip_edges(),
		str(deck_option.get_item_metadata(deck_option.selected)),
	)

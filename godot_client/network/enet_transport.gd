class_name EnetTransport
extends NetTransport

var peer: ENetMultiplayerPeer
var server := false
var connected := false
var last_status := MultiplayerPeer.CONNECTION_DISCONNECTED
var remote_peer_id := 0
var events: Array[Dictionary] = []


func start_host(port: int) -> Error:
	close()
	server = true
	peer = ENetMultiplayerPeer.new()
	var error := peer.create_server(port, 1, 2)
	if error != OK:
		peer = null
		return error
	peer.peer_connected.connect(_on_peer_connected)
	peer.peer_disconnected.connect(_on_peer_disconnected)
	last_status = peer.get_connection_status()
	events.append({"type": "listening", "port": port})
	return OK


func start_client(address: String, port: int) -> Error:
	close()
	server = false
	peer = ENetMultiplayerPeer.new()
	var error := peer.create_client(address, port, 2)
	if error != OK:
		peer = null
		return error
	last_status = peer.get_connection_status()
	return OK


func poll() -> Array[Dictionary]:
	if peer == null:
		return _drain_events()
	peer.poll()
	var status := peer.get_connection_status()
	if not server and status != last_status:
		if status == MultiplayerPeer.CONNECTION_CONNECTED:
			connected = true
			events.append({"type": "connected", "peer_id": 1})
		elif (
			status == MultiplayerPeer.CONNECTION_DISCONNECTED
			and last_status == MultiplayerPeer.CONNECTION_CONNECTING
		):
			events.append({"type": "connection_failed"})
		elif status == MultiplayerPeer.CONNECTION_DISCONNECTED and connected:
			connected = false
			events.append({"type": "disconnected"})
	last_status = status
	while peer.get_available_packet_count() > 0:
		var sender_peer := peer.get_packet_peer()
		var bytes := peer.get_packet()
		if bytes.size() > ProtocolV3.MAX_MESSAGE_BYTES:
			events.append({
				"type": "transport_error",
				"code": "message_too_large",
			})
			continue
		var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
		if parsed is Dictionary:
			events.append({
				"type": "message",
				"peer_id": sender_peer,
				"message": parsed,
			})
		else:
			events.append({"type": "transport_error", "code": "invalid_json"})
	return _drain_events()


func send(message: Dictionary) -> bool:
	if peer == null or not connected:
		return false
	var bytes := JSON.stringify(message).to_utf8_buffer()
	if bytes.size() > ProtocolV3.MAX_MESSAGE_BYTES:
		return false
	if server:
		peer.set_target_peer(remote_peer_id)
	var error := peer.put_packet(bytes)
	if server:
		peer.set_target_peer(0)
	return error == OK


func close() -> void:
	if peer != null:
		peer.close()
	peer = null
	connected = false
	remote_peer_id = 0
	last_status = MultiplayerPeer.CONNECTION_DISCONNECTED
	events.clear()


func connected_state() -> bool:
	return connected


func _on_peer_connected(peer_id: int) -> void:
	if remote_peer_id != 0 and remote_peer_id != peer_id:
		return
	remote_peer_id = peer_id
	connected = true
	events.append({"type": "connected", "peer_id": peer_id})


func _on_peer_disconnected(peer_id: int) -> void:
	if peer_id != remote_peer_id:
		return
	remote_peer_id = 0
	connected = false
	events.append({"type": "disconnected", "peer_id": peer_id})


func _drain_events() -> Array[Dictionary]:
	var result := events.duplicate(true)
	events.clear()
	return result

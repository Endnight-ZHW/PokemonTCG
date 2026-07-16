class_name WebSocketRelayTransport
extends NetTransport

var socket: WebSocketPeer
var url := ""
var room_id := ""
var host := false
var connected := false
var handshake_sent := false
var resume_requested := false
var resume_role := ""
var resume_token := ""
var events: Array[Dictionary] = []


func start_host(relay_url: String) -> Error:
	host = true
	room_id = ""
	resume_requested = false
	resume_role = ""
	resume_token = ""
	return _start(relay_url)


func start_client(relay_url: String, target_room: String) -> Error:
	host = false
	room_id = target_room.strip_edges()
	if room_id.is_empty():
		return ERR_INVALID_PARAMETER
	resume_requested = false
	resume_role = ""
	resume_token = ""
	return _start(relay_url)


func resume_session(
	relay_url: String,
	target_room: String,
	role: String,
	token: String,
) -> Error:
	if target_room.strip_edges().is_empty() or role not in ["p1", "p2"] or token.is_empty():
		return ERR_INVALID_PARAMETER
	host = role == "p1"
	room_id = target_room.strip_edges()
	resume_requested = true
	resume_role = role
	resume_token = token
	return _start(relay_url)


func _start(relay_url: String) -> Error:
	close()
	url = _normalize_url(relay_url)
	socket = WebSocketPeer.new()
	return socket.connect_to_url(url)


func poll() -> Array[Dictionary]:
	if socket == null:
		return _drain_events()
	socket.poll()
	var state := socket.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN and not handshake_sent:
		handshake_sent = true
		var control := (
			{
				"type": "resume_room",
				"room_id": room_id,
				"role": resume_role,
				"resume_token": resume_token,
			}
			if resume_requested
			else ({"type": "create_room"} if host else {
				"type": "join_room",
				"room_id": room_id,
			})
		)
		socket.send_text(JSON.stringify(control))
	elif state == WebSocketPeer.STATE_CLOSED:
		if connected:
			events.append({"type": "disconnected"})
		elif handshake_sent:
			events.append({"type": "connection_failed"})
		connected = false
		socket = null
		return _drain_events()
	while socket != null and socket.get_available_packet_count() > 0:
		var bytes := socket.get_packet()
		if bytes.size() > ProtocolV4.MAX_MESSAGE_BYTES:
			events.append({"type": "transport_error", "code": "message_too_large"})
			continue
		var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
		if not parsed is Dictionary:
			events.append({"type": "transport_error", "code": "invalid_json"})
			continue
		var message: Dictionary = parsed
		match str(message.get("type", "")):
			"room_created":
				room_id = str(message.get("room_id", ""))
				resume_token = str(message.get("resume_token", ""))
				events.append({
					"type": "room_created",
					"room_id": room_id,
					"resume_token": resume_token,
				})
			"room_joined":
				room_id = str(message.get("room_id", room_id))
				resume_token = str(message.get("resume_token", ""))
				events.append({
					"type": "room_joined",
					"room_id": room_id,
					"resume_token": resume_token,
				})
			"room_resumed":
				room_id = str(message.get("room_id", room_id))
				resume_token = str(message.get("resume_token", resume_token))
				events.append({
					"type": "room_resumed",
					"room_id": room_id,
					"resume_token": resume_token,
				})
			"opponent_joined":
				if not connected:
					connected = true
					events.append({"type": "connected", "room_id": room_id})
			"opponent_disconnected":
				connected = false
				events.append({"type": "disconnected"})
			"error":
				events.append({
					"type": "connection_failed" if not connected else "transport_error",
					"message": str(message.get("message", "Relay error")),
				})
			_:
				events.append({"type": "message", "message": message})
	return _drain_events()


func send(message: Dictionary) -> bool:
	if socket == null or not connected:
		return false
	var text := JSON.stringify(message)
	if text.to_utf8_buffer().size() > ProtocolV4.MAX_MESSAGE_BYTES:
		return false
	return socket.send_text(text) == OK


func close() -> void:
	if socket != null:
		socket.close()
	socket = null
	connected = false
	handshake_sent = false
	events.clear()


func connected_state() -> bool:
	return connected


func get_room_id() -> String:
	return room_id


func get_resume_token() -> String:
	return resume_token


func _normalize_url(value: String) -> String:
	var result := value.strip_edges()
	if not result.begins_with("ws://") and not result.begins_with("wss://"):
		result = "ws://%s" % result
	return result


func _drain_events() -> Array[Dictionary]:
	var result := events.duplicate(true)
	events.clear()
	return result

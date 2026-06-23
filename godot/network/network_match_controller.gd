class_name NetworkMatchController
extends RefCounted

var transport: NetTransport
var session: AuthoritativeSession
var host := false
var player_idx := -1
var room_id := ""
var local_deck_key := ""
var remote_deck_key := ""
var send_sequence := 0
var receive_sequence := 0
var current_revision := -1
var awaiting_update := false
var connected := false
var last_receive_msec := 0
var last_send_msec := 0
const HEARTBEAT_INTERVAL_MSEC := 15000
const CONNECTION_TIMEOUT_MSEC := 45000
var seed := 20260621
var events: Array[Dictionary] = []


func host_lan(port: int, deck_key: String, match_seed: int = 20260621) -> Error:
	close()
	host = true
	player_idx = 0
	local_deck_key = deck_key
	seed = match_seed
	room_id = "lan-%08x" % (Time.get_unix_time_from_system() as int)
	var enet := EnetTransport.new()
	var error := enet.start_host(port)
	if error == OK:
		transport = enet
		session = AuthoritativeSession.new(room_id)
	return error


func join_lan(address: String, port: int, deck_key: String) -> Error:
	close()
	host = false
	player_idx = 1
	local_deck_key = deck_key
	var enet := EnetTransport.new()
	var error := enet.start_client(address, port)
	if error == OK:
		transport = enet
	return error


func host_relay(relay_url: String, deck_key: String, match_seed: int = 20260621) -> Error:
	close()
	host = true
	player_idx = 0
	local_deck_key = deck_key
	seed = match_seed
	var relay := WebSocketRelayTransport.new()
	var error := relay.start_host(relay_url)
	if error == OK:
		transport = relay
	return error


func join_relay(relay_url: String, target_room: String, deck_key: String) -> Error:
	close()
	host = false
	player_idx = 1
	local_deck_key = deck_key
	room_id = target_room
	var relay := WebSocketRelayTransport.new()
	var error := relay.start_client(relay_url, target_room)
	if error == OK:
		transport = relay
	return error


func poll() -> Array[Dictionary]:
	if transport == null:
		return _drain_events()
	for event in transport.poll():
		match str(event.get("type", "")):
			"room_created":
				room_id = str(event.get("room_id", ""))
				if host:
					session = AuthoritativeSession.new(room_id)
				events.append(event)
			"connected":
				connected = true
				last_receive_msec = Time.get_ticks_msec()
				last_send_msec = last_receive_msec
				if room_id.is_empty():
					room_id = transport.get_room_id()
				if host:
					if session == null:
						session = AuthoritativeSession.new(room_id)
					_send(ProtocolV3.WELCOME, {
						"player_idx": 1,
						"rules_version": AppState.RULES_SCHEMA_VERSION,
						"action_version": AppState.ACTION_SCHEMA_VERSION,
					})
					events.append({"type": "connected", "player_idx": 0, "room_id": room_id})
				else:
					events.append({"type": "transport_connected", "room_id": room_id})
			"message":
				_handle_message(event.get("message", {}))
			"disconnected", "connection_failed", "transport_error":
				connected = false
				events.append(event)
	var now := Time.get_ticks_msec()
	if connected and now - last_send_msec >= HEARTBEAT_INTERVAL_MSEC:
		_send(ProtocolV3.PING, {}, get_revision())
	if connected and now - last_receive_msec >= CONNECTION_TIMEOUT_MSEC:
		connected = false
		events.append({"type": "disconnected", "reason": "timeout"})
	return _drain_events()


func submit_action(action: GameAction) -> bool:
	if player_idx < 0:
		return false
	if not host and awaiting_update:
		return false
	if action.action_id.is_empty():
		action.action_id = "net:%d:%d:%d" % [
			player_idx,
			get_revision(),
			send_sequence + 1,
		]
	action.actor = player_idx
	if host:
		var step := session.submit_action(0, action.to_dict())
		if not step.success:
			events.append({"type": "error", "code": step.error_code, "message": step.message})
			return false
		_broadcast_state(step.events)
		return true
	var sent := _send(
		ProtocolV3.ACTION_SUBMIT,
		{"action": action.to_dict()},
		get_revision(),
		action.action_id,
	)
	awaiting_update = sent
	return sent


func submit_choice(response: ChoiceResponse) -> bool:
	if player_idx < 0:
		return false
	if not host and awaiting_update:
		return false
	if host:
		var step := session.submit_choice(0, response.to_dict())
		if not step.success:
			events.append({"type": "error", "code": step.error_code, "message": step.message})
			return false
		_broadcast_state(step.events)
		return true
	var sent := _send(
		ProtocolV3.CHOICE_SUBMIT,
		{"response": response.to_dict()},
		get_revision(),
		"",
		response.request_id,
	)
	awaiting_update = sent
	return sent


func surrender() -> void:
	if host:
		if session != null:
			var step := session.surrender(0)
			_broadcast_state(step.events)
	else:
		_send(ProtocolV3.SURRENDER, {}, get_revision())


func request_resync() -> void:
	if not host:
		_send(ProtocolV3.RESYNC_REQUEST, {}, get_revision())


func get_revision() -> int:
	if session != null and session.state != null:
		return session.state.revision
	return current_revision


func close() -> void:
	if transport != null:
		transport.close()
	transport = null
	session = null
	host = false
	player_idx = -1
	room_id = ""
	local_deck_key = ""
	remote_deck_key = ""
	send_sequence = 0
	receive_sequence = 0
	current_revision = -1
	awaiting_update = false
	connected = false
	last_receive_msec = 0
	last_send_msec = 0
	events.clear()


func _handle_message(message: Variant) -> void:
	if (
		not host
		and room_id.is_empty()
		and message is Dictionary
		and str(message.get("message_type", "")) == ProtocolV3.WELCOME
	):
		room_id = str(message.get("room_id", ""))
	var validation := ProtocolV3.validate(
		message,
		room_id,
		1 if host else 0,
		receive_sequence,
	)
	if not bool(validation.get("ok", false)):
		var code := str(validation.get("code", "invalid_message"))
		if host:
			_send(ProtocolV3.ERROR, ProtocolV3.error_payload(
				code, str(validation.get("message", "消息无效。"))))
		events.append({
			"type": "error",
			"code": code,
			"message": str(validation.get("message", "消息无效。")),
		})
		return
	var row: Dictionary = message
	receive_sequence = int(validation["sequence"])
	last_receive_msec = Time.get_ticks_msec()
	var message_type := str(row["message_type"])
	var payload: Dictionary = row["payload"]
	if host:
		_handle_host_message(row, message_type, payload)
	else:
		_handle_client_message(message_type, payload)


func _handle_host_message(
	row: Dictionary,
	message_type: String,
	payload: Dictionary,
) -> void:
	match message_type:
		ProtocolV3.DECK_SELECT:
			var deck_key := str(payload.get("deck_key", ""))
			if not CardCatalog.new().decks.has(deck_key):
				_send(ProtocolV3.ERROR, ProtocolV3.error_payload(
					"invalid_deck", "未知牌组。"))
				return
			remote_deck_key = deck_key
			var result := session.start_match(local_deck_key, remote_deck_key, seed)
			if not result.success:
				_send(ProtocolV3.ERROR, ProtocolV3.error_payload(
					result.error_code, result.message))
				return
			_broadcast_state(result.events)
		ProtocolV3.ACTION_SUBMIT:
			if not _revision_matches(row):
				return
			var action_data: Dictionary = payload.get("action", {})
			if str(row["action_id"]) != str(action_data.get("action_id", "")):
				_reject("action_id_mismatch", "动作 ID 不匹配。")
				return
			var step := session.submit_action(1, action_data)
			if not step.success:
				_reject(step.error_code, step.message)
				return
			_broadcast_state(step.events)
		ProtocolV3.CHOICE_SUBMIT:
			if not _revision_matches(row):
				return
			var response_data: Dictionary = payload.get("response", {})
			if str(row["request_id"]) != str(response_data.get("request_id", "")):
				_reject("request_id_mismatch", "选择请求 ID 不匹配。")
				return
			var step := session.submit_choice(1, response_data)
			if not step.success:
				_reject(step.error_code, step.message)
				return
			_broadcast_state(step.events)
		ProtocolV3.RESYNC_REQUEST:
			_send_state_to_client()
		ProtocolV3.SURRENDER:
			var step := session.surrender(1)
			_broadcast_state(step.events)
		ProtocolV3.PING:
			_send(ProtocolV3.PONG)
		_:
			_reject("unexpected_message", "房主不接受该消息。")


func _handle_client_message(message_type: String, payload: Dictionary) -> void:
	match message_type:
		ProtocolV3.WELCOME:
			player_idx = int(payload.get("player_idx", 1))
			_send(ProtocolV3.DECK_SELECT, {"deck_key": local_deck_key})
			events.append({"type": "connected", "player_idx": player_idx, "room_id": room_id})
		ProtocolV3.STATE_UPDATE:
			current_revision = int(payload.get("state", {}).get("revision", -1))
			awaiting_update = false
			events.append({
				"type": "state",
				"view": payload,
				"player_idx": player_idx,
			})
		ProtocolV3.ERROR:
			awaiting_update = false
			events.append({
				"type": "error",
				"code": str(payload.get("code", "remote_error")),
				"message": str(payload.get("message", "房主拒绝了请求。")),
			})
			if str(payload.get("code", "")) in [
				"stale_revision", "sequence_gap", "stale_sequence",
			]:
				request_resync()
		ProtocolV3.PING:
			_send(ProtocolV3.PONG)
		ProtocolV3.PONG:
			pass
		_:
			events.append({
				"type": "error",
				"code": "unexpected_message",
				"message": "客户端收到非预期消息。",
			})


func _revision_matches(row: Dictionary) -> bool:
	if session == null or session.state == null:
		_reject("not_started", "对局尚未开始。")
		return false
	if int(row["state_revision"]) != session.state.revision:
		_reject(
			"stale_revision",
			"局面版本已过期（收到 %d，当前 %d）。" % [
				int(row["state_revision"]),
				session.state.revision,
			],
		)
		_send_state_to_client()
		return false
	return true


func _broadcast_state(presentation_events: Array = []) -> void:
	if session == null or session.state == null:
		return
	events.append({
		"type": "state",
		"view": session.view_for(0, presentation_events),
		"player_idx": 0,
	})
	_send_state_to_client(presentation_events)


func _send_state_to_client(presentation_events: Array = []) -> void:
	if session == null or session.state == null:
		return
	_send(
		ProtocolV3.STATE_UPDATE,
		session.view_for(1, presentation_events),
		session.state.revision,
	)


func _reject(code: String, message: String) -> void:
	_send(ProtocolV3.ERROR, ProtocolV3.error_payload(code, message), get_revision())


func _send(
	message_type: String,
	payload: Dictionary = {},
	state_revision: int = -1,
	action_id: String = "",
	request_id: String = "",
) -> bool:
	if transport == null or not transport.connected_state():
		return false
	send_sequence += 1
	var sent := transport.send(ProtocolV3.envelope(
		message_type,
		room_id,
		0 if host else 1,
		send_sequence,
		state_revision,
		action_id,
		request_id,
		payload,
	))
	if sent:
		last_send_msec = Time.get_ticks_msec()
	return sent


func _drain_events() -> Array[Dictionary]:
	var result := events.duplicate(true)
	events.clear()
	return result

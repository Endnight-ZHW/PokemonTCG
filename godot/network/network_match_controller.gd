class_name NetworkMatchController
extends RefCounted

enum ConnectionPhase {
	CONNECTING,
	LOBBY,
	PLAYING,
	CLOSED,
}

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
var connection_phase: ConnectionPhase = ConnectionPhase.CLOSED
var deck_selection_sent := false
var last_receive_msec := 0
var last_send_msec := 0
const HEARTBEAT_INTERVAL_MSEC := 15000
const CONNECTION_TIMEOUT_MSEC := 45000
var seed := -1
var events: Array[Dictionary] = []


func host_lan(port: int, deck_key: String, match_seed: int = -1) -> Error:
	close()
	host = true
	player_idx = 0
	local_deck_key = deck_key
	seed = _resolved_match_seed(match_seed)
	room_id = "lan-%08x" % (Time.get_unix_time_from_system() as int)
	var enet := EnetTransport.new()
	var error := enet.start_host(port)
	if error == OK:
		transport = enet
		session = AuthoritativeSession.new(room_id)
		connection_phase = ConnectionPhase.CONNECTING
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
		connection_phase = ConnectionPhase.CONNECTING
	return error


func host_relay(relay_url: String, deck_key: String, match_seed: int = -1) -> Error:
	close()
	host = true
	player_idx = 0
	local_deck_key = deck_key
	seed = _resolved_match_seed(match_seed)
	var relay := WebSocketRelayTransport.new()
	var error := relay.start_host(relay_url)
	if error == OK:
		transport = relay
		connection_phase = ConnectionPhase.CONNECTING
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
		connection_phase = ConnectionPhase.CONNECTING
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
				if connection_phase != ConnectionPhase.CONNECTING:
					continue
				connected = true
				connection_phase = ConnectionPhase.LOBBY
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
			"disconnected", "connection_failed":
				connected = false
				connection_phase = ConnectionPhase.CLOSED
				events.append(event)
			"transport_error":
				connected = false
				connection_phase = ConnectionPhase.CLOSED
				transport.close()
				events.append(event)
				events.append({"type": "disconnected", "reason": "transport_error"})
	var now := Time.get_ticks_msec()
	if connected and now - last_send_msec >= HEARTBEAT_INTERVAL_MSEC:
		_send(ProtocolV3.PING, {}, get_revision())
	if connected and now - last_receive_msec >= CONNECTION_TIMEOUT_MSEC:
		connected = false
		connection_phase = ConnectionPhase.CLOSED
		events.append({"type": "disconnected", "reason": "timeout"})
	return _drain_events()


func needs_poll() -> bool:
	return transport != null or not events.is_empty()


func submit_action(action: GameAction) -> bool:
	if player_idx < 0 or connection_phase != ConnectionPhase.PLAYING:
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
	if player_idx < 0 or connection_phase != ConnectionPhase.PLAYING:
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
	if connection_phase != ConnectionPhase.PLAYING:
		return
	if host:
		if session != null:
			var step := session.surrender(0)
			_broadcast_state(step.events)
	else:
		_send(ProtocolV3.SURRENDER, {}, get_revision())


func request_resync() -> void:
	if not host and connection_phase == ConnectionPhase.PLAYING:
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
	connection_phase = ConnectionPhase.CLOSED
	deck_selection_sent = false
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
	var message_type := str(row["message_type"])
	var payload: Dictionary = row["payload"]
	receive_sequence = int(validation["sequence"])
	last_receive_msec = Time.get_ticks_msec()
	var payload_validation := ProtocolV3.validate_payload(message_type, payload)
	if not bool(payload_validation.get("ok", false)):
		var code := str(payload_validation.get("code", "invalid_payload"))
		var message_text := str(payload_validation.get("message", "消息内容无效。"))
		if host:
			_send(ProtocolV3.ERROR, ProtocolV3.error_payload(code, message_text))
		else:
			awaiting_update = false
			if message_type == ProtocolV3.STATE_UPDATE:
				request_resync()
		events.append({
			"type": "error",
			"code": code,
			"message": message_text,
		})
		return
	if (
		message_type == ProtocolV3.STATE_UPDATE
		and int(row["state_revision"])
		!= int(Dictionary(payload["state"]).get("revision", -1))
	):
		awaiting_update = false
		events.append({
			"type": "error",
			"code": "revision_mismatch",
			"message": "状态消息的局面版本不一致。",
		})
		if not host:
			request_resync()
		return
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
			if connection_phase != ConnectionPhase.LOBBY:
				_reject("invalid_phase", "牌组只能在大厅阶段选择。")
				return
			if (
				int(payload.get("rules_version", -1))
				!= AppState.RULES_SCHEMA_VERSION
				or int(payload.get("action_version", -1))
				!= AppState.ACTION_SCHEMA_VERSION
			):
				_reject("schema_mismatch", "规则或动作版本不兼容。")
				return
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
			connection_phase = ConnectionPhase.PLAYING
			_broadcast_state(result.events)
		ProtocolV3.ACTION_SUBMIT:
			if not _remote_message_allowed_while_playing():
				return
			if not _revision_matches(row):
				return
			var action_data: Dictionary = payload["action"]
			if str(row["action_id"]) != str(action_data.get("action_id", "")):
				_reject("action_id_mismatch", "动作 ID 不匹配。")
				return
			var step := session.submit_action(1, action_data)
			if not step.success:
				_reject(step.error_code, step.message)
				return
			_broadcast_state(step.events)
		ProtocolV3.CHOICE_SUBMIT:
			if not _remote_message_allowed_while_playing():
				return
			if not _revision_matches(row):
				return
			var response_data: Dictionary = payload["response"]
			if str(row["request_id"]) != str(response_data.get("request_id", "")):
				_reject("request_id_mismatch", "选择请求 ID 不匹配。")
				return
			var step := session.submit_choice(1, response_data)
			if not step.success:
				_reject(step.error_code, step.message)
				return
			_broadcast_state(step.events)
		ProtocolV3.RESYNC_REQUEST:
			if _remote_message_allowed_while_playing():
				_send_state_to_client()
		ProtocolV3.SURRENDER:
			if not _remote_message_allowed_while_playing():
				return
			var step := session.surrender(1)
			_broadcast_state(step.events)
		ProtocolV3.PING:
			_send(ProtocolV3.PONG)
		_:
			_reject("unexpected_message", "房主不接受该消息。")


func _handle_client_message(message_type: String, payload: Dictionary) -> void:
	match message_type:
		ProtocolV3.WELCOME:
			if (
				connection_phase != ConnectionPhase.LOBBY
				or deck_selection_sent
			):
				events.append({
					"type": "error",
					"code": "invalid_phase",
					"message": "欢迎消息只能处理一次。",
				})
				return
			if (
				int(payload.get("rules_version", -1))
				!= AppState.RULES_SCHEMA_VERSION
				or int(payload.get("action_version", -1))
				!= AppState.ACTION_SCHEMA_VERSION
			):
				connected = false
				connection_phase = ConnectionPhase.CLOSED
				if transport != null:
					transport.close()
				events.append({
					"type": "error",
					"code": "schema_mismatch",
					"message": "规则或动作版本不兼容。",
				})
				events.append({"type": "disconnected", "reason": "schema_mismatch"})
				return
			player_idx = int(payload.get("player_idx", 1))
			deck_selection_sent = _send(
				ProtocolV3.DECK_SELECT,
				{
					"deck_key": local_deck_key,
					"rules_version": AppState.RULES_SCHEMA_VERSION,
					"action_version": AppState.ACTION_SCHEMA_VERSION,
				},
			)
			if not deck_selection_sent:
				events.append({
					"type": "transport_error",
					"code": "deck_select_send_failed",
				})
				return
			events.append({"type": "connected", "player_idx": player_idx, "room_id": room_id})
		ProtocolV3.STATE_UPDATE:
			if connection_phase not in [
				ConnectionPhase.LOBBY,
				ConnectionPhase.PLAYING,
			]:
				events.append({
					"type": "error",
					"code": "invalid_phase",
					"message": "当前阶段不能接收局面同步。",
				})
				return
			var state_payload: Dictionary = payload["state"]
			current_revision = int(state_payload.get("revision", -1))
			awaiting_update = false
			connection_phase = ConnectionPhase.PLAYING
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


func _remote_message_allowed_while_playing() -> bool:
	if connection_phase == ConnectionPhase.PLAYING:
		return true
	_reject("invalid_phase", "对局尚未开始或已经结束。")
	return false


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
	var next_sequence := send_sequence + 1
	var sent := transport.send(ProtocolV3.envelope(
		message_type,
		room_id,
		0 if host else 1,
		next_sequence,
		state_revision,
		action_id,
		request_id,
		payload,
	))
	if sent:
		send_sequence = next_sequence
		last_send_msec = Time.get_ticks_msec()
	return sent


func _drain_events() -> Array[Dictionary]:
	var result := events.duplicate(true)
	events.clear()
	return result


func _resolved_match_seed(match_seed: int) -> int:
	if match_seed >= 0:
		return match_seed
	return PortableRandomSource.fresh_seed()

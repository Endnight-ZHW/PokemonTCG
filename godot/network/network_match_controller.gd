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
var catalog: CardCatalog
var host := false
var player_idx := -1
var room_id := ""
var local_deck_key := ""
var remote_deck_key := ""
var send_sequence := 0
var receive_sequence := 0
var current_revision := -1
# `awaiting_update` remains as a compatibility mirror for callers that only need
# a boolean. Correlation and timeout state live in `pending_submission`.
var awaiting_update := false
var pending_submission: Dictionary = {}
var resync_in_progress := false
var connected := false
var connection_phase: ConnectionPhase = ConnectionPhase.CLOSED
var deck_selection_sent := false
var last_receive_msec := 0
var last_send_msec := 0
var reconnecting := false
var reconnect_deadline_msec := 0
var next_reconnect_attempt_msec := 0
var transport_kind := ""
var lan_address := ""
var lan_port := 0
var relay_url := ""
var relay_resume_token := ""
const HEARTBEAT_INTERVAL_MSEC := 15000
const PENDING_SUBMISSION_TIMEOUT_MSEC := 10000
const CONNECTION_TIMEOUT_MSEC := 45000
const RECONNECT_GRACE_MSEC := 30000
const RECONNECT_RETRY_MSEC := 1200
var seed := -1
var events: Array[Dictionary] = []


func _init(p_catalog: CardCatalog = null) -> void:
	catalog = p_catalog if p_catalog != null else CardCatalog.shared()


func host_lan(port: int, deck_key: String, match_seed: int = -1) -> Error:
	close()
	if not catalog.decks.has(deck_key):
		return ERR_INVALID_PARAMETER
	host = true
	player_idx = 0
	local_deck_key = deck_key
	seed = _resolved_match_seed(match_seed)
	room_id = "lan-%08x" % (Time.get_unix_time_from_system() as int)
	transport_kind = "lan"
	lan_port = port
	var enet := _new_enet_transport()
	var error := enet.start_host(port)
	if error == OK:
		transport = enet
		session = AuthoritativeSession.new(room_id, catalog)
		connection_phase = ConnectionPhase.CONNECTING
	else:
		enet.close()
		close()
	return error


func join_lan(address: String, port: int, deck_key: String) -> Error:
	close()
	if not catalog.decks.has(deck_key):
		return ERR_INVALID_PARAMETER
	host = false
	player_idx = 1
	local_deck_key = deck_key
	transport_kind = "lan"
	lan_address = address
	lan_port = port
	var enet := _new_enet_transport()
	var error := enet.start_client(address, port)
	if error == OK:
		transport = enet
		connection_phase = ConnectionPhase.CONNECTING
	else:
		enet.close()
		close()
	return error


func host_relay(relay_url: String, deck_key: String, match_seed: int = -1) -> Error:
	close()
	if not catalog.decks.has(deck_key):
		return ERR_INVALID_PARAMETER
	host = true
	player_idx = 0
	local_deck_key = deck_key
	seed = _resolved_match_seed(match_seed)
	transport_kind = "relay"
	self.relay_url = relay_url
	var relay := _new_relay_transport()
	var error := relay.start_host(relay_url)
	if error == OK:
		transport = relay
		connection_phase = ConnectionPhase.CONNECTING
	else:
		relay.close()
		close()
	return error


func join_relay(relay_url: String, target_room: String, deck_key: String) -> Error:
	close()
	if not catalog.decks.has(deck_key):
		return ERR_INVALID_PARAMETER
	host = false
	player_idx = 1
	local_deck_key = deck_key
	room_id = target_room
	transport_kind = "relay"
	self.relay_url = relay_url
	var relay := _new_relay_transport()
	var error := relay.start_client(relay_url, target_room)
	if error == OK:
		transport = relay
		connection_phase = ConnectionPhase.CONNECTING
	else:
		relay.close()
		close()
	return error


func poll() -> Array[Dictionary]:
	_poll_reconnect()
	if connection_phase == ConnectionPhase.CLOSED:
		return _drain_events()
	if transport == null:
		return _drain_events()
	for event in transport.poll():
		match str(event.get("type", "")):
			"room_created":
				room_id = str(event.get("room_id", ""))
				relay_resume_token = str(event.get("resume_token", relay_resume_token))
				if host:
					session = AuthoritativeSession.new(room_id, catalog)
				events.append(event)
			"room_joined", "room_resumed":
				room_id = str(event.get("room_id", room_id))
				relay_resume_token = str(event.get("resume_token", relay_resume_token))
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
						session = AuthoritativeSession.new(room_id, catalog)
					_send(ProtocolV3.WELCOME, {
						"player_idx": 1,
						"rules_version": AppState.RULES_SCHEMA_VERSION,
						"action_version": AppState.ACTION_SCHEMA_VERSION,
						"resume": session != null and session.state != null,
					})
					events.append({"type": "connected", "player_idx": 0, "room_id": room_id})
				else:
					events.append({"type": "transport_connected", "room_id": room_id})
			"message":
				_handle_message(event.get("message", {}))
			"disconnected", "connection_failed":
				if _can_reconnect_match():
					_begin_reconnect(str(event.get("reason", event.get("type", "disconnected"))))
				else:
					connected = false
					connection_phase = ConnectionPhase.CLOSED
					_clear_pending_submission()
					resync_in_progress = false
					_discard_transport()
					events.append(event)
			"transport_error":
				if _can_reconnect_match():
					_begin_reconnect("transport_error")
				else:
					connected = false
					connection_phase = ConnectionPhase.CLOSED
					_clear_pending_submission()
					resync_in_progress = false
					_discard_transport()
					events.append(event)
					events.append({"type": "disconnected", "reason": "transport_error"})
	var now := Time.get_ticks_msec()
	_check_pending_submission_timeout(now)
	if (
		connected
		and connection_phase != ConnectionPhase.CLOSED
		and now - last_send_msec >= HEARTBEAT_INTERVAL_MSEC
	):
		_send(ProtocolV3.PING, {}, get_revision())
	if (
		connected
		and connection_phase != ConnectionPhase.CLOSED
		and now - last_receive_msec >= CONNECTION_TIMEOUT_MSEC
	):
		if _can_reconnect_match():
			_begin_reconnect("timeout")
		else:
			connected = false
			connection_phase = ConnectionPhase.CLOSED
			_clear_pending_submission()
			resync_in_progress = false
			_discard_transport()
			events.append({"type": "disconnected", "reason": "timeout"})
	return _drain_events()


func needs_poll() -> bool:
	return (
		reconnecting
		or not events.is_empty()
		or (transport != null and connection_phase != ConnectionPhase.CLOSED)
	)


func submit_action(action: GameAction) -> bool:
	if player_idx < 0 or connection_phase != ConnectionPhase.PLAYING:
		return false
	if not host and submission_locked():
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
			events.append({
				"type": "error",
				"code": step.error_code,
				"message": step.message,
				"origin_action_id": action.action_id,
				"origin_request_id": "",
			})
			return false
		_broadcast_state(step.events, action.action_id)
		return true
	var base_revision := get_revision()
	var sent := _send(
		ProtocolV3.ACTION_SUBMIT,
		{"action": action.to_dict()},
		get_revision(),
		action.action_id,
	)
	if sent:
		_begin_pending_submission(
			"action", action.action_id, "", base_revision
		)
	return sent


func submit_choice(response: ChoiceResponse) -> bool:
	if player_idx < 0 or connection_phase != ConnectionPhase.PLAYING:
		return false
	if not host and submission_locked():
		return false
	if host:
		var step := session.submit_choice(0, response.to_dict())
		if not step.success:
			events.append({
				"type": "error",
				"code": step.error_code,
				"message": step.message,
				"origin_action_id": "",
				"origin_request_id": response.request_id,
			})
			return false
		_broadcast_state(step.events, "", response.request_id)
		return true
	var base_revision := get_revision()
	var sent := _send(
		ProtocolV3.CHOICE_SUBMIT,
		{"response": response.to_dict()},
		get_revision(),
		"",
		response.request_id,
	)
	if sent:
		_begin_pending_submission(
			"choice", "", response.request_id, base_revision
		)
	return sent


func surrender() -> void:
	if connection_phase != ConnectionPhase.PLAYING:
		return
	if host:
		if session != null:
			var step := session.surrender(0)
			if not step.success:
				events.append({
					"type": "error",
					"code": step.error_code,
					"message": step.message,
				})
				return
			_broadcast_state(step.events)
	else:
		_send(ProtocolV3.SURRENDER, {}, get_revision())


func request_resync() -> void:
	if not host and connection_phase == ConnectionPhase.PLAYING:
		if resync_in_progress:
			return
		resync_in_progress = true
		_send(ProtocolV3.RESYNC_REQUEST, {}, get_revision())


func submission_locked() -> bool:
	return reconnecting or not pending_submission.is_empty() or resync_in_progress


func begin_reconnect(reason: String = "connection_interrupted") -> void:
	if _can_reconnect_match():
		_begin_reconnect(reason)


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
	_clear_pending_submission()
	resync_in_progress = false
	reconnecting = false
	reconnect_deadline_msec = 0
	next_reconnect_attempt_msec = 0
	connected = false
	connection_phase = ConnectionPhase.CLOSED
	deck_selection_sent = false
	last_receive_msec = 0
	last_send_msec = 0
	transport_kind = ""
	lan_address = ""
	lan_port = 0
	relay_url = ""
	relay_resume_token = ""
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
		var recoverable_gap := code == "sequence_gap" and message is Dictionary
		if recoverable_gap:
			# The envelope has already passed all structural, room and sender
			# validation before ProtocolV3 reports a gap.  Adopt its sequence as a
			# recovery fence, discard its payload, and request a fresh snapshot.
			# Otherwise every later RESYNC reply is rejected against the same gap.
			receive_sequence = int(Dictionary(message).get("sequence", receive_sequence))
		var origin_action_id := _envelope_identifier(message, "action_id")
		var origin_request_id := _envelope_identifier(message, "request_id")
		if host:
			_send(
				ProtocolV3.ERROR,
				ProtocolV3.error_payload(
					code, str(validation.get("message", "消息无效。"))
				),
				get_revision(),
				origin_action_id,
				origin_request_id,
			)
		events.append({
			"type": "error",
			"code": code,
			"message": str(validation.get("message", "消息无效。")),
			"origin_action_id": origin_action_id,
			"origin_request_id": origin_request_id,
		})
		if recoverable_gap and not host:
			request_resync()
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
		var origin_action_id := str(row.get("action_id", ""))
		var origin_request_id := str(row.get("request_id", ""))
		if host:
			_send(
				ProtocolV3.ERROR,
				ProtocolV3.error_payload(code, message_text),
				get_revision(),
				origin_action_id,
				origin_request_id,
			)
		else:
			if message_type == ProtocolV3.STATE_UPDATE:
				request_resync()
		events.append({
			"type": "error",
			"code": code,
			"message": message_text,
			"origin_action_id": origin_action_id,
			"origin_request_id": origin_request_id,
		})
		return
	if (
		message_type == ProtocolV3.STATE_UPDATE
		and int(row["state_revision"])
		!= int(Dictionary(payload["state"]).get("revision", -1))
	):
		events.append({
			"type": "error",
			"code": "revision_mismatch",
			"message": "状态消息的局面版本不一致。",
			"origin_action_id": str(row.get("action_id", "")),
			"origin_request_id": str(row.get("request_id", "")),
		})
		if not host:
			request_resync()
		return
	if host:
		_handle_host_message(row, message_type, payload)
	else:
		_handle_client_message(row, message_type, payload)


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
			if not catalog.decks.has(deck_key):
				_send(ProtocolV3.ERROR, ProtocolV3.error_payload(
					"invalid_deck", "未知牌组。"))
				return
			var resume_requested := bool(payload.get("resume", false))
			if session != null and session.state != null:
				if not resume_requested or (
					not remote_deck_key.is_empty() and deck_key != remote_deck_key
				):
					_reject("resume_mismatch", "恢复请求与当前对局不匹配。")
					return
				remote_deck_key = deck_key
				reconnecting = false
				resync_in_progress = false
				connection_phase = ConnectionPhase.PLAYING
				events.append({"type": "reconnected", "player_idx": 0})
				events.append({
					"type": "state",
					"view": session.view_for(0),
					"player_idx": 0,
					"origin_action_id": "",
					"origin_request_id": "",
					"matched_pending": false,
					"is_resync": true,
				})
				_send_state_to_client()
				return
			if resume_requested:
				_reject("resume_unavailable", "房主已无法恢复该对局。")
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
			if not _remote_message_allowed_while_playing(row):
				return
			if not _revision_matches(row):
				return
			var action_data: Dictionary = payload["action"]
			if str(row["action_id"]) != str(action_data.get("action_id", "")):
				_reject("action_id_mismatch", "动作 ID 不匹配。", row)
				return
			var step := session.submit_action(1, action_data)
			if not step.success:
				_reject(step.error_code, step.message, row)
				return
			_broadcast_state(
				step.events,
				str(row.get("action_id", "")),
				str(row.get("request_id", "")),
			)
		ProtocolV3.CHOICE_SUBMIT:
			if not _remote_message_allowed_while_playing(row):
				return
			if not _revision_matches(row):
				return
			var response_data: Dictionary = payload["response"]
			if str(row["request_id"]) != str(response_data.get("request_id", "")):
				_reject("request_id_mismatch", "选择请求 ID 不匹配。", row)
				return
			var step := session.submit_choice(1, response_data)
			if not step.success:
				_reject(step.error_code, step.message, row)
				return
			_broadcast_state(
				step.events,
				str(row.get("action_id", "")),
				str(row.get("request_id", "")),
			)
		ProtocolV3.RESYNC_REQUEST:
			if _remote_message_allowed_while_playing(row):
				_send_state_to_client()
		ProtocolV3.SURRENDER:
			if not _remote_message_allowed_while_playing(row):
				return
			var step := session.surrender(1)
			if not step.success:
				_reject(step.error_code, step.message, row)
				return
			_broadcast_state(step.events)
		ProtocolV3.PING:
			_send(ProtocolV3.PONG)
		_:
			_reject("unexpected_message", "房主不接受该消息。")


func _handle_client_message(
	row: Dictionary,
	message_type: String,
	payload: Dictionary,
) -> void:
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
				_clear_pending_submission()
				resync_in_progress = false
				_discard_transport()
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
					"resume": reconnecting or current_revision >= 0,
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
			var next_revision := int(state_payload.get("revision", -1))
			if current_revision >= 0 and next_revision < current_revision:
				events.append({
					"type": "error",
					"code": "stale_state_revision",
					"message": "收到的局面版本早于当前局面，正在重新同步。",
					"origin_action_id": str(row.get("action_id", "")),
					"origin_request_id": str(row.get("request_id", "")),
					"matched_pending": false,
				})
				request_resync()
				return
			var was_reconnecting := reconnecting
			var is_recovery_snapshot := resync_in_progress or was_reconnecting
			var origins := _resolve_pending_state(row, next_revision)
			current_revision = next_revision
			resync_in_progress = false
			reconnecting = false
			reconnect_deadline_msec = 0
			next_reconnect_attempt_msec = 0
			connection_phase = (
				ConnectionPhase.CLOSED
				if str(state_payload.get("phase", "")) == "GAME_OVER"
				else ConnectionPhase.PLAYING
			)
			if was_reconnecting:
				events.append({"type": "reconnected", "player_idx": player_idx})
			events.append({
				"type": "state",
				"view": payload,
				"player_idx": player_idx,
				"is_resync": is_recovery_snapshot,
				"origin_action_id": str(origins.get("action_id", "")),
				"origin_request_id": str(origins.get("request_id", "")),
				"matched_pending": bool(origins.get("matched", false)),
			})
			if connection_phase == ConnectionPhase.CLOSED:
				_clear_pending_submission()
		ProtocolV3.ERROR:
			var origins := _resolve_pending_error(row)
			events.append({
				"type": "error",
				"code": str(payload.get("code", "remote_error")),
				"message": str(payload.get("message", "房主拒绝了请求。")),
				"origin_action_id": str(origins.get("action_id", "")),
				"origin_request_id": str(origins.get("request_id", "")),
				"matched_pending": bool(origins.get("matched", false)),
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
		_reject("not_started", "对局尚未开始。", row)
		return false
	if int(row["state_revision"]) != session.state.revision:
		_reject(
			"stale_revision",
			"局面版本已过期（收到 %d，当前 %d）。" % [
				int(row["state_revision"]),
				session.state.revision,
			],
			row,
		)
		_send_state_to_client()
		return false
	return true


func _remote_message_allowed_while_playing(row: Dictionary = {}) -> bool:
	if connection_phase == ConnectionPhase.PLAYING:
		return true
	_reject("invalid_phase", "对局尚未开始或已经结束。", row)
	return false


func _broadcast_state(
	presentation_events: Array = [],
	origin_action_id: String = "",
	origin_request_id: String = "",
) -> void:
	if session == null or session.state == null:
		return
	events.append({
		"type": "state",
		"view": session.view_for(0, presentation_events),
		"player_idx": 0,
		"origin_action_id": origin_action_id,
		"origin_request_id": origin_request_id,
	})
	_send_state_to_client(
		presentation_events, origin_action_id, origin_request_id
	)
	if session.state.phase == "GAME_OVER" or session.state.winner >= 0:
		_clear_pending_submission()
		resync_in_progress = false
		connection_phase = ConnectionPhase.CLOSED


func _send_state_to_client(
	presentation_events: Array = [],
	origin_action_id: String = "",
	origin_request_id: String = "",
) -> void:
	if session == null or session.state == null:
		return
	_send(
		ProtocolV3.STATE_UPDATE,
		session.view_for(1, presentation_events),
		session.state.revision,
		origin_action_id,
		origin_request_id,
	)


func _reject(
	code: String,
	message: String,
	origin: Dictionary = {},
) -> void:
	_send(
		ProtocolV3.ERROR,
		ProtocolV3.error_payload(code, message),
		get_revision(),
		str(origin.get("action_id", "")),
		str(origin.get("request_id", "")),
	)


func _begin_pending_submission(
	kind: String,
	action_id: String,
	request_id: String,
	base_revision: int,
) -> void:
	pending_submission = {
		"kind": kind,
		"action_id": action_id,
		"request_id": request_id,
		"base_revision": base_revision,
		"sent_msec": Time.get_ticks_msec(),
		"timeout_notified": false,
	}
	awaiting_update = true


func _clear_pending_submission() -> void:
	pending_submission.clear()
	awaiting_update = false


func _check_pending_submission_timeout(now_msec: int) -> void:
	if host or pending_submission.is_empty():
		return
	if bool(pending_submission.get("timeout_notified", false)):
		return
	var sent_msec := int(pending_submission.get("sent_msec", now_msec))
	if now_msec - sent_msec < PENDING_SUBMISSION_TIMEOUT_MSEC:
		return
	pending_submission["timeout_notified"] = true
	pending_submission["timeout_msec"] = now_msec
	events.append({
		"type": "pending_timeout",
		"code": "authoritative_timeout",
		"base_revision": int(pending_submission.get("base_revision", -1)),
		"origin_action_id": str(pending_submission.get("action_id", "")),
		"origin_request_id": str(pending_submission.get("request_id", "")),
	})
	request_resync()


func _resolve_pending_state(row: Dictionary, next_revision: int) -> Dictionary:
	var origins := {
		"action_id": str(row.get("action_id", "")),
		"request_id": str(row.get("request_id", "")),
		"matched": false,
	}
	if pending_submission.is_empty():
		return origins
	var pending_action_id := str(pending_submission.get("action_id", ""))
	var pending_request_id := str(pending_submission.get("request_id", ""))
	var incoming_action_id := str(origins["action_id"])
	var incoming_request_id := str(origins["request_id"])
	var has_incoming_origin := (
		not incoming_action_id.is_empty()
		or not incoming_request_id.is_empty()
	)
	var matched := false
	if has_incoming_origin:
		var identifier_matches := (
			(not pending_action_id.is_empty() and incoming_action_id == pending_action_id)
			or (
				not pending_request_id.is_empty()
				and incoming_request_id == pending_request_id
			)
		)
		matched = (
			identifier_matches
			and next_revision > int(pending_submission.get("base_revision", -1))
		)
		if identifier_matches and not matched:
			# An echoed identifier without a causally newer authoritative state is
			# not a confirmation. Hide it from presentation correlation so a stale
			# echo cannot commit a parked drag proxy.
			origins["action_id"] = ""
			origins["request_id"] = ""
	elif bool(pending_submission.get("timeout_notified", false)):
		# A valid state received after our explicit resync completes recovery,
		# but is not presented as confirmation of the timed-out action.
		matched = true
	elif resync_in_progress:
		# Protocol recovery can legitimately return the same revision (for
		# example after rejecting a stale or malformed submission). The valid
		# uncorrelated snapshot releases the lock without attributing the action.
		matched = true
	elif next_revision > int(pending_submission.get("base_revision", -1)):
		# Protocol V3 peers predating correlation echo sent an empty envelope.
		# With one in-flight submission, a strict revision advance is unambiguous.
		origins["action_id"] = pending_action_id
		origins["request_id"] = pending_request_id
		matched = true
	if matched:
		origins["matched"] = true
		_clear_pending_submission()
	return origins


func _resolve_pending_error(row: Dictionary) -> Dictionary:
	var origins := {
		"action_id": str(row.get("action_id", "")),
		"request_id": str(row.get("request_id", "")),
		"matched": false,
	}
	if pending_submission.is_empty():
		return origins
	var pending_action_id := str(pending_submission.get("action_id", ""))
	var pending_request_id := str(pending_submission.get("request_id", ""))
	var incoming_action_id := str(origins["action_id"])
	var incoming_request_id := str(origins["request_id"])
	var has_incoming_origin := (
		not incoming_action_id.is_empty()
		or not incoming_request_id.is_empty()
	)
	var matched := false
	if has_incoming_origin:
		matched = (
			(not pending_action_id.is_empty() and incoming_action_id == pending_action_id)
			or (
				not pending_request_id.is_empty()
				and incoming_request_id == pending_request_id
			)
		)
	else:
		# Legacy errors did not echo correlation identifiers. There can only be
		# one in-flight client submission, so the rejection is still attributable.
		origins["action_id"] = pending_action_id
		origins["request_id"] = pending_request_id
		matched = true
	if matched:
		origins["matched"] = true
		_clear_pending_submission()
	return origins


func _envelope_identifier(message: Variant, field: String) -> String:
	if not message is Dictionary:
		return ""
	var value: Variant = Dictionary(message).get(field, "")
	if not value is String:
		return ""
	var identifier := str(value)
	if identifier.to_utf8_buffer().size() > ProtocolV3.MAX_IDENTIFIER_BYTES:
		return ""
	return identifier


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


func _discard_transport() -> void:
	var current_transport := transport
	transport = null
	if current_transport != null:
		current_transport.close()


func _can_reconnect_match() -> bool:
	if transport_kind not in ["lan", "relay"]:
		return false
	if host:
		return session != null and session.state != null and session.state.winner < 0
	return (
		current_revision >= 0
		and connection_phase != ConnectionPhase.CLOSED
	) or reconnecting


func _begin_reconnect(reason: String) -> void:
	var first_attempt := not reconnecting
	connected = false
	connection_phase = ConnectionPhase.CONNECTING
	_clear_pending_submission()
	resync_in_progress = not host
	_discard_transport()
	if first_attempt:
		reconnecting = true
		send_sequence = 0
		receive_sequence = 0
		deck_selection_sent = false
		var now := Time.get_ticks_msec()
		reconnect_deadline_msec = now + RECONNECT_GRACE_MSEC
		next_reconnect_attempt_msec = now + 250
		events.append({
			"type": "reconnecting",
			"reason": reason,
			"deadline_msec": reconnect_deadline_msec,
		})
	else:
		next_reconnect_attempt_msec = Time.get_ticks_msec() + RECONNECT_RETRY_MSEC


func _poll_reconnect() -> void:
	if not reconnecting:
		return
	var now := Time.get_ticks_msec()
	if now >= reconnect_deadline_msec:
		reconnecting = false
		resync_in_progress = false
		connection_phase = ConnectionPhase.CLOSED
		_discard_transport()
		events.append({"type": "disconnected", "reason": "reconnect_timeout"})
		return
	if transport != null or now < next_reconnect_attempt_msec:
		return
	var error := _start_reconnect_transport()
	if error != OK:
		_discard_transport()
		next_reconnect_attempt_msec = now + RECONNECT_RETRY_MSEC


func _start_reconnect_transport() -> Error:
	if transport_kind == "lan":
		var enet := _new_enet_transport()
		var error := (
			enet.start_host(lan_port)
			if host
			else enet.start_client(lan_address, lan_port)
		)
		if error == OK:
			transport = enet
		return error
	if transport_kind == "relay":
		var relay := _new_relay_transport()
		var error := relay.resume_session(
			relay_url,
			room_id,
			"p1" if host else "p2",
			relay_resume_token,
		)
		if error == OK:
			transport = relay
		return error
	return ERR_UNAVAILABLE


func _new_enet_transport() -> EnetTransport:
	return EnetTransport.new()


func _new_relay_transport() -> WebSocketRelayTransport:
	return WebSocketRelayTransport.new()


func _resolved_match_seed(match_seed: int) -> int:
	if match_seed >= 0:
		return match_seed
	return PortableRandomSource.fresh_seed()

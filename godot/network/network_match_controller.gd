class_name NetworkMatchController
extends "res://network/network_match_controller_dispatch.gd"

func _init(p_catalog: CardCatalog = null) -> void:
	catalog = p_catalog if p_catalog != null else CardCatalog.shared()


func host_lan(
	port: int,
	deck_key: String,
	match_seed: int = -1,
	apply_type_matchups: bool = false,
) -> Error:
	close()
	if not catalog.decks.has(deck_key):
		return ERR_INVALID_PARAMETER
	host = true
	player_idx = 0
	local_deck_key = deck_key
	rules_options = {"apply_type_matchups": apply_type_matchups}
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


func host_relay(
	relay_url: String,
	deck_key: String,
	match_seed: int = -1,
	apply_type_matchups: bool = false,
) -> Error:
	close()
	if not catalog.decks.has(deck_key):
		return ERR_INVALID_PARAMETER
	host = true
	player_idx = 0
	local_deck_key = deck_key
	rules_options = {"apply_type_matchups": apply_type_matchups}
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
	var polled_transport := transport
	var transport_events := polled_transport.poll()
	for event in transport_events:
		# A disconnect/error can replace or discard the transport while handling the
		# current event. Ignore all later events from that retired connection epoch.
		if transport != polled_transport:
			break
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
					_send(ProtocolV6.WELCOME, {
						"player_idx": 1,
						"rules_version": AppState.RULES_SCHEMA_VERSION,
						"action_version": AppState.ACTION_SCHEMA_VERSION,
						"core_fingerprint": _core_fingerprint(),
						"rules_profile_id": GameState.RULES_PROFILE_ID,
						"rules_options": rules_options.duplicate(true),
						"resume": session != null and session.state != null,
					})
					events.append({
						"type": "connected",
						"player_idx": 0,
						"room_id": room_id,
						"rules_options": rules_options.duplicate(true),
					})
				else:
					events.append({"type": "transport_connected", "room_id": room_id})
			"message":
				_handle_message(event.get("message", {}))
			"disconnected", "connection_failed":
				if connection_phase == ConnectionPhase.FINISHING and not host:
					_finish_terminal_connection()
				elif _can_reconnect_match():
					_begin_reconnect(str(event.get("reason", event.get("type", "disconnected"))))
				else:
					connected = false
					connection_phase = ConnectionPhase.CLOSED
					_clear_pending_submission()
					resync_in_progress = false
					_discard_transport()
					events.append(event)
			"transport_error":
				if connection_phase == ConnectionPhase.FINISHING and not host:
					_finish_terminal_connection()
				elif _can_reconnect_match():
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
	_poll_terminal_delivery(now)
	if (
		connected
		and connection_phase != ConnectionPhase.CLOSED
		and now - last_send_msec >= HEARTBEAT_INTERVAL_MSEC
	):
		_send(ProtocolV6.PING, {}, get_revision())
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
	action.base_revision = get_revision()
	action.schema_version = GameAction.SCHEMA_VERSION
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
		ProtocolV6.ACTION_SUBMIT,
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
		ProtocolV6.CHOICE_SUBMIT,
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
		_send(ProtocolV6.SURRENDER, {}, get_revision())



func submission_locked() -> bool:
	return reconnecting or not pending_submission.is_empty() or resync_in_progress


func begin_reconnect(reason: String = "connection_interrupted") -> void:
	if _can_reconnect_match():
		_begin_reconnect(reason)

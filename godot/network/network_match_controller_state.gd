extends RefCounted

enum ConnectionPhase {
	CONNECTING,
	LOBBY,
	PLAYING,
	FINISHING,
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
var rules_options: Dictionary = {"apply_type_matchups": false}
var terminal_revision := -1
var terminal_delivery_deadline_msec := 0
var terminal_last_ack_send_msec := 0
var terminal_last_state_send_msec := 0
const HEARTBEAT_INTERVAL_MSEC := 15000
const PENDING_SUBMISSION_TIMEOUT_MSEC := 10000
const CONNECTION_TIMEOUT_MSEC := 45000
const RECONNECT_GRACE_MSEC := 30000
const RECONNECT_RETRY_MSEC := 1200
const TERMINAL_DELIVERY_GRACE_MSEC := 30000
const TERMINAL_ACK_RETRY_MSEC := 1000
const TERMINAL_STATE_RETRY_MSEC := 1000
var seed := -1
var events: Array[Dictionary] = []


func request_resync() -> void:
	if not host and connection_phase == ConnectionPhase.PLAYING:
		if resync_in_progress:
			return
		if _send(ProtocolV6.RESYNC_REQUEST, {}, get_revision()):
			resync_in_progress = true
		elif _can_reconnect_match():
			_begin_reconnect("resync_send_failed")
		else:
			events.append({
				"type": "transport_error",
				"code": "resync_send_failed",
			})



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
	rules_options = {"apply_type_matchups": false}
	terminal_revision = -1
	terminal_delivery_deadline_msec = 0
	terminal_last_ack_send_msec = 0
	terminal_last_state_send_msec = 0
	events.clear()



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
	if connection_phase == ConnectionPhase.FINISHING:
		_reject("game_over", "对局已经结束。", row)
		_send_state_to_client()
		return false
	_reject("invalid_phase", "对局尚未开始或已经结束。", row)
	return false


func _remote_state_sync_allowed(row: Dictionary = {}) -> bool:
	if connection_phase in [
		ConnectionPhase.PLAYING,
		ConnectionPhase.FINISHING,
	]:
		return true
	_reject("invalid_phase", "当前阶段无法同步局面。", row)
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
		_begin_terminal_delivery(session.state.revision)


func _send_state_to_client(
	presentation_events: Array = [],
	origin_action_id: String = "",
	origin_request_id: String = "",
) -> void:
	if session == null or session.state == null:
		return
	var sent := _send(
		ProtocolV6.STATE_UPDATE,
		session.view_for(1, presentation_events),
		session.state.revision,
		origin_action_id,
		origin_request_id,
	)
	if sent and session.state.is_terminal():
		terminal_last_state_send_msec = Time.get_ticks_msec()


func _reject(
	code: String,
	message: String,
	origin: Dictionary = {},
) -> void:
	_send(
		ProtocolV6.ERROR,
		ProtocolV6.error_payload(code, message),
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


func _clear_pending_submission() -> void:
	pending_submission.clear()


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
		# Uncorrelated recovery snapshots can still advance the authoritative
		# revision. With one in-flight submission that advance is unambiguous.
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
	if identifier.to_utf8_buffer().size() > ProtocolV6.MAX_IDENTIFIER_BYTES:
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
	var sent := transport.send(ProtocolV6.envelope(
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


func _begin_terminal_delivery(revision: int) -> void:
	terminal_revision = revision
	if terminal_delivery_deadline_msec <= 0:
		terminal_delivery_deadline_msec = (
			Time.get_ticks_msec() + TERMINAL_DELIVERY_GRACE_MSEC
		)
	connection_phase = ConnectionPhase.FINISHING
	if not host:
		_send_terminal_ack(Time.get_ticks_msec())


func _send_terminal_ack(now_msec: int) -> bool:
	if host or terminal_revision < 0:
		return false
	var sent := _send(
		ProtocolV6.PONG,
		{},
		terminal_revision,
	)
	if sent:
		terminal_last_ack_send_msec = now_msec
	return sent


func _poll_terminal_delivery(now_msec: int) -> void:
	if connection_phase != ConnectionPhase.FINISHING:
		return
	if (
		terminal_delivery_deadline_msec > 0
		and now_msec >= terminal_delivery_deadline_msec
	):
		_finish_terminal_connection()
		return
	if (
		host
		and now_msec - terminal_last_state_send_msec
		>= TERMINAL_STATE_RETRY_MSEC
	):
		_send_state_to_client()
	if (
		not host
		and now_msec - terminal_last_ack_send_msec
		>= TERMINAL_ACK_RETRY_MSEC
	):
		_send_terminal_ack(now_msec)


func _finish_terminal_connection() -> void:
	_clear_pending_submission()
	resync_in_progress = false
	reconnecting = false
	reconnect_deadline_msec = 0
	next_reconnect_attempt_msec = 0
	connected = false
	connection_phase = ConnectionPhase.CLOSED
	_discard_transport()
	terminal_revision = -1
	terminal_delivery_deadline_msec = 0
	terminal_last_ack_send_msec = 0
	terminal_last_state_send_msec = 0


func _can_reconnect_match() -> bool:
	if transport_kind not in ["lan", "relay"]:
		return false
	if host:
		return (
			session != null
			and session.state != null
			and (
				not session.state.is_terminal()
				or (
					terminal_revision >= 0
					and Time.get_ticks_msec()
					< terminal_delivery_deadline_msec
				)
			)
		)
	if terminal_revision >= 0:
		return false
	return (
		current_revision >= 0
		and connection_phase != ConnectionPhase.CLOSED
	) or reconnecting


func _core_fingerprint() -> String:
	var content_fingerprint := str(catalog.card_ir.get("content_fingerprint", ""))
	var contract_fingerprint := str(catalog.card_ir.get("contract_fingerprint", ""))
	var manifest := _release_manifest()
	var native_rules: Dictionary = Dictionary(manifest.get("native_rules", {}))
	var native_core_fingerprint := str(native_rules.get("core_fingerprint", ""))
	if (
		not ProtocolV6._valid_sha256(content_fingerprint)
		or not ProtocolV6._valid_sha256(contract_fingerprint)
		or not ProtocolV6._valid_sha256(native_core_fingerprint)
		or str(native_rules.get("card_ir_content_fingerprint", ""))
		!= content_fingerprint
		or str(native_rules.get("card_ir_contract_fingerprint", ""))
		!= contract_fingerprint
	):
		return ""
	return ("%s\n%s\n%s" % [
		content_fingerprint,
		contract_fingerprint,
		native_core_fingerprint,
	]).sha256_text()


func _release_manifest() -> Dictionary:
	var file := FileAccess.open(AppState.RELEASE_MANIFEST_PATH, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	return Dictionary(parsed) if parsed is Dictionary else {}


func _peer_core_compatible(payload: Dictionary) -> bool:
	var peer := str(payload.get("core_fingerprint", ""))
	var local := _core_fingerprint()
	return not local.is_empty() and peer == local


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
		if host and terminal_revision >= 0:
			_finish_terminal_connection()
			return
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

extends "res://network/network_match_controller_state.gd"

func _handle_message(message: Variant) -> void:
	if (
		not host
		and room_id.is_empty()
		and message is Dictionary
		and str(message.get("message_type", "")) == ProtocolV6.WELCOME
	):
		room_id = str(message.get("room_id", ""))
	var validation := ProtocolV6.validate(
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
			# validation before ProtocolV6 reports a gap.  Adopt its sequence as a
			# recovery fence, discard its payload, and request a fresh snapshot.
			# Otherwise every later RESYNC reply is rejected against the same gap.
			receive_sequence = int(Dictionary(message).get("sequence", receive_sequence))
		var origin_action_id := _envelope_identifier(message, "action_id")
		var origin_request_id := _envelope_identifier(message, "request_id")
		if host:
			_send(
				ProtocolV6.ERROR,
				ProtocolV6.error_payload(
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
	var payload_validation := ProtocolV6.validate_payload(message_type, payload)
	if not bool(payload_validation.get("ok", false)):
		var code := str(payload_validation.get("code", "invalid_payload"))
		var message_text := str(payload_validation.get("message", "消息内容无效。"))
		if message_type == ProtocolV6.STATE_UPDATE:
			message_text += " groups=%s" % JSON.stringify(
				payload.get("legal_action_groups", []))
		var origin_action_id := str(row.get("action_id", ""))
		var origin_request_id := str(row.get("request_id", ""))
		if host:
			_send(
				ProtocolV6.ERROR,
				ProtocolV6.error_payload(code, message_text),
				get_revision(),
				origin_action_id,
				origin_request_id,
			)
		else:
			if message_type == ProtocolV6.STATE_UPDATE:
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
		message_type == ProtocolV6.STATE_UPDATE
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
		ProtocolV6.DECK_SELECT:
			if connection_phase != ConnectionPhase.LOBBY:
				_reject("invalid_phase", "牌组只能在大厅阶段选择。")
				return
			if (
				int(payload.get("rules_version", -1))
				!= AppState.RULES_SCHEMA_VERSION
				or int(payload.get("action_version", -1))
				!= AppState.ACTION_SCHEMA_VERSION
				or str(payload.get("rules_profile_id", ""))
				!= GameState.RULES_PROFILE_ID
				or not _peer_core_compatible(payload)
			):
				_reject("schema_mismatch", "卡牌内容或规则核心版本不兼容。")
				return
			var peer_rules_options: Dictionary = Dictionary(
				payload.get("rules_options", {})).duplicate(true)
			if peer_rules_options != rules_options:
				_reject("rules_options_mismatch", "规则选项与房主锁定配置不一致。")
				return
			var deck_key := str(payload.get("deck_key", ""))
			if not catalog.decks.has(deck_key):
				_send(ProtocolV6.ERROR, ProtocolV6.error_payload(
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
				var resumed_terminal := session.state.is_terminal()
				connection_phase = (
					ConnectionPhase.FINISHING
					if resumed_terminal
					else ConnectionPhase.PLAYING
				)
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
				if resumed_terminal:
					_begin_terminal_delivery(session.state.revision)
				return
			if resume_requested:
				_reject("resume_unavailable", "房主已无法恢复该对局。")
				return
			remote_deck_key = deck_key
			var result := session.start_match(
				local_deck_key,
				remote_deck_key,
				seed,
				-1,
				rules_options,
			)
			if not result.success:
				_send(ProtocolV6.ERROR, ProtocolV6.error_payload(
					result.error_code, result.message))
				return
			connection_phase = ConnectionPhase.PLAYING
			_broadcast_state(result.events)
		ProtocolV6.ACTION_SUBMIT:
			if not _remote_message_allowed_while_playing(row):
				return
			if (
				not str(row.get("action_id", "")).is_empty()
				and str(row.get("action_id", "")) in session.state.processed_action_ids
			):
				_reject("duplicate_action", "动作已处理。", row)
				_send_state_to_client()
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
		ProtocolV6.CHOICE_SUBMIT:
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
		ProtocolV6.RESYNC_REQUEST:
			if _remote_state_sync_allowed(row):
				_send_state_to_client()
		ProtocolV6.SURRENDER:
			if not _remote_message_allowed_while_playing(row):
				return
			var step := session.surrender(1)
			if not step.success:
				_reject(step.error_code, step.message, row)
				return
			_broadcast_state(step.events)
		ProtocolV6.PING:
			_send(ProtocolV6.PONG, {}, get_revision())
		ProtocolV6.PONG:
			if (
				connection_phase == ConnectionPhase.FINISHING
				and session != null
				and session.state != null
				and session.state.is_terminal()
				and int(row.get("state_revision", -1)) == terminal_revision
			):
				_finish_terminal_connection()
		_:
			_reject("unexpected_message", "房主不接受该消息。")


func _handle_client_message(
	row: Dictionary,
	message_type: String,
	payload: Dictionary,
) -> void:
	match message_type:
		ProtocolV6.WELCOME:
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
				or str(payload.get("rules_profile_id", ""))
				!= GameState.RULES_PROFILE_ID
				or not _peer_core_compatible(payload)
			):
				connected = false
				connection_phase = ConnectionPhase.CLOSED
				_clear_pending_submission()
				resync_in_progress = false
				_discard_transport()
				events.append({
					"type": "error",
					"code": "schema_mismatch",
					"message": "卡牌内容或规则核心版本不兼容。",
				})
				events.append({"type": "disconnected", "reason": "schema_mismatch"})
				return
			rules_options = Dictionary(payload.get("rules_options", {})).duplicate(true)
			player_idx = int(payload.get("player_idx", 1))
			deck_selection_sent = _send(
				ProtocolV6.DECK_SELECT,
				{
					"deck_key": local_deck_key,
					"rules_version": AppState.RULES_SCHEMA_VERSION,
					"action_version": AppState.ACTION_SCHEMA_VERSION,
					"core_fingerprint": _core_fingerprint(),
					"rules_profile_id": GameState.RULES_PROFILE_ID,
					"rules_options": rules_options.duplicate(true),
					"resume": reconnecting or current_revision >= 0,
				},
			)
			if not deck_selection_sent:
				events.append({
					"type": "transport_error",
					"code": "deck_select_send_failed",
				})
				return
			events.append({
				"type": "connected",
				"player_idx": player_idx,
				"room_id": room_id,
				"rules_options": rules_options.duplicate(true),
			})
		ProtocolV6.STATE_UPDATE:
			if connection_phase not in [
				ConnectionPhase.LOBBY,
				ConnectionPhase.PLAYING,
				ConnectionPhase.FINISHING,
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
				ConnectionPhase.FINISHING
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
			if connection_phase == ConnectionPhase.FINISHING:
				_begin_terminal_delivery(next_revision)
				_clear_pending_submission()
		ProtocolV6.ERROR:
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
		ProtocolV6.PING:
			_send(ProtocolV6.PONG, {}, get_revision())
		ProtocolV6.PONG:
			pass
		_:
			events.append({
				"type": "error",
				"code": "unexpected_message",
				"message": "客户端收到非预期消息。",
			})

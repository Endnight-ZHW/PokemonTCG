extends "res://tests/network_contract_gameplay.gd"

func _run_terminal_state_contract() -> void:
	var session := AuthoritativeSession.new("terminal-contract")
	var started := session.start_match("fire", "fire", 20260711, 0)
	_expect(started.success, "terminal session fixture did not start")
	if not started.success:
		return
	var host := NetworkMatchController.new(session.catalog)
	var host_transport := FakeNetworkTransport.new()
	host.host = true
	host.player_idx = 0
	host.connected = true
	host.room_id = "terminal-contract"
	host.transport = host_transport
	host.session = session
	host.connection_phase = NetworkMatchController.ConnectionPhase.PLAYING

	var surrendered := session.surrender(0)
	_expect(surrendered.success, "first surrender was rejected")
	host._broadcast_state(surrendered.events)
	_expect(
		host.connection_phase == NetworkMatchController.ConnectionPhase.FINISHING
		and host.terminal_revision == session.state.revision
		and host.needs_poll(),
		"host did not retain a terminal delivery window after GAME_OVER",
	)
	_expect(
		not host_transport.sent_messages.is_empty()
		and host_transport.sent_messages[-1]["payload"]["state"]["phase"] == "GAME_OVER",
		"host did not send the terminal state before awaiting acknowledgement",
	)
	var first_terminal_send_count := host_transport.sent_messages.size()
	var retry_now := Time.get_ticks_msec()
	host.last_receive_msec = retry_now
	host.terminal_last_state_send_msec = (
		retry_now - NetworkMatchController.TERMINAL_STATE_RETRY_MSEC - 1
	)
	host.poll()
	_expect(
		host.connection_phase == NetworkMatchController.ConnectionPhase.FINISHING
		and host_transport.sent_messages.size() == first_terminal_send_count + 1
		and host_transport.sent_messages[-1]["payload"]["state"]["phase"]
		== "GAME_OVER",
		"finishing host did not retry an unacknowledged terminal snapshot",
	)
	var retried_terminal_send_count := host_transport.sent_messages.size()
	host._handle_message(ProtocolV6.envelope(
		ProtocolV6.RESYNC_REQUEST,
		"terminal-contract",
		1,
		1,
		maxi(0, session.state.revision - 1),
	))
	_expect(
		host.connection_phase == NetworkMatchController.ConnectionPhase.FINISHING
		and host_transport.sent_messages.size() == retried_terminal_send_count + 1
		and host_transport.sent_messages[-1]["payload"]["state"]["phase"]
		== "GAME_OVER",
		"finishing host did not serve a terminal recovery snapshot",
	)

	var terminal_winner := session.state.winner
	var terminal_revision := session.state.revision
	var terminal_log := session.state.action_log.duplicate()
	var repeated := session.surrender(1)
	_expect(
		not repeated.success
		and repeated.error_code == "game_over"
		and session.state.winner == terminal_winner
		and session.state.revision == terminal_revision
		and session.state.action_log == terminal_log,
		"repeated surrender mutated an already terminal match",
	)

	var client := NetworkMatchController.new(session.catalog)
	var client_transport := QueuedNetworkTransport.new()
	client.host = false
	client.player_idx = 1
	client.connected = true
	client.room_id = "terminal-contract"
	client.transport = client_transport
	client.connection_phase = NetworkMatchController.ConnectionPhase.PLAYING
	client.receive_sequence = int(
		host_transport.sent_messages[-1].get("sequence", 1)
	) - 1
	client.send_sequence = 1
	client._handle_message(host_transport.sent_messages[-1])
	_expect(
		client.connection_phase == NetworkMatchController.ConnectionPhase.FINISHING
		and client.terminal_revision == terminal_revision
		and not client_transport.sent_messages.is_empty()
		and client_transport.sent_messages[-1]["message_type"]
		== ProtocolV6.PONG
		and int(client_transport.sent_messages[-1]["state_revision"])
		== terminal_revision,
		"client did not acknowledge the terminal state",
	)
	_expect(
		client._drain_events().any(func(event: Dictionary) -> bool:
			return event.get("type", "") == "state"),
		"client did not publish the terminal state event",
	)
	_expect(client.needs_poll(), "client stopped polling before terminal close")

	host._drain_events()
	host._handle_message(client_transport.sent_messages[-1])
	_expect(
		host.connection_phase == NetworkMatchController.ConnectionPhase.CLOSED
		and host.transport == null
		and not host.needs_poll(),
		"host did not close after the matching terminal acknowledgement",
	)
	client_transport.queued_events.append({"type": "disconnected"})
	client.poll()
	_expect(
		client.connection_phase == NetworkMatchController.ConnectionPhase.CLOSED
		and client.transport == null
		and not client.needs_poll(),
		"client treated the acknowledged terminal close as a reconnectable failure",
	)

	var remote_repeat := ProtocolV6.envelope(
		ProtocolV6.SURRENDER,
		"terminal-contract",
		1,
		3,
		session.state.revision,
	)
	host._handle_message(remote_repeat)
	_expect(
		session.state.winner == terminal_winner
		and session.state.revision == terminal_revision,
		"closed host accepted a repeated remote surrender",
	)


func _run_submission_correlation_contract() -> void:
	var session := AuthoritativeSession.new("correlation-contract")
	var started := session.start_match("fire", "water", 20260714, 0)
	_expect(started.success, "correlation session fixture did not start")
	if not started.success:
		return
	_advance_setup_to_remote_actor(session)
	var remote_view := session.view_for(1)
	var legal_actions := _concrete_actions(
		remote_view.get("legal_action_groups", []))
	_expect(not legal_actions.is_empty(), "remote correlation fixture has no legal action")
	if legal_actions.is_empty():
		return

	var host_controller := NetworkMatchController.new(session.catalog)
	var host_transport := FakeNetworkTransport.new()
	host_controller.host = true
	host_controller.player_idx = 0
	host_controller.connected = true
	host_controller.room_id = "correlation-contract"
	host_controller.transport = host_transport
	host_controller.session = session
	host_controller.connection_phase = NetworkMatchController.ConnectionPhase.PLAYING
	var remote_action: GameAction = legal_actions[0]
	remote_action.action_id = "remote-action:success"
	remote_action.actor = 1
	host_controller._handle_message(ProtocolV6.envelope(
		ProtocolV6.ACTION_SUBMIT,
		"correlation-contract",
		1,
		1,
		session.state.revision,
		remote_action.action_id,
		"",
		{"action": remote_action.to_dict()},
	))
	_expect(
		not host_transport.sent_messages.is_empty()
		and host_transport.sent_messages[-1]["message_type"] == ProtocolV6.STATE_UPDATE
		and host_transport.sent_messages[-1]["action_id"] == remote_action.action_id,
		"successful authoritative state did not echo action_id",
	)
	var host_events := host_controller._drain_events()
	_expect(
		_has_origin_event(host_events, "state", remote_action.action_id),
		"host state event did not expose origin_action_id",
	)

	var rejected_action := remote_action.to_dict()
	rejected_action["action_id"] = "remote-action:rejected"
	host_controller._handle_message(ProtocolV6.envelope(
		ProtocolV6.ACTION_SUBMIT,
		"correlation-contract",
		1,
		2,
		maxi(0, session.state.revision - 1),
		str(rejected_action["action_id"]),
		"",
		{"action": rejected_action},
	))
	var rejection_index := host_transport.sent_messages.size() - 2
	_expect(
		rejection_index >= 0
		and host_transport.sent_messages[rejection_index]["message_type"] == ProtocolV6.ERROR
		and host_transport.sent_messages[rejection_index]["action_id"]
		== rejected_action["action_id"],
		"authoritative rejection did not echo action_id",
	)
	var heartbeat_send_count := host_transport.sent_messages.size()
	host_controller._handle_message(ProtocolV6.envelope(
		ProtocolV6.PONG,
		"correlation-contract",
		1,
		3,
		session.state.revision,
	))
	_expect(
		host_transport.sent_messages.size() == heartbeat_send_count
		and host_controller._drain_events().is_empty(),
		"host rejected a valid heartbeat PONG",
	)

	var client := _new_correlation_client(session)
	var submitted_action: GameAction = legal_actions[0]
	submitted_action.action_id = "client-action:pending"
	_expect(client.submit_action(submitted_action), "client action submission failed")
	_expect(
		not client.pending_submission.is_empty()
		and client.pending_submission.get("action_id", "") == submitted_action.action_id
		and int(client.pending_submission.get("base_revision", -1))
		== session.state.revision
		and client.pending_submission.has("sent_msec"),
		"client did not retain the correlated pending submission",
	)
	client._handle_message(_state_envelope(
		session,
		1,
		"other-action",
	))
	_expect(
		not client.pending_submission.is_empty()
		and client.pending_submission.get("action_id", "") == submitted_action.action_id,
		"non-matching state update cleared the pending submission",
	)
	client._handle_message(_state_envelope(
		session,
		2,
		submitted_action.action_id,
	))
	var same_revision_events := client._drain_events()
	_expect(
		not client.pending_submission.is_empty()
		and not client.pending_submission.is_empty()
		and not _has_origin_event(
			same_revision_events, "state", submitted_action.action_id
		),
		"matching ID without a revision advance confirmed a submission",
	)
	var base_revision := session.state.revision
	client._handle_message(_state_envelope(
		session,
		3,
		"",
		"",
		base_revision - 1,
	))
	var stale_state_events := client._drain_events()
	_expect(
		client.current_revision == base_revision
		and not client.pending_submission.is_empty()
		and client.resync_in_progress
		and _has_event_code(stale_state_events, "stale_state_revision"),
		"a regressing state revision was accepted or did not trigger resync",
	)
	client._handle_message(_state_envelope(
		session,
		4,
		submitted_action.action_id,
		"",
		base_revision + 1,
	))
	var matching_events := client._drain_events()
	_expect(
		not client.submission_locked()
		and client.current_revision == base_revision + 1
		and _has_origin_event(
			matching_events, "state", submitted_action.action_id
		),
		"causally newer matching state did not confirm the submission",
	)

	var uncorrelated_client := _new_correlation_client(session)
	uncorrelated_client._begin_pending_submission(
		"action", "uncorrelated-action", "", session.state.revision
	)
	uncorrelated_client._handle_message(_state_envelope(session, 1))
	_expect(
		not uncorrelated_client.pending_submission.is_empty(),
		"uncorrelated state without revision advance confirmed a submission",
	)
	var advanced_view := session.view_for(1)
	advanced_view["state"]["revision"] = session.state.revision + 1
	advanced_view["legal_action_groups"] = []
	advanced_view["legal_action_error"] = ""
	uncorrelated_client._handle_message(ProtocolV6.envelope(
		ProtocolV6.STATE_UPDATE,
		"correlation-contract",
		0,
		2,
		session.state.revision + 1,
		"",
		"",
		advanced_view,
	))
	var uncorrelated_events := uncorrelated_client._drain_events()
	_expect(
		uncorrelated_client.pending_submission.is_empty()
		and _has_origin_event(
			uncorrelated_events, "state", "uncorrelated-action"),
		"revision advance did not infer the sole pending action",
	)

	var error_client := _new_correlation_client(session)
	error_client._begin_pending_submission(
		"action", "rejected-client-action", "", session.state.revision
	)
	error_client._handle_message(ProtocolV6.envelope(
		ProtocolV6.ERROR,
		"correlation-contract",
		0,
		1,
		session.state.revision,
		"rejected-client-action",
		"",
		ProtocolV6.error_payload("illegal_action", "rejected"),
	))
	var error_events := error_client._drain_events()
	_expect(
		error_client.pending_submission.is_empty()
		and _has_origin_event(
			error_events, "error", "rejected-client-action"
		)
		and _has_matched_pending_event(error_events, "error"),
		"matching error did not resolve and publish origin_action_id",
	)

	var nonmatching_error_client := _new_correlation_client(session)
	nonmatching_error_client._begin_pending_submission(
		"action", "still-pending-action", "", session.state.revision
	)
	nonmatching_error_client._handle_message(ProtocolV6.envelope(
		ProtocolV6.ERROR,
		"correlation-contract",
		0,
		1,
		session.state.revision,
		"different-action",
		"",
		ProtocolV6.error_payload("illegal_action", "unrelated"),
	))
	var nonmatching_error_events := nonmatching_error_client._drain_events()
	_expect(
		not nonmatching_error_client.pending_submission.is_empty()
		and nonmatching_error_client.pending_submission.get("action_id", "")
		== "still-pending-action"
		and not _has_matched_pending_event(nonmatching_error_events, "error"),
		"non-matching error cleared or claimed the active submission",
	)

	var uncorrelated_error_client := _new_correlation_client(session)
	uncorrelated_error_client._begin_pending_submission(
		"action", "heartbeat-safe-action", "", session.state.revision
	)
	uncorrelated_error_client._handle_message(ProtocolV6.envelope(
		ProtocolV6.ERROR,
		"correlation-contract",
		0,
		1,
		session.state.revision,
		"",
		"",
		ProtocolV6.error_payload("protocol_notice", "uncorrelated"),
	))
	var uncorrelated_error_events := uncorrelated_error_client._drain_events()
	_expect(
		not uncorrelated_error_client.pending_submission.is_empty()
		and not _has_matched_pending_event(uncorrelated_error_events, "error"),
		"uncorrelated protocol error claimed the active submission",
	)

	var request_client := _new_correlation_client(session)
	request_client._begin_pending_submission(
		"choice", "", "choice-request:success", session.state.revision
	)
	request_client._handle_message(_state_envelope(
		session,
		1,
		"",
		"choice-request:success",
		session.state.revision + 1,
	))
	var request_events := request_client._drain_events()
	_expect(
		not request_client.submission_locked()
		and _has_origin_request_event(
			request_events, "state", "choice-request:success"
		)
		and _has_matched_pending_event(request_events, "state"),
		"successful choice state did not correlate origin_request_id",
	)

	var rejected_request_client := _new_correlation_client(session)
	rejected_request_client._begin_pending_submission(
		"choice", "", "choice-request:rejected", session.state.revision
	)
	rejected_request_client._handle_message(ProtocolV6.envelope(
		ProtocolV6.ERROR,
		"correlation-contract",
		0,
		1,
		session.state.revision,
		"",
		"choice-request:rejected",
		ProtocolV6.error_payload("illegal_choice", "rejected"),
	))
	var rejected_request_events := rejected_request_client._drain_events()
	_expect(
		rejected_request_client.pending_submission.is_empty()
		and _has_origin_request_event(
			rejected_request_events, "error", "choice-request:rejected"
		)
		and _has_matched_pending_event(rejected_request_events, "error"),
		"rejected choice did not correlate origin_request_id",
	)

	var timeout_client := _new_correlation_client(session)
	timeout_client._begin_pending_submission(
		"action", "timed-out-action", "", session.state.revision
	)
	var now := Time.get_ticks_msec()
	timeout_client.pending_submission["sent_msec"] = (
		now - NetworkMatchController.PENDING_SUBMISSION_TIMEOUT_MSEC - 1
	)
	timeout_client.last_receive_msec = now
	timeout_client.last_send_msec = now
	var timeout_events := timeout_client.poll()
	_expect(
		timeout_client.connected
		and timeout_client.connection_phase == NetworkMatchController.ConnectionPhase.PLAYING
		and not timeout_client.pending_submission.is_empty()
		and timeout_client.resync_in_progress
		and _has_origin_event(
			timeout_events, "pending_timeout", "timed-out-action"
		),
		"10-second pending timeout disconnected or prematurely unlocked the client",
	)
	var timeout_transport := timeout_client.transport as FakeNetworkTransport
	_expect(
		timeout_transport.sent_messages.size() == 1
		and timeout_transport.sent_messages[0]["message_type"]
		== ProtocolV6.RESYNC_REQUEST,
		"pending timeout did not request exactly one resync",
	)
	_expect(
		timeout_client.poll().is_empty()
		and timeout_transport.sent_messages.size() == 1,
		"pending timeout emitted repeatedly before resync completed",
	)
	timeout_client._handle_message(ProtocolV6.envelope(
		ProtocolV6.ERROR,
		"correlation-contract",
		0,
		1,
		session.state.revision,
		"timed-out-action",
		"",
		ProtocolV6.error_payload("illegal_action", "late rejection"),
	))
	_expect(
		timeout_client.submission_locked()
		and timeout_client.resync_in_progress,
		"late matching error unlocked a timed-out submission before resync",
	)
	timeout_client._drain_events()
	timeout_client._handle_message(_state_envelope(session, 2))
	_expect(
		timeout_client.pending_submission.is_empty()
		and not timeout_client.resync_in_progress
		and not timeout_client.submission_locked(),
		"valid resync state did not release a timed-out submission lock",
	)



func _run_recovery_contract() -> void:
	var session := AuthoritativeSession.new("recovery-room")
	var started := session.start_match("fire", "water", 20260715, 0)
	_expect(started.success, "recovery fixture did not start")
	if not started.success:
		return
	var client := NetworkMatchController.new()
	client.host = false
	client.player_idx = 1
	client.room_id = "recovery-room"
	client.local_deck_key = "water"
	client.current_revision = session.state.revision
	client.connection_phase = NetworkMatchController.ConnectionPhase.PLAYING
	client.connected = true
	client.transport = FakeNetworkTransport.new()
	# A structurally valid gap establishes a new receive fence and sends one
	# RESYNC request.  The following reply can then be accepted at sequence 4.
	client._handle_message(ProtocolV6.envelope(
		ProtocolV6.PING,
		"recovery-room",
		0,
		3,
		session.state.revision,
	))
	_expect(
		client.receive_sequence == 3 and client.resync_in_progress,
		"sequence gap did not establish a recoverable receive fence",
	)
	var transport := client.transport as FakeNetworkTransport
	_expect(
		transport != null
		and transport.sent_messages.size() == 1
		and str(transport.sent_messages[0].get("message_type", ""))
		== ProtocolV6.RESYNC_REQUEST,
		"sequence gap did not request exactly one recovery snapshot",
	)
	client._handle_message(ProtocolV6.envelope(
		ProtocolV6.STATE_UPDATE,
		"recovery-room",
		0,
		4,
		session.state.revision,
		"",
		"",
		session.view_for(1),
	))
	var state_event: Dictionary = {}
	for event in client.events:
		if str(event.get("type", "")) == "state":
			state_event = event
	_expect(
		not state_event.is_empty()
		and bool(state_event.get("is_resync", false))
		and not client.resync_in_progress,
		"recovery snapshot was not identified or did not complete resync",
	)

	var host := NetworkMatchController.new()
	host.host = true
	host.player_idx = 0
	host.room_id = "recovery-room"
	host.local_deck_key = "fire"
	host.remote_deck_key = "water"
	host.session = session
	host.transport = FakeNetworkTransport.new()
	host.connection_phase = NetworkMatchController.ConnectionPhase.LOBBY
	host.reconnecting = true
	var revision_before := session.state.revision
	host._handle_host_message({}, ProtocolV6.DECK_SELECT, {
		"deck_key": "water",
		"rules_version": AppState.RULES_SCHEMA_VERSION,
		"action_version": AppState.ACTION_SCHEMA_VERSION,
		"core_fingerprint": host._core_fingerprint(),
		"rules_profile_id": GameState.RULES_PROFILE_ID,
		"rules_options": host.rules_options.duplicate(true),
		"resume": true,
	})
	_expect(
		host.connection_phase == NetworkMatchController.ConnectionPhase.PLAYING
		and not host.reconnecting
		and session.state.revision == revision_before,
		"resume handshake restarted or failed to restore the existing match",
	)
	var host_state_event: Dictionary = {}
	var reconnected_index := -1
	var recovery_state_index := -1
	for index in range(host.events.size()):
		var event: Dictionary = host.events[index]
		if str(event.get("type", "")) == "reconnected":
			reconnected_index = index
		if str(event.get("type", "")) == "state":
			host_state_event = event
			recovery_state_index = index
	_expect(
		bool(host_state_event.get("is_resync", false)),
		"host resume did not publish an atomic recovery snapshot",
	)
	_expect(
		reconnected_index >= 0
		and recovery_state_index > reconnected_index,
		"resume notification did not precede the recovery snapshot barrier",
	)

	var locked_rules_host := NetworkMatchController.new()
	locked_rules_host.host = true
	locked_rules_host.player_idx = 0
	locked_rules_host.room_id = "rules-lock-contract"
	locked_rules_host.local_deck_key = "fire"
	locked_rules_host.rules_options = {"apply_type_matchups": true}
	locked_rules_host.session = AuthoritativeSession.new("rules-lock-contract")
	locked_rules_host.transport = FakeNetworkTransport.new()
	locked_rules_host.connection_phase = NetworkMatchController.ConnectionPhase.LOBBY
	locked_rules_host._handle_host_message({}, ProtocolV6.DECK_SELECT, {
		"deck_key": "water",
		"rules_version": AppState.RULES_SCHEMA_VERSION,
		"action_version": AppState.ACTION_SCHEMA_VERSION,
		"core_fingerprint": locked_rules_host._core_fingerprint(),
		"rules_profile_id": GameState.RULES_PROFILE_ID,
		"rules_options": {"apply_type_matchups": false},
		"resume": false,
	})
	var locked_transport: FakeNetworkTransport = locked_rules_host.transport
	_expect(
		locked_rules_host.connection_phase == NetworkMatchController.ConnectionPhase.LOBBY
		and locked_rules_host.remote_deck_key.is_empty()
		and not locked_transport.sent_messages.is_empty()
		and str(locked_transport.sent_messages[-1].get("message_type", ""))
		== ProtocolV6.ERROR
		and str(Dictionary(locked_transport.sent_messages[-1].get(
			"payload", {})).get("code", "")) == "rules_options_mismatch",
		"challenger was able to change the host-locked matchup option",
	)


func _run_retired_transport_batch_contract() -> void:
	var session := AuthoritativeSession.new("retired-transport-contract")
	var started := session.start_match("fire", "water", 20260828, 0)
	_expect(started.success, "retired transport fixture did not start")
	if not started.success:
		return
	var transport := QueuedNetworkTransport.new()
	transport.queued_events.assign([
		{"type": "disconnected", "reason": "test_disconnect"},
		{"type": "connected", "room_id": "retired-transport-contract"},
		{
			"type": "message",
			"message": ProtocolV6.envelope(
				ProtocolV6.PING,
				"retired-transport-contract",
				1,
				1,
				session.state.revision,
			),
		},
	])
	var host := NetworkMatchController.new(session.catalog)
	host.host = true
	host.player_idx = 0
	host.connected = true
	host.room_id = "retired-transport-contract"
	host.local_deck_key = "fire"
	host.remote_deck_key = "water"
	host.transport_kind = "relay"
	host.relay_url = "ws://127.0.0.1:1"
	host.transport = transport
	host.session = session
	host.connection_phase = NetworkMatchController.ConnectionPhase.PLAYING
	var recovery_events := host.poll()
	_expect(
		host.transport == null
		and host.reconnecting
		and host.connection_phase == NetworkMatchController.ConnectionPhase.CONNECTING
		and transport.close_count == 1
		and transport.sent_messages.is_empty()
		and not recovery_events.any(func(event: Dictionary) -> bool:
			return str(event.get("type", "")) == "connected"),
		"retired transport events crossed into the new connection epoch",
	)


func _run_modifier_wire_number_contract() -> void:
	var session := AuthoritativeSession.new("modifier-wire-contract")
	var started := session.start_match("steel", "steel", 20260720, 0)
	_expect(started.success, "modifier wire fixture did not start")
	if not started.success:
		return
	var pokemon := PokemonState.new("svm-zamazenta")
	var descriptor := {
		"hook": "MODIFY_DAMAGE",
		"layer": "attacker_adjust",
		"priority": 0,
		"controller": 0,
		"source_ref": {
			"kind": "pokemon",
			"player": 0,
			"slot": "bench_0",
			"card_id": "svm-zamazenta",
		},
		"scope": "attached_attacker",
		"duration": "until_leave_play",
		"stacking": "replace_same_source",
		"conflict_policy": "commutative",
		"condition": {"target_active": true},
		"operation": {"kind": "damage_delta", "amount": 10},
	}
	_expect(
		pokemon.register_modifier(descriptor).is_empty(),
		"valid modifier fixture was rejected before serialization",
	)
	var view := session.view_for(0)
	view["state"]["your"]["bench"][0] = pokemon.to_dict()
	var relay_roundtrip: Variant = JSON.parse_string(JSON.stringify(view))
	_expect(
		relay_roundtrip is Dictionary
		and bool(ProtocolV6.validate_payload(
			ProtocolV6.STATE_UPDATE, relay_roundtrip).get("ok", false)),
		"relay JSON roundtrip rejected integral Modifier descriptor numbers",
	)
	if not relay_roundtrip is Dictionary:
		return
	var fractional: Dictionary = Dictionary(relay_roundtrip).duplicate(true)
	fractional["state"]["your"]["bench"][0]["modifiers"][0]["operation"]["amount"] = 10.5
	_expect_invalid_state(fractional, "fractional Modifier integer field")


func _run_start_failure_contract() -> void:
	var controller := FailingStartController.new()
	var attempts: Array[Callable] = [
		func() -> Error: return controller.host_lan(12345, "fire"),
		func() -> Error: return controller.join_lan("127.0.0.1", 12345, "fire"),
		func() -> Error: return controller.host_relay("ws://relay.invalid", "fire"),
		func() -> Error:
			return controller.join_relay("ws://relay.invalid", "1234", "fire"),
		func() -> Error: return controller.host_lan(12345, "__missing_deck"),
	]
	for index in range(attempts.size()):
		_prime_controller(controller)
		var error := int(attempts[index].call())
		_expect(error != OK, "failing start attempt %d unexpectedly succeeded" % index)
		_expect(
			_controller_is_reset(controller),
			"failing start attempt %d left partial controller state" % index,
		)
	_expect(
		controller.enet_probe.close_count >= 2,
		"failed ENet candidates were not closed",
	)
	_expect(
		controller.relay_probe.close_count >= 2,
		"failed Relay candidates were not closed",
	)

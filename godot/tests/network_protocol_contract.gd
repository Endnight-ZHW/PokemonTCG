extends SceneTree

var failures: Array[String] = []


class FailingEnetTransport:
	extends EnetTransport

	var close_count := 0

	func start_host(_port: int) -> Error:
		return ERR_CANT_CONNECT

	func start_client(_address: String, _port: int) -> Error:
		return ERR_CANT_CONNECT

	func close() -> void:
		close_count += 1


class FailingRelayTransport:
	extends WebSocketRelayTransport

	var close_count := 0

	func start_host(_relay_url: String) -> Error:
		return ERR_CANT_CONNECT

	func start_client(_relay_url: String, _target_room: String) -> Error:
		return ERR_CANT_CONNECT

	func close() -> void:
		close_count += 1


class FailingStartController:
	extends NetworkMatchController

	var enet_probe := FailingEnetTransport.new()
	var relay_probe := FailingRelayTransport.new()

	func _new_enet_transport() -> EnetTransport:
		return enet_probe

	func _new_relay_transport() -> WebSocketRelayTransport:
		return relay_probe


func _initialize() -> void:
	_run_protocol_boundaries()
	_run_start_failure_contract()
	_run_terminal_state_contract()
	if failures.is_empty():
		print("NETWORK_PROTOCOL_CONTRACT_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _run_protocol_boundaries() -> void:
	var envelope := ProtocolV3.envelope(ProtocolV3.PING, "contract", 0, 1)
	for row in [
		{"field": "protocol_version", "value": {}},
		{"field": "message_type", "value": []},
		{"field": "sender", "value": {}},
		{"field": "sequence", "value": NAN},
		{"field": "state_revision", "value": []},
	]:
		var malformed: Dictionary = envelope.duplicate(true)
		malformed[row["field"]] = row["value"]
		_expect(
			not bool(ProtocolV3.validate(malformed).get("ok", false)),
			"envelope accepted malformed %s" % row["field"],
		)

	var session := AuthoritativeSession.new("protocol-contract")
	var started := session.start_match("fire", "fire", 20260710, 0)
	_expect(started.success, "same-deck protocol fixture did not start")
	if not started.success:
		return
	var view := session.view_for(0)
	_expect(
		bool(ProtocolV3.validate_payload(ProtocolV3.STATE_UPDATE, view).get("ok", false)),
		"authoritative fixture view is not protocol-valid",
	)

	var inconsistent_terminal: Dictionary = view.duplicate(true)
	inconsistent_terminal["state"]["phase"] = "GAME_OVER"
	inconsistent_terminal["state"]["winner"] = -1
	_expect_invalid_state(inconsistent_terminal, "terminal state without winner")

	var malformed_action := GameAction.new(
		"END_TURN",
		{"hand_idx": {}},
		true,
		0,
		null,
		null,
		"malformed-action",
	).to_dict()
	_expect(
		not bool(ProtocolV3.validate_payload(
			ProtocolV3.ACTION_SUBMIT,
			{"action": malformed_action},
		).get("ok", false)),
		"action payload accepted a non-integer hand index",
	)

	var choice_request := ChoiceRequest.new(
		"choice:contract",
		"select_card",
		0,
		"选择",
		[{
			"option_id": "card:0",
			"label": "Card",
			"ref": EntityRef.new("card", 0, "hand", "", 0, "", "svi-chim").to_dict(),
			"value": {"index": 0, "card_id": "svi-chim"},
		}],
		1,
		1,
		false,
		false,
		{"revision": int(view["state"]["revision"]), "revealed_card_ids": []},
	).to_dict()
	var choice_view: Dictionary = view.duplicate(true)
	choice_view["choice_request"] = choice_request
	_expect(
		bool(ProtocolV3.validate_payload(
			ProtocolV3.STATE_UPDATE, choice_view
		).get("ok", false)),
		"valid choice request fixture was rejected",
	)
	var malformed_choice_ref: Dictionary = choice_view.duplicate(true)
	malformed_choice_ref["choice_request"]["options"][0]["ref"]["index"] = {}
	_expect_invalid_state(malformed_choice_ref, "malformed choice entity reference")
	var malformed_choice_metadata: Dictionary = choice_view.duplicate(true)
	malformed_choice_metadata["choice_request"]["metadata"]["predetermined_flips"] = {}
	_expect_invalid_state(malformed_choice_metadata, "malformed choice metadata")

	var presentation_event := PresentationEvent.normalize({
		"event_type": "cards_drawn",
		"actor": 0,
		"visibility": "owner",
		"data": {"player": 0, "cards": ["svi-chim"]},
	}, int(view["state"]["revision"]))
	var presentation_view: Dictionary = view.duplicate(true)
	presentation_view["presentation_events"] = [presentation_event]
	_expect(
		bool(ProtocolV3.validate_payload(
			ProtocolV3.STATE_UPDATE, presentation_view
		).get("ok", false)),
		"valid presentation event fixture was rejected",
	)
	for mutation in [
		{"path": "amount", "value": {}},
		{"path": "source_player", "value": {}},
		{"path": "data_player", "value": {}},
	]:
		var malformed_event_view: Dictionary = presentation_view.duplicate(true)
		var event: Dictionary = malformed_event_view["presentation_events"][0]
		match mutation["path"]:
			"amount":
				event["amount"] = mutation["value"]
			"source_player":
				event["source"]["player"] = mutation["value"]
			"data_player":
				event["data"]["player"] = mutation["value"]
		_expect_invalid_state(
			malformed_event_view,
			"malformed presentation %s" % mutation["path"],
		)


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
		host.connection_phase == NetworkMatchController.ConnectionPhase.CLOSED,
		"host remained PLAYING after broadcasting GAME_OVER",
	)
	_expect(
		not host_transport.sent_messages.is_empty()
		and host_transport.sent_messages[-1]["payload"]["state"]["phase"] == "GAME_OVER",
		"host did not send the terminal state before closing the logical match",
	)
	host._drain_events()
	var terminal_send_count := host_transport.sent_messages.size()
	_expect(not host.needs_poll(), "closed host kept polling an idle transport")
	host.poll()
	_expect(
		host_transport.sent_messages.size() == terminal_send_count,
		"closed host emitted a heartbeat after terminal state",
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
	client.host = false
	client.player_idx = 1
	client.connected = true
	client.room_id = "terminal-contract"
	client.transport = FakeNetworkTransport.new()
	client.connection_phase = NetworkMatchController.ConnectionPhase.LOBBY
	client._handle_message(host_transport.sent_messages[-1])
	_expect(
		client.connection_phase == NetworkMatchController.ConnectionPhase.CLOSED,
		"client changed a GAME_OVER state back to PLAYING",
	)
	_expect(
		client._drain_events().any(func(event: Dictionary) -> bool:
			return event.get("type", "") == "state"),
		"client did not publish the terminal state event",
	)
	_expect(not client.needs_poll(), "closed client kept polling an idle transport")

	var remote_repeat := ProtocolV3.envelope(
		ProtocolV3.SURRENDER,
		"terminal-contract",
		1,
		1,
		session.state.revision,
	)
	host._handle_message(remote_repeat)
	_expect(
		session.state.winner == terminal_winner
		and session.state.revision == terminal_revision,
		"closed host accepted a repeated remote surrender",
	)


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


func _prime_controller(controller: NetworkMatchController) -> void:
	controller.transport = FakeNetworkTransport.new()
	controller.session = AuthoritativeSession.new("old-session")
	controller.host = true
	controller.player_idx = 1
	controller.room_id = "old-room"
	controller.local_deck_key = "water"
	controller.remote_deck_key = "fire"
	controller.send_sequence = 9
	controller.receive_sequence = 7
	controller.current_revision = 5
	controller.awaiting_update = true
	controller.connected = true
	controller.connection_phase = NetworkMatchController.ConnectionPhase.PLAYING
	controller.deck_selection_sent = true
	controller.events.append({"type": "old-event"})


func _controller_is_reset(controller: NetworkMatchController) -> bool:
	return (
		controller.transport == null
		and controller.session == null
		and not controller.host
		and controller.player_idx == -1
		and controller.room_id.is_empty()
		and controller.local_deck_key.is_empty()
		and controller.remote_deck_key.is_empty()
		and controller.send_sequence == 0
		and controller.receive_sequence == 0
		and controller.current_revision == -1
		and not controller.awaiting_update
		and not controller.connected
		and controller.connection_phase == NetworkMatchController.ConnectionPhase.CLOSED
		and not controller.deck_selection_sent
		and controller.events.is_empty()
	)


func _expect_invalid_state(view: Dictionary, label: String) -> void:
	_expect(
		not bool(ProtocolV3.validate_payload(
			ProtocolV3.STATE_UPDATE, view
		).get("ok", false)),
		"state payload accepted %s" % label,
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

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
	_run_submission_correlation_contract()
	_run_recovery_contract()
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
	var random_session := AuthoritativeSession.new("setup-coin-contract")
	var random_started := random_session.start_match("fire", "water", 20260709)
	var random_view := random_session.view_for(0, random_started.events)
	var setup_events: Array = random_view.get("presentation_events", [])
	_expect(
		random_started.success
		and setup_events.size() == 1
		and str(Dictionary(setup_events[0]).get("event_type", "")) == "coin_flip"
		and str(Dictionary(setup_events[0]).get("data", {}).get("purpose", ""))
		== "setup_first_player"
		and bool(ProtocolV3.validate_payload(
			ProtocolV3.STATE_UPDATE,
			random_view,
		).get("ok", false)),
		"random setup coin was not public and protocol-valid",
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
		{
			"revision": int(view["state"]["revision"]),
			"revealed_card_ids": [],
			"source_zone": "deck",
		},
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
	var malformed_source_zone: Dictionary = choice_view.duplicate(true)
	malformed_source_zone["choice_request"]["metadata"]["source_zone"] = {}
	_expect_invalid_state(malformed_source_zone, "non-string choice source_zone")
	var source_zone_choice: Dictionary = choice_view.duplicate(true)
	source_zone_choice["choice_request"]["metadata"]["source_zone"] = "hand"
	_expect(
		bool(ProtocolV3.validate_payload(
			ProtocolV3.STATE_UPDATE, source_zone_choice
		).get("ok", false)),
		"valid choice metadata source_zone was rejected",
	)
	var attachment_ref := EntityRef.new(
		"attachment", 0, "field", "active", 0, "energy", "sv1-ener-2"
	).to_dict()
	var wait_stack := ResolutionStack.new()
	wait_stack.pending_request = ChoiceRequest.new(
		"choice:attachment-wait",
		"select_attachment",
		0,
		"选择能量",
		[{
			"option_id": "attachment:0:active:energy:0:sv1-ener-2",
			"label": "Energy",
			"ref": attachment_ref,
			"value": {
				"player": 0, "slot": "active", "index": 0,
				"attachment_type": "energy", "card_id": "sv1-ener-2",
			},
		}],
		1,
		1,
		false,
		false,
		{
			"revision": session.state.revision,
			"purpose": "discard_energy",
			"attachment_refs": [attachment_ref],
			"card_ids": ["sv1-ener-2"],
			"source_player": 0,
			"source_slot": "active",
			"same_source": true,
			"same_target": false,
			"max_per_target": 1,
		},
	)
	session.state.resolution_stack = wait_stack.to_dict()
	var chooser_view := session.view_for(0)
	var waiting_view := session.view_for(1)
	_expect(
		chooser_view.get("choice_request") is Dictionary
		and chooser_view.get("wait_context") == null,
		"choice owner did not receive the full attachment request",
	)
	_expect(
		waiting_view.get("choice_request") == null
		and waiting_view.get("wait_context") == {
			"waiting_for_player": 0,
			"choice_kind": "attachment",
		},
		"non-chooser did not receive the coarse attachment wait context",
	)
	_expect(
		bool(ProtocolV3.validate_payload(
			ProtocolV3.STATE_UPDATE, waiting_view
		).get("ok", false)),
		"coarse attachment wait context was rejected by ProtocolV3",
	)
	var malformed_wait_view: Dictionary = waiting_view.duplicate(true)
	malformed_wait_view["wait_context"]["card_ids"] = ["sv1-ener-2"]
	_expect_invalid_state(malformed_wait_view, "wait context leaked attachment identities")
	session.state.resolution_stack = ResolutionStack.new().to_dict()

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
	var reveal_view: Dictionary = view.duplicate(true)
	reveal_view["presentation_events"] = [PresentationEvent.normalize({
		"event_type": "cards_revealed",
		"actor": 0,
		"visibility": "public",
		"data": {
			"player": 0,
			"cards": [{
				"card_id": "sv1-ener-2",
				"matched": true,
				"destination": {"player": 0, "zone": "discard"},
			}],
			"summary": {
				"kind": "energy_damage",
				"matched_count": 1,
				"amount": 80,
			},
		},
	}, int(view["state"]["revision"]))]
	_expect(
		bool(ProtocolV3.validate_payload(
			ProtocolV3.STATE_UPDATE, reveal_view
		).get("ok", false)),
		"valid structured public reveal event was rejected",
	)
	var malformed_reveal: Dictionary = reveal_view.duplicate(true)
	malformed_reveal["presentation_events"][0]["data"]["cards"][0][
		"matched"
	] = "true"
	_expect_invalid_state(malformed_reveal, "malformed structured reveal card")
	var empty_reveal: Dictionary = reveal_view.duplicate(true)
	empty_reveal["presentation_events"][0]["data"]["cards"] = []
	empty_reveal["presentation_events"][0]["data"]["summary"] = {
		"kind": "energy_damage",
		"matched_count": 0,
		"amount": 0,
	}
	empty_reveal["presentation_events"][0]["amount"] = 0
	_expect(
		bool(ProtocolV3.validate_payload(
			ProtocolV3.STATE_UPDATE, empty_reveal
		).get("ok", false)),
		"valid zero-card public reveal event was rejected",
	)
	var missing_reveal_summary: Dictionary = reveal_view.duplicate(true)
	missing_reveal_summary["presentation_events"][0]["data"].erase("summary")
	_expect_invalid_state(missing_reveal_summary, "missing reveal summary")
	for malformed_summary in [
		{"kind": 4, "matched_count": 1, "amount": 80},
		{"kind": "energy_damage", "matched_count": "1", "amount": 80},
		{"kind": "energy_damage", "matched_count": 2, "amount": 80},
		{"kind": "energy_damage", "matched_count": 1, "amount": -1},
	]:
		var malformed_summary_view: Dictionary = reveal_view.duplicate(true)
		malformed_summary_view["presentation_events"][0]["data"][
			"summary"
		] = malformed_summary
		_expect_invalid_state(malformed_summary_view, "malformed reveal summary")
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


func _run_submission_correlation_contract() -> void:
	var session := AuthoritativeSession.new("correlation-contract")
	var started := session.start_match("fire", "water", 20260714, 0)
	_expect(started.success, "correlation session fixture did not start")
	if not started.success:
		return
	_advance_setup_to_remote_actor(session)
	var remote_view := session.view_for(1)
	var legal_actions: Array = remote_view.get("legal_actions", [])
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
	var remote_action := GameAction.from_dict(legal_actions[0])
	remote_action.action_id = "remote-action:success"
	remote_action.actor = 1
	host_controller._handle_message(ProtocolV3.envelope(
		ProtocolV3.ACTION_SUBMIT,
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
		and host_transport.sent_messages[-1]["message_type"] == ProtocolV3.STATE_UPDATE
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
	host_controller._handle_message(ProtocolV3.envelope(
		ProtocolV3.ACTION_SUBMIT,
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
		and host_transport.sent_messages[rejection_index]["message_type"] == ProtocolV3.ERROR
		and host_transport.sent_messages[rejection_index]["action_id"]
		== rejected_action["action_id"],
		"authoritative rejection did not echo action_id",
	)

	var client := _new_correlation_client(session)
	var submitted_action := GameAction.from_dict(legal_actions[0])
	submitted_action.action_id = "client-action:pending"
	_expect(client.submit_action(submitted_action), "client action submission failed")
	_expect(
		client.awaiting_update
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
		client.awaiting_update
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
		client.awaiting_update
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
		and client.awaiting_update
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

	var legacy_client := _new_correlation_client(session)
	legacy_client._begin_pending_submission(
		"action", "legacy-action", "", session.state.revision
	)
	legacy_client._handle_message(_state_envelope(session, 1))
	_expect(
		legacy_client.awaiting_update,
		"legacy empty-ID state without revision advance confirmed a submission",
	)
	var advanced_view := session.view_for(1)
	advanced_view["state"]["revision"] = session.state.revision + 1
	legacy_client._handle_message(ProtocolV3.envelope(
		ProtocolV3.STATE_UPDATE,
		"correlation-contract",
		0,
		2,
		session.state.revision + 1,
		"",
		"",
		advanced_view,
	))
	var legacy_events := legacy_client._drain_events()
	_expect(
		not legacy_client.awaiting_update
		and _has_origin_event(legacy_events, "state", "legacy-action"),
		"legacy revision advance did not infer the sole pending action",
	)

	var error_client := _new_correlation_client(session)
	error_client._begin_pending_submission(
		"action", "rejected-client-action", "", session.state.revision
	)
	error_client._handle_message(ProtocolV3.envelope(
		ProtocolV3.ERROR,
		"correlation-contract",
		0,
		1,
		session.state.revision,
		"rejected-client-action",
		"",
		ProtocolV3.error_payload("illegal_action", "rejected"),
	))
	var error_events := error_client._drain_events()
	_expect(
		not error_client.awaiting_update
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
	nonmatching_error_client._handle_message(ProtocolV3.envelope(
		ProtocolV3.ERROR,
		"correlation-contract",
		0,
		1,
		session.state.revision,
		"different-action",
		"",
		ProtocolV3.error_payload("illegal_action", "unrelated"),
	))
	var nonmatching_error_events := nonmatching_error_client._drain_events()
	_expect(
		nonmatching_error_client.awaiting_update
		and nonmatching_error_client.pending_submission.get("action_id", "")
		== "still-pending-action"
		and not _has_matched_pending_event(nonmatching_error_events, "error"),
		"non-matching error cleared or claimed the active submission",
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
	rejected_request_client._handle_message(ProtocolV3.envelope(
		ProtocolV3.ERROR,
		"correlation-contract",
		0,
		1,
		session.state.revision,
		"",
		"choice-request:rejected",
		ProtocolV3.error_payload("illegal_choice", "rejected"),
	))
	var rejected_request_events := rejected_request_client._drain_events()
	_expect(
		not rejected_request_client.awaiting_update
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
		and timeout_client.awaiting_update
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
		== ProtocolV3.RESYNC_REQUEST,
		"pending timeout did not request exactly one resync",
	)
	_expect(
		timeout_client.poll().is_empty()
		and timeout_transport.sent_messages.size() == 1,
		"pending timeout emitted repeatedly before resync completed",
	)
	timeout_client._handle_message(ProtocolV3.envelope(
		ProtocolV3.ERROR,
		"correlation-contract",
		0,
		1,
		session.state.revision,
		"timed-out-action",
		"",
		ProtocolV3.error_payload("illegal_action", "late rejection"),
	))
	_expect(
		timeout_client.submission_locked()
		and timeout_client.resync_in_progress,
		"late matching error unlocked a timed-out submission before resync",
	)
	timeout_client._drain_events()
	timeout_client._handle_message(_state_envelope(session, 2))
	_expect(
		not timeout_client.awaiting_update
		and timeout_client.pending_submission.is_empty()
		and not timeout_client.resync_in_progress
		and not timeout_client.submission_locked(),
		"valid resync state did not release a timed-out submission lock",
	)


func _new_correlation_client(
	session: AuthoritativeSession,
) -> NetworkMatchController:
	var controller := NetworkMatchController.new(session.catalog)
	controller.host = false
	controller.player_idx = 1
	controller.connected = true
	controller.room_id = "correlation-contract"
	controller.transport = FakeNetworkTransport.new()
	controller.current_revision = session.state.revision
	controller.connection_phase = NetworkMatchController.ConnectionPhase.PLAYING
	return controller


func _advance_setup_to_remote_actor(session: AuthoritativeSession) -> void:
	for step_index in range(16):
		if not session.view_for(1).get("legal_actions", []).is_empty():
			return
		var host_actions: Array = session.view_for(0).get("legal_actions", [])
		if host_actions.is_empty():
			return
		var selected: Dictionary = host_actions[0]
		for action_value in host_actions:
			var action_row: Dictionary = action_value
			if str(action_row.get("action", "")) == "SETUP_DONE":
				selected = action_row
				break
		var action := GameAction.from_dict(selected)
		action.action_id = "contract-host-setup:%d" % step_index
		var result := session.submit_action(0, action.to_dict())
		if not result.success:
			return


func _state_envelope(
	session: AuthoritativeSession,
	sequence: int,
	action_id: String = "",
	request_id: String = "",
	revision_override: int = -1,
) -> Dictionary:
	var revision := (
		revision_override
		if revision_override >= 0
		else session.state.revision
	)
	var view := session.view_for(1)
	view["state"]["revision"] = revision
	return ProtocolV3.envelope(
		ProtocolV3.STATE_UPDATE,
		"correlation-contract",
		0,
		sequence,
		revision,
		action_id,
		request_id,
		view,
	)


func _has_origin_event(
	rows: Array,
	event_type: String,
	action_id: String,
) -> bool:
	for value in rows:
		var event: Dictionary = value
		if (
			str(event.get("type", "")) == event_type
			and str(event.get("origin_action_id", "")) == action_id
		):
			return true
	return false


func _has_origin_request_event(
	rows: Array,
	event_type: String,
	request_id: String,
) -> bool:
	for value in rows:
		var event: Dictionary = value
		if (
			str(event.get("type", "")) == event_type
			and str(event.get("origin_request_id", "")) == request_id
		):
			return true
	return false


func _has_matched_pending_event(rows: Array, event_type: String) -> bool:
	for value in rows:
		var event: Dictionary = value
		if (
			str(event.get("type", "")) == event_type
			and bool(event.get("matched_pending", false))
		):
			return true
	return false


func _has_event_code(rows: Array, code: String) -> bool:
	for value in rows:
		var event: Dictionary = value
		if str(event.get("code", "")) == code:
			return true
	return false


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
	client._handle_message(ProtocolV3.envelope(
		ProtocolV3.PING,
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
		== ProtocolV3.RESYNC_REQUEST,
		"sequence gap did not request exactly one recovery snapshot",
	)
	client._handle_message(ProtocolV3.envelope(
		ProtocolV3.STATE_UPDATE,
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
	host._handle_host_message({}, ProtocolV3.DECK_SELECT, {
		"deck_key": "water",
		"rules_version": AppState.RULES_SCHEMA_VERSION,
		"action_version": AppState.ACTION_SCHEMA_VERSION,
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
	controller.pending_submission = {
		"kind": "action",
		"action_id": "old-action",
		"request_id": "",
		"base_revision": 5,
		"sent_msec": 1,
		"timeout_notified": false,
	}
	controller.awaiting_update = true
	controller.resync_in_progress = true
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
		and controller.pending_submission.is_empty()
		and not controller.resync_in_progress
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

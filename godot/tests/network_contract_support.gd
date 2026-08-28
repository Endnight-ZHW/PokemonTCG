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


class QueuedNetworkTransport:
	extends FakeNetworkTransport

	var queued_events: Array[Dictionary] = []
	var close_count := 0

	func poll() -> Array[Dictionary]:
		var result := queued_events.duplicate(true)
		queued_events.clear()
		return result

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
		if not session.view_for(1).get("legal_action_groups", []).is_empty():
			return
		var host_actions := _concrete_actions(
			session.view_for(0).get("legal_action_groups", []))
		if host_actions.is_empty():
			return
		var selected: GameAction = host_actions[0]
		for action_row in host_actions:
			if action_row.kind == "SETUP_DONE":
				selected = action_row
				break
		selected.action_id = "contract-host-setup:%d" % step_index
		var result := session.submit_action(0, selected.to_dict())
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
	# Synthetic correlation packets may override the state revision. Do not carry
	# groups tied to the authoritative revision into those deliberately stale views.
	view["legal_action_groups"] = []
	view["legal_action_error"] = ""
	return ProtocolV6.envelope(
		ProtocolV6.STATE_UPDATE,
		"correlation-contract",
		0,
		sequence,
		revision,
		action_id,
		request_id,
		view,
	)


func _concrete_actions(group_rows: Array) -> Array[GameAction]:
	var actions: Array[GameAction] = []
	for value in group_rows:
		if not value is Dictionary:
			continue
		var group := LegalActionGroup.from_dict(value)
		for action in group.concrete_actions():
			actions.append(action)
	return actions


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
	controller.resync_in_progress = true
	controller.connected = true
	controller.connection_phase = NetworkMatchController.ConnectionPhase.PLAYING
	controller.deck_selection_sent = true
	controller.terminal_revision = 5
	controller.terminal_delivery_deadline_msec = 123
	controller.terminal_last_ack_send_msec = 45
	controller.terminal_last_state_send_msec = 67
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
		and controller.pending_submission.is_empty()
		and not controller.resync_in_progress
		and not controller.connected
		and controller.connection_phase == NetworkMatchController.ConnectionPhase.CLOSED
		and not controller.deck_selection_sent
		and controller.terminal_revision == -1
		and controller.terminal_delivery_deadline_msec == 0
		and controller.terminal_last_ack_send_msec == 0
		and controller.terminal_last_state_send_msec == 0
		and controller.events.is_empty()
	)


func _expect_invalid_state(view: Dictionary, label: String) -> void:
	_expect(
		not bool(ProtocolV6.validate_payload(
			ProtocolV6.STATE_UPDATE, view
		).get("ok", false)),
		"state payload accepted %s" % label,
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

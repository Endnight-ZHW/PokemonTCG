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
	_run_modifier_wire_number_contract()
	_run_direct_knockout_protocol_contract()
	_run_setup_hidden_information_contract()
	_run_mulligan_presentation_contract()
	_run_setup_stage_recovery_contract()
	_run_final_setup_publication_contract()
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
	var envelope := ProtocolV6.envelope(ProtocolV6.PING, "contract", 0, 1)
	var legacy_envelope: Dictionary = envelope.duplicate(true)
	legacy_envelope["protocol_version"] = 4
	var legacy_validation := ProtocolV6.validate(legacy_envelope)
	_expect(
		not bool(legacy_validation.get("ok", false))
		and str(legacy_validation.get("code", "")) == "protocol_mismatch",
		"protocol v4 did not fail with an explicit incompatibility diagnostic",
	)
	var protocol_five_envelope: Dictionary = envelope.duplicate(true)
	protocol_five_envelope["protocol_version"] = 5
	var protocol_five_validation := ProtocolV6.validate(protocol_five_envelope)
	_expect(
		not bool(protocol_five_validation.get("ok", false))
		and str(protocol_five_validation.get("code", "")) == "protocol_mismatch"
		and "旧 v5 房间不能恢复" in str(protocol_five_validation.get("message", "")),
		"protocol v5 did not fail with the explicit no-bridge diagnostic",
	)
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
			not bool(ProtocolV6.validate(malformed).get("ok", false)),
			"envelope accepted malformed %s" % row["field"],
		)

	var session := AuthoritativeSession.new("protocol-contract")
	var started := session.start_match("fire", "fire", 20260710, 0)
	_expect(started.success, "same-deck protocol fixture did not start")
	if not started.success:
		return
	var view := session.view_for(0)
	_expect(
		bool(ProtocolV6.validate_payload(ProtocolV6.STATE_UPDATE, view).get("ok", false)),
		"authoritative fixture view is not protocol-valid",
	)
	var hidden_view: Dictionary = view.duplicate(true)
	hidden_view["state"]["opponent"]["active"] = {"hidden": true}
	_expect(
		bool(ProtocolV6.validate_payload(
			ProtocolV6.STATE_UPDATE, hidden_view
		).get("ok", false)),
		"strict hidden setup placeholder was rejected",
	)
	for malformed_hidden in [
		{"hidden": false},
		{"hidden": true, "card_id": "sv1-lecho"},
		{"hidden": 1},
	]:
		var malformed_hidden_view: Dictionary = hidden_view.duplicate(true)
		malformed_hidden_view["state"]["opponent"]["active"] = malformed_hidden
		_expect_invalid_state(
			malformed_hidden_view,
			"non-canonical hidden setup placeholder",
		)
	var own_hidden_view: Dictionary = view.duplicate(true)
	own_hidden_view["state"]["your"]["active"] = {"hidden": true}
	_expect_invalid_state(own_hidden_view, "hidden placeholder in owning player view")
	var visible_setup_view: Dictionary = view.duplicate(true)
	visible_setup_view["state"]["opponent"]["active"] = PokemonState.new(
		"sv1-104",
	).to_dict()
	_expect_invalid_state(
		visible_setup_view,
		"visible opponent Pokemon before setup completion",
	)
	var complete_visible_view: Dictionary = visible_setup_view.duplicate(true)
	complete_visible_view["state"]["setup_stage"] = GameState.SETUP_COMPLETE
	_expect(
		bool(ProtocolV6.validate_payload(
			ProtocolV6.STATE_UPDATE,
			complete_visible_view,
		).get("ok", false)),
		"visible opponent Pokemon was rejected after setup completion",
	)
	var complete_hidden_view: Dictionary = complete_visible_view.duplicate(true)
	complete_hidden_view["state"]["opponent"]["active"] = {"hidden": true}
	_expect_invalid_state(
		complete_hidden_view,
		"hidden opponent placeholder after setup completion",
	)

	var bad_profile: Dictionary = view.duplicate(true)
	bad_profile["state"]["rules_profile_id"] = "INTERNATIONAL"
	_expect_invalid_state(bad_profile, "unknown rules profile")
	var bad_rules_options: Dictionary = view.duplicate(true)
	bad_rules_options["state"]["rules_options"]["future_option"] = true
	_expect_invalid_state(bad_rules_options, "unlocked or unknown rules option")
	var random_session := AuthoritativeSession.new("setup-coin-contract")
	var random_started := random_session.start_match("fire", "water", 20260709)
	var random_view := random_session.view_for(0, random_started.events)
	var setup_events: Array = random_view.get("presentation_events", [])
	_expect(
		random_started.success
		and setup_events.size() == 1
		and str(Dictionary(setup_events[0]).get("event_type", "")) == "coin_flip"
		and str(Dictionary(setup_events[0]).get("data", {}).get("purpose", ""))
		== "setup_turn_order"
		and bool(ProtocolV6.validate_payload(
			ProtocolV6.STATE_UPDATE,
			random_view,
		).get("ok", false)),
		"random setup coin was not public and protocol-valid",
	)

	var draw_view: Dictionary = view.duplicate(true)
	draw_view["state"]["phase"] = "GAME_OVER"
	draw_view["state"]["winner"] = -1
	draw_view["state"]["result_status"] = "DRAW"
	draw_view["state"]["result_reason"] = "equal_win_conditions"
	_expect(
		bool(ProtocolV6.validate_payload(
			ProtocolV6.STATE_UPDATE, draw_view
		).get("ok", false)),
		"DRAW with winner=-1 was rejected",
	)
	var inconsistent_terminal: Dictionary = draw_view.duplicate(true)
	inconsistent_terminal["state"]["result_status"] = "WIN"
	_expect_invalid_state(inconsistent_terminal, "WIN terminal state without winner")

	var malformed_action := GameAction.create(
		"END_TURN",
		{"hand_idx": {}},
		0,
		null,
		null,
		"malformed-action",
		int(view["state"]["revision"]),
	).to_dict()
	_expect(
		not bool(ProtocolV6.validate_payload(
			ProtocolV6.ACTION_SUBMIT,
			{"action": malformed_action},
		).get("ok", false)),
		"action payload accepted a non-integer hand index",
	)

	var internal_choice_request := ChoiceRequest.new(
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
			"domain": "contract",
			"revision": int(view["state"]["revision"]),
			"continuation_frame_id": "frame:contract",
			"revealed_card_ids": [],
			"source_zone": "deck",
		},
	)
	var choice_request := ChoiceView.from_request(
		internal_choice_request, int(view["state"]["revision"])).to_dict()
	var choice_view: Dictionary = view.duplicate(true)
	choice_view["choice_request"] = choice_request
	_expect(
		bool(ProtocolV6.validate_payload(
			ProtocolV6.STATE_UPDATE, choice_view
		).get("ok", false)),
		"valid choice request fixture was rejected",
	)
	var malformed_choice_ref: Dictionary = choice_view.duplicate(true)
	malformed_choice_ref["choice_request"]["options"][0]["ref"]["index"] = {}
	_expect_invalid_state(malformed_choice_ref, "malformed choice entity reference")
	var leaked_choice_value: Dictionary = choice_view.duplicate(true)
	leaked_choice_value["choice_request"]["options"][0]["value"] = {"private": true}
	_expect_invalid_state(leaked_choice_value, "private choice option value")
	var malformed_choice_metadata: Dictionary = choice_view.duplicate(true)
	malformed_choice_metadata["choice_request"]["presentation"]["predetermined_flips"] = {}
	_expect_invalid_state(malformed_choice_metadata, "malformed choice metadata")
	var malformed_source_zone: Dictionary = choice_view.duplicate(true)
	malformed_source_zone["choice_request"]["presentation"]["source_zone"] = {}
	_expect_invalid_state(malformed_source_zone, "non-string choice source_zone")
	var source_zone_choice: Dictionary = choice_view.duplicate(true)
	source_zone_choice["choice_request"]["presentation"]["source_zone"] = "hand"
	_expect(
		bool(ProtocolV6.validate_payload(
			ProtocolV6.STATE_UPDATE, source_zone_choice
		).get("ok", false)),
		"valid choice metadata source_zone was rejected",
	)
	var prize_choice_view: Dictionary = view.duplicate(true)
	prize_choice_view["choice_request"] = ChoiceView.new(
		"choice:prize-contract",
		int(view["state"]["revision"]),
		"select_prize",
		0,
		"选择奖赏卡",
		[{"option_id": "prize:0", "label": "奖赏卡 1"}],
		1,
		1,
		false,
		false,
		{"domain": "knockout", "purpose": "select_prize"},
	).to_dict()
	_expect(
		bool(ProtocolV6.validate_payload(
			ProtocolV6.STATE_UPDATE, prize_choice_view
		).get("ok", false)),
		"identity-free Prize ChoiceView was rejected",
	)
	var leaked_prize_identity: Dictionary = prize_choice_view.duplicate(true)
	leaked_prize_identity["choice_request"]["presentation"]["card_ids"] = [
		"secret-prize-card",
	]
	_expect_invalid_state(leaked_prize_identity, "Prize presentation card identity")
	var leaked_prize_ref: Dictionary = prize_choice_view.duplicate(true)
	leaked_prize_ref["choice_request"]["options"][0]["ref"] = EntityRef.new(
		"card", 0, "prizes", "", 0, "", "secret-prize-card"
	).to_dict()
	_expect_invalid_state(leaked_prize_ref, "Prize option identity reference")


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
			"domain": "contract",
			"revision": session.state.revision,
			"continuation_frame_id": "frame:attachment-wait",
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
		bool(ProtocolV6.validate_payload(
			ProtocolV6.STATE_UPDATE, waiting_view
		).get("ok", false)),
		"coarse attachment wait context was rejected by ProtocolV6",
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
		bool(ProtocolV6.validate_payload(
			ProtocolV6.STATE_UPDATE, presentation_view
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
		bool(ProtocolV6.validate_payload(
			ProtocolV6.STATE_UPDATE, reveal_view
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
		bool(ProtocolV6.validate_payload(
			ProtocolV6.STATE_UPDATE, empty_reveal
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


func _run_direct_knockout_protocol_contract() -> void:
	var session := AuthoritativeSession.new("direct-ko-contract")
	var direct_state := GameState.new()
	direct_state.setup_stage = GameState.SETUP_COMPLETE
	direct_state.phase = "MAIN"
	direct_state.turn_number = 2
	direct_state.first_player_idx = 0
	direct_state.active_player_idx = 0
	direct_state.players[0].active = PokemonState.new("svf-klea")
	direct_state.players[0].active.placed_this_turn = false
	direct_state.players[0].active.energy_card_ids = [
		"sv1-ener-1", "sv1-ener-2",
	]
	direct_state.players[0].prizes = ["sv1-ener-3"]
	direct_state.players[1].active = PokemonState.new("sv1-104")
	direct_state.players[1].active.placed_this_turn = false
	# Lucky Energy is an AFTER_DAMAGE hook. A direct-KO effect must discard it
	# with the Pokemon without ever drawing the defender a card.
	direct_state.players[1].active.energy_card_ids = ["svi-mirc"]
	direct_state.players[1].deck = ["sv1-ener-4"]
	direct_state.players[1].prizes = ["sv1-ener-5"]
	session.state = direct_state
	session.rng = PortableRandomSource.new(2) # First two flips are both heads.

	var attack_action: GameAction = null
	for candidate in RulesTestHarness.legal_actions(session.engine, direct_state, 0, true):
		if (
			candidate.action == "DECLARE_ATTACK"
			and int(candidate.params.get("attack_idx", -1)) == 0
		):
			attack_action = candidate
			break
	_expect(attack_action != null, "direct-KO fixture has no legal first attack")
	if attack_action == null:
		return
	attack_action.action_id = "direct-ko:attack"
	var attack_step := session.submit_action(0, attack_action.to_dict())
	var causal_types_by_player := {0: [], 1: []}
	_collect_direct_ko_view_events(
		session, attack_step, causal_types_by_player)
	var coin_request := attack_step.pending_choice
	_expect(
		attack_step.success
		and coin_request != null
		and coin_request.request_type == "coin_flip"
		and coin_request.metadata.get("predetermined_flips", []) == [true, true],
		"direct-KO attack did not pause on the fixed double-heads result",
	)
	if coin_request == null:
		return

	var coin_step := session.submit_choice(
		0,
		ChoiceResponse.new(coin_request.request_id, []).to_dict(),
	)
	_collect_direct_ko_view_events(
		session, coin_step, causal_types_by_player)
	var prize_request := coin_step.pending_choice
	_expect(
		coin_step.success
		and prize_request != null
		and prize_request.request_type == "select_prize",
		"direct-KO settlement did not pause for an explicit prize position",
	)
	if prize_request == null:
		return
	var prize_step := session.submit_choice(
		0,
		ChoiceResponse.new(prize_request.request_id, ["prize:0"]).to_dict(),
	)
	_collect_direct_ko_view_events(
		session, prize_step, causal_types_by_player)
	_expect(
		prize_step.success and prize_step.pending_choice == null,
		"direct-KO prize settlement did not finish",
	)

	var expected_causal_order := [
		"coin_flip",
		"direct_knockout_applied",
		"pokemon_ko",
		"ko_card_moved",
		"prize_taken",
	]
	for player_idx in [0, 1]:
		var actual: Array = causal_types_by_player[player_idx]
		var cursor := -1
		var causal := true
		for expected_type in expected_causal_order:
			var found := actual.find(expected_type, cursor + 1)
			if found < 0:
				causal = false
				break
			cursor = found
		_expect(
			causal,
			"direct-KO presentation order was not causal for player %d: %s"
			% [player_idx, actual],
		)
		_expect(
			"damage_dealt" not in actual and "cards_drawn" not in actual,
			"direct-KO incorrectly entered damage/AFTER_DAMAGE presentation for player %d"
			% player_idx,
		)
	_expect(
		direct_state.players[1].hand.is_empty()
		and direct_state.players[1].deck == ["sv1-ener-4"],
		"Lucky Energy drew a card after a direct-KO effect",
	)


func _collect_direct_ko_view_events(
	session: AuthoritativeSession,
	step: StepResult,
	causal_types_by_player: Dictionary,
) -> void:
	for player_idx in [0, 1]:
		var view := session.view_for(player_idx, step.events)
		_expect(
			bool(ProtocolV6.validate_payload(
				ProtocolV6.STATE_UPDATE, view
			).get("ok", false)),
			"direct-KO state update was not Protocol v6-valid for player %d"
			% player_idx,
		)
		var actual: Array = causal_types_by_player[player_idx]
		for event_value in view.get("presentation_events", []):
			var event: Dictionary = event_value
			var event_type := PresentationEvent.canonical_event_type(
				str(event.get("event_type", "")),
			)
			if (
				event_type == "card_moved"
				and bool(event.get("data", {}).get("ko_leave_play", false))
			):
				event_type = "ko_card_moved"
			actual.append(event_type)
		causal_types_by_player[player_idx] = actual


func _run_setup_hidden_information_contract() -> void:
	var session := AuthoritativeSession.new("setup-hidden-contract")
	var started := session.start_match("fire", "water", 20260716)
	_expect(started.success, "hidden setup fixture did not start")
	if not started.success:
		return
	var chooser := session.state.opening_coin_winner_idx
	var choice_value: Variant = session.view_for(chooser).get("choice_request")
	_expect(choice_value is Dictionary, "coin winner did not receive turn-order choice")
	if not choice_value is Dictionary:
		return
	var request := ChoiceRequest.from_dict(choice_value)
	var turn_order := session.submit_choice(
		chooser,
		ChoiceResponse.new(request.request_id, ["turn:first"]).to_dict(),
	)
	_expect(turn_order.success, "turn-order choice failed in hidden setup fixture")
	if not turn_order.success:
		return
	var actor := session.state.first_player_idx
	var actor_actions := _concrete_actions(
		session.view_for(actor).get("legal_action_groups", []))
	var placement: GameAction = null
	for action_row in actor_actions:
		if (
			action_row.kind == "PLAY_BASIC"
			and action_row.target != null
			and action_row.target.slot == "active"
		):
			placement = action_row
			break
	_expect(placement != null, "setup fixture had no active Basic placement")
	if placement == null:
		return
	placement.action_id = "setup-hidden-placement"
	var placed := session.submit_action(actor, placement.to_dict())
	_expect(placed.success, "setup Basic placement failed")
	if not placed.success:
		return
	var hidden_card_id := session.state.get_player(actor).active.card_id
	var opponent_view := session.view_for(1 - actor, placed.events)
	var opponent_payload: Dictionary = opponent_view.get("state", {}).get(
		"opponent", {})
	_expect(
		opponent_payload.get("active") == {"hidden": true},
		"opponent setup Pokemon was not serialized as the strict placeholder",
	)
	_expect(
		bool(ProtocolV6.validate_payload(
			ProtocolV6.STATE_UPDATE, opponent_view
		).get("ok", false)),
		"actual hidden setup view was not Protocol v6 valid",
	)
	_expect(
		not JSON.stringify(opponent_view.get("presentation_events", [])).contains(
			hidden_card_id
		)
		and not JSON.stringify(opponent_view["state"].get("action_log", [])).contains(
			hidden_card_id
		)
		and opponent_view["state"].get("action_log", []).any(
			func(line: String) -> bool: return line.contains("暗置宝可梦")
		),
		"setup event or log leaked the hidden Pokemon identity",
	)
	var reconnect_view := session.view_for(1 - actor)
	_expect(
		Dictionary(reconnect_view["state"]["opponent"]).get("active")
		== {"hidden": true},
		"reconnection view leaked a setup Pokemon identity",
	)


func _run_mulligan_presentation_contract() -> void:
	var session: AuthoritativeSession
	var started: StepResult
	for seed_offset in range(1, 513):
		var candidate := AuthoritativeSession.new("mulligan-presentation-contract")
		var candidate_started := candidate.start_match(
			"fire",
			"water",
			2026071600 + seed_offset,
			0,
		)
		if (
			candidate_started.success
			and maxi(candidate.state.mulligan_count[0], candidate.state.mulligan_count[1]) > 0
		):
			session = candidate
			started = candidate_started
			break
	_expect(session != null, "could not find a deterministic mulligan fixture")
	if session == null:
		return

	var sequence_is_causal := true
	for actor in [0, 1]:
		var actor_events: Array[Dictionary] = []
		for event_value in started.events:
			var event: Dictionary = event_value
			if (
				int(event.get("actor", -1)) == actor
				and str(event.get("event_type", "")) in [
					"cards_drawn", "cards_revealed", "card_moved", "deck_shuffled",
				]
			):
				actor_events.append(event)
		var mulligan_count := session.state.mulligan_count[actor]
		sequence_is_causal = (
			sequence_is_causal
			and actor_events.size() == 1 + mulligan_count * 4
		)
		if actor_events.is_empty():
			sequence_is_causal = false
			continue
		var opening_data: Dictionary = actor_events[0].get("data", {})
		sequence_is_causal = (
			sequence_is_causal
			and str(actor_events[0].get("event_type", "")) == "cards_drawn"
			and str(opening_data.get("purpose", "")) == "opening_hand"
			and int(opening_data.get("round", -1)) == 0
			and Array(opening_data.get("card_ids", [])).size() == 7
			and bool(opening_data.get("final_opening_hand", false))
			== (mulligan_count == 0)
		)
		for round_number in range(1, mulligan_count + 1):
			var base := 1 + (round_number - 1) * 4
			if base + 3 >= actor_events.size():
				sequence_is_causal = false
				break
			var reveal: Dictionary = actor_events[base]
			var returned: Dictionary = actor_events[base + 1]
			var shuffled: Dictionary = actor_events[base + 2]
			var redrawn: Dictionary = actor_events[base + 3]
			var reveal_data: Dictionary = reveal.get("data", {})
			var return_data: Dictionary = returned.get("data", {})
			var shuffle_data: Dictionary = shuffled.get("data", {})
			var redraw_data: Dictionary = redrawn.get("data", {})
			sequence_is_causal = (
				sequence_is_causal
				and str(reveal.get("event_type", "")) == "cards_revealed"
				and str(reveal_data.get("purpose", "")) == "mulligan"
				and int(reveal_data.get("round", -1)) == round_number
				and Array(reveal_data.get("cards", [])).size() == 7
				and Array(reveal_data.get("cards", []))
				== Array(return_data.get("card_ids", []))
				and str(returned.get("event_type", "")) == "card_moved"
				and str(return_data.get("purpose", "")) == "mulligan_return"
				and int(return_data.get("round", -1)) == round_number
				and str(shuffled.get("event_type", "")) == "deck_shuffled"
				and str(shuffle_data.get("purpose", "")) == "mulligan"
				and int(shuffle_data.get("round", -1)) == round_number
				and str(redrawn.get("event_type", "")) == "cards_drawn"
				and str(redraw_data.get("purpose", "")) == "mulligan_redraw"
				and int(redraw_data.get("round", -1)) == round_number
				and Array(redraw_data.get("card_ids", [])).size() == 7
				and bool(redraw_data.get("final_opening_hand", false))
				== (round_number == mulligan_count)
			)
	_expect(
		sequence_is_causal,
		"mulligan events did not serialize draw -> reveal -> return -> shuffle -> redraw causally",
	)

	for perspective in [0, 1]:
		var view := session.view_for(perspective, started.events)
		_expect(
			bool(ProtocolV6.validate_payload(
				ProtocolV6.STATE_UPDATE,
				view,
			).get("ok", false)),
			"mulligan presentation view was not Protocol v6-valid for player %d"
			% perspective,
		)
		var privacy_is_correct := true
		for event_value in view.get("presentation_events", []):
			var event: Dictionary = event_value
			var event_type := str(event.get("event_type", ""))
			var data: Dictionary = event.get("data", {})
			if event_type == "cards_drawn" and str(data.get("purpose", "")) in [
				"opening_hand", "mulligan_redraw",
			]:
				privacy_is_correct = (
					privacy_is_correct
					and int(event.get("amount", 0)) == 7
					and Array(data.get("card_ids", [])).size()
					== (7 if int(event.get("actor", -1)) == perspective else 0)
				)
			elif event_type == "cards_revealed":
				privacy_is_correct = (
					privacy_is_correct
					and Array(data.get("cards", [])).size() == 7
					and Array(data.get("card_ids", [])).size() == 7
				)
		_expect(
			privacy_is_correct,
			"mulligan owner redraw or public old-hand visibility leaked for player %d"
			% perspective,
		)


func _run_setup_stage_recovery_contract() -> void:
	for stage in [
		GameState.SETUP_TURN_ORDER,
		GameState.SETUP_INITIAL_PLACEMENT,
		GameState.SETUP_BONUS_DRAW,
		GameState.SETUP_BONUS_PLACEMENT,
	]:
		var state := _setup_recovery_state(stage)
		for perspective in [0, 1]:
			var view := _state_update_payload(state, perspective)
			var opponent: Dictionary = view["state"]["opponent"]
			var opponent_card_id := (
				"sv1-104" if perspective == 0 else "svi-chim"
			)
			var has_board := state.get_player(1 - perspective).active != null
			_expect(
				bool(ProtocolV6.validate_payload(
					ProtocolV6.STATE_UPDATE,
					view,
				).get("ok", false))
				and (
					opponent.get("active") == {"hidden": true}
					if has_board
					else opponent.get("active") == null
				)
				and not view["state"].has("setup_bonus_card_ids")
				and (
					not JSON.stringify(view).contains(opponent_card_id)
					if has_board
					else true
				),
				"%s recovery snapshot leaked setup authority for player %d"
				% [stage, perspective],
			)

	var complete_state := _setup_recovery_state(GameState.SETUP_COMPLETE)
	complete_state.phase = "MAIN"
	for perspective in [0, 1]:
		var complete_view := _state_update_payload(complete_state, perspective)
		var opponent: Dictionary = complete_view["state"]["opponent"]
		_expect(
			bool(ProtocolV6.validate_payload(
				ProtocolV6.STATE_UPDATE,
				complete_view,
			).get("ok", false))
			and opponent.get("active") is Dictionary
			and not bool(Dictionary(opponent["active"]).get("hidden", false)),
			"COMPLETE recovery snapshot did not publish the opponent board",
		)


func _setup_recovery_state(stage: String) -> GameState:
	var state := GameState.new()
	state.phase = "SETUP"
	state.turn_number = 1
	state.first_player_idx = 0
	state.active_player_idx = 0
	state.revision = 17
	state.public_deck_keys = ["fire", "water"]
	state.setup_stage = stage
	state.setup_actor_idx = 0 if stage != GameState.SETUP_COMPLETE else -1
	state.opening_coin_winner_idx = 0
	state.mulligan_bonus_max = 2
	state.mulligan_count = [0, 2]
	state.setup_bonus_card_ids = [["sv1-ener-1"], []]
	for player_idx in [0, 1]:
		state.get_player(player_idx).deck = [
			"sv1-ener-1", "sv1-ener-2", "sv1-ener-3", "sv1-ener-4",
		]
		state.get_player(player_idx).hand = ["svf-potion"]
	if stage != GameState.SETUP_TURN_ORDER:
		state.get_player(0).active = PokemonState.new("svi-chim")
		state.get_player(1).active = PokemonState.new("sv1-104")
	return state


func _state_update_payload(state: GameState, perspective: int) -> Dictionary:
	return {
		"state": StateSerializer.for_player(state, perspective),
		"legal_action_groups": [],
		"legal_action_error": "",
		"presentation_events": [],
		"choice_request": null,
		"wait_context": null,
	}


func _run_final_setup_publication_contract() -> void:
	var session := AuthoritativeSession.new("final-setup-publication-contract")
	session.state = GameState.new()
	session.state.phase = "SETUP"
	session.state.turn_number = 1
	session.state.first_player_idx = 0
	session.state.active_player_idx = 0
	session.state.setup_stage = GameState.SETUP_INITIAL_PLACEMENT
	session.state.setup_actor_idx = 0
	session.state.opening_coin_winner_idx = 0
	session.state.public_deck_keys = ["fire", "water"]
	session.state.get_player(0).hand = ["svi-chim"]
	session.state.get_player(1).hand = ["svi-chim"]
	for player_idx in [0, 1]:
		for _index in range(10):
			session.state.get_player(player_idx).deck.append("sv1-ener-1")

	var steps: Array[StepResult] = []
	for row in [
		{"actor": 0, "action": "PLAY_BASIC", "params": {"hand_idx": 0, "target": "active"}},
		{"actor": 0, "action": "SETUP_DONE", "params": {}},
		{"actor": 1, "action": "PLAY_BASIC", "params": {"hand_idx": 0, "target": "active"}},
		{"actor": 1, "action": "SETUP_DONE", "params": {}},
	]:
		var action: GameAction = null
		for candidate in _concrete_actions(
			session.view_for(int(row["actor"])).get("legal_action_groups", [])
		):
			if candidate.kind != str(row["action"]):
				continue
			if (
				candidate.kind == "PLAY_BASIC"
				and (candidate.target == null or candidate.target.slot != "active")
			):
				continue
			action = candidate
			break
		if action == null:
			steps.append(StepResult.new(false, "missing legal setup action"))
			continue
		action.action_id = "final-setup:%d" % steps.size()
		steps.append(session.submit_action(int(row["actor"]), action.to_dict()))
	var all_steps_succeeded := steps.all(
		func(step: StepResult) -> bool: return step.success,
	)
	_expect(all_steps_succeeded, "final setup publication fixture failed")
	if not all_steps_succeeded:
		return
	var final_step: StepResult = steps[-1]
	for perspective in [0, 1]:
		var view := session.view_for(perspective, final_step.events)
		var event_types: Array[String] = []
		var draw_event: Dictionary = {}
		for event_value in view.get("presentation_events", []):
			var event: Dictionary = event_value
			event_types.append(str(event.get("event_type", "")))
			if str(event.get("event_type", "")) == "cards_drawn":
				draw_event = event
		var draw_ids: Array = Dictionary(draw_event.get("data", {})).get(
			"card_ids", [])
		_expect(
			bool(ProtocolV6.validate_payload(
				ProtocolV6.STATE_UPDATE,
				view,
			).get("ok", false))
			and session.state.setup_stage == GameState.SETUP_COMPLETE
			and view["state"]["opponent"].get("active") is Dictionary
			and event_types == ["setup_revealed", "turn_start", "cards_drawn"]
			and int(draw_event.get("actor", -1)) == 0
			and draw_ids.size() == (1 if perspective == 0 else 0),
			"final setup reveal/start/draw publication was invalid for player %d"
			% perspective,
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

	var remote_repeat := ProtocolV6.envelope(
		ProtocolV6.SURRENDER,
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

	var client := _new_correlation_client(session)
	var submitted_action: GameAction = legal_actions[0]
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
	advanced_view["legal_action_groups"] = []
	advanced_view["legal_action_error"] = ""
	legacy_client._handle_message(ProtocolV6.envelope(
		ProtocolV6.STATE_UPDATE,
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
		"condition": {"expires_after_turn": 2},
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
		not bool(ProtocolV6.validate_payload(
			ProtocolV6.STATE_UPDATE, view
		).get("ok", false)),
		"state payload accepted %s" % label,
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

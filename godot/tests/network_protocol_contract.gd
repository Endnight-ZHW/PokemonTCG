extends "res://tests/network_contract_controller.gd"

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

	var welcome_payload := {
		"player_idx": 1,
		"rules_version": AppState.RULES_SCHEMA_VERSION,
		"action_version": AppState.ACTION_SCHEMA_VERSION,
		"core_fingerprint": str(CardCatalog.shared().card_ir.get(
			"contract_fingerprint", "")),
		"rules_profile_id": GameState.RULES_PROFILE_ID,
		"rules_options": {"apply_type_matchups": false},
		"resume": false,
	}
	_expect(
		bool(ProtocolV6.validate_payload(
			ProtocolV6.WELCOME, welcome_payload).get("ok", false)),
		"valid core contract fingerprint was rejected",
	)
	var malformed_fingerprint: Dictionary = welcome_payload.duplicate(true)
	malformed_fingerprint["core_fingerprint"] = "not-a-sha256"
	_expect(
		not bool(ProtocolV6.validate_payload(
			ProtocolV6.WELCOME, malformed_fingerprint).get("ok", false)),
		"malformed core contract fingerprint was accepted",
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
	var locked_attack_view: Dictionary = view.duplicate(true)
	locked_attack_view["state"]["your"]["attack_locked_names"] = {
		"岩窟冲撞": 5,
	}
	_expect(
		bool(ProtocolV6.validate_payload(
			ProtocolV6.STATE_UPDATE,
			locked_attack_view,
		).get("ok", false)),
		"public player-scoped named attack lock was rejected",
	)
	for invalid_locks in [
		{"": 5},
		{"岩窟冲撞": -1},
		{"岩窟冲撞": "5"},
	]:
		var invalid_lock_view: Dictionary = view.duplicate(true)
		invalid_lock_view["state"]["your"]["attack_locked_names"] = invalid_locks
		_expect_invalid_state(invalid_lock_view, "invalid named attack lock")
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

	var internal_choice_view := ChoiceView.new(
		"choice:contract",
		int(view["state"]["revision"]),
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
	var choice_request := internal_choice_view.to_dict()
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
	var attachment_choice := ChoiceView.new(
		"choice:attachment-wait",
		session.state.revision,
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
			"purpose": "discard_energy",
			"attachment_refs": [attachment_ref],
			"card_ids": ["sv1-ener-2"],
			"source_player": 0,
			"source_slot": "active",
			"same_source": true,
			"same_target": false,
			"max_per_target": 1,
		},
	).to_dict()
	var chooser_view: Dictionary = view.duplicate(true)
	chooser_view["choice_request"] = attachment_choice
	chooser_view["wait_context"] = null
	var waiting_view: Dictionary = view.duplicate(true)
	waiting_view["choice_request"] = null
	waiting_view["wait_context"] = {
		"waiting_for_player": 0,
		"choice_kind": "attachment",
	}
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
	var presentation_event := PresentationEvent.normalize({
		"event_type": "cards_drawn",
		"actor": 0,
		"visibility": "owner",
		"data": {"player": 0, "cards": ["svi-chim"]},
	}, int(view["state"]["revision"]))
	var same_id_redraw := PresentationEvent.normalize({
		"event_type": "cards_drawn",
		"actor": 0,
		"amount": 4,
		"visibility": "owner",
		"data": {
			"player": 0,
			"count": 5,
			"card_ids": [
				"sv1-ener-2",
				"sv1-ener-3",
				"sv1-ener-4",
				"sv1-ener-5",
				"sv1-ener-2",
			],
		},
	}, int(view["state"]["revision"]))
	_expect(
		int(same_id_redraw.get("amount", 0)) == 5,
		"same-id redraw kept the smaller net-diff animation count",
	)
	var cross_owner_move := PresentationEvent.normalize({
		"event_type": "card_moved",
		"actor": 1,
		"visibility": "owner",
		"source": {"player": 0, "zone": "hand", "index": 1},
		"target": {"player": 0, "zone": "deck", "index": 9},
		"data": {
			"player": 0,
			"card_ids": ["sv1-ener-2"],
			"count": 1,
			"source_zone": "hand",
			"target_zone": "deck",
		},
	}, int(view["state"]["revision"]))
	var physical_owner_event := PresentationEvent.for_player(cross_owner_move, 0)
	var causal_actor_event := PresentationEvent.for_player(cross_owner_move, 1)
	_expect(
		int(Dictionary(cross_owner_move.get("data", {})).get(
			"visibility_owner", -1)) == 0
		and Array(Dictionary(physical_owner_event.get("data", {})).get(
			"card_ids", [])).size() == 1
		and Array(Dictionary(causal_actor_event.get("data", {})).get(
			"card_ids", [])).is_empty(),
		"hidden cross-player movement privacy followed causal actor instead of physical owner",
	)
	var presentation_view: Dictionary = view.duplicate(true)
	presentation_view["presentation_events"] = [presentation_event, cross_owner_move]
	_expect(
		bool(ProtocolV6.validate_payload(
			ProtocolV6.STATE_UPDATE, presentation_view
		).get("ok", false)),
		"valid presentation event fixture was rejected",
	)
	var malformed_motion_indices: Dictionary = presentation_view.duplicate(true)
	malformed_motion_indices["presentation_events"][1]["data"][
		"source_indices"
	] = ["1"]
	_expect_invalid_state(
		malformed_motion_indices,
		"presentation motion indices accepted a non-integer value",
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

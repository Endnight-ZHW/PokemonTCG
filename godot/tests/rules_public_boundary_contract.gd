extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	_test_engine_service_boundary()
	_test_legal_query_result()
	_test_choice_view_projection()
	_test_prize_choice_privacy()
	_test_snapshot_three_rejection()
	if failures.is_empty():
		print("RULES_PUBLIC_BOUNDARY_CONTRACT_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_engine_service_boundary() -> void:
	var engine := GameEngine.new()
	var exposed_properties: Array[String] = []
	for property in engine.get_property_list():
		exposed_properties.append(str(Dictionary(property).get("name", "")))
	for private_service in [
		"runtime", "validator", "effect_engine", "knockout_settlement",
		"attack_settlement", "turn_settlement", "action_executor",
		"transaction_manager", "action_settlement", "choice_settlement",
		"action_registry",
	]:
		_check(
			private_service not in exposed_properties,
			"GameEngine publicly exposed private rules service: %s" % private_service,
		)
	_check(
		not engine.has_method("apply_choice")
		and not engine.has_method("legal_actions")
		and engine.has_method("query_legal_action_groups")
		and engine.has_method("apply_action")
		and engine.has_method("apply_choice_response")
		and engine.has_method("query_pending_choice"),
		"GameEngine did not enforce the v6 query/submit boundary",
	)
	_check(
		RulesTestHarness.runtime_for(engine).is_ready()
		and RulesTestHarness.validator_for(engine) != null
		and RulesTestHarness.transaction_manager_for(engine) != null,
		"RulesTestHarness could not access the private composition root",
	)


func _test_legal_query_result() -> void:
	var engine := GameEngine.new()
	var invalid := engine.query_legal_action_groups(GameState.new(), -1)
	_check(
		not invalid.success
		and invalid.code == "invalid_actor"
		and invalid.groups.is_empty(),
		"invalid legal-action query did not return a structured failure",
	)
	var state := GameState.new()
	state.revision = 12
	state.setup_stage = GameState.SETUP_INITIAL_PLACEMENT
	state.setup_actor_idx = 0
	state.players[0].hand = ["svi-chim"]
	var query := engine.query_legal_action_groups(state, 0)
	_check(
		query.success
		and query.base_revision == 12
		and not query.groups.is_empty(),
		"legal-action query did not return a successful versioned result",
	)
	if query.groups.is_empty():
		return
	var expected_targets := query.groups[0].targets.size()
	query.groups[0].targets.clear()
	var cached := engine.query_legal_action_groups(state, 0)
	_check(
		cached.success and cached.groups[0].targets.size() == expected_targets,
		"legal-action result cache leaked mutable groups",
	)


func _test_choice_view_projection() -> void:
	var engine := GameEngine.new()
	var state := GameState.new()
	state.revision = 21
	var stack := ResolutionStack.new()
	stack.push_continuation("private_operation", {
		"kind": "private_operation",
		"frame_id": "private-frame",
		"card_ids": ["secret-prize-card"],
		"revealed_card_ids": ["secret-deck-card"],
		"top_card_id": "secret-top-card",
		"source_slot": "active",
		"command": {"op": "draw_cards"},
		"guard": {"revision": 21},
	})
	stack.context["cancel_action_checkpoint"] = {
		"state": {"private": true},
		"rng": {"private": true},
	}
	stack.pending_request = ChoiceRequest.new(
		"choice:public-boundary",
		"select_attachment",
		0,
		"请选择。",
		[{
			"option_id": "attachment:0:active:energy:0:sv1-ener-5",
			"label": "能量",
			"ref": EntityRef.new(
				"attachment", 0, "", "active", 0, "energy",
				"sv1-ener-5",
			).to_dict(),
			"value": {"private_index": 0},
		}],
		1,
		1,
		false,
		true,
		{
			"domain": "rules",
			"purpose": "retreat_payment",
			"labels": ["公开提示"],
			"category_limits": {"pokemon": 2, "checkpoint": 1},
			"continuation": {"private": true},
			"checkpoint": {"private": true},
			"commands": [{"private": true}],
			"source_player": "not-an-integer",
			"attachment_refs": [{"kind": "card", "player": 0, "zone": "prizes", "index": 0, "card_id": "secret-prize-card"}],
		},
	)
	state.resolution_stack = stack.to_dict()
	var view := engine.query_pending_choice(state, 0)
	_check(view != null, "choice owner could not query the pending ChoiceView")
	_check(
		engine.query_pending_choice(state, 1) == null,
		"ChoiceView leaked to a non-owner viewer",
	)
	if view == null:
		return
	var row := view.to_dict()
	var expected_keys := [
		"allow_duplicates", "base_revision", "can_cancel", "max_select",
		"min_select", "options", "player", "presentation", "prompt",
		"request_id", "request_type", "schema_version",
	]
	var actual_keys: Array = row.keys()
	actual_keys.sort()
	expected_keys.sort()
	var encoded := JSON.stringify(row)
	_check(actual_keys == expected_keys, "ChoiceView did not expose its exact v2 schema")
	_check(
		int(row.get("schema_version", 0)) == 2
		and int(row.get("base_revision", -1)) == state.revision,
		"ChoiceView version/revision was not bound to authoritative state",
	)
	_check(
		not encoded.contains("value")
		and not encoded.contains("continuation")
		and not encoded.contains("guard")
		and not encoded.contains("command")
		and not encoded.contains("checkpoint")
		and not encoded.contains("secret-prize-card")
		and not encoded.contains("secret-deck-card")
		and not encoded.contains("secret-top-card")
		and bool(Dictionary(row["presentation"]).get("cancels_action", false))
		and Dictionary(row["presentation"]).get("labels", []) == ["公开提示"]
		and Dictionary(row["presentation"]).get("category_limits", {}) == {
			"pokemon": 2,
		}
		and not Dictionary(row["presentation"]).has("source_player")
		and not Dictionary(row["presentation"]).has("attachment_refs")
		and not Dictionary(row["presentation"]).has("card_ids")
		and not Dictionary(row["presentation"]).has("source_slot"),
		"ChoiceView copied presentation-shaped secrets from a continuation frame",
	)
	var display := engine.query_state_view(state, 0)
	_check(
		display.get("state") is Dictionary
		and not Dictionary(display["state"]).has("resolution_stack")
		and display.get("choice_request") is Dictionary
		and Dictionary(display["choice_request"]).get("presentation") is Dictionary,
		"presentation state required access to the private resolution stack",
	)


func _test_prize_choice_privacy() -> void:
	var engine := GameEngine.new()
	var state := GameState.new()
	state.revision = 31
	state.players[0].prizes.assign([
		"secret-prize-alpha",
		"secret-prize-beta",
	])
	var stack := ResolutionStack.new()
	stack.context["prize_awards"] = [{
		"player": 0,
		"remaining": 1,
		"defeated_player": 1,
		"defeated_card_id": "public-defeated-card",
	}]
	var request := RulesTestHarness.knockout_settlement_for(engine).request_next_prize(state, stack)
	_check(
		request != null and request.request_type == "select_prize",
		"production Prize settlement did not create a choice",
	)
	# Exercise ChoiceView's fail-safe as well as the production producer: even a
	# malformed internal request must not turn a face-down Prize into a reveal.
	if request != null:
		stack.pending_request.options[0]["ref"] = EntityRef.new(
			"card", 0, "prizes", "", 0, "", "secret-prize-alpha"
		).to_dict()
		stack.pending_request.metadata["card_ids"] = ["secret-prize-alpha"]
		stack.pending_request.metadata["top_card_id"] = "secret-prize-beta"
		state.resolution_stack = stack.to_dict()
	var view := engine.query_pending_choice(state, 0)
	if view == null:
		_check(false, "Prize owner could not query the public choice")
		return
	var row := view.to_dict()
	var encoded := JSON.stringify(row)
	_check(
		not encoded.contains("secret-prize-alpha")
		and not encoded.contains("secret-prize-beta")
		and not encoded.contains("\"value\"")
		and not encoded.contains("continuation")
		and Dictionary(row.get("presentation", {})).get("purpose", "") == "select_prize",
		"Prize ChoiceView leaked a hidden Prize identity or internal payload",
	)
	for option_value in row.get("options", []):
		var option: Dictionary = option_value
		var exact_public_option := true
		for key in option:
			if key not in ["option_id", "label"]:
				exact_public_option = false
		_check(
			exact_public_option,
			"Prize option exposed an identity ref or private value",
		)
	var internal_result := StepResult.new(true, "internal", request)
	var serialized_result := JSON.stringify(internal_result.to_dict(state.revision))
	_check(
		not serialized_result.contains("secret-prize-alpha")
		and not serialized_result.contains("secret-prize-beta")
		and not serialized_result.contains("\"value\"")
		and not serialized_result.contains("\"metadata\""),
		"StepResult serialization bypassed the ChoiceView v2 boundary",
	)


func _test_snapshot_three_rejection() -> void:
	var state := GameState.new()
	var snapshot := state.snapshot()
	_check(
		int(snapshot.get("snapshot_version", 0)) == 3
		and int(Dictionary(snapshot.get("resolution_stack", {})).get(
			"schema_version", 0)) == 3,
		"Snapshot 3 did not serialize a tagged ResolutionStack",
	)
	var legacy := snapshot.duplicate(true)
	legacy["snapshot_version"] = 2
	_check(
		GameState.snapshot_compatibility_error(legacy) == "incompatible_snapshot",
		"Snapshot 2 was accepted by the 0.6.0 runtime",
	)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

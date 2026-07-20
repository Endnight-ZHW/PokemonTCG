extends SceneTree

var failures: Array[String] = []


class QueryProbeEngine:
	extends GameEngine

	var apply_action_calls := 0

	func apply_action(
		state: GameState,
		_action: GameAction,
		_rng: PortableRandomSource,
	) -> StepResult:
		apply_action_calls += 1
		return StepResult.new(
			false, "query invoked apply_action", null, [], state.winner, false,
			"query_simulated_action",
		)


func _initialize() -> void:
	_test_registry_and_strict_wire()
	_test_grouped_query_without_simulation()
	_test_all_groups_bind_and_tamper_fails()
	_test_bounded_maximums()
	_test_retreat_payment_contract()
	_test_retreat_cancellation()
	_test_forged_choice_request_is_ignored()
	if failures.is_empty():
		print("ACTION_V5_CONTRACT_TESTS_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_registry_and_strict_wire() -> void:
	var registry := ActionDefinitionRegistry.shared()
	_check(registry.is_frozen(), "shared action definition registry is not frozen")
	var public_kinds := registry.public_kinds()
	var seen_kinds: Dictionary = {}
	var seen_encoding_ids: Dictionary = {}
	for kind in public_kinds:
		var encoding_id := registry.encoding_index(kind)
		_check(not seen_kinds.has(kind), "duplicate public action kind: %s" % kind)
		_check(
			encoding_id >= 0 and not seen_encoding_ids.has(encoding_id),
			"invalid or duplicate public action encoding id: %s=%d" % [kind, encoding_id],
		)
		seen_kinds[kind] = true
		seen_encoding_ids[encoding_id] = kind
	_check(
		public_kinds.size() == 11 and not public_kinds.has("NOOP") and registry.has("NOOP"),
		"public action inventory must contain 11 unique kinds and keep NOOP internal",
	)

	var noop_wire := GameAction.create(
		"NOOP", {}, 0, null, null, "external-noop", 0).to_dict()
	_assert_contract_error(
		registry.validate_wire_dict(noop_wire),
		"illegal_action",
		"external NOOP",
	)

	var valid_wire := GameAction.create(
		"END_TURN", {}, 0, null, null, "strict-end-turn", 7).to_dict()
	_check(
		bool(registry.validate_wire_dict(valid_wire).get("ok", false)),
		"strict v4 action envelope was rejected",
	)
	var legacy_wire := {
		"action": "END_TURN",
		"params": {},
		"terminal": true,
		"actor": 0,
		"action_id": "legacy",
	}
	_assert_contract_error(
		registry.validate_wire_dict(legacy_wire),
		"invalid_schema",
		"legacy action envelope",
	)
	var extra_wire := valid_wire.duplicate(true)
	extra_wire["terminal"] = true
	_assert_contract_error(
		registry.validate_wire_dict(extra_wire),
		"invalid_schema",
		"extra top-level action field",
	)
	var extra_payload_wire := valid_wire.duplicate(true)
	extra_payload_wire["payload"] = {"target_slot": "active"}
	_assert_contract_error(
		registry.validate_wire_dict(extra_payload_wire),
		"invalid_schema",
		"extra action payload field",
	)

	var unknown_ref_wire := GameAction.create(
		"ATTACH_ENERGY",
		{},
		0,
		EntityRef.new("card", 0, "hand", "", 0, "", "sv1-ener-5"),
		EntityRef.new("pokemon", 0, "", "active", -1, "", "sv1-104"),
		"unknown-ref",
		7,
	).to_dict()
	unknown_ref_wire["source"] = {"kind": "unknown", "player": 0}
	_assert_contract_error(
		registry.validate_wire_dict(unknown_ref_wire),
		"invalid_ref",
		"unknown entity ref",
	)
	var extra_ref_wire := GameAction.create(
		"ATTACH_ENERGY",
		{},
		0,
		EntityRef.new("card", 0, "hand", "", 0, "", "sv1-ener-5"),
		EntityRef.new("pokemon", 0, "", "active", -1, "", "sv1-104"),
		"extra-ref",
		7,
	).to_dict()
	extra_ref_wire["source"]["slot"] = "active"
	_assert_contract_error(
		registry.validate_wire_dict(extra_ref_wire),
		"invalid_ref",
		"extra entity ref field",
	)

	var engine := GameEngine.new()
	_check(
		RulesTestHarness.runtime_for(engine) != null
		and RulesTestHarness.runtime_for(engine).is_ready()
		and RulesTestHarness.action_registry_for(engine).is_frozen()
		and RulesTestHarness.choice_settlement_for(engine) != null,
		"RulesRuntime composition root is not ready or GameEngine bypasses it",
	)
	var stale_state := _battle_state()
	stale_state.revision = 7
	var stale_rng := PortableRandomSource.new(4001)
	var stale_snapshot := stale_state.snapshot()
	var stale_rng_state := stale_rng.get_state()
	var stale_action := GameAction.create(
		"END_TURN", {}, 0, null, null, "stale-action", 6)
	var stale_result := engine.apply_action(stale_state, stale_action, stale_rng)
	_check(
		not stale_result.success
		and stale_result.error_code == "stale_revision"
		and _deep_equal(stale_state.snapshot(), stale_snapshot)
		and stale_rng.get_state() == stale_rng_state,
		"stale action revision was not rejected without mutation",
	)

	var legacy_state := _battle_state()
	var legacy_rng := PortableRandomSource.new(4002)
	var legacy_before := legacy_state.snapshot()
	var legacy_result := engine.apply_action(
		legacy_state,
		GameAction.new("END_TURN", {}, true, 0),
		legacy_rng,
	)
	_check(
		not legacy_result.success
		and legacy_result.error_code == "invalid_schema"
		and _deep_equal(legacy_state.snapshot(), legacy_before),
		"typed legacy action bypassed the strict Actions v4 engine boundary",
	)

	var forged_source_state := _battle_state()
	forged_source_state.revision = 8
	forged_source_state.players[0].bench[0] = PokemonState.new("svi-chim")
	var forged_attack := GameAction.create(
		"DECLARE_ATTACK",
		{"attack_index": 0},
		0,
		EntityRef.new("pokemon", 0, "", "bench_0", -1, "", "svi-chim"),
		null,
		"forged-attack-source",
		forged_source_state.revision,
	)
	var forged_attack_result := engine.apply_action(
		forged_source_state, forged_attack, PortableRandomSource.new(4003))
	_check(
		not forged_attack_result.success
		and forged_attack_result.error_code == "invalid_ref",
		"a real Bench reference was accepted as the source of an Active attack",
	)


func _test_grouped_query_without_simulation() -> void:
	var engine := QueryProbeEngine.new()
	var state := _battle_state()
	state.revision = 19
	state.players[0].hand = ["sv1-ener-5"]
	state.players[0].bench[0] = PokemonState.new("svi-chim")
	state.players[0].bench[1] = PokemonState.new("sv2-delib")
	state.players[0].bench[0].placed_this_turn = false
	state.players[0].bench[1].placed_this_turn = false
	var before := state.snapshot()
	var query := engine.query_legal_action_groups(state, 0)
	var groups := query.groups
	_check(query.success, "legal action query failed: %s" % query.code)
	var energy_groups: Array[LegalActionGroup] = []
	for group in groups:
		if (
			group.kind == "ATTACH_ENERGY"
			and group.source != null
			and group.source.kind == "card"
			and group.source.zone == "hand"
			and group.source.index == 0
		):
			energy_groups.append(group)
	_check(
		energy_groups.size() == 1,
		"one physical hand energy did not produce exactly one legal action group",
	)
	if energy_groups.size() == 1:
		var slots: Array[String] = []
		for target in energy_groups[0].targets:
			slots.append(target.slot)
		slots.sort()
		_check(
			slots == ["active", "bench_0", "bench_1"]
			and energy_groups[0].base_revision == state.revision,
			"energy action group did not preserve all three legal targets",
		)
	_check(
		engine.apply_action_calls == 0
		and _deep_equal(state.snapshot(), before),
		"legal action group query invoked execution/simulation or mutated state",
	)


func _test_all_groups_bind_and_tamper_fails() -> void:
	var engine := GameEngine.new()
	var state := _battle_state()
	state.setup_stage = GameState.SETUP_COMPLETE
	state.revision = 29
	state.players[0].hand = ["sv1-ener-5", "svi-chim"]
	state.players[0].bench[0] = PokemonState.new("svi-chim")
	state.players[0].bench[0].placed_this_turn = false
	var query := engine.query_legal_action_groups(state, 0)
	var groups := query.groups
	_check(query.success, "bindability legal action query failed: %s" % query.code)
	_check(not groups.is_empty(), "bindability fixture produced no groups")
	for group in groups:
		for action in group.concrete_actions():
			action.action_id = "bind:%s:%s" % [group.group_id, action.target.slot if action.target else "-"]
			var clone := GameState.from_dict(state.snapshot())
			var result := GameEngine.new().apply_action(
				clone, action, PortableRandomSource.new(4100))
			_check(
				result.success,
				"enumerated group action failed to execute: %s/%s code=%s" % [
					group.kind, group.group_id, result.error_code,
				],
			)

	var energy_group: LegalActionGroup = null
	for group in groups:
		if group.kind == "ATTACH_ENERGY":
			energy_group = group
			break
	_check(energy_group != null, "tamper fixture produced no energy group")
	if energy_group == null:
		return
	var forged_target := EntityRef.new(
		"pokemon", 0, "", "active", -1, "", "forged-card")
	_check(
		energy_group.bind(forged_target, "forged-bind") == null,
		"group accepted a target outside its bounded target list",
	)
	var valid := energy_group.bind(energy_group.targets[0], "tampered-ref")
	valid.target = forged_target
	var ref_result := engine.apply_action(
		GameState.from_dict(state.snapshot()), valid, PortableRandomSource.new(4101))
	_check(
		not ref_result.success and ref_result.error_code == "invalid_ref",
		"tampered group target did not fail as invalid_ref",
	)
	var payload_tamper := energy_group.bind(
		energy_group.targets[0], "tampered-payload")
	payload_tamper.payload["target_slot"] = "active"
	var payload_result := engine.apply_action(
		GameState.from_dict(state.snapshot()),
		payload_tamper,
		PortableRandomSource.new(4102),
	)
	_check(
		not payload_result.success and payload_result.error_code == "invalid_schema",
		"tampered group payload did not fail as invalid_schema",
	)


func _test_bounded_maximums() -> void:
	var engine := GameEngine.new()
	var group_state := _battle_state()
	group_state.revision = 31
	group_state.players[0].hand.clear()
	for _index in range(54):
		group_state.players[0].hand.append("sv1-ener-5")
	for bench_index in range(5):
		group_state.players[0].bench[bench_index] = PokemonState.new("svi-chim")
		group_state.players[0].bench[bench_index].placed_this_turn = false
	var energy_group_count := 0
	var every_group_has_six_targets := true
	var group_query := engine.query_legal_action_groups(group_state, 0)
	for group in group_query.groups:
		if group.kind == "ATTACH_ENERGY":
			energy_group_count += 1
			every_group_has_six_targets = (
				every_group_has_six_targets and group.targets.size() == 6)
	_check(
		energy_group_count == 54
		and every_group_has_six_targets
		and group_query.success,
		"54 physical energies were expanded or truncated instead of producing 54 groups",
	)

	var payment_state := _retreat_state([])
	for _index in range(60):
		payment_state.players[0].active.energy_card_ids.append("sv1-ener-5")
	var payment := engine.apply_action(
		payment_state,
		_retreat_action(payment_state, "retreat-sixty-attachments"),
		PortableRandomSource.new(8001),
	)
	_check(
		payment.success
		and payment.pending_choice != null
		and payment.pending_choice.request_type == "select_retreat_payment"
		and payment.pending_choice.options.size() == 60,
		"60 retreat attachments did not produce exactly 60 bounded options",
	)


func _test_retreat_payment_contract() -> void:
	var engine := GameEngine.new()
	var free_state := _retreat_state([])
	free_state.players[0].active = PokemonState.new("svl-chat")
	free_state.players[0].active.placed_this_turn = false
	var free_result := engine.apply_action(
		free_state,
		_retreat_action(free_state, "retreat-free"),
		PortableRandomSource.new(5000),
	)
	_check(
		free_result.success
		and free_result.pending_choice == null
		and free_state.players[0].active.card_id == "svi-chim"
		and free_state.players[0].bench[0].card_id == "svl-chat",
		"zero-cost retreat did not settle immediately",
	)
	var state := _retreat_state([
		"sv1-ener-5", "sv1-ener-5", "sv1-ener-5",
	])
	var rng := PortableRandomSource.new(5001)
	var start := engine.apply_action(state, _retreat_action(state, "retreat-pay"), rng)
	_check(
		start.success
		and start.pending_choice != null
		and start.pending_choice.request_type == "select_retreat_payment"
		and start.pending_choice.options.size() == 3
		and int(start.pending_choice.metadata.get("required_units", -1)) == 2,
		"RETREAT did not produce the bounded select_retreat_payment request",
	)
	if not start.success or start.pending_choice == null:
		return
	var request := start.pending_choice
	var pending_snapshot := state.snapshot()
	var pending_events := state.event_stream._events.duplicate(true)
	var pending_rng_state := rng.get_state()
	_assert_failed_payment_preserves(
		engine,
		state,
		rng,
		ChoiceResponse.new(request.request_id, ["retreat:energy:missing"]),
		pending_snapshot,
		pending_events,
		pending_rng_state,
		"invalid retreat payment",
	)
	_assert_failed_payment_preserves(
		engine,
		state,
		rng,
		ChoiceResponse.new(request.request_id, ["retreat:energy:0"]),
		pending_snapshot,
		pending_events,
		pending_rng_state,
		"insufficient retreat payment",
	)
	_assert_failed_payment_preserves(
		engine,
		state,
		rng,
		ChoiceResponse.new(request.request_id, [
			"retreat:energy:0", "retreat:energy:1", "retreat:energy:2",
		]),
		pending_snapshot,
		pending_events,
		pending_rng_state,
		"extra retreat payment",
	)

	var dte_state := _retreat_state(["svi-dtur"])
	var dte_rng := PortableRandomSource.new(5002)
	var dte_start := engine.apply_action(
		dte_state, _retreat_action(dte_state, "retreat-dte"), dte_rng)
	_check(
		dte_start.success
		and dte_start.pending_choice != null
		and dte_start.pending_choice.options.size() == 1,
		"Double Turbo retreat did not request its single physical attachment",
	)
	if dte_start.success and dte_start.pending_choice != null:
		var dte_request := dte_start.pending_choice
		var dte_result := engine.apply_choice_response(
			dte_state,
			ChoiceResponse.new(dte_request.request_id, ["retreat:energy:0"]),
			dte_rng,
		)
		_check(
			dte_result.success
			and dte_result.pending_choice == null
			and dte_state.players[0].active.card_id == "svi-chim"
			and dte_state.players[0].bench[0].card_id == "sv1-104"
			and dte_state.players[0].bench[0].energy_card_ids.is_empty()
			and dte_state.players[0].discard == ["svi-dtur"]
			and dte_state.players[0].retreated_this_turn,
			"one Double Turbo Energy did not satisfy a two-unit retreat cost: %s/%s" % [
				dte_result.error_code, dte_result.message,
			],
		)


func _test_retreat_cancellation() -> void:
	var engine := GameEngine.new()
	var state := _retreat_state(["sv1-ener-5", "sv1-ener-5"])
	state.revision = 23
	state.action_log.append("before-retreat")
	state.event_stream.push("before_retreat", {"stable": true})
	var rng := PortableRandomSource.new(6001)
	var before := state.snapshot()
	var before_events := state.event_stream._events.duplicate(true)
	var before_rng := rng.get_state()
	var start := engine.apply_action(state, _retreat_action(state, "retreat-cancel"), rng)
	_check(
		start.success and start.pending_choice != null and start.pending_choice.can_cancel,
		"cancellable retreat payment was not created",
	)
	if not start.success or start.pending_choice == null:
		return
	var pending_revision := state.revision
	var cancelled := engine.apply_choice_response(
		state,
		ChoiceResponse.new(start.pending_choice.request_id, [], true),
		rng,
	)
	var restored := state.snapshot()
	var restored_revision := int(restored.get("revision", -1))
	restored["revision"] = before["revision"]
	_check(
		cancelled.success
		and cancelled.pending_choice == null
		and restored_revision == pending_revision + 1
		and _deep_equal(restored, before)
		and _deep_equal(state.event_stream._events, before_events)
		and rng.get_state() == before_rng,
		"retreat cancellation did not restore pre-action state/RNG with causal revision",
	)


func _test_forged_choice_request_is_ignored() -> void:
	var engine := GameEngine.new()
	var state := _retreat_state(["svi-dtur"])
	var rng := PortableRandomSource.new(7001)
	var start := engine.apply_action(
		state, _retreat_action(state, "retreat-forged-request"), rng)
	_check(
		start.success and start.pending_choice != null,
		"forged request adapter fixture did not reach a pending choice",
	)
	if not start.success or start.pending_choice == null:
		return
	var authoritative := start.pending_choice
	var forged := ChoiceRequest.new(
		"forged-request-id",
		"choose_turn_order",
		1,
		"forged",
		[{"option_id": "forged", "value": {"goes_first": true}}],
		0,
		0,
		true,
		false,
		{"domain": "setup", "revision": -999},
	)
	var result := RulesTestHarness.apply_choice(engine, 
		state,
		forged,
		ChoiceResponse.new(authoritative.request_id, ["retreat:energy:0"]),
		rng,
	)
	_check(
		result.success
		and state.players[0].active.card_id == "svi-chim"
		and state.players[0].discard == ["svi-dtur"],
		"compatibility ChoiceRequest influenced the response-only authoritative adapter: %s/%s" % [
			result.error_code, result.message,
		],
	)


func _battle_state() -> GameState:
	var state := GameState.new()
	state.phase = "MAIN"
	state.turn_number = 3
	state.first_player_idx = 1
	state.active_player_idx = 0
	state.players[0].active = PokemonState.new("sv1-104")
	state.players[0].active.placed_this_turn = false
	state.players[0].hand = ["sv1-ener-5"]
	state.players[0].deck = ["sv1-ener-5", "sv1-ener-5"]
	state.players[0].prizes = ["sv1-ener-5"]
	state.players[1].active = PokemonState.new("sv1-104")
	state.players[1].active.placed_this_turn = false
	state.players[1].deck = ["sv1-ener-5", "sv1-ener-5"]
	state.players[1].prizes = ["sv1-ener-5"]
	return state


func _retreat_state(energy_ids: Array[String]) -> GameState:
	var state := _battle_state()
	state.revision = 11
	state.players[0].hand.clear()
	state.players[0].active.energy_card_ids.assign(energy_ids)
	state.players[0].bench[0] = PokemonState.new("svi-chim")
	state.players[0].bench[0].placed_this_turn = false
	state.players[0].discard.clear()
	return state


func _retreat_action(state: GameState, action_id: String) -> GameAction:
	return GameAction.create(
		"RETREAT",
		{},
		0,
		EntityRef.new(
			"pokemon", 0, "", "active", -1, "",
			state.players[0].active.card_id),
		EntityRef.new("pokemon", 0, "", "bench_0", -1, "", "svi-chim"),
		action_id,
		state.revision,
	)


func _assert_failed_payment_preserves(
	engine: GameEngine,
	state: GameState,
	rng: PortableRandomSource,
	response: ChoiceResponse,
	expected_snapshot: Dictionary,
	expected_events: Array,
	expected_rng_state: int,
	label: String,
) -> void:
	var result := engine.apply_choice_response(state, response, rng)
	_check(
		not result.success
		and result.error_code in ["invalid_choice", "invalid_ref"]
		and _deep_equal(state.snapshot(), expected_snapshot)
		and _deep_equal(state.event_stream._events, expected_events)
		and rng.get_state() == expected_rng_state,
		"%s did not fail atomically: code=%s message=%s" % [
			label, result.error_code, result.message,
		],
	)


func _assert_contract_error(result: Dictionary, code: String, label: String) -> void:
	_check(
		not bool(result.get("ok", true)) and str(result.get("code", "")) == code,
		"%s did not fail with %s: %s" % [label, code, JSON.stringify(result)],
	)


func _deep_equal(left: Variant, right: Variant) -> bool:
	if typeof(left) != typeof(right):
		return false
	if left is Dictionary:
		var left_dict: Dictionary = left
		var right_dict: Dictionary = right
		if left_dict.size() != right_dict.size():
			return false
		for key in left_dict:
			if not right_dict.has(key) or not _deep_equal(left_dict[key], right_dict[key]):
				return false
		return true
	if left is Array:
		var left_array: Array = left
		var right_array: Array = right
		if left_array.size() != right_array.size():
			return false
		for index in range(left_array.size()):
			if not _deep_equal(left_array[index], right_array[index]):
				return false
		return true
	return left == right


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

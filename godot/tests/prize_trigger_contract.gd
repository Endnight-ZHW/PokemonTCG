extends SceneTree

var failures: Array[String] = []
var engine := GameEngine.new(CardCatalog.new())


func _initialize() -> void:
	_test_decline_and_public_boundary()
	_test_confirm_target_snapshot_and_attach()
	_test_descriptor_clone_has_identical_trigger()
	if failures.is_empty():
		print("PRIZE_TRIGGER_CONTRACT_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_decline_and_public_boundary() -> void:
	var state := _state()
	var request := _prize_request(state)
	if request == null:
		_fail("KO did not request a Prize position")
		return
	var prompted := engine.apply_choice_response(
		state,
		ChoiceResponse.new(request.request_id, ["prize:0"]),
		PortableRandomSource.new(601),
	)
	var confirm := prompted.pending_choice
	_expect(
		prompted.success,
		"ON_PRIZE_REVEALED trigger confirmation failed: %s" % prompted.error_code,
	)
	_expect(confirm != null, "ON_PRIZE_REVEALED did not create a trigger confirmation")
	if confirm != null:
		_expect(confirm.request_type == "confirm_trigger", "Prize trigger exposed the wrong Choice type")
		_expect(
			str(confirm.presentation.get("purpose", "")) == "trigger_confirm",
			"Prize trigger omitted its public presentation purpose",
		)
		_expect(confirm.options.size() == 1, "Prize trigger exposed the wrong option count")
		if confirm.options.size() == 1:
			_expect(
				not confirm.options[0].has("ref"),
				"Prize trigger leaked its face-down Prize ref",
			)
			_expect(
				not confirm.options[0].has("value"),
				"Prize trigger leaked its internal option value",
			)
	_expect(
		state.players[0].prizes == ["svi-trea", "sv1-ener-2"],
		"Treasure Energy left the Prize zone before its trigger choice resolved",
	)
	_expect(prompted.events.is_empty(), "Prize trigger published events before confirmation")
	var authoritative := ResolutionStack.from_dict(state.resolution_stack).pending_request
	_expect(
		authoritative != null
		and authoritative.options.size() == 1
		and authoritative.options[0].get("ref") is Dictionary
		and str(authoritative.options[0]["ref"].get("zone", "")) == "prizes"
		and str(authoritative.options[0]["ref"].get("card_id", "")) == "svi-trea",
		"Authoritative Prize trigger lost its exact private CardRef",
	)
	_expect(
		engine.query_pending_choice(state, 1) == null,
		"Prize trigger identity leaked to the opposing viewer",
	)
	if confirm == null:
		return
	var declined := engine.apply_choice_response(
		state,
		ChoiceResponse.new(confirm.request_id, [], true),
		PortableRandomSource.new(602),
	)
	_expect(
		declined.success
		and state.players[0].prizes == ["sv1-ener-2"]
		and "svi-trea" in state.players[0].hand
		and _event_index(declined.events, "prize_taken") >= 0
		and _event_index(declined.events, "energy_attached") < 0,
		"Declined Prize trigger did not resume the Prize award into hand",
	)


func _test_confirm_target_snapshot_and_attach() -> void:
	var state := _state()
	var prize := _prize_request(state)
	var prompted := engine.apply_choice_response(
		state,
		ChoiceResponse.new(prize.request_id, ["prize:0"]),
		PortableRandomSource.new(603),
	)
	var confirm := prompted.pending_choice
	var confirmed := engine.apply_choice_response(
		state,
		ChoiceResponse.new(confirm.request_id, [str(confirm.options[0]["option_id"])]),
		PortableRandomSource.new(604),
	)
	var target := confirmed.pending_choice
	_expect(
		confirmed.success and target != null
		and target.request_type == "select_energy_target"
		and target.options.size() >= 2
		and target.options[0].get("ref") is Dictionary
		and not target.options[0].has("value"),
		"Confirmed Prize trigger did not suspend in the generic attachment target Choice",
	)
	if target == null:
		return
	var snapshot := state.snapshot()
	var restored := GameState.from_snapshot(snapshot)
	_expect(
		restored != null and restored.snapshot() == snapshot,
		"Prize trigger attachment Choice did not roundtrip Snapshot 3 exactly",
	)
	var bench_option := ""
	for option in target.options:
		if str(option.get("ref", {}).get("slot", "")) == "bench_0":
			bench_option = str(option.get("option_id", ""))
	var attached := engine.apply_choice_response(
		restored,
		ChoiceResponse.new(target.request_id, [bench_option]),
		PortableRandomSource.new(605),
	)
	var prize_event := _event_index(attached.events, "prize_taken")
	var attach_event := _event_index(attached.events, "energy_attached")
	_expect(
		attached.success
		and restored.players[0].prizes == ["sv1-ener-2"]
		and restored.players[0].bench[0].energy_card_ids == ["svi-trea"]
		and "svi-trea" not in restored.players[0].hand
		and prize_event >= 0 and attach_event > prize_event,
		"Generic Prize trigger did not attach the exact CardRef or preserve event order",
	)


func _test_descriptor_clone_has_identical_trigger() -> void:
	var clone_catalog := CardCatalog.new(true)
	var clone_descriptor := clone_catalog.get_card("svi-trea").duplicate(true)
	clone_descriptor["api_id"] = "test-prize-trigger-clone"
	clone_descriptor["name"] = "Descriptor Clone"
	clone_catalog.cards["test-prize-trigger-clone"] = clone_descriptor
	var clone_engine := GameEngine.new(clone_catalog)
	var state := _state("test-prize-trigger-clone")
	var events: Array[Dictionary] = []
	var ko: Dictionary = RulesTestHarness.knockout_settlement_for(
		clone_engine
	).resolve_knockouts(
		state, 0, events, false, ResolutionStack.new(), PortableRandomSource.new(606))
	var prize: ChoiceRequest = ko.get("pending_choice", null)
	var prompted := clone_engine.apply_choice_response(
		state,
		ChoiceResponse.new(prize.request_id, ["prize:0"]),
		PortableRandomSource.new(607),
	)
	_expect(
		prompted.success and prompted.pending_choice != null
		and prompted.pending_choice.request_type == "confirm_trigger"
		and state.players[0].prizes[0] == "test-prize-trigger-clone",
		"A different card_id with the same compiled trigger descriptor behaved differently",
	)


func _prize_request(state: GameState) -> ChoiceRequest:
	var events: Array[Dictionary] = []
	var result := RulesTestHarness.knockout_settlement_for(engine).resolve_knockouts(
		state, 0, events, false, ResolutionStack.new(), PortableRandomSource.new(600))
	return result.get("pending_choice", null)


func _state(prize_card_id: String = "svi-trea") -> GameState:
	var state := GameState.new()
	state.phase = "MAIN"
	state.active_player_idx = 0
	state.first_player_idx = 0
	state.players[0].active = PokemonState.new("svi-chim")
	state.players[0].bench[0] = PokemonState.new("sv2-delib")
	state.players[0].prizes = [prize_card_id, "sv1-ener-2"]
	state.players[1].active = PokemonState.new("svi-chim")
	state.players[1].active.damage_counters = 99
	state.players[1].bench[0] = PokemonState.new("sv2-delib")
	return state


func _event_index(events: Array, event_type: String) -> int:
	for index in range(events.size()):
		if str(events[index].get("event_type", "")) == event_type:
			return index
	return -1


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	failures.append(message)

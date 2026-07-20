extends SceneTree

var failures: Array[String] = []
var catalog := CardCatalog.new()


func _initialize() -> void:
	_test_strict_frame_contract()
	_test_order_decline_and_snapshot()
	_test_incoming_first_order()
	_test_nested_on_attach_trigger()
	_test_budget_persists_in_snapshot()
	if failures.is_empty():
		print("TRIGGER_STACK_CONTRACT_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_strict_frame_contract() -> void:
	var engine := EffectEngine.new(catalog)
	var valid := _candidate(
		"strict:valid", "STRICT", 0, false,
		_pokemon_ref(0, "active", "svi-chim"), [_draw_spec(1)])
	var malformed := valid.duplicate(true)
	malformed["optional"] = 1
	_expect(
		not bool(engine.trigger_commands().queue_candidates(
			ResolutionStack.new(), [malformed], "STRICT", 0).get("success", true)),
		"TriggerCandidate accepted a non-boolean optional field")
	malformed = valid.duplicate(true)
	malformed["source_ref"] = {"kind": "mystery", "player": 0}
	_expect(
		not bool(engine.trigger_commands().queue_candidates(
			ResolutionStack.new(), [malformed], "STRICT", 0).get("success", true)),
		"TriggerCandidate accepted an invalid EntityRef")
	malformed = valid.duplicate(true)
	malformed["liveness"] = {"kind": "always", "extra": true}
	_expect(
		not bool(engine.trigger_commands().queue_candidates(
			ResolutionStack.new(), [malformed], "STRICT", 0).get("success", true)),
		"TriggerCandidate accepted an open liveness schema")
	malformed = valid.duplicate(true)
	malformed["guards"] = [{"kind": "always", "extra": true}]
	_expect(
		not bool(engine.trigger_commands().queue_candidates(
			ResolutionStack.new(), [malformed], "STRICT", 0).get("success", true)),
		"TriggerCandidate accepted an open guard schema")
	_expect(
		not bool(engine.trigger_commands().queue_candidates(
			ResolutionStack.new(), [valid], "OTHER_HOOK", 0).get("success", true)),
		"trigger_batch accepted a candidate with a different hook")
	malformed = valid.duplicate(true)
	malformed["commands"] = [{
		"op": "__private_trigger_op", "args": {}, "branches": {},
	}]
	var internal_result := engine.trigger_commands().queue_candidates(
		ResolutionStack.new(), [malformed], "STRICT", 0)
	_expect(
		not bool(internal_result.get("success", true))
		and str(internal_result.get("error_code", "")) == "invalid_trigger_payload",
		"TriggerCandidate accepted an unknown/private VM op")
	var legacy := ResolutionStack.from_dict({
		"schema_version": VMResolutionFrameCodec.STACK_SCHEMA_VERSION,
		"frames": [{
			"kind": "effect", "effect": _draw_spec(1),
			"player_idx": 0, "source_slot": "active",
		}],
		"pending_request": null, "sequence": 0, "context": {},
	})
	_expect(
		str(legacy.validation_result().get("error_code", "")) == "invalid_stack_frame",
		"Snapshot 3 accepted a legacy effect frame")
	var oversized := ResolutionStack.new()
	oversized.context["blob"] = "x".repeat(
		VMResolutionFrameCodec.MAX_SERIALIZED_BYTES + 1)
	_expect(
		str(oversized.validation_result().get("error_code", ""))
		== "stack_snapshot_size_limit",
		"Snapshot 3 accepted a stack larger than 1 MiB")


func _test_order_decline_and_snapshot() -> void:
	var state := _state()
	state.players[0].deck = ["sv1-ener-1", "sv1-ener-2"]
	var engine := EffectEngine.new(catalog)
	var stack := ResolutionStack.new()
	var source_ref := _pokemon_ref(0, "active", state.players[0].active.card_id)
	var candidates: Array[Dictionary] = [
		_candidate("order:first", "ORDER", 0, true, source_ref, [_draw_spec(1)]),
		_candidate("order:second", "ORDER", 0, true, source_ref, [_draw_spec(1)]),
	]
	var queued := engine.trigger_commands().queue_candidates(
		stack, candidates, "ORDER", 0, "apnap", "effect")
	_expect(bool(queued.get("success", false)), "same-priority trigger batch did not queue")
	var first_step := engine.resolve(state, stack, PortableRandomSource.new(10))
	_expect(
		first_step.success and first_step.pending_choice != null
		and first_step.pending_choice.request_type == "choose_trigger_order",
		"same-controller/same-priority triggers did not request an order")
	var encoded := stack.to_dict()
	var restored := ResolutionStack.from_dict(encoded)
	_expect(
		restored.validation_result().is_empty() and restored.to_dict() == encoded,
		"trigger-order Snapshot 3 roundtrip was not byte-stable")
	if first_step.pending_choice == null:
		return
	var order_request := first_step.pending_choice
	var ordered := engine.apply_choice(
		state, restored,
		ChoiceResponse.new(order_request.request_id, [
			str(order_request.options[1].get("option_id", ""))]),
		PortableRandomSource.new(10))
	_expect(
		ordered.success and ordered.pending_choice != null
		and ordered.pending_choice.request_type == "confirm_trigger",
		"ordered optional trigger did not request confirmation")
	if ordered.pending_choice == null:
		return
	var declined := engine.apply_choice(
		state, restored,
		ChoiceResponse.new(ordered.pending_choice.request_id, [], true),
		PortableRandomSource.new(10))
	_expect(
		declined.success and declined.pending_choice != null
		and state.players[0].hand.is_empty(),
		"declining one optional trigger cancelled or executed the parent batch")
	if declined.pending_choice == null:
		return
	var accepted := engine.apply_choice(
		state, restored,
		ChoiceResponse.new(declined.pending_choice.request_id, [
			str(declined.pending_choice.options[0].get("option_id", ""))]),
		PortableRandomSource.new(10))
	_expect(
		accepted.success and accepted.pending_choice == null
		and state.players[0].hand.size() == 1
		and restored.current_trigger_depth() == 0,
		"remaining optional trigger did not resume and finish its parent batch")


func _test_incoming_first_order() -> void:
	var state := _state()
	state.players[0].deck = ["sv1-ener-1"]
	state.players[1].deck = ["sv1-ener-2"]
	var engine := EffectEngine.new(catalog)
	var stack := ResolutionStack.new()
	var candidates: Array[Dictionary] = [
		_candidate(
			"incoming:p0", "CHECKUP", 0, false,
			_pokemon_ref(0, "active", state.players[0].active.card_id), [_draw_spec(1)]),
		_candidate(
			"incoming:p1", "CHECKUP", 1, false,
			_pokemon_ref(1, "active", state.players[1].active.card_id), [_draw_spec(1)]),
	]
	engine.trigger_commands().queue_candidates(
		stack, candidates, "CHECKUP", 1, "incoming_first", "effect")
	var step := engine.resolve(state, stack, PortableRandomSource.new(11))
	var draw_players: Array[int] = []
	for event in step.events:
		if str(event.get("event_type", "")) == "cards_drawn":
			draw_players.append(int(event.get("data", {}).get("player", -1)))
	_expect(
		step.success and draw_players == [1, 0],
		"Checkup trigger order was not incoming player then outgoing player")


func _test_nested_on_attach_trigger() -> void:
	var state := _state()
	state.players[0].bench[0] = PokemonState.new("sv2-delib")
	state.players[0].hand = ["svi-jete"]
	var engine := EffectEngine.new(catalog)
	var stack := ResolutionStack.new()
	var outer := _candidate(
		"nested:outer", "NESTED", 0, false,
		_pokemon_ref(0, "bench_0", state.players[0].bench[0].card_id),
		[{
			"op": "attach_energy",
			"args": {
				"amount": 1, "filter": "any", "from_zone": "hand", "to": "self",
			},
			"branches": {},
		}])
	var queued := engine.trigger_commands().queue_candidates(
		stack, [outer], "NESTED", 0, "apnap", "effect")
	_expect(bool(queued.get("success", false)), "nested parent trigger did not queue")
	var step := engine.resolve(state, stack, PortableRandomSource.new(12))
	_expect(
		step.success and step.pending_choice == null
		and state.players[0].active.card_id == "sv2-delib"
		and state.players[0].active.energy_card_ids == ["svi-jete"]
		and stack.current_trigger_depth() == 0,
		"ON_ATTACH child trigger did not pre-empt and complete its parent trigger: %s active=%s bench=%s stack=%s" % [
			step.to_dict() if step.has_method("to_dict") else {
				"success": step.success, "message": step.message,
				"error_code": step.error_code,
			},
			state.players[0].active.to_dict(),
			state.players[0].bench[0].to_dict(),
			stack.to_dict(),
		])


func _test_budget_persists_in_snapshot() -> void:
	var state := _state()
	state.players[0].deck = ["sv1-ener-1"]
	var engine := EffectEngine.new(catalog)
	var stack := ResolutionStack.new()
	stack.context["vm_budget"] = {"steps_used": VMContract.MAX_VM_STEPS - 1}
	var candidate := _candidate(
		"budget:trigger", "BUDGET", 0, false,
		_pokemon_ref(0, "active", state.players[0].active.card_id), [_draw_spec(1)])
	engine.trigger_commands().queue_candidates(
		stack, [candidate], "BUDGET", 0, "apnap", "effect")
	var restored := ResolutionStack.from_dict(stack.to_dict())
	var step := engine.resolve(state, restored, PortableRandomSource.new(13))
	_expect(
		not step.success and step.error_code == "vm_step_limit"
		and int(restored.context.get("vm_budget", {}).get("steps_used", 0))
		== VMContract.MAX_VM_STEPS,
		"VM step budget reset across a trigger Snapshot roundtrip")


func _state() -> GameState:
	var state := GameState.new()
	state.phase = "MAIN"
	state.active_player_idx = 0
	state.players[0].active = PokemonState.new("svi-chim")
	state.players[1].active = PokemonState.new("sv1-104")
	return state


func _candidate(
	trigger_id: String,
	hook: String,
	controller: int,
	optional: bool,
	source_ref: Dictionary,
	commands: Array,
) -> Dictionary:
	var specs: Array[Dictionary] = []
	for command in commands:
		specs.append(Dictionary(command).duplicate(true))
	return {
		"trigger_id": trigger_id, "hook": hook, "controller": controller,
		"priority": 20, "source_ref": source_ref, "optional": optional,
		"liveness": {"kind": "source_exists"}, "guards": [],
		"commands": specs, "parent_trigger_id": "", "depth": 1,
	}


func _pokemon_ref(player_idx: int, slot: String, card_id: String) -> Dictionary:
	return EntityRef.new(
		"pokemon", player_idx, "field", slot, -1, "", card_id).to_dict()


func _draw_spec(amount: int) -> Dictionary:
	return {"op": "draw_cards", "args": {"amount": amount}, "branches": {}}


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

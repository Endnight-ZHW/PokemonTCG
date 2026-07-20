extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	_test_registry_contract()
	_test_data_defined_energy_clones()
	_test_lucky_energy_clone_trigger()
	_test_ultra_ball_clone_cost_and_execution()
	_test_transient_modifier_lifetime()
	_test_controller_choice_conflict_roundtrip()
	_test_persistent_registered_modifiers()
	_test_tool_attachment_and_frozen_attacker_context()
	if failures.is_empty():
		print("MODIFIER_DESCRIPTOR_CONTRACT_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_registry_contract() -> void:
	var registry := VMModifierDescriptorRegistry.shared()
	_check(registry.is_frozen(), "modifier descriptor registry is not frozen")
	_check(
		not registry.register_definition("late_operation", {}),
		"frozen modifier registry accepted a late definition",
	)
	var descriptor := VMModifierManager.descriptor(
		VMModifierManager.MODIFY_DAMAGE,
		"attacker_adjust",
		30,
		0,
		VMModifierManager.source_pokemon_ref(0, "active", "sv1-104"),
		"self",
		"until_end_of_turn",
		"stack",
		{"expires_after_turn": 3},
		{"kind": "damage_delta", "amount": -20},
	)
	_check(registry.validation_error(descriptor).is_empty(), "valid descriptor was rejected")
	var extra := descriptor.duplicate(true)
	extra["unknown"] = true
	_check(
		not registry.validation_error(extra).is_empty(),
		"descriptor with an extra field was accepted",
	)
	var wrong_layer := descriptor.duplicate(true)
	wrong_layer["layer"] = "set"
	_check(
		not registry.validation_error(wrong_layer).is_empty(),
		"descriptor with mismatched operation layer was accepted",
	)
	var manager := VMModifierManager.new()
	_check(manager.register_descriptor(descriptor), "manager rejected a valid descriptor")
	var higher_priority := descriptor.duplicate(true)
	higher_priority["priority"] = 40
	_check(manager.register_descriptor(higher_priority), "manager rejected priority clone")
	_check(
		int(manager.descriptors_for(VMModifierManager.MODIFY_DAMAGE)[0]["priority"]) == 40,
		"modifier descriptors were not ordered by layer and priority",
	)


func _test_data_defined_energy_clones() -> void:
	var catalog := CardCatalog.new(true)
	var luminous_clone: Dictionary = catalog.get_card("svg2-lume").duplicate(true)
	luminous_clone["api_id"] = "clone-luminous"
	luminous_clone["name"] = "克隆夜光能量"
	catalog.cards["clone-luminous"] = luminous_clone
	_check(
		EnergyView.units_for_cards(["clone-luminous"], catalog) == ["Rainbow"],
		"cloned wildcard energy did not use its descriptor",
	)
	_check(
		EnergyView.units_for_cards(["clone-luminous", "svi-dtur"], catalog)[0] == "Colorless",
		"cloned wildcard energy did not apply data-defined downgrade",
	)

	var turbo_clone: Dictionary = catalog.get_card("svi-dtur").duplicate(true)
	turbo_clone["api_id"] = "clone-double-turbo"
	turbo_clone["name"] = "克隆双重涡轮能量"
	catalog.cards["clone-double-turbo"] = turbo_clone
	var original_damage := _damage_with_energy(catalog, "svi-dtur")
	var clone_damage := _damage_with_energy(catalog, "clone-double-turbo")
	_check(original_damage == 80, "original descriptor-driven damage modifier changed")
	_check(
		clone_damage == original_damage,
		"different card_id with the same energy descriptor changed behavior",
	)


func _damage_with_energy(catalog: CardCatalog, energy_id: String) -> int:
	var state := GameState.new()
	state.players[0].active = PokemonState.new("sv1-104")
	state.players[1].active = PokemonState.new("sv1-104")
	state.players[0].active.energy_card_ids = [energy_id]
	return VMDamageModifierHooks.apply_modify_damage(state, catalog, {
		"actor": 0,
		"attacker": state.players[0].active,
		"defender": state.players[1].active,
		"damage": 100,
		"modifier_phase": "attacker",
	})


func _test_lucky_energy_clone_trigger() -> void:
	var catalog := CardCatalog.new(true)
	var clone: Dictionary = catalog.get_card("svi-mirc").duplicate(true)
	clone["api_id"] = "clone-lucky-energy"
	clone["name"] = "克隆幸运能量"
	catalog.cards["clone-lucky-energy"] = clone
	for energy_id in ["svi-mirc", "clone-lucky-energy"]:
		var state := GameState.new()
		state.players[0].active = PokemonState.new("sv1-104")
		state.players[1].active = PokemonState.new("sv2-delib")
		state.players[1].active.energy_card_ids = [energy_id]
		state.players[1].deck = ["sv1-ener-3"]
		var effect_engine := EffectEngine.new(catalog)
		var trigger_commands := effect_engine.trigger_commands()
		var candidates: Array[Dictionary] = []
		trigger_commands.collect_after_damage_triggers(state, {
			"actor": 0,
			"attacker": state.players[0].active,
			"defender": state.players[1].active,
			"defender_player": 1,
			"defender_slot": "active",
			"damage": 30,
		}, candidates)
		_check(candidates.size() == 1, "%s did not compile one AFTER_DAMAGE trigger" % energy_id)
		if candidates.size() != 1:
			continue
		var commands: Array = candidates[0].get("commands", [])
		_check(
			commands.size() == 1
			and str(Dictionary(commands[0]).get("op", "")) == "trigger_draw_cards"
			and str(Dictionary(commands[0]).get("args", {}).get("source", "")) == energy_id,
			"%s trigger was not descriptor-derived" % energy_id,
		)
		var stack := ResolutionStack.new()
		var queued := trigger_commands.queue_candidates(
			stack, candidates, VMModifierManager.AFTER_DAMAGE, 0, "apnap", "effect")
		_check(bool(queued.get("success", false)), "%s trigger did not queue: %s candidate=%s" % [
			energy_id, JSON.stringify(queued), JSON.stringify(candidates[0]),
		])
		var resolved := effect_engine.resolve(
			state, stack, PortableRandomSource.new(6601))
		_check(
			resolved.success
			and state.players[1].hand == ["sv1-ener-3"]
			and state.players[1].deck.is_empty(),
			"different card_id with the Lucky Energy descriptor changed trigger behavior",
		)


func _test_ultra_ball_clone_cost_and_execution() -> void:
	var catalog := CardCatalog.new(true)
	var clone: Dictionary = catalog.get_card("sv1-153").duplicate(true)
	clone["api_id"] = "clone-ultra-ball"
	clone["name"] = "克隆高级球"
	catalog.cards["clone-ultra-ball"] = clone
	var fingerprints: Array[Dictionary] = []
	for card_id in ["sv1-153", "clone-ultra-ball"]:
		fingerprints.append(_ultra_ball_descriptor_fingerprint(catalog, card_id))
	_check(
		fingerprints.size() == 2
		and fingerprints[0] == fingerprints[1]
		and bool(fingerprints[0].get("unpaid_rejected", false))
		and bool(fingerprints[0].get("paid_completed", false)),
		"different card_id with the Ultra Ball descriptor changed preflight or execution: %s" % JSON.stringify(fingerprints),
	)


func _ultra_ball_descriptor_fingerprint(
	catalog: CardCatalog,
	card_id: String,
) -> Dictionary:
	var effects := VMRuntimeEffects.strict_trainer_effects(
		catalog.get_card(card_id), "trainer:%s" % card_id)
	var availability := VMAvailability.new(catalog)
	var unpaid := GameState.new()
	unpaid.players[0].hand = [card_id, "sv1-ener-1"]
	var unpaid_result := availability.preflight_costs(
		unpaid, 0, effects, 0, "trainer")
	var payable := GameState.new()
	payable.players[0].hand = [card_id, "sv1-ener-1", "sv1-ener-2"]
	var payable_result := availability.preflight_costs(
		payable, 0, effects, 0, "trainer")

	var state := GameState.new()
	state.players[0].active = PokemonState.new("sv1-104")
	state.players[1].active = PokemonState.new("sv1-104")
	state.players[0].hand = ["sv1-ener-1", "sv1-ener-2"]
	state.players[0].deck = ["svi-chim"]
	var effect_engine := EffectEngine.new(catalog)
	var stack := ResolutionStack.new()
	stack.context["effect_source_kind"] = "trainer"
	stack.push_effects(effects, 0, "active")
	var step := effect_engine.resolve(state, stack, PortableRandomSource.new(6602))
	if not step.success or step.pending_choice == null:
		return {
			"unpaid_rejected": bool(unpaid_result.get("ok", false)) and not bool(unpaid_result.get("legal", true)),
			"payable_accepted": bool(payable_result.get("ok", false)) and bool(payable_result.get("legal", false)),
			"paid_completed": false,
		}
	var discard_ids: Array[String] = []
	for option in step.pending_choice.options:
		discard_ids.append(str(option.get("option_id", "")))
	step = effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, discard_ids),
		PortableRandomSource.new(6603),
	)
	if not step.success or step.pending_choice == null:
		return {
			"unpaid_rejected": bool(unpaid_result.get("ok", false)) and not bool(unpaid_result.get("legal", true)),
			"payable_accepted": bool(payable_result.get("ok", false)) and bool(payable_result.get("legal", false)),
			"paid_completed": false,
		}
	var search_option_id := str(step.pending_choice.options[0].get("option_id", ""))
	step = effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [search_option_id]),
		PortableRandomSource.new(6604),
	)
	return {
		"unpaid_rejected": bool(unpaid_result.get("ok", false)) and not bool(unpaid_result.get("legal", true)),
		"payable_accepted": bool(payable_result.get("ok", false)) and bool(payable_result.get("legal", false)),
		"paid_completed": (
			step.success
			and state.players[0].hand == ["svi-chim"]
			and state.players[0].discard.size() == 2
			and "sv1-ener-1" in state.players[0].discard
			and "sv1-ener-2" in state.players[0].discard
			and state.players[0].deck.is_empty()
		),
		"final_success": step.success,
		"final_error": step.error_code,
		"hand": state.players[0].hand.duplicate(),
		"discard": state.players[0].discard.duplicate(),
		"deck": state.players[0].deck.duplicate(),
	}


func _test_transient_modifier_lifetime() -> void:
	var catalog := CardCatalog.new(true)
	var state := GameState.new()
	state.turn_number = 5
	state.players[0].active = PokemonState.new("sv1-104")
	state.players[1].active = PokemonState.new("sv1-001")
	var commands := VMStatusCommands.new(catalog)
	var result := commands.apply_prevention(state, 0, "active", true, true)
	_check(bool(result.get("success", false)), "prevention modifier registration failed")
	_check(state.players[0].active.prevents_damage(), "damage prevention descriptor is inactive")
	_check(state.players[0].active.prevents_effects(), "effect prevention descriptor is inactive")
	_check(
		state.players[0].active.modifier_descriptors().size() == 2,
		"prevention flags were not migrated to strict descriptors",
	)
	state.players[0].active.expire_modifiers_at_turn(5)
	_check(state.players[0].active.prevents_damage(), "modifier expired one turn too early")
	state.players[0].active.expire_modifiers_at_turn(6)
	_check(not state.players[0].active.prevents_damage(), "modifier did not expire at boundary")
	_check(not state.players[0].active.prevents_effects(), "effect modifier did not expire at boundary")
	var dazzle := commands.apply_dazzling_beam(
		state, ResolutionStack.new(), 0, {"target": "opponent_active"})
	_check(bool(dazzle.get("success", false)), "dazzle descriptor registration failed")
	_check(state.players[1].active.has_attack_gate("dazzled"), "dazzle gate descriptor is inactive")
	_check(
		state.players[1].active.consume_modifier_operation("attack_gate_coin", "dazzled"),
		"dazzle gate was not consumable",
	)


func _test_controller_choice_conflict_roundtrip() -> void:
	var state := GameState.new()
	state.revision = 9
	state.players[0].active = PokemonState.new("sv1-104")
	state.players[0].bench[0] = PokemonState.new("sv1-001")
	var manager := VMModifierManager.new()
	for row in [
		{"slot": "active", "card_id": "sv1-104", "value": 1},
		{"slot": "bench_0", "card_id": "sv1-001", "value": 2},
	]:
		_check(manager.register_descriptor(VMModifierManager.descriptor(
			VMModifierManager.CAN_RETREAT,
			"set",
			10,
			0,
			VMModifierManager.source_pokemon_ref(
				0, str(row["slot"]), str(row["card_id"])),
			"self",
			"until_leave_play",
			"replace_same_source",
			{},
			{"kind": "retreat_set", "value": int(row["value"])},
			"controller_choice",
		)), "manager rejected controller-choice replacement")
	var stack := ResolutionStack.new()
	var conflict := manager.resolve_controller_choices(
		state, stack, VMModifierManager.CAN_RETREAT, "retreat:test:9")
	_check(bool(conflict.get("success", false)), "controller-choice resolver failed")
	var request: ChoiceRequest = conflict.get("pending_choice", null)
	_check(request != null, "replacement conflict did not suspend for a choice")
	if request == null:
		return
	_check(request.options.size() == 2, "replacement conflict exposed the wrong candidates")
	var public_payload := request.to_public_dict(state.revision)
	_check(
		not _tree_has_forbidden_choice_key(public_payload),
		"public modifier choice leaked continuation/value/command data",
	)
	_check(
		Dictionary(public_payload.get("options", [])[0]).has("ref"),
		"public modifier choice omitted its source ref",
	)
	var paused_payload := stack.to_dict()
	var paused_validation := VMResolutionFrameCodec.validate_stack_payload(paused_payload)
	_check(paused_validation.is_empty(), "modifier conflict stack was not Snapshot-3 safe")
	var restored := ResolutionStack.from_dict(paused_payload)
	_check(
		restored.to_dict() == paused_payload,
		"modifier conflict pause changed across Snapshot-3 roundtrip",
	)
	var interpreter := VMInterpreter.new()
	VMModifierContinuations.new().register(interpreter)
	var registry_errors := interpreter.freeze([])
	_check(registry_errors.is_empty(), "modifier continuation registry did not freeze")
	var selected_option_id := str(restored.pending_request.options[1]["option_id"])
	var resumed := interpreter.apply_choice(
		state,
		restored,
		ChoiceResponse.new(restored.pending_request.request_id, [selected_option_id]),
		PortableRandomSource.new(6060),
	)
	_check(resumed.success, "modifier controller choice continuation failed: %s" % resumed.message)
	var resolved := manager.resolve_controller_choices(
		state, restored, VMModifierManager.CAN_RETREAT, "retreat:test:9")
	_check(bool(resolved.get("success", false)), "resolved modifier choice became invalid")
	var selected_descriptors: Array = resolved.get("descriptors", [])
	_check(selected_descriptors.size() == 1, "unselected replacement descriptor survived")
	if selected_descriptors.size() == 1:
		_check(
			int(Dictionary(selected_descriptors[0]["operation"])["value"]) == 2,
			"controller choice did not retain the selected replacement",
		)


func _test_persistent_registered_modifiers() -> void:
	var catalog := CardCatalog.new(true)
	var state := GameState.new()
	state.players[0].active = PokemonState.new("sv1-104")
	state.players[0].bench[0] = PokemonState.new("sv2-delib")
	state.players[1].active = PokemonState.new("sv1-001")
	var commands := VMModifierCommands.new()
	var boost := commands.register_named_modifier(
		state,
		0,
		"bench_0",
		"aura_damage_boost",
		{"amount": 30},
	)
	_check(bool(boost.get("success", false)), "persistent aura boost registration failed")
	var boosted := VMDamageModifierHooks.apply_modify_damage(state, catalog, {
		"actor": 0,
		"attacker": state.players[0].active,
		"defender": state.players[1].active,
		"damage": 20,
		"modifier_phase": "attacker",
	})
	_check(boosted == 50, "persistent aura boost descriptor was not applied")
	var reduction := commands.register_named_modifier(
		state,
		1,
		"active",
		"aura_damage_reduction",
		{"reduction": 20},
	)
	_check(bool(reduction.get("success", false)), "persistent aura reduction registration failed")
	var reduced := VMDamageModifierHooks.apply_modify_damage(state, catalog, {
		"actor": 0,
		"attacker": state.players[0].active,
		"defender": state.players[1].active,
		"target_player": 1,
		"target_slot": "active",
		"damage": 20,
		"modifier_phase": "defender",
	})
	_check(reduced == 0, "persistent aura reduction descriptor was not applied")


func _test_tool_attachment_and_frozen_attacker_context() -> void:
	var catalog := CardCatalog.new(true)
	var engine := GameEngine.new(catalog)
	var state := GameState.new()
	state.phase = "MAIN"
	state.turn_number = 2
	state.first_player_idx = 1
	state.active_player_idx = 0
	state.players[0].active = PokemonState.new("sv1-104")
	state.players[0].active.placed_this_turn = false
	state.players[0].active.energy_card_ids = ["svi-dtur"]
	state.players[0].hand = ["svl-vitb"]
	state.players[0].deck = ["sv1-ener-5"]
	state.players[0].prizes = ["sv1-ener-5"]
	state.players[1].active = PokemonState.new("sv1-001")
	state.players[1].active.placed_this_turn = false
	state.players[1].deck = ["sv1-ener-5"]
	state.players[1].prizes = ["sv1-ener-5"]
	var legacy_action := GameAction.new(
		"PLAY_TRAINER",
		{"hand_idx": 0, "target_slot": "active"},
		false,
		0,
	)
	var action := engine._canonicalize_action(state, legacy_action, 0)
	var step := engine.apply_action(
		state, action, PortableRandomSource.new(6061))
	_check(step.success, "tool attachment did not execute compiled effects: %s" % step.message)
	_check(
		step.events.any(func(event: Dictionary) -> bool:
			return str(event.get("event_type", "")) == "tool_attached"),
		"tool attachment VM result dropped the attachment event",
	)
	var descriptors := state.players[0].active.modifier_descriptors(
		VMModifierManager.MODIFY_DAMAGE)
	_check(descriptors.size() == 1, "tool attachment did not persist exactly one modifier")
	if descriptors.size() == 1:
		var source_ref: Dictionary = descriptors[0].get("source_ref", {})
		_check(
			str(source_ref.get("kind", "")) == "pokemon"
			and str(source_ref.get("slot", "")) == "active"
			and str(source_ref.get("card_id", "")) == "sv1-104",
			"tool modifier source differs from the cross-runtime contract",
		)

	# Attack settlement keeps this object as a frozen snapshot. The live source
	# may already have left play before damage is calculated, so slot resolution
	# must come from the attack context rather than object identity.
	var frozen_attacker := PokemonState.from_dict(state.players[0].active.to_dict())
	var damage_state := GameState.new()
	damage_state.players[0].active = null
	damage_state.players[1].active = PokemonState.new("sv1-104")
	var frozen_damage := VMDamageModifierHooks.apply_modify_damage(damage_state, catalog, {
		"actor": 0,
		"attacker_slot": "active",
		"attacker": frozen_attacker,
		"defender": damage_state.players[1].active,
		"damage": 100,
		"modifier_phase": "attacker",
	})
	_check(
		frozen_damage == 90,
		"frozen attacker did not apply DTE (-20) and its tool (+10) exactly once: %d"
		% frozen_damage,
	)


func _tree_has_forbidden_choice_key(value: Variant) -> bool:
	if value is Dictionary:
		for key_value in Dictionary(value).keys():
			var key := str(key_value)
			if key in ["value", "continuation", "guard", "command", "checkpoint"]:
				return true
			if _tree_has_forbidden_choice_key(Dictionary(value)[key_value]):
				return true
	elif value is Array:
		for child in Array(value):
			if _tree_has_forbidden_choice_key(child):
				return true
	return false


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

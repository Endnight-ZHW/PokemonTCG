class_name VMActionAvailability
extends RefCounted

var catalog: CardCatalog
var validator: RulesValidator
var availability: VMAvailability
var attack_settlement: VMAttackSettlement


func _init(
	p_catalog: CardCatalog,
	p_validator: RulesValidator,
	p_availability: VMAvailability,
	p_attack_settlement: VMAttackSettlement,
) -> void:
	catalog = p_catalog
	validator = p_validator
	availability = p_availability
	attack_settlement = p_attack_settlement


func legal_actions(
	state: GameState,
	actor: int,
	validate_effects: bool = true,
	apply_action_for_simulation: Callable = Callable(),
) -> Array[GameAction]:
	var actions: Array[GameAction] = []
	if actor not in [0, 1]:
		return actions
	var stored_stack := ResolutionStack.from_dict(state.resolution_stack)
	if stored_stack.pending_request != null:
		return actions
	if not state.pending_promotions.is_empty():
		if actor != int(state.pending_promotions[0]):
			return actions
		var promote_player := state.get_player(actor)
		for bench_idx in range(promote_player.bench.size()):
			var pokemon: PokemonState = promote_player.bench[bench_idx]
			if pokemon:
				actions.append(GameAction.new(
					"PROMOTE",
					{"bench_idx": bench_idx},
					false,
					actor,
					null,
					EntityRef.new(
						"pokemon", actor, "", "bench_%d" % bench_idx,
						-1, "", pokemon.card_id),
				))
		return actions
	if state.phase == "SETUP":
		return setup_actions(state, actor)
	if state.phase == "ATTACK":
		if state.active_player_idx == actor:
			actions.append(GameAction.new("END_TURN", {}, true, actor))
		return actions
	if state.phase != "MAIN" or state.active_player_idx != actor:
		return actions

	var player := state.get_player(actor)
	var seen: Dictionary = {}
	var empty_slots: Array[String] = []
	for index in range(player.bench.size()):
		if player.bench[index] == null:
			empty_slots.append("bench_%d" % index)

	for hand_idx in range(player.hand.size()):
		var card_id := player.hand[hand_idx]
		var source := EntityRef.new("card", actor, "hand", "", hand_idx, "", card_id)
		if catalog.is_basic_pokemon(card_id):
			for target_slot in empty_slots:
				_add_action(actions, seen, GameAction.new(
					"PLAY_BASIC",
					{"hand_idx": hand_idx, "target": target_slot},
					false,
					actor,
					source,
					EntityRef.new("pokemon", actor, "", target_slot),
				))
		elif catalog.is_stage1(card_id) or catalog.is_stage2(card_id):
			for row in player.get_all_pokemon():
				var pokemon: PokemonState = row["pokemon"]
				var slot := str(row["slot"])
				if pokemon and validator.can_evolve(state, actor, slot, card_id).is_empty():
					_add_action(actions, seen, GameAction.new(
						"EVOLVE",
						{"hand_idx": hand_idx, "slot": slot},
						false,
						actor,
						source,
						EntityRef.new("pokemon", actor, "", slot, -1, "", pokemon.card_id),
					))
		elif catalog.is_energy(card_id):
			for row in player.get_all_pokemon():
				var pokemon: PokemonState = row["pokemon"]
				var slot := str(row["slot"])
				if pokemon and validator.can_attach_energy(state, actor, card_id, slot).is_empty():
					_add_action(actions, seen, GameAction.new(
						"ATTACH_ENERGY",
						{"hand_idx": hand_idx, "target_slot": slot},
						false,
						actor,
						source,
						EntityRef.new("pokemon", actor, "", slot, -1, "", pokemon.card_id),
					))
		elif catalog.is_tool(card_id):
			for row in player.get_all_pokemon():
				var pokemon: PokemonState = row["pokemon"]
				var slot := str(row["slot"])
				if pokemon and validator.can_play_trainer(state, actor, card_id, slot).is_empty():
					_add_action(actions, seen, GameAction.new(
						"PLAY_TRAINER",
						{"hand_idx": hand_idx, "target_slot": slot},
						false,
						actor,
						source,
						EntityRef.new("pokemon", actor, "", slot, -1, "", pokemon.card_id),
					))
		elif catalog.is_trainer(card_id):
			if validator.can_play_trainer(state, actor, card_id).is_empty():
				var trainer_action := GameAction.new(
					"PLAY_TRAINER", {"hand_idx": hand_idx}, false, actor, source)
				if (
					action_cost_error(state, trainer_action, actor).is_empty()
					and action_target_availability_error(state, trainer_action, actor).is_empty()
					and (
						not validate_effects
						or simulated_action_succeeds(
							state, trainer_action, apply_action_for_simulation)
					)
				):
					_add_action(actions, seen, trainer_action)

	for row in player.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon == null:
			continue
		var slot := str(row["slot"])
		for ability_value in catalog.get_card(pokemon.card_id).get("abilities", []):
			var ability: Dictionary = ability_value
			var ability_name := str(ability.get("name", ""))
			if validator.can_use_ability(state, actor, slot, ability_name).is_empty():
				var ability_action := GameAction.new(
					"USE_ABILITY",
					{"slot": slot, "ability_name": ability_name},
					false,
					actor,
					EntityRef.new("pokemon", actor, "", slot, -1, "", pokemon.card_id),
				)
				if (
					action_target_availability_error(state, ability_action, actor).is_empty()
					and (
						not validate_effects
						or simulated_action_succeeds(
							state, ability_action, apply_action_for_simulation)
					)
				):
					_add_action(actions, seen, ability_action)

	if availability.stadium_is_activatable(state) and not player.stadium_used_this_turn:
		var stadium_action := GameAction.new("USE_STADIUM", {}, false, actor)
		if (
			action_target_availability_error(state, stadium_action, actor).is_empty()
			and (
				not validate_effects
				or simulated_action_succeeds(state, stadium_action, apply_action_for_simulation)
			)
		):
			_add_action(actions, seen, stadium_action)

	for bench_idx in range(player.bench.size()):
		var bench_pokemon: PokemonState = player.bench[bench_idx]
		if bench_pokemon == null:
			continue
		for payment in retreat_payments(state, actor, bench_idx):
			_add_action(actions, seen, GameAction.new(
				"RETREAT",
				{"bench_idx": bench_idx, "energy_indices": payment},
				false,
				actor,
				null,
				EntityRef.new(
					"pokemon", actor, "", "bench_%d" % bench_idx,
					-1, "", bench_pokemon.card_id),
			))

	if player.active:
		var attacks: Array = catalog.get_card(player.active.card_id).get("attacks", [])
		for attack_idx in range(attacks.size()):
			if validator.can_attack(state, actor, attack_idx).is_empty():
				var attack_action := GameAction.new(
					"DECLARE_ATTACK",
					{"attack_idx": attack_idx},
					true,
					actor,
					EntityRef.new("pokemon", actor, "", "active", -1, "", player.active.card_id),
				)
				if action_target_availability_error(state, attack_action, actor).is_empty():
					_add_action(actions, seen, attack_action)
	_add_action(actions, seen, GameAction.new("END_TURN", {}, true, actor))
	return actions


func setup_actions(state: GameState, actor: int) -> Array[GameAction]:
	var actions: Array[GameAction] = []
	if state.setup_ready[actor]:
		return actions
	var player := state.get_player(actor)
	for hand_idx in range(player.hand.size()):
		var card_id := player.hand[hand_idx]
		if not catalog.is_basic_pokemon(card_id):
			continue
		var source := EntityRef.new("card", actor, "hand", "", hand_idx, "", card_id)
		if player.active == null:
			actions.append(GameAction.new(
				"PLAY_BASIC",
				{"hand_idx": hand_idx, "target": "active"},
				false,
				actor,
				source,
				EntityRef.new("pokemon", actor, "", "active"),
			))
		else:
			for bench_idx in range(player.bench.size()):
				if player.bench[bench_idx] == null:
					var slot := "bench_%d" % bench_idx
					actions.append(GameAction.new(
						"PLAY_BASIC",
						{"hand_idx": hand_idx, "target": slot},
						false,
						actor,
						source,
						EntityRef.new("pokemon", actor, "", slot),
					))
	if player.active:
		actions.append(GameAction.new("SETUP_DONE", {}, true, actor))
	return actions


func retreat_payments(
	state: GameState,
	actor: int,
	bench_idx: int,
) -> Array[Array]:
	var result: Array[Array] = []
	var player := state.get_player(actor)
	if player.active == null or player.bench[bench_idx] == null:
		return result
	var cost := validator.effective_retreat_cost(state, player)
	if cost <= 0:
		if validator.can_retreat(state, actor, bench_idx, []).is_empty():
			result.append([])
		return result
	var count := player.active.energy_card_ids.size()
	if count > 12:
		return result
	for mask in range(1, 1 << count):
		var indices: Array[int] = []
		var units := 0
		for index in range(count):
			if mask & (1 << index):
				indices.append(index)
				units += max(1, catalog.provides_energy(
					player.active.energy_card_ids[index]).size())
		if units < cost:
			continue
		var minimal := true
		for index in indices:
			var reduced: int = units - max(1, catalog.provides_energy(
				player.active.energy_card_ids[index]).size())
			if reduced >= cost:
				minimal = false
				break
		if minimal and validator.can_retreat(state, actor, bench_idx, indices).is_empty():
			result.append(indices)
	return result


func simulated_action_succeeds(
	state: GameState,
	action: GameAction,
	apply_action_for_simulation: Callable,
) -> bool:
	if not apply_action_for_simulation.is_valid():
		return true
	var simulation := GameState.from_dict(state.snapshot())
	var result: StepResult = apply_action_for_simulation.call(
		simulation, action, PortableRandomSource.new(1))
	return result.success


func action_cost_error(
	state: GameState,
	action: GameAction,
	actor: int,
) -> String:
	if action.action != "PLAY_TRAINER":
		return ""
	var player := state.get_player(actor)
	var hand_idx := int(action.params.get("hand_idx", -1))
	if hand_idx < 0 or hand_idx >= player.hand.size():
		return ""
	var effects: Array = _trainer_runtime_effects(str(player.hand[hand_idx]))
	if effects.is_empty() or availability.effects_cost_is_payable(state, actor, effects, hand_idx):
		return ""
	return "无法支付代价。"


func action_target_availability_error(
	state: GameState,
	action: GameAction,
	actor: int,
) -> String:
	match action.action:
		"PLAY_TRAINER":
			var player := state.get_player(actor)
			var hand_idx := int(action.params.get("hand_idx", -1))
			if hand_idx < 0 or hand_idx >= player.hand.size():
				return ""
			var card_id := str(player.hand[hand_idx])
			var effects: Array = _trainer_runtime_effects(card_id)
			if effects.is_empty():
				return ""
			var source_slot := str(action.params.get("target_slot", "active"))
			if source_slot.is_empty():
				source_slot = "active"
			if not availability.effects_have_legal_target(
				state, actor, effects, source_slot, hand_idx
			):
				return "没有合法目标，不能使用。"
		"USE_ABILITY":
			var slot := str(action.params.get("slot", ""))
			var pokemon := state.get_player(actor).get_pokemon(slot)
			if pokemon == null:
				return ""
			var ability_name := str(action.params.get("ability_name", "")).to_lower()
			for ability_value in catalog.get_card(pokemon.card_id).get("abilities", []):
				var ability: Dictionary = ability_value
				if str(ability.get("name", "")).to_lower() != ability_name:
					continue
				var ability_effects: Array = _ability_runtime_effects(ability)
				if (
					not ability_effects.is_empty()
					and not availability.effects_have_legal_target(
						state, actor, ability_effects, slot)
				):
					return "没有合法目标，不能使用该特性。"
				break
		"USE_STADIUM":
			if state.stadium_card_id.is_empty():
				return ""
			var stadium_effects: Array = _trainer_runtime_effects(state.stadium_card_id)
			if (
				not stadium_effects.is_empty()
				and not availability.effects_have_legal_target(
					state, actor, stadium_effects, "active")
			):
				return "没有合法目标，不能使用竞技场。"
		"DECLARE_ATTACK":
			var attacker := state.get_player(actor).active
			if attacker == null:
				return ""
			var attack_idx := int(action.params.get("attack_idx", -1))
			var attacks: Array = catalog.get_card(attacker.card_id).get("attacks", [])
			if attack_idx < 0 or attack_idx >= attacks.size():
				return ""
			var attack: Dictionary = attacks[attack_idx]
			if int(attack.get("damage", 0)) > 0 and state.get_player(1 - actor).active != null:
				return ""
			if not availability.effects_have_legal_target(
				state, actor, attack_settlement.attack_runtime_effects(attack), "active"
			):
				return "没有合法目标，不能使用该招式。"
	return ""


func validate_action_references(state: GameState, action: GameAction) -> String:
	for ref in [action.source, action.target]:
		if ref == null:
			continue
		if ref.player not in [0, 1]:
			return "实体引用玩家无效。"
		if ref.kind == "card":
			var zone := _zone(state.get_player(ref.player), ref.zone)
			if ref.index < 0 or ref.index >= zone.size():
				return "卡牌引用位置已变化。"
			if not ref.card_id.is_empty() and zone[ref.index] != ref.card_id:
				return "卡牌引用内容已变化。"
		elif ref.kind == "pokemon":
			var pokemon := state.get_player(ref.player).get_pokemon(ref.slot)
			if pokemon == null:
				if ref.card_id.is_empty():
					continue
				return "宝可梦引用位置已变化。"
			if not ref.card_id.is_empty() and pokemon.card_id != ref.card_id:
				return "宝可梦引用内容已变化。"
	return ""


func _trainer_runtime_effects(card_id: String) -> Array:
	return VMRuntimeEffects.strict_trainer_effects(catalog.get_card(card_id), "trainer:%s" % card_id)


func _ability_runtime_effects(ability: Dictionary) -> Array:
	return VMRuntimeEffects.strict_ability_effects(ability)


func _zone(player: PlayerState, zone_name: String) -> Array[String]:
	match zone_name:
		"hand":
			return player.hand
		"discard":
			return player.discard
		"prizes":
			return player.prizes
		_:
			return player.deck


func _add_action(
	actions: Array[GameAction],
	seen: Dictionary,
	action: GameAction,
) -> void:
	var signature := "%s:%s" % [action.action, JSON.stringify(action.params)]
	if seen.has(signature):
		return
	seen[signature] = true
	actions.append(action)

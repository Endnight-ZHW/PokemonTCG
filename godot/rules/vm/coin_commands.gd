class_name VMCoinCommands
extends RefCounted

var catalog: CardCatalog
var combat_damage: VMCombatDamage


func _init(p_catalog: CardCatalog, p_combat_damage: VMCombatDamage) -> void:
	catalog = p_catalog
	combat_damage = p_combat_damage


func register(interpreter: VMInterpreter) -> void:
	var registrations := {
		"flip_coin": Callable(self, "cmd_flip_coin"),
		"flip_coin_repeat_damage": Callable(self, "cmd_flip_coin_repeat_damage"),
		"flip_coin_then_discard_energy": Callable(self, "cmd_flip_coin_then_discard_energy"),
		"flip_coin_then_ko": Callable(self, "cmd_flip_coin_then_ko"),
		"flip_until_tails": Callable(self, "cmd_flip_until_tails"),
	}
	for op in registrations:
		interpreter.register_command_handler(str(op), registrations[op])


func cmd_flip_coin(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	args: Dictionary,
	branches: Dictionary,
	player_idx: int,
	source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	var coin_params := args.duplicate(true)
	for branch_name in branches:
		coin_params[str(branch_name)] = Array(branches[branch_name]).duplicate(true)
	return coin_request(state, stack, rng, "branch", coin_params, player_idx, source_slot)


func cmd_flip_coin_repeat_damage(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return coin_request(
		state, stack, rng, "repeat_damage", args.duplicate(true), player_idx, source_slot)


func cmd_flip_coin_then_discard_energy(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return coin_request(
		state, stack, rng, "discard_energy", args.duplicate(true), player_idx, source_slot)


func cmd_flip_coin_then_ko(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return coin_request(state, stack, rng, "double_ko", args.duplicate(true), player_idx, source_slot)


func cmd_flip_until_tails(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return coin_request(state, stack, rng, "until_tails", args.duplicate(true), player_idx, source_slot)


func coin_request(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	coin_kind: String,
	params: Dictionary,
	player_idx: int,
	source_slot: String,
) -> Dictionary:
	var results: Array[bool] = []
	if coin_kind == "until_tails":
		while true:
			var result := rng.coin()
			results.append(result)
			if not result or results.size() >= 32:
				break
	else:
		var count := int(params.get("flips", 1))
		if coin_kind == "repeat_damage":
			count = int(params.get("flips", 3))
		elif coin_kind == "double_ko":
			count = 2
		for _index in range(max(1, count)):
			results.append(rng.coin())
	stack.push_continuation("coin", {
		"coin_kind": coin_kind,
		"params": params.duplicate(true),
		"player_idx": player_idx,
		"source_slot": source_slot,
		"results": results,
	})
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, player_idx, "coin_flip"),
		"coin_flip", player_idx, "硬币结果",
		[], 0, 0, false, false,
		{"revision": state.revision, "predetermined_flips": results})
	return VMResult.ok("正在掷硬币。")


func resolve_coin(
	state: GameState,
	stack: ResolutionStack,
	data: Dictionary,
	events: Array[Dictionary],
) -> Dictionary:
	var results: Array = data["results"]
	var coin_kind := str(data["coin_kind"])
	var params: Dictionary = data["params"]
	var player_idx := int(data["player_idx"])
	var source_slot := str(data["source_slot"])
	var heads := 0
	for result in results:
		if result:
			heads += 1
	events.append({"event_type": "coin_flip", "data": {"results": results.duplicate()}})
	match coin_kind:
		"branch":
			var branch: Variant = params.get("on_heads", []) if bool(results[0]) else params.get("on_tails", [])
			var branch_effects: Array = [branch] if branch is Dictionary else branch
			if bool(stack.context.get("finish_attack", false)):
				var pre_hit_branch: Array[Dictionary] = []
				var post_hit_branch: Array[Dictionary] = []
				for effect_value in branch_effects:
					var effect := Dictionary(effect_value).duplicate(true)
					if _branch_effect_is_pre_hit(effect):
						pre_hit_branch.append(effect)
					else:
						post_hit_branch.append(effect)
				var deferred: Array = stack.context.get("conditional_post_hit_effects", [])
				deferred.append_array(post_hit_branch)
				stack.context["conditional_post_hit_effects"] = deferred
				stack.push_effects(pre_hit_branch, player_idx, source_slot)
			else:
				stack.push_effects(branch_effects, player_idx, source_slot)
		"repeat_damage":
			return combat_damage.deal_attack_or_effect_damage(
				state, stack, player_idx, 1 - player_idx, "active",
				heads * int(params.get("damage_per_head", 10)), events)
		"double_ko":
			if heads == 2:
				var target_player_idx := 1 - player_idx
				var target := state.get_player(target_player_idx).active
				if target:
					if (
						target.all_prevented_next_turn
						and stack.is_blockable_opponent_attack_effect(
							player_idx, target_player_idx)
					):
						return VMResult.ok("击倒效果被免疫。")
					var applied_counters: int = maxi(
						1,
						ceili(float(target.current_hp(catalog)) / 10.0),
					)
					target.damage_counters += applied_counters
					var causes: Dictionary = stack.context.get("knockout_causes", {})
					causes["%d:active" % target_player_idx] = {
						"source_kind": "attack_effect",
						"cause_kind": "direct_knockout",
						"source_player": player_idx,
					}
					stack.context["knockout_causes"] = causes
					events.append({
						"event_type": "direct_knockout_applied",
						"actor": player_idx,
						"source": {"player": player_idx, "slot": source_slot},
						"target": {"player": 1 - player_idx, "slot": "active"},
						"amount": 0,
						"data": {
							"player": 1 - player_idx,
							"slot": "active",
							"cause": "coin_double_ko",
							"direct_knockout": true,
						},
					})
		"until_tails":
			return combat_damage.deal_attack_or_effect_damage(
				state, stack, player_idx, 1 - player_idx, "active",
				heads * int(params.get("per_head", 20)), events)
		"discard_energy":
			if bool(results[0]):
				var opponent_idx := 1 - player_idx
				var opponent := state.get_player(opponent_idx)
				var options: Array[Dictionary] = []
				var attachment_refs: Array[Dictionary] = []
				var card_ids: Array[String] = []
				for row in opponent.get_all_pokemon():
					var pokemon: PokemonState = row["pokemon"]
					if pokemon == null:
						continue
					if (
						pokemon.all_prevented_next_turn
						and stack.is_blockable_opponent_attack_effect(
							player_idx, opponent_idx)
					):
						continue
					var slot := str(row["slot"])
					for index in range(pokemon.energy_card_ids.size()):
						var energy_id := str(pokemon.energy_card_ids[index])
						var attachment_ref := EntityRef.new(
							"attachment", opponent_idx, "field", slot,
							index, "energy", energy_id).to_dict()
						attachment_refs.append(attachment_ref)
						card_ids.append(energy_id)
						options.append({
							"option_id": "attachment:%d:%s:energy:%d:%s" % [opponent_idx, slot, index, energy_id],
							"label": "%s - %s" % [catalog.card_name(pokemon.card_id), catalog.card_name(energy_id)],
							"ref": attachment_ref,
							"value": {
								"player": opponent_idx,
								"slot": slot,
								"index": index,
								"card_id": energy_id,
							},
						})
				if options.is_empty():
					return VMResult.ok("对手场上没有能量。")
				stack.push_continuation("discard_attachment", {"player_idx": player_idx})
				stack.pending_request = ChoiceRequest.new(
					stack.next_request_id(state, player_idx, "discard_attachment"),
					"select_attachment",
					player_idx,
					"选择对手场上的1个能量丢弃。",
					options,
					1,
					1,
					false,
					false,
					{
						"revision": state.revision,
						"purpose": "discard_energy",
						"attachment_refs": attachment_refs,
						"card_ids": card_ids,
						"source_player": opponent_idx,
						"source_slot": "",
						"same_source": false,
						"same_target": false,
						"max_per_target": 1,
					},
				)
	return VMResult.ok()


func _branch_effect_is_pre_hit(effect: Dictionary) -> bool:
	var op := str(effect.get("op", ""))
	if op == "deal_damage":
		return str(Dictionary(effect.get("args", {})).get(
			"target", "opponent_active")) != "self"
	return op in [
		"choose_damage_target",
		"conditional_damage",
		"conditional_damage_then_heal",
		"deal_damage_per_discard_psychic",
		"deal_damage_per_energy",
		"deal_damage_per_evolved",
		"deal_damage_per_hand_size",
		"deal_damage_per_self_damage",
		"deal_damage_per_self_energy",
		"deal_damage_per_self_energy_type",
		"deal_damage_plus_bench",
		"deal_damage_with_self_penalty",
		"discard_energy_then_damage",
		"discard_hand_then_damage",
		"fail_attack",
		"flip_coin",
		"flip_coin_repeat_damage",
		"flip_coin_then_ko",
		"flip_until_tails",
		"mill_then_damage",
		"set_attack_damage_formula",
		"set_attack_flags",
	]

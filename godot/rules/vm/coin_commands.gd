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
			if branch is Dictionary:
				stack.push_effect(branch, player_idx, source_slot)
			elif branch is Array:
				stack.push_effects(branch, player_idx, source_slot)
		"repeat_damage":
			return combat_damage.deal_attack_or_effect_damage(
				state, stack, player_idx, 1 - player_idx, "active",
				heads * int(params.get("damage_per_head", 10)), events)
		"double_ko":
			if heads == 2:
				var target := state.get_player(1 - player_idx).active
				if target:
					target.damage_counters += max(1, ceili(float(target.current_hp(catalog)) / 10.0))
		"until_tails":
			return combat_damage.deal_attack_or_effect_damage(
				state, stack, player_idx, 1 - player_idx, "active",
				heads * int(params.get("per_head", 20)), events)
		"discard_energy":
			if bool(results[0]):
				var opponent := state.get_player(1 - player_idx)
				var options: Array[Dictionary] = []
				for row in opponent.get_all_pokemon():
					var pokemon: PokemonState = row["pokemon"]
					if pokemon == null:
						continue
					var slot := str(row["slot"])
					for index in range(pokemon.energy_card_ids.size()):
						var energy_id := str(pokemon.energy_card_ids[index])
						options.append({
							"option_id": "attachment:%d:%s:energy:%d:%s" % [1 - player_idx, slot, index, energy_id],
							"label": "%s - %s" % [catalog.card_name(pokemon.card_id), catalog.card_name(energy_id)],
							"ref": EntityRef.new("attachment", 1 - player_idx, "", slot, index, "energy", energy_id).to_dict(),
							"value": {
								"player": 1 - player_idx,
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
					{"revision": state.revision},
				)
	return VMResult.ok()

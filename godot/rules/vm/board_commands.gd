class_name VMBoardCommands
extends RefCounted

var catalog: CardCatalog


func _init(p_catalog: CardCatalog) -> void:
	catalog = p_catalog


func register(interpreter: VMInterpreter) -> void:
	var registrations := {
		"discard_then_revive": Callable(self, "cmd_discard_then_revive"),
		"evolve_skip_stage": Callable(self, "cmd_evolve_skip_stage"),
		"return_to_hand": Callable(self, "cmd_return_to_hand"),
		"search_any_and_switch": Callable(self, "cmd_search_any_and_switch"),
		"switch_pokemon": Callable(self, "cmd_switch_pokemon"),
	}
	for op in registrations:
		interpreter.register_command_handler(str(op), registrations[op])


func cmd_discard_then_revive(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	return ability_discard_revive(state, player_idx, source_slot, args, events)


func cmd_evolve_skip_stage(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	_args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	_source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	return rare_candy(state, stack, player_idx, events)


func cmd_return_to_hand(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	_args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	return return_to_hand(state, player_idx, source_slot, events)


func cmd_search_any_and_switch(
	_state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return search_any_and_switch(stack, player_idx, source_slot, args)


func cmd_switch_pokemon(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	_source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	var switch_target := str(args.get("target", ""))
	if switch_target.is_empty():
		switch_target = "self"
	return switch_request(
		state,
		stack,
		player_idx,
		1 - player_idx if switch_target == "opponent" else player_idx,
		bool(args.get("optional", false)),
		bool(args.get("you_choose", false)),
	)


func request_board_target(
	state: GameState,
	stack: ResolutionStack,
	chooser: int,
	target_player: int,
	operation: String,
	data: Dictionary,
	prompt: String,
) -> Dictionary:
	var options: Array[Dictionary] = []
	for row in state.get_player(target_player).get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon == null:
			continue
		var slot := str(row["slot"])
		options.append({
			"option_id": "pokemon:%d:%s:%s" % [target_player, slot, pokemon.card_id],
			"label": catalog.card_name(pokemon.card_id),
			"ref": EntityRef.new("pokemon", target_player, "", slot, -1, "", pokemon.card_id).to_dict(),
			"value": {"slot": slot, "card_id": pokemon.card_id},
		})
	if options.is_empty():
		return VMResult.ok("没有可选目标。")
	var presentation := _target_choice_presentation(
		state, data, operation, target_player)
	if options.size() == 1:
		stack.push_continuation(operation, data)
		var synthetic := ChoiceRequest.new(
			stack.next_request_id(state, chooser, operation), operation, chooser, prompt,
			options, 1, 1, false, false, presentation)
		stack.pending_request = synthetic
		return VMResult.ok()
	stack.push_continuation(operation, data)
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, chooser, operation), operation, chooser, prompt,
		options, 1, 1, false, false, presentation)
	return VMResult.ok()


func request_bench_target(
	state: GameState,
	stack: ResolutionStack,
	chooser: int,
	target_player: int,
	operation: String,
	data: Dictionary,
	prompt: String,
	count: int = 1,
) -> Dictionary:
	var options: Array[Dictionary] = []
	var target_state := state.get_player(target_player)
	for index in range(target_state.bench.size()):
		var pokemon: PokemonState = target_state.bench[index]
		if pokemon == null:
			continue
		var slot := "bench_%d" % index
		options.append({
			"option_id": "pokemon:%d:%s:%s" % [target_player, slot, pokemon.card_id],
			"label": catalog.card_name(pokemon.card_id),
			"ref": EntityRef.new("pokemon", target_player, "", slot, -1, "", pokemon.card_id).to_dict(),
			"value": {"slot": slot, "card_id": pokemon.card_id},
		})
	if options.is_empty():
		return VMResult.ok("没有可选备战目标。")
	var actual_count: int = min(max(1, count), options.size())
	stack.push_continuation(operation, data)
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, chooser, operation),
		operation,
		chooser,
		prompt,
		options,
		actual_count,
		actual_count,
		false,
		false,
		_target_choice_presentation(state, data, operation, target_player),
	)
	return VMResult.ok()


func _target_choice_presentation(
	state: GameState,
	data: Dictionary,
	operation: String,
	target_player: int,
) -> Dictionary:
	var presentation := {
		"domain": "effect",
		"purpose": operation,
		"revision": state.revision,
		"target_player": target_player,
	}
	for field in ["amount", "source_player", "source_slot", "source_card_id"]:
		if data.has(field):
			presentation[field] = data[field]
	if not presentation.has("amount") and data.has("counters"):
		presentation["amount"] = maxi(0, int(data.get("counters", 0))) * 10
	var source_player := int(presentation.get("source_player", -1))
	var source_slot := str(presentation.get("source_slot", ""))
	if (
		not presentation.has("source_card_id")
		and source_player in [0, 1]
		and not source_slot.is_empty()
	):
		var source := state.get_player(source_player).get_pokemon(source_slot)
		if source != null:
			presentation["source_card_id"] = source.card_id
	return presentation


func switch_request(
	state: GameState,
	stack: ResolutionStack,
	chooser: int,
	target_player_idx: int,
	optional: bool,
	you_choose: bool,
) -> Dictionary:
	var target_player := state.get_player(target_player_idx)
	if (
		target_player_idx != chooser
		and target_player.active
		and target_player.active.prevents_effects()
		and stack.is_blockable_opponent_attack_effect(chooser, target_player_idx)
	):
		return VMResult.ok("替换效果被免疫。")
	var options: Array[Dictionary] = []
	for index in range(target_player.bench.size()):
		var pokemon: PokemonState = target_player.bench[index]
		if pokemon:
			var slot := "bench_%d" % index
			options.append({
				"option_id": "pokemon:%d:%s:%s" % [target_player_idx, slot, pokemon.card_id],
				"label": catalog.card_name(pokemon.card_id),
				"ref": EntityRef.new("pokemon", target_player_idx, "", slot, -1, "", pokemon.card_id).to_dict(),
				"value": {"slot": slot, "card_id": pokemon.card_id},
			})
	if options.is_empty():
		return VMResult.ok("没有可替换的备战宝可梦。")
	if optional:
		return VMChoiceRequests.confirm_request(
			state, stack, chooser, "confirm_switch",
			{"chooser": chooser, "target_player": target_player_idx},
			"是否替换战斗宝可梦？",
			{
				"domain": "effect",
				"purpose": "confirm_switch",
				"target_player": target_player_idx,
			},
		)
	stack.push_continuation("switch", {"target_player": target_player_idx})
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, chooser, "switch"),
		"select_opponent_bench" if target_player_idx != chooser else "select_bench",
		chooser if you_choose or target_player_idx == chooser else target_player_idx,
		"选择替换上场的宝可梦。",
		options, 1, 1, false, false, {
			"domain": "effect",
			"purpose": "switch",
			"revision": state.revision,
			"target_player": target_player_idx,
		})
	return VMResult.ok()


func search_any_and_switch(
	stack: ResolutionStack,
	player_idx: int,
	source_slot: String,
	params: Dictionary,
) -> Dictionary:
	stack.push_effect(
		{"op": "switch_pokemon", "args": {"target": "self", "optional": true}, "branches": {}},
		player_idx,
		source_slot,
	)
	stack.push_effect(
		{
			"op": "search_cards",
			"args": {
				"from_zone": "deck",
				"filter": "any",
				"destination": "hand",
				"count": int(params.get("count", 2)),
				"min_select": int(params.get("min_select", 0)),
			},
			"branches": {},
		},
		player_idx,
		source_slot,
	)
	return VMResult.ok()


func ability_discard_revive(
	state: GameState,
	player_idx: int,
	source_slot: String,
	params: Dictionary,
	events: Array[Dictionary],
) -> Dictionary:
	var player := state.get_player(player_idx)
	var revive_id := str(params.get("card_id", ""))
	var discard_index := (
		source_slot.trim_prefix("discard_").to_int()
		if source_slot.begins_with("discard_")
		else player.discard.find(revive_id)
	)
	var bench_slot := player.find_empty_bench_slot()
	if (
		discard_index < 0
		or discard_index >= player.discard.size()
		or str(player.discard[discard_index]) != revive_id
		or not player.hand.is_empty()
		or bench_slot < 0
	):
		return VMResult.fail("紧急上浮条件不满足。")
	player.discard.remove_at(discard_index)
	var revived := player.place_bench(revive_id, bench_slot)
	if revived:
		revived.used_abilities.append("紧急上浮")
	events.append(VMZoneHelpers.card_moved_event(
		player_idx,
		[revive_id],
		{"player": player_idx, "zone": "discard", "index": discard_index},
		{"player": player_idx, "slot": "bench_%d" % bench_slot, "index": bench_slot},
	))
	VMZoneHelpers.draw(state, player_idx, 3, events)
	return VMResult.ok()


func rare_candy(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	_events: Array[Dictionary],
) -> Dictionary:
	var player := state.get_player(player_idx)
	if state.is_player_first_turn(player_idx):
		return VMResult.fail("第一回合不能使用神奇糖果。")
	var options: Array[Dictionary] = []
	for row in player.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon == null or not catalog.is_basic_pokemon(pokemon.card_id):
			continue
		if pokemon.placed_this_turn or not pokemon.can_evolve_this_turn:
			continue
		for hand_index in range(player.hand.size()):
			var stage2_id := player.hand[hand_index]
			if not catalog.is_stage2(stage2_id):
				continue
			if not stage2_can_evolve_from_basic(stage2_id, pokemon.card_id):
				continue
			var target_slot := str(row["slot"])
			var base_name := catalog.card_name(pokemon.card_id)
			var stage2_name := catalog.card_name(stage2_id)
			options.append({
				"option_id": "rare_candy:%s:%d:%s" % [target_slot, hand_index, stage2_id],
				"label": "%s → %s" % [base_name, stage2_name],
				"ref": EntityRef.new(
					"card", player_idx, "hand", "", hand_index, "", stage2_id).to_dict(),
				"value": {
					"slot": target_slot,
					"base_card_id": pokemon.card_id,
					"base_name": base_name,
					"hand_index": hand_index,
					"card_id": stage2_id,
					"evolution_name": stage2_name,
				},
			})
	if options.is_empty():
		return VMResult.fail("没有可用神奇糖果进化的目标。")
	stack.push_continuation("evolve_skip_stage", {"player_idx": player_idx})
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, player_idx, "evolve_skip_stage"),
		"evolve_skip_stage",
		player_idx,
		"选择神奇糖果进化目标。",
		options,
		1,
		1,
		false,
		false,
		{
			"domain": "effect",
			"purpose": "evolve_skip_stage",
			"revision": state.revision,
			"source_player": player_idx,
			"source_zone": "hand",
		},
	)
	return VMResult.ok("选择神奇糖果进化目标。")


func stage2_can_evolve_from_basic(stage2_id: String, basic_id: String) -> bool:
	var stage1_name := str(catalog.get_card(stage2_id).get("evolves_from", ""))
	if stage1_name.is_empty():
		return false
	var basic_name := catalog.card_name(basic_id).to_lower()
	for candidate_id in catalog.cards:
		if catalog.card_name(candidate_id) != stage1_name:
			continue
		return str(catalog.get_card(candidate_id).get("evolves_from", "")).to_lower() == basic_name
	return false


func return_to_hand(
	state: GameState,
	player_idx: int,
	source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	var player := state.get_player(player_idx)
	var source := player.get_pokemon(source_slot)
	if source == null:
		return VMResult.fail("没有宝可梦。")
	var returned_cards: Array[String] = [source.card_id]
	returned_cards.append_array(source.evolution_stack_ids)
	returned_cards.append_array(source.energy_card_ids)
	if not source.attached_tool_id.is_empty():
		returned_cards.append(source.attached_tool_id)
	var hand_start := player.hand.size()
	player.hand.append_array(returned_cards)
	if source_slot == "active":
		player.active = null
	elif source_slot.begins_with("bench_"):
		player.bench[source_slot.trim_prefix("bench_").to_int()] = null
	var source_indices: Array[int] = []
	var target_indices: Array[int] = []
	for index in range(returned_cards.size()):
		source_indices.append(index)
		target_indices.append(hand_start + index)
	events.append(VMZoneHelpers.card_moved_event(
		player_idx,
		returned_cards,
		{
			"player": player_idx,
			"slot": source_slot,
			"indices": source_indices,
		},
		{
			"player": player_idx,
			"zone": "hand",
			"indices": target_indices,
		},
	))
	return VMResult.ok()

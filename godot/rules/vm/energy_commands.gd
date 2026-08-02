class_name VMEnergyCommands
extends RefCounted

var catalog: CardCatalog
var trigger_commands: VMTriggerCommands


func _init(p_catalog: CardCatalog, p_trigger_commands: VMTriggerCommands) -> void:
	catalog = p_catalog
	trigger_commands = p_trigger_commands


func register(interpreter: VMInterpreter) -> void:
	var registrations := {
		"attach_energy": Callable(self, "cmd_attach_energy"),
		"attach_energy_from_discard": Callable(self, "cmd_attach_energy_from_discard"),
		"discard_energy": Callable(self, "cmd_discard_energy"),
		"draw_and_attach_energy": Callable(self, "cmd_draw_and_attach_energy"),
		"relocate_energy": Callable(self, "cmd_relocate_energy"),
	}
	for op in registrations:
		interpreter.register_command_handler(str(op), registrations[op])


func cmd_attach_energy(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	return energy_attach(state, stack, rng, player_idx, source_slot, args, events)


func cmd_attach_energy_from_discard(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return attach_from_discard(state, stack, player_idx, source_slot, args)


func cmd_discard_energy(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	return discard_energy(state, stack, player_idx, source_slot, args, events)


func cmd_draw_and_attach_energy(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	_source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	VMZoneHelpers.draw_available(state, player_idx, 2, events)
	return attach_from_hand_to_bench(
		state,
		stack,
		player_idx,
		int(args.get("energy_count", 2)),
		str(args.get("energy_type", "Grass")),
		int(args.get("min_select", int(args.get("energy_count", 2)))),
	)


func cmd_relocate_energy(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	_source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return energy_relocate_request(state, stack, player_idx, args)


func energy_attach(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	player_idx: int,
	source_slot: String,
	params: Dictionary,
	events: Array[Dictionary],
) -> Dictionary:
	var player := state.get_player(player_idx)
	var zone := str(params.get("from_zone", "deck"))
	var source: Array[String] = VMZoneHelpers.zone(player, zone)
	var filter := str(params.get("filter", "any")).to_lower()
	var matching_refs: Array[Dictionary] = []
	if zone == "prizes":
		var trigger_source := (
			trigger_commands.vm_interpreter.trigger_scheduler
			.source_ref_for_current_trigger(stack)
		)
		var trigger_index := int(trigger_source.get("index", -1))
		var trigger_card_id := str(trigger_source.get("card_id", ""))
		if (
			str(trigger_source.get("kind", "")) != "card"
			or int(trigger_source.get("player", -1)) != player_idx
			or str(trigger_source.get("zone", "")) != "prizes"
			or trigger_index < 0
			or trigger_index >= source.size()
			or str(source[trigger_index]) != trigger_card_id
		):
			return VMResult.fail(
				"奖赏卡附能缺少有效的触发来源引用。", "invalid_trigger_origin")
		if energy_matches(trigger_card_id, filter):
			matching_refs.append(trigger_source)
	else:
		for index in range(source.size()):
			var card_id := str(source[index])
			if energy_matches(card_id, filter):
				matching_refs.append(EntityRef.new(
					"card", player_idx, zone, "", index, "", card_id).to_dict())
	var amount := int(params.get("amount", 1))
	var base_amount := amount
	var bonus_applied := false
	if state.active_player_idx != state.first_player_idx and state.is_player_first_turn(player_idx):
		amount = max(amount, int(params.get("going_second_bonus", amount)))
		bonus_applied = amount > base_amount
	if matching_refs.is_empty():
		if zone == "deck":
			events.append(VMZoneHelpers.cards_selected_event(
				player_idx, "deck", "field", [], 0))
			VMZoneHelpers.shuffle_deck(state, rng, player_idx, events)
		return VMResult.ok("没有符合条件的能量。")
	var optional_count := bool(params.has("min_select") or params.get("optional", false) or bonus_applied)
	var min_select := int(params.get("min_select", 0 if optional_count else -1))
	var target_spec := str(params.get("to", "self"))
	var target_slots: Array[String] = []
	if target_spec == "self":
		target_slots.append(source_slot)
	elif target_spec == "self_basic":
		for row in player.get_all_pokemon():
			var pokemon: PokemonState = row["pokemon"]
			if pokemon and catalog.is_basic_pokemon(pokemon.card_id):
				target_slots.append(str(row["slot"]))
	elif target_spec == "bench":
		for index in range(player.bench.size()):
			if player.bench[index]:
				target_slots.append("bench_%d" % index)
	else:
		for row in player.get_all_pokemon():
			if row["pokemon"]:
				target_slots.append(str(row["slot"]))
	var attach_count: int = mini(amount, matching_refs.size())
	var max_per_target := int(params.get("max_per_target", 99))
	var same_target := bool(params.get(
		"same_target", target_spec in ["self_basic", "any"]))
	if bool(params.get("select_source", false)):
		return request_energy_source_cards(
			state, stack, player_idx, zone, matching_refs,
			attach_count, target_slots, max_per_target,
			min_select,
			attach_count if optional_count else -1,
			same_target)
	# A mandatory attachment to one already-determined target has no player
	# decision.  Resolve it immediately so direct VM execution, public action
	# execution, and the Python rules runtime share the same transaction/RNG
	# boundary instead of publishing a redundant one-option choice.
	if target_slots.size() == 1 and not optional_count:
		return attach_cards(
			state,
			player_idx,
			zone,
			matching_refs.slice(0, attach_count),
			target_slots[0],
			events,
			rng,
			stack,
		)
	return request_energy_target(
		state,
		stack,
		player_idx,
		zone,
		matching_refs.slice(0, attach_count),
		target_slots,
		max_per_target,
		min_select,
		attach_count if optional_count else -1,
		same_target,
	)


func attach_from_discard(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	source_slot: String,
	params: Dictionary,
) -> Dictionary:
	var player := state.get_player(player_idx)
	var energy_type := str(params.get("energy_type", "any")).to_lower()
	var target_pokemon_type := str(params.get("target_pokemon_type", ""))
	var matching_refs: Array[Dictionary] = []
	for index in range(player.discard.size()):
		var card_id := str(player.discard[index])
		if not catalog.is_basic_energy(card_id):
			continue
		if energy_type in ["any", "basic", "basic_energy"]:
			matching_refs.append(EntityRef.new(
				"card", player_idx, "discard", "", index, "", card_id).to_dict())
		else:
			for provided in catalog.provides_energy(card_id):
				if str(provided).to_lower() == energy_type:
					matching_refs.append(EntityRef.new(
						"card", player_idx, "discard", "", index, "", card_id).to_dict())
					break
	if matching_refs.is_empty():
		return VMResult.ok("弃牌区没有符合条件的能量。")
	var amount: int = min(int(params.get("amount", 1)), matching_refs.size())
	var optional_count := bool(params.has("min_select") or params.get("optional", false))
	var min_select := int(params.get("min_select", 0 if optional_count else -1))
	var slots: Array[String] = []
	match str(params.get("target", "self")):
		"self":
			var source_pokemon := player.get_pokemon(source_slot)
			if source_pokemon and pokemon_matches_type(source_pokemon, target_pokemon_type):
				slots.append(source_slot)
		"bench":
			for index in range(player.bench.size()):
				if player.bench[index] and pokemon_matches_type(player.bench[index], target_pokemon_type):
					slots.append("bench_%d" % index)
		_:
			for row in player.get_all_pokemon():
				if row["pokemon"] and pokemon_matches_type(row["pokemon"], target_pokemon_type):
					slots.append(str(row["slot"]))
	var same_target := bool(params.get(
		"same_target", str(params.get("target", "self")) == "self_or_bench"))
	if bool(params.get("select_source", false)):
		return request_energy_source_cards(
			state, stack, player_idx, "discard",
			matching_refs,
			amount,
			slots,
			99,
			min_select,
			amount if optional_count else -1,
			same_target)
	return request_energy_target(
		state,
		stack,
		player_idx,
		"discard",
		matching_refs.slice(0, amount),
		slots,
		99,
		min_select,
		amount if optional_count else -1,
		same_target,
	)


func request_energy_source_cards(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	source_zone: String,
	matching_refs: Array[Dictionary],
	amount: int,
	target_slots: Array[String],
	max_per_target: int = 99,
	min_select: int = -1,
	max_select: int = -1,
	same_target: bool = false,
) -> Dictionary:
	var request_max := mini(amount, matching_refs.size())
	if max_select >= 0:
		request_max = mini(request_max, max_select)
	var request_min := request_max if min_select < 0 else mini(request_max, maxi(0, min_select))
	if matching_refs.size() == request_max and request_min == request_max:
		return request_energy_target(
			state, stack, player_idx, source_zone, matching_refs,
			target_slots, max_per_target, -1, -1, same_target)
	var options: Array[Dictionary] = []
	for ref in matching_refs:
		var card_id := str(ref.get("card_id", ""))
		options.append({
			"option_id": "card:%d:%s:%d:%s" % [
				player_idx, source_zone, int(ref.get("index", -1)), card_id],
			"label": catalog.card_name(card_id),
			"ref": ref.duplicate(true),
			"value": {
				"player": player_idx,
				"zone": source_zone,
				"index": int(ref.get("index", -1)),
				"card_id": card_id,
			},
		})
	var frame_id := "effect:energy_sources:%d" % stack.sequence
	stack.push_continuation("energy_attach_sources", {
		"player_idx": player_idx,
		"source_zone": source_zone,
		"target_slots": target_slots.duplicate(),
		"max_per_target": max_per_target,
		"same_target": same_target,
		"frame_id": frame_id,
	})
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, player_idx, "energy_attach_sources"),
		"select_card",
		player_idx,
		"选择要附着的能量。",
		options,
		request_min,
		request_max,
		false,
		request_min == 0,
		{
			"domain": _choice_domain(stack),
			"purpose": "energy_attach_sources",
			"revision": state.revision,
			"continuation_frame_id": frame_id,
			"source_player": player_idx,
			"source_zone": source_zone,
			"same_target": same_target,
			"max_per_target": max_per_target,
		},
	)
	return VMResult.ok()


func pokemon_matches_type(pokemon: PokemonState, target_type: String) -> bool:
	if target_type.is_empty():
		return true
	var normalized := target_type.to_lower()
	for card_type in catalog.get_card(pokemon.card_id).get("energy_types", []):
		if str(card_type).to_lower() == normalized:
			return true
	return false


func request_energy_target(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	source_zone: String,
	card_refs: Array,
	target_slots: Array[String],
	max_per_target: int = 99,
	min_select: int = -1,
	max_select: int = -1,
	same_target: bool = false,
) -> Dictionary:
	if target_slots.is_empty():
		return VMResult.ok("没有附能目标。")
	var capped_card_refs := card_refs.duplicate(true)
	var target_capacity: int = max(0, target_slots.size() * max_per_target)
	if capped_card_refs.size() > target_capacity:
		capped_card_refs = capped_card_refs.slice(0, target_capacity)
	if capped_card_refs.is_empty():
		return VMResult.ok("没有可附着的能量。")
	var capped_card_ids: Array[String] = []
	for ref_value in capped_card_refs:
		if ref_value is Dictionary:
			capped_card_ids.append(str(ref_value.get("card_id", "")))
		else:
			capped_card_ids.append(str(ref_value))
	var options: Array[Dictionary] = []
	for slot in target_slots:
		var pokemon := state.get_player(player_idx).get_pokemon(slot)
		if pokemon:
			var target_ref := EntityRef.new(
				"pokemon", player_idx, "field", slot, -1, "", pokemon.card_id
			)
			var target_option_id := "pokemon:%d:%s:%s" % [
				player_idx, slot, pokemon.card_id]
			for energy_index in range(capped_card_ids.size()):
				var energy_card_id := str(capped_card_ids[energy_index])
				options.append({
					"option_id": "energy:%d:%s->%s" % [
						energy_index, energy_card_id, target_option_id],
					"label": "%s → %s" % [
						catalog.card_name(energy_card_id),
						catalog.card_name(pokemon.card_id),
					],
					"ref": target_ref.to_dict(),
					"value": {
						"slot": slot,
						"card_id": pokemon.card_id,
						"energy_index": energy_index,
						"energy_card_id": energy_card_id,
					},
				})
	var operation := (
		"energy_attach_distribution"
		if capped_card_ids.size() > 1
		else "energy_attach_target"
	)
	var request_min := capped_card_ids.size() if capped_card_ids.size() > 1 else 1
	var request_max := request_min
	if max_select >= 0:
		request_max = min(max_select, capped_card_ids.size())
		request_min = min(request_max, max(0, min_select))
	stack.push_continuation(operation, {
		"player_idx": player_idx,
		"source_zone": source_zone,
		"card_refs": capped_card_refs,
		"card_ids": capped_card_ids,
		"max_per_target": max_per_target,
		"same_target": same_target,
	})
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, player_idx, operation),
		"distribute_energy" if capped_card_ids.size() > 1 else "select_energy_target",
		player_idx,
		"为每张能量选择附着目标。" if capped_card_ids.size() > 1 else "选择附着能量的宝可梦。",
		options,
		request_min,
		request_max,
		false,
		request_min <= 0,
		{
			"domain": _choice_domain(stack),
			"revision": state.revision,
			"purpose": operation,
			"card_ids": capped_card_ids.duplicate(),
			"source_player": player_idx,
			"source_zone": source_zone,
			"same_source": true,
			"same_target": same_target,
			"max_per_target": max_per_target,
		},
	)
	return VMResult.ok()


func attach_cards(
	state: GameState,
	player_idx: int,
	source_zone: String,
	card_refs: Array,
	target_slot: String,
	events: Array[Dictionary],
	rng: PortableRandomSource,
	active_stack: ResolutionStack = null,
) -> Dictionary:
	var player := state.get_player(player_idx)
	var source: Array[String] = VMZoneHelpers.zone(player, source_zone)
	var target := player.get_pokemon(target_slot)
	if target == null:
		return VMResult.fail("附能目标不存在。")
	var normalized_refs := normalize_zone_card_refs(
		player_idx, source_zone, source, card_refs)
	if normalized_refs.size() != card_refs.size():
		return VMResult.fail("选择的能量已不存在。", "stale_choice")
	var removal_order := normalized_refs.duplicate(true)
	removal_order.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return int(left.get("index", -1)) > int(right.get("index", -1))
	)
	for ref in removal_order:
		source.remove_at(int(ref.get("index", -1)))
	var trigger_candidates: Array[Dictionary] = []
	for ref in normalized_refs:
		var card_id := str(ref.get("card_id", ""))
		var index := int(ref.get("index", -1))
		if not card_id.is_empty():
			var hand_index := player.hand.size()
			if source_zone == "prizes":
				events.append({
					"event_type": "prize_taken",
					"actor": player_idx,
					"visibility": "public",
					"card_id": card_id,
					"source": {
						"player": player_idx, "zone": "prizes", "index": index,
					},
					"target": {
						"player": player_idx, "zone": "hand", "index": hand_index,
					},
					"data": {
						"player": player_idx, "count": 1, "card_id": card_id,
						"source_index": index, "target_index": hand_index,
					},
				})
				if active_stack != null:
					var resolved: Dictionary = active_stack.context.get(
						"resolved_prize_reveals", {})
					resolved[_prize_ref_key(player_idx, index, card_id)] = "attached"
					active_stack.context["resolved_prize_reveals"] = resolved
			target.energy_card_ids.append(card_id)
			var attachment_index := target.energy_card_ids.size() - 1
			events.append({
				"event_type": "energy_attached",
				"actor": player_idx,
				"card_id": card_id,
				"source": (
					{"player": player_idx, "zone": "hand", "index": hand_index}
					if source_zone == "prizes"
					else {"player": player_idx, "zone": source_zone, "index": index}
				),
				"target": {"player": player_idx, "slot": target_slot},
				"data": {
					"player": player_idx,
					"slot": target_slot,
					"card_id": card_id,
					"source_zone": source_zone,
					"source_index": index,
				},
			})
			trigger_commands.collect_on_attach_triggers(
				card_id,
				player_idx,
				target_slot,
				source_zone,
				trigger_candidates,
				attachment_index,
			)
	if not trigger_candidates.is_empty():
		var stack := active_stack if active_stack != null else ResolutionStack.new()
		var trigger_result := trigger_commands.queue_candidates(
			stack,
			trigger_candidates,
			VMModifierManager.ON_ATTACH,
			state.active_player_idx,
			"apnap",
			_choice_domain(stack),
		)
		if not bool(trigger_result.get("success", false)):
			return trigger_result
		if active_stack == null:
			var trigger_step := trigger_commands.vm_interpreter.resolve(state, stack, rng)
			events.append_array(trigger_step.events)
			if not trigger_step.success:
				return VMResult.fail(trigger_step.message, trigger_step.error_code)
			if trigger_step.pending_choice != null:
				var pending := VMResult.ok(trigger_step.message)
				pending["pending_choice"] = trigger_step.pending_choice
				return pending
	if source_zone == "deck":
		VMZoneHelpers.shuffle_deck(state, rng, player_idx, events)
	return VMResult.ok()


func _choice_domain(stack: ResolutionStack) -> String:
	if stack == null or stack.current_trigger_id().is_empty():
		return "effect"
	return trigger_commands.vm_interpreter.trigger_scheduler.choice_domain_for_current_trigger(
		stack)


static func _prize_ref_key(player_idx: int, index: int, card_id: String) -> String:
	return "%d:%d:%s" % [player_idx, index, card_id]


func normalize_zone_card_refs(
	player_idx: int,
	source_zone: String,
	source: Array[String],
	values: Array,
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var used_indices: Dictionary = {}
	for value in values:
		var ref: Dictionary = {}
		if value is Dictionary:
			ref = Dictionary(value).duplicate(true)
		else:
			var card_id := str(value)
			for candidate_index in range(source.size()):
				if not used_indices.has(candidate_index) and str(source[candidate_index]) == card_id:
					ref = EntityRef.new(
						"card", player_idx, source_zone, "", candidate_index, "", card_id
					).to_dict()
					break
		var index := int(ref.get("index", -1))
		if (
			str(ref.get("kind", "")) != "card"
			or int(ref.get("player", -1)) != player_idx
			or str(ref.get("zone", "")) != source_zone
			or index < 0
			or index >= source.size()
			or used_indices.has(index)
			or str(source[index]) != str(ref.get("card_id", ""))
		):
			return []
		used_indices[index] = true
		result.append(ref)
	return result


func energy_relocate_request(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	params: Dictionary,
) -> Dictionary:
	var player := state.get_player(player_idx)
	var energy_type := str(params.get("energy_type", params.get("filter", "any")))
	var source_options: Array[Dictionary] = []
	for row in player.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		var slot := str(row["slot"])
		if (
			pokemon
			and matching_energy_ids(pokemon.energy_card_ids, energy_type).size() > 0
			and (not bool(params.get("from_self", false)) or slot == "active")
		):
			source_options.append({
				"option_id": "pokemon:%d:%s:%s" % [player_idx, slot, pokemon.card_id],
				"label": catalog.card_name(pokemon.card_id),
				"ref": EntityRef.new(
					"pokemon", player_idx, "field", slot, -1, "", pokemon.card_id
				).to_dict(),
				"value": {"player": player_idx, "slot": slot, "card_id": pokemon.card_id},
			})
	if source_options.is_empty():
		return VMResult.ok("场上没有可移动的能量。")
	if source_options.size() == 1:
		return request_relocation_attachments(
			state,
			stack,
			player_idx,
			str(source_options[0].get("value", {}).get("slot", "")),
			int(params.get("amount", 1)),
			energy_type,
			int(params.get("min_select", -1)),
			bool(params.get("same_target", false)),
		)
	stack.push_continuation("energy_relocate_source", {
		"player_idx": player_idx,
		"amount": int(params.get("amount", 1)),
		"energy_type": energy_type,
		"min_select": int(params.get("min_select", -1)),
		"same_target": bool(params.get("same_target", false)),
	})
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, player_idx, "energy_relocate_source"),
		"select_energy_source",
		player_idx,
		"选择能量来源宝可梦。",
		source_options,
		1,
		1,
		false,
		false,
		{
			"domain": "effect",
			"revision": state.revision,
			"purpose": "relocate_energy_source",
			"source_player": player_idx,
			"same_source": true,
			"same_target": bool(params.get("same_target", false)),
			"max_per_target": int(params.get("amount", 1)),
		},
	)
	return VMResult.ok()


func request_relocation_attachments(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	source_slot: String,
	amount: int,
	energy_type: String = "any",
	min_select: int = -1,
	same_target: bool = false,
) -> Dictionary:
	var player := state.get_player(player_idx)
	var source := player.get_pokemon(source_slot)
	if source == null:
		return VMResult.ok("能量来源已不存在。")
	var has_target := false
	for row in player.get_all_pokemon():
		if row["pokemon"] and str(row["slot"]) != source_slot:
			has_target = true
			break
	if not has_target:
		return VMResult.ok("没有能量转移目标。")
	var matching_refs := matching_energy_refs(
		player_idx, source_slot, source.energy_card_ids, energy_type)
	if matching_refs.is_empty():
		return VMResult.ok("能量来源没有可移动的能量。")
	var move_count: int = min(max(0, amount), matching_refs.size())
	var request_min := move_count
	if min_select >= 0:
		request_min = min(move_count, max(0, min_select))
	var must_choose_exact_attachments := request_min < move_count or matching_refs.size() > move_count
	if not must_choose_exact_attachments:
		return request_relocation_targets(
			state,
			stack,
			player_idx,
			source_slot,
			matching_refs.slice(0, move_count),
			same_target,
		)
	var options: Array[Dictionary] = []
	for ref_value in matching_refs:
		var ref: Dictionary = ref_value
		var energy_id := str(ref.get("card_id", ""))
		options.append({
			"option_id": attachment_option_id(ref),
			"label": "%s - %s" % [
				catalog.card_name(source.card_id), catalog.card_name(energy_id)],
			"ref": ref.duplicate(true),
			"value": {
				"player": player_idx,
				"slot": source_slot,
				"index": int(ref.get("index", -1)),
				"attachment_type": "energy",
				"card_id": energy_id,
			},
		})
	stack.push_continuation("energy_relocate_attachments", {
		"player_idx": player_idx,
		"source_slot": source_slot,
		"amount": move_count,
		"energy_type": energy_type,
		"same_target": same_target,
	})
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, player_idx, "energy_relocate_attachments"),
		"select_attachment",
		player_idx,
		"选择要转附的能量。",
		options,
		request_min,
		move_count,
		false,
		request_min <= 0,
		attachment_choice_metadata(
			state,
			"relocate_energy",
			matching_refs,
			player_idx,
			source_slot,
			true,
			same_target,
			move_count,
		),
	)
	return VMResult.ok()


func request_relocation_targets(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	source_slot: String,
	attachment_refs: Array,
	same_target: bool = false,
) -> Dictionary:
	var player := state.get_player(player_idx)
	var source := player.get_pokemon(source_slot)
	if source == null or attachment_refs.is_empty():
		return VMResult.ok("能量来源没有可移动的能量。")
	var options: Array[Dictionary] = []
	for row in player.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		var slot := str(row["slot"])
		if pokemon and slot != source_slot:
			options.append({
				"option_id": "pokemon:%d:%s:%s" % [player_idx, slot, pokemon.card_id],
				"label": catalog.card_name(pokemon.card_id),
				"ref": EntityRef.new(
					"pokemon", player_idx, "field", slot, -1, "", pokemon.card_id
				).to_dict(),
				"value": {"player": player_idx, "slot": slot, "card_id": pokemon.card_id},
			})
	if options.is_empty():
		return VMResult.ok("没有能量转移目标。")
	var move_count := attachment_refs.size()
	var operation := (
		"energy_relocate_distribution"
		if move_count > 1
		else "energy_relocate_target"
	)
	stack.push_continuation(operation, {
		"player_idx": player_idx,
		"source_slot": source_slot,
		"amount": move_count,
		"attachment_refs": attachment_refs.duplicate(true),
		"card_ids": attachment_card_ids(attachment_refs),
		"max_per_target": move_count,
		"same_target": same_target,
	})
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, player_idx, operation),
		"distribute_energy" if move_count > 1 else "select_energy_target",
		player_idx,
		"为每张能量选择转移目标。" if move_count > 1 else "选择能量转移目标。",
		options,
		move_count,
		move_count,
		move_count > 1,
		false,
		attachment_choice_metadata(
			state,
			"relocate_energy_target",
			attachment_refs,
			player_idx,
			source_slot,
			true,
			same_target,
			move_count,
		),
	)
	return VMResult.ok()


func attach_from_hand_to_bench(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	amount: int,
	energy_type: String,
	min_select: int = -1,
) -> Dictionary:
	var player := state.get_player(player_idx)
	var matching_refs: Array[Dictionary] = []
	for index in range(player.hand.size()):
		var card_id := str(player.hand[index])
		if catalog.is_basic_energy(card_id) and energy_type in catalog.provides_energy(card_id):
			matching_refs.append(EntityRef.new(
				"card", player_idx, "hand", "", index, "", card_id).to_dict())
	var slots: Array[String] = []
	for index in range(player.bench.size()):
		if player.bench[index]:
			slots.append("bench_%d" % index)
	if matching_refs.is_empty() or slots.is_empty():
		return VMResult.ok()
	var attach_count: int = mini(amount, matching_refs.size())
	return request_energy_target(
		state,
		stack,
		player_idx,
		"hand",
		matching_refs.slice(0, attach_count),
		slots,
		99,
		min_select,
		attach_count if min_select >= 0 else -1,
		true,
	)


func energy_matches(card_id: String, energy_type: String) -> bool:
	var normalized := energy_type.to_lower()
	if not catalog.is_energy(card_id):
		return false
	if normalized in ["any", "energy", ""]:
		return true
	if normalized in ["basic", "basic_energy"]:
		return catalog.is_basic_energy(card_id)
	for provided in catalog.provides_energy(card_id):
		if str(provided).to_lower() == normalized:
			return true
	return false


func discard_energy(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	source_slot: String,
	params: Dictionary,
	events: Array[Dictionary],
) -> Dictionary:
	var from_opponent := str(params.get("from", "self")) != "self"
	var owner_idx := 1 - player_idx if from_opponent else player_idx
	var owner := state.get_player(owner_idx)
	var source := owner.active if from_opponent else owner.get_pokemon(source_slot)
	if source == null:
		return VMResult.fail("没有能量来源。")
	if (
		from_opponent
		and source.prevents_effects()
		and stack.is_blockable_opponent_attack_effect(player_idx, owner_idx)
	):
		return VMResult.ok("能量丢弃效果被免疫。")
	var filter_type := str(params.get("filter", params.get("energy_type", "any"))).to_lower()
	var resolved_slot := "active" if from_opponent else source_slot
	var matching_refs := matching_energy_refs(
		owner_idx, resolved_slot, source.energy_card_ids, filter_type)
	var amount: int = min(max(0, int(params.get("amount", 1))), matching_refs.size())
	if amount <= 0:
		return VMResult.ok("没有符合条件的能量。")
	if amount < matching_refs.size():
		var options: Array[Dictionary] = []
		for ref_value in matching_refs:
			var ref: Dictionary = ref_value
			var energy_id := str(ref.get("card_id", ""))
			options.append({
				"option_id": attachment_option_id(ref),
				"label": "%s - %s" % [
					catalog.card_name(source.card_id), catalog.card_name(energy_id)],
				"ref": ref.duplicate(true),
				"value": {
					"player": owner_idx,
					"slot": resolved_slot,
					"index": int(ref.get("index", -1)),
					"attachment_type": "energy",
					"card_id": energy_id,
				},
			})
		stack.push_continuation("discard_energy_attachments", {
			"player_idx": player_idx,
			"owner_idx": owner_idx,
			"source_slot": resolved_slot,
			"amount": amount,
			"filter": filter_type,
		})
		stack.pending_request = ChoiceRequest.new(
			stack.next_request_id(state, player_idx, "discard_energy_attachments"),
			"select_attachment",
			player_idx,
			"选择要丢弃的%d张能量。" % amount,
			options,
			amount,
			amount,
			false,
			false,
			attachment_choice_metadata(
				state,
				"discard_energy",
				matching_refs,
				owner_idx,
				resolved_slot,
				true,
				false,
				amount,
			),
		)
		return VMResult.ok()
	return discard_attachment_refs(
		state,
		player_idx,
		owner_idx,
		resolved_slot,
		matching_refs.slice(0, amount),
		events,
	)


func discard_attachment_refs(
	state: GameState,
	actor_idx: int,
	owner_idx: int,
	source_slot: String,
	attachment_refs: Array,
	events: Array[Dictionary],
) -> Dictionary:
	var owner := state.get_player(owner_idx)
	var source := owner.get_pokemon(source_slot)
	if source == null:
		return VMResult.fail("能量来源已不存在。")
	var seen_indices: Dictionary = {}
	var validated: Array[Dictionary] = []
	for ref_value in attachment_refs:
		if not ref_value is Dictionary:
			return VMResult.fail("能量引用无效。")
		var ref: Dictionary = ref_value
		var index := int(ref.get("index", -1))
		var card_id := str(ref.get("card_id", ""))
		if (
			str(ref.get("kind", "")) != "attachment"
			or int(ref.get("player", -1)) != owner_idx
			or str(ref.get("slot", "")) != source_slot
			or str(ref.get("attachment_type", "")) != "energy"
			or index < 0
			or index >= source.energy_card_ids.size()
			or seen_indices.has(index)
			or str(source.energy_card_ids[index]) != card_id
		):
			return VMResult.fail("选择的能量已不存在。")
		seen_indices[index] = true
		validated.append({"index": index, "card_id": card_id})
	var removal_order := validated.duplicate(true)
	removal_order.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return int(left["index"]) > int(right["index"])
	)
	for row in removal_order:
		source.energy_card_ids.remove_at(int(row["index"]))
	var discarded_ids: Array[String] = []
	var discarded_indices: Array[int] = []
	var discard_start := owner.discard.size()
	for row in validated:
		discarded_ids.append(str(row["card_id"]))
		discarded_indices.append(int(row["index"]))
		owner.discard.append(str(row["card_id"]))
	if not discarded_ids.is_empty():
		var discarded_event := VMZoneHelpers.discard_event(
			owner_idx,
			"",
			discarded_ids,
			discarded_ids.size(),
			discarded_indices,
			source_slot,
			discard_start,
		)
		discarded_event["actor"] = actor_idx
		discarded_event["source"]["attachment_type"] = "energy"
		events.append(discarded_event)
	return VMResult.ok("丢弃了%d张能量。" % discarded_ids.size())


func matching_energy_refs(
	player_idx: int,
	slot: String,
	card_ids: Array,
	energy_type: String,
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for index in range(card_ids.size()):
		var card_id := str(card_ids[index])
		if attached_energy_matches(card_ids, index, energy_type):
			result.append(EntityRef.new(
				"attachment", player_idx, "field", slot, index, "energy", card_id
			).to_dict())
	return result


static func attachment_option_id(ref: Dictionary) -> String:
	return "attachment:%d:%s:energy:%d:%s" % [
		int(ref.get("player", -1)),
		str(ref.get("slot", "")),
		int(ref.get("index", -1)),
		str(ref.get("card_id", "")),
	]


static func attachment_card_ids(attachment_refs: Array) -> Array[String]:
	var result: Array[String] = []
	for ref_value in attachment_refs:
		if ref_value is Dictionary:
			result.append(str(Dictionary(ref_value).get("card_id", "")))
	return result


static func attachment_choice_metadata(
	state: GameState,
	purpose: String,
	attachment_refs: Array,
	source_player: int,
	source_slot: String,
	same_source: bool,
	same_target: bool,
	max_per_target: int,
) -> Dictionary:
	return {
		"domain": "effect",
		"revision": state.revision,
		"purpose": purpose,
		"attachment_refs": attachment_refs.duplicate(true),
		"card_ids": attachment_card_ids(attachment_refs),
		"source_player": source_player,
		"source_slot": source_slot,
		"same_source": same_source,
		"same_target": same_target,
		"max_per_target": max_per_target,
	}


func matching_energy_ids(card_ids: Array, energy_type: String) -> Array[String]:
	var result: Array[String] = []
	for index in range(card_ids.size()):
		var card_id := str(card_ids[index])
		if attached_energy_matches(card_ids, index, energy_type):
			result.append(card_id)
	return result


func attached_energy_matches(card_ids: Array, card_index: int, energy_type: String) -> bool:
	if card_index < 0 or card_index >= card_ids.size():
		return false
	var typed_ids: Array[String] = []
	for card_value in card_ids:
		typed_ids.append(str(card_value))
	var card_id := typed_ids[card_index]
	var normalized := energy_type.to_lower()
	if normalized in ["", "any", "energy"]:
		return catalog.is_energy(card_id)
	if normalized in ["basic", "basic_energy"]:
		return catalog.is_basic_energy(card_id)
	if normalized.ends_with("_energy"):
		normalized = normalized.trim_suffix("_energy")
	for provided in EnergyView.units_for_card_at(typed_ids, card_index, catalog):
		if str(provided).to_lower() in [normalized, "rainbow"]:
			return true
	return false

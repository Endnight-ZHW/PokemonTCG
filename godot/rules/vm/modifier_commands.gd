class_name VMModifierCommands
extends RefCounted


func register(interpreter: VMInterpreter) -> void:
	var registrations := {
		"register_aura_damage_boost": Callable(self, "cmd_register_aura_damage_boost"),
		"register_aura_damage_reduction": Callable(self, "cmd_register_aura_damage_reduction"),
		"register_conditional_hp_boost": Callable(self, "cmd_register_conditional_hp_boost"),
		"register_conditional_zero_retreat": Callable(self, "cmd_register_conditional_zero_retreat"),
		"register_reactive_thorns": Callable(self, "cmd_register_reactive_thorns"),
		"register_tool_exp_share": Callable(self, "cmd_register_tool_exp_share"),
		"register_tool_modifier": Callable(self, "cmd_register_tool_modifier"),
	}
	for op in registrations:
		interpreter.register_command_handler(str(op), registrations[op])


func cmd_register_aura_damage_boost(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return register_named_modifier(state, player_idx, source_slot, "aura_damage_boost", args)


func cmd_register_aura_damage_reduction(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return register_named_modifier(state, player_idx, source_slot, "aura_damage_reduction", args)


func cmd_register_conditional_hp_boost(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return register_named_modifier(state, player_idx, source_slot, "conditional_hp_boost", args)


func cmd_register_conditional_zero_retreat(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return register_named_modifier(state, player_idx, source_slot, "conditional_zero_retreat", args)


func cmd_register_reactive_thorns(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return register_named_modifier(state, player_idx, source_slot, "reactive_thorns", args)


func cmd_register_tool_exp_share(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return register_named_modifier(state, player_idx, source_slot, "tool_exp_share", args)


func cmd_register_tool_modifier(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return register_modifier(state, player_idx, source_slot, args, "tool", "道具效果已注册。")


func register_named_modifier(
	state: GameState,
	player_idx: int,
	source_slot: String,
	modifier_kind: String,
	args: Dictionary,
) -> Dictionary:
	return register_modifier(state, player_idx, source_slot, args, modifier_kind, "")


func register_modifier(
	state: GameState,
	player_idx: int,
	source_slot: String,
	args: Dictionary,
	modifier_kind: String,
	message: String = "",
) -> Dictionary:
	var pokemon := state.get_player(player_idx).get_pokemon(source_slot)
	if pokemon == null:
		return VMResult.ok()
	if modifier_kind.is_empty():
		return VMResult.ok()
	var source := "%d:%s:%s:%s:%s" % [
		player_idx,
		source_slot,
		pokemon.card_id,
		modifier_kind,
		str(args.get("effect", "")),
	]
	var kept: Array[Dictionary] = []
	for modifier in pokemon.modifiers:
		if str(modifier.get("source", "")) != source:
			kept.append(modifier)
	pokemon.modifiers = kept
	pokemon.modifiers.append({
		"source": source,
		"source_player": player_idx,
		"source_slot": source_slot,
		"source_card_id": pokemon.card_id,
		"modifier_kind": modifier_kind,
		"params": args.duplicate(true),
	})
	return VMResult.ok(message)

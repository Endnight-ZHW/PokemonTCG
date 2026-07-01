class_name VMStatusCommands
extends RefCounted

var catalog: CardCatalog


func _init(p_catalog: CardCatalog) -> void:
	catalog = p_catalog


func register(interpreter: VMInterpreter) -> void:
	var registrations := {
		"apply_attack_lock_basic": Callable(self, "cmd_apply_attack_lock_basic"),
		"apply_dazzling_beam": Callable(self, "cmd_apply_dazzling_beam"),
		"apply_outgoing_damage_reduction": Callable(self, "cmd_apply_outgoing_damage_reduction"),
		"apply_self_attack_lock": Callable(self, "cmd_apply_self_attack_lock"),
		"apply_status": Callable(self, "cmd_apply_status"),
		"conditional_status": Callable(self, "cmd_conditional_status"),
		"fail_attack": Callable(self, "cmd_fail_attack"),
		"prevent_all": Callable(self, "cmd_prevent_all"),
		"prevent_damage": Callable(self, "cmd_prevent_damage"),
		"prevent_effects": Callable(self, "cmd_prevent_effects"),
		"set_attack_flags": Callable(self, "cmd_set_attack_flags"),
	}
	for op in registrations:
		interpreter.register_command_handler(str(op), registrations[op])


func cmd_apply_attack_lock_basic(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	_source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return apply_attack_lock_basic(state, player_idx, args)


func cmd_apply_dazzling_beam(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	_source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return apply_dazzling_beam(state, player_idx, args)


func cmd_apply_outgoing_damage_reduction(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return apply_outgoing_damage_reduction(state, player_idx, source_slot, args)


func cmd_apply_self_attack_lock(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return apply_self_attack_lock(state, player_idx, source_slot, args)


func cmd_apply_status(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	var target_player_idx := target_player_idx_for(player_idx, args)
	var target_slot := target_slot_for(source_slot, args)
	return apply_status(state, target_player_idx, target_slot, str(args.get("status", "")), events)


func cmd_conditional_status(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	if str(args.get("condition", "")) == "ko_by_attack_last_turn":
		if not state.get_player(player_idx).was_ko_by_attack:
			return VMResult.ok("条件未满足。")
		state.get_player(player_idx).was_ko_by_attack = false
	var target_player_idx := target_player_idx_for(player_idx, args)
	var target_slot := target_slot_for(source_slot, args)
	return apply_status(state, target_player_idx, target_slot, str(args.get("status", "")), events)


func cmd_fail_attack(
	_state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	_args: Dictionary,
	_branches: Dictionary,
	_player_idx: int,
	_source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	var result := VMResult.ok("招式失败。")
	result["attack_failed"] = true
	return result


func cmd_prevent_all(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	_args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return apply_prevention(state, player_idx, source_slot, true, true)


func cmd_prevent_damage(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	_args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return apply_prevention(state, player_idx, source_slot, true, false)


func cmd_prevent_effects(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	_args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return apply_prevention(state, player_idx, source_slot, false, true)


func cmd_set_attack_flags(
	_state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	_player_idx: int,
	_source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	set_attack_flags(stack, args)
	return VMResult.ok("穿透攻击标记已设置。")


func apply_dazzling_beam(state: GameState, player_idx: int, args: Dictionary) -> Dictionary:
	var target := (
		state.get_player(1 - player_idx).active
		if str(args.get("target", "opponent_active")) == "opponent_active"
		else state.get_player(player_idx).active
	)
	if target:
		if target.all_prevented_next_turn:
			target.all_prevented_next_turn = false
			return VMResult.ok("炫目效果被免疫。")
		target.dazzled = true
	return VMResult.ok("目标被施加炫目效果。")


func apply_attack_lock_basic(state: GameState, player_idx: int, args: Dictionary) -> Dictionary:
	var target := (
		state.get_player(1 - player_idx).active
		if str(args.get("target", "opponent_active")) == "opponent_active"
		else state.get_player(player_idx).active
	)
	if target:
		if target.all_prevented_next_turn:
			target.all_prevented_next_turn = false
			return VMResult.ok("攻击封锁被免疫。")
		if catalog.is_basic_pokemon(target.card_id):
			target.attack_locked = true
	return VMResult.ok()


func apply_outgoing_damage_reduction(
	state: GameState,
	player_idx: int,
	source_slot: String,
	args: Dictionary,
) -> Dictionary:
	var target := (
		state.get_player(1 - player_idx).active
		if str(args.get("target", "opponent_active")) == "opponent_active"
		else state.get_player(player_idx).get_pokemon(source_slot)
	)
	if target:
		if target.all_prevented_next_turn:
			target.all_prevented_next_turn = false
			return VMResult.ok("恫吓效果被免疫。")
		target.outgoing_damage_reduction_next_turn = maxi(
			target.outgoing_damage_reduction_next_turn,
			int(args.get("amount", 0)),
		)
	return VMResult.ok()


func apply_self_attack_lock(
	state: GameState,
	player_idx: int,
	source_slot: String,
	args: Dictionary,
) -> Dictionary:
	var target := state.get_player(player_idx).get_pokemon(source_slot)
	if target:
		var scope := str(args.get("scope", "attack")).to_lower()
		var lock_key := "__all__" if scope == "all" else str(args.get("attack_name", ""))
		if not lock_key.is_empty():
			target.attack_locked_names[lock_key] = state.turn_number
	return VMResult.ok()


func apply_prevention(
	state: GameState,
	player_idx: int,
	source_slot: String,
	prevent_damage: bool,
	prevent_effects: bool,
) -> Dictionary:
	var target := state.get_player(player_idx).get_pokemon(source_slot)
	if target:
		if prevent_damage:
			target.damage_prevented_next_turn = true
		if prevent_effects:
			target.all_prevented_next_turn = true
	return VMResult.ok()


func apply_status(
	state: GameState,
	player_idx: int,
	slot: String,
	status: String,
	events: Array[Dictionary],
) -> Dictionary:
	var pokemon := state.get_player(player_idx).get_pokemon(slot)
	if pokemon == null:
		return VMResult.fail("没有状态目标。")
	if pokemon.all_prevented_next_turn:
		pokemon.all_prevented_next_turn = false
		return VMResult.ok("状态效果被免疫。")
	var normalized := status.to_upper()
	if normalized not in ["POISONED", "BURNED", "ASLEEP", "PARALYZED", "CONFUSED"]:
		return VMResult.fail("未知状态: %s" % status)
	if normalized in ["ASLEEP", "PARALYZED", "CONFUSED"]:
		for exclusive in ["ASLEEP", "PARALYZED", "CONFUSED"]:
			pokemon.status_conditions.erase(exclusive)
	if normalized not in pokemon.status_conditions:
		pokemon.status_conditions.append(normalized)
	if normalized == "PARALYZED":
		pokemon.paralyzed_since_turn = state.turn_number
	events.append({"event_type": "status_applied", "data": {
		"player": player_idx, "slot": slot, "status": normalized,
	}})
	return VMResult.ok()


func set_attack_flags(stack: ResolutionStack, params: Dictionary) -> void:
	if bool(params.get("ignore_weakness", true)) or bool(params.get("ignore_resistance", true)):
		stack.context["piercing"] = true
	if bool(params.get("ignore_effects", false)):
		stack.context["ignore_defender_effects"] = true


func target_player_idx_for(player_idx: int, args: Dictionary) -> int:
	return (
		1 - player_idx
		if str(args.get("target", "opponent_active")) == "opponent_active"
		else player_idx
	)


func target_slot_for(source_slot: String, args: Dictionary) -> String:
	return (
		"active"
		if str(args.get("target", "opponent_active")) == "opponent_active"
		else source_slot
	)

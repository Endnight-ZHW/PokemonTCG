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
		return VMResult.fail("Modifier来源宝可梦不存在。", "invalid_modifier_source")
	if modifier_kind.is_empty():
		return VMResult.fail("Modifier类型不能为空。", "invalid_modifier_descriptor")
	# Trigger descriptors are collected from the authoritative card/tool data by
	# TriggerScheduler. They must never be stored as continuous modifiers.
	if modifier_kind in ["reactive_thorns", "tool_exp_share"]:
		return VMResult.ok(message)
	var descriptor := _descriptor_for(
		player_idx, source_slot, pokemon.card_id, pokemon.attached_tool_id,
		modifier_kind, args)
	if descriptor.is_empty():
		return VMResult.fail(
			"未知或不完整的Modifier：%s" % modifier_kind,
			"invalid_modifier_descriptor",
		)
	var error := pokemon.register_modifier(descriptor)
	if not error.is_empty():
		return VMResult.fail(error, "invalid_modifier_descriptor")
	return VMResult.ok(message)


static func _descriptor_for(
	player_idx: int,
	source_slot: String,
	card_id: String,
	attached_tool_id: String,
	modifier_kind: String,
	args: Dictionary,
) -> Dictionary:
	var hook := ""
	var layer := ""
	var priority := int(args.get("priority", 0))
	var scope := "self"
	var duration := "until_leave_play"
	var condition: Dictionary = {}
	var operation: Dictionary = {}
	match modifier_kind:
		"aura_damage_boost":
			hook = VMModifierManager.MODIFY_DAMAGE
			layer = "attacker_adjust"
			scope = "allied_board"
			condition = {
				"attacker_subtype": str(args.get("attacker_subtype", "")),
				"defender_type": str(args.get("defender_type", "")),
			}
			operation = {"kind": "damage_delta", "amount": int(args.get("amount", 0))}
		"aura_damage_reduction":
			hook = VMModifierManager.MODIFY_DAMAGE
			layer = "defender_adjust"
			condition = {
				"requires_attached_energy": bool(args.get("requires_attached_energy", false)),
			}
			operation = {
				"kind": "damage_delta", "amount": -abs(int(args.get("reduction", 20))),
			}
		"conditional_hp_boost":
			hook = VMModifierManager.MAX_HP
			layer = "add"
			condition = {
				"energy_type": str(args.get("energy_type", "")),
				"threshold": int(args.get("threshold", 0)),
			}
			operation = {"kind": "hp_delta", "amount": int(args.get("amount", 0))}
		"conditional_zero_retreat":
			hook = VMModifierManager.CAN_RETREAT
			layer = "set"
			condition = {"energy_type": str(args.get("energy_type", ""))}
			operation = {"kind": "retreat_set", "value": 0}
		"tool":
			return _tool_descriptor(
				player_idx, source_slot, card_id, attached_tool_id,
				args, priority, duration)
		_:
			return {}
	return VMModifierManager.descriptor(
		hook,
		layer,
		priority,
		player_idx,
		VMModifierManager.source_pokemon_ref(player_idx, source_slot, card_id),
		scope,
		duration,
		"replace_same_source",
		condition,
		operation,
	)


static func _tool_descriptor(
	player_idx: int,
	source_slot: String,
	pokemon_card_id: String,
	_attached_tool_id: String,
	args: Dictionary,
	priority: int,
	duration: String,
) -> Dictionary:
	var effect := str(args.get("effect", ""))
	var hook := VMModifierManager.MODIFY_DAMAGE
	var layer := "attacker_adjust"
	var scope := "attached_attacker"
	var condition: Dictionary = {}
	var operation: Dictionary = {}
	match effect:
		"damage_boost_10":
			operation = {"kind": "damage_delta", "amount": 10}
		"damage_boost_when_behind":
			condition = {"behind_on_prizes": true}
			operation = {"kind": "damage_delta", "amount": 30}
		"damage_reduction_stage1":
			layer = "defender_adjust"
			scope = "attached_defender"
			condition = {"target_stage": "stage1"}
			operation = {
				"kind": "damage_delta", "amount": -abs(int(args.get("amount", 30))),
			}
		"hp_boost_basic":
			hook = VMModifierManager.MAX_HP
			layer = "add"
			scope = "self"
			condition = {"target_basic": true}
			operation = {"kind": "hp_delta", "amount": int(args.get("amount", 50))}
		_:
			return {}
	return VMModifierManager.descriptor(
		hook,
		layer,
		priority,
		player_idx,
		VMModifierManager.source_pokemon_ref(
			player_idx, source_slot, pokemon_card_id),
		scope,
		duration,
		"replace_same_source",
		condition,
		operation,
	)

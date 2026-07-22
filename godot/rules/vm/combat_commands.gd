class_name VMCombatCommands
extends RefCounted

var catalog: CardCatalog
var trainer_commands: VMTrainerCommands
var board_commands: VMBoardCommands
var damage: VMCombatDamage
var formula: VMCombatFormula
var choice: VMCombatChoice
var conditionals: VMCombatConditionals
var combo: VMCombatCombo


func _init(
	p_catalog: CardCatalog,
	p_trainer_commands: VMTrainerCommands,
	p_board_commands: VMBoardCommands,
) -> void:
	catalog = p_catalog
	trainer_commands = p_trainer_commands
	board_commands = p_board_commands
	damage = VMCombatDamage.new()
	formula = VMCombatFormula.new(catalog, damage)
	choice = VMCombatChoice.new(catalog, board_commands, damage)
	conditionals = VMCombatConditionals.new(catalog, damage)
	combo = VMCombatCombo.new(catalog, damage)


func register(interpreter: VMInterpreter) -> void:
	var registrations := {
		"choose_damage_target": Callable(self, "cmd_choose_damage_target"),
		"choose_heal_damage": Callable(self, "cmd_choose_heal_damage"),
		"conditional": Callable(self, "cmd_conditional"),
		"conditional_damage": Callable(self, "cmd_conditional_damage"),
		"conditional_damage_then_heal": Callable(self, "cmd_conditional_damage_then_heal"),
		"conditional_search": Callable(self, "cmd_conditional_search"),
		"deal_bench_damage": Callable(self, "cmd_deal_bench_damage"),
		"deal_damage": Callable(self, "cmd_deal_damage"),
		"deal_damage_per_discard_psychic": Callable(self, "cmd_deal_damage_per_discard_psychic"),
		"deal_damage_per_energy": Callable(self, "cmd_deal_damage_per_energy"),
		"deal_damage_per_evolved": Callable(self, "cmd_deal_damage_per_evolved"),
		"deal_damage_per_hand_size": Callable(self, "cmd_deal_damage_per_hand_size"),
		"deal_damage_per_self_damage": Callable(self, "cmd_deal_damage_per_self_damage"),
		"deal_damage_per_self_energy": Callable(self, "cmd_deal_damage_per_self_energy"),
		"deal_damage_per_self_energy_type": Callable(self, "cmd_deal_damage_per_self_energy_type"),
		"deal_damage_plus_bench": Callable(self, "cmd_deal_damage_plus_bench"),
		"deal_damage_then_heal": Callable(self, "cmd_deal_damage_then_heal"),
		"deal_damage_with_self_penalty": Callable(self, "cmd_deal_damage_with_self_penalty"),
		"discard_energy_then_damage": Callable(self, "cmd_discard_energy_then_damage"),
		"discard_hand_then_damage": Callable(self, "cmd_discard_hand_then_damage"),
		"heal_all": Callable(self, "cmd_heal_all"),
		"heal_damage": Callable(self, "cmd_heal_damage"),
		"mill_then_damage": Callable(self, "cmd_mill_then_damage"),
		"place_damage_counters": Callable(self, "cmd_place_damage_counters"),
		"place_counters_then_self_ko": Callable(self, "cmd_place_counters_then_self_ko"),
		"set_attack_damage_formula": Callable(self, "cmd_set_attack_damage_formula"),
	}
	for op in registrations:
		interpreter.register_command_handler(str(op), registrations[op])


func cmd_choose_damage_target(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return choice.choose_damage_target(
		state, stack, player_idx, source_slot, args)


func cmd_choose_heal_damage(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	_source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return choice.request_injured_target(state, stack, player_idx, int(args.get("amount", 30)))


func cmd_conditional(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	branches: Dictionary,
	player_idx: int,
	source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	var conditional_params := args.duplicate(true)
	if branches.has("cost"):
		conditional_params["cost"] = Array(branches["cost"]).duplicate(true)
	if branches.has("on_pay"):
		conditional_params["on_pay"] = Array(branches["on_pay"]).duplicate(true)
	return conditionals.conditional_effect(state, stack, player_idx, source_slot, conditional_params)


func cmd_conditional_damage(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	_source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	return conditionals.conditional_damage_bonus(state, stack, player_idx, args, events)


func cmd_conditional_damage_then_heal(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	var total := int(args.get("base", 0))
	var source := state.get_player(player_idx).get_pokemon(source_slot)
	if source != null and source.healed_this_turn:
		total += int(args.get("bonus", 0))
	return damage.deal_attack_or_effect_damage(
		state, stack, player_idx, 1 - player_idx, "active", total, events)


func cmd_conditional_search(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	_source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	return trainer_commands.conditional_search_request(
		state, stack, rng, player_idx, args, events)


func cmd_deal_bench_damage(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	return choice.bench_damage(
		state, stack, player_idx, source_slot, args, events)


func cmd_deal_damage(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	var amount := int(args.get("amount", 0))
	var formula_node: Variant = null
	if args.has("formula_ast"):
		formula_node = args["formula_ast"]
	elif args.get("formula", null) is Dictionary:
		formula_node = args["formula"]
	if formula_node != null:
		var formula_result: Dictionary = formula.evaluate_formula_ast(
			state, player_idx, source_slot, formula_node)
		if not bool(formula_result.get("success", false)):
			return {
				"success": false,
				"message": str(formula_result.get("message", "非法伤害公式。")),
				"error_code": "invalid_formula_ast",
			}
		amount = int(formula_result.get("value", 0))
	if bool(stack.context.get("finish_attack", false)):
		if bool(args.get("ignore_weakness", false)):
			stack.context["ignore_weakness"] = true
		if bool(args.get("ignore_resistance", false)):
			stack.context["ignore_resistance"] = true
		if bool(args.get(
			"ignore_defender_damage_effects",
			args.get("ignore_defender_effects", false),
		)):
			stack.context["ignore_defender_damage_effects"] = true
	var target := str(args.get("target", "opponent_active"))
	if target == "self":
		return damage.deal_damage(state, player_idx, source_slot, amount, events)
	var result := damage.deal_attack_or_effect_damage(
		state, stack, player_idx, 1 - player_idx, "active", amount, events)
	return result


func cmd_deal_damage_per_discard_psychic(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	return formula.deal_damage_formula_spec(
		state, stack, player_idx, source_slot, "per_discard_psychic", args, events)


func cmd_deal_damage_per_energy(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	return formula.deal_damage_formula_spec(
		state, stack, player_idx, source_slot, "per_energy", args, events)


func cmd_deal_damage_per_evolved(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	return formula.deal_damage_formula_spec(
		state, stack, player_idx, source_slot, "per_evolved", args, events)


func cmd_deal_damage_per_hand_size(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	return formula.deal_damage_formula_spec(
		state, stack, player_idx, source_slot, "per_hand_size", args, events)


func cmd_deal_damage_per_self_damage(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	return formula.deal_damage_formula_spec(
		state, stack, player_idx, source_slot, "per_self_damage", args, events)


func cmd_deal_damage_per_self_energy(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	return formula.deal_damage_formula_spec(
		state, stack, player_idx, source_slot, "per_self_energy", args, events)


func cmd_deal_damage_per_self_energy_type(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	return formula.deal_damage_formula_spec(
		state, stack, player_idx, source_slot, "per_self_energy_type", args, events)


func cmd_deal_damage_plus_bench(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	return formula.deal_damage_formula_spec(
		state, stack, player_idx, source_slot, "plus_bench", args, events)


func cmd_deal_damage_then_heal(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	var result: Dictionary = damage.deal_attack_or_effect_damage(
		state, stack, player_idx, 1 - player_idx, "active",
		int(args.get("damage", 0)), events)
	damage.heal_pokemon(state, player_idx, source_slot, int(args.get("heal", 0)), events)
	return result


func cmd_deal_damage_with_self_penalty(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	var source := state.get_player(player_idx).get_pokemon(source_slot)
	var penalty_count := source.damage_counters if source else 0
	return damage.deal_attack_or_effect_damage(
		state, stack, player_idx, 1 - player_idx, "active",
		max(0, int(args.get("base", 0)) - penalty_count * int(args.get("per_counter", 0))),
		events)


func cmd_discard_energy_then_damage(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	return combo.discard_fighting_energy_then_damage(
		state, stack, player_idx, source_slot, args, events)


func cmd_discard_hand_then_damage(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	_source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	return combo.discard_hand_then_damage(state, stack, player_idx, args, events)


func cmd_heal_all(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	_source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	for row in state.get_player(player_idx).get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon:
			damage.heal_pokemon(state, player_idx, str(row["slot"]), int(args.get("amount", 20)), events)
	return VMResult.ok()


func cmd_heal_damage(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	var heal_slot := source_slot
	if str(args.get("target", "self")) == "self":
		heal_slot = "active"
	return damage.heal_pokemon(state, player_idx, heal_slot, int(args.get("amount", 0)), events)


func cmd_mill_then_damage(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	_source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	return combo.mill_then_damage(state, stack, rng, player_idx, args, events)


func cmd_place_damage_counters(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	var pokemon := state.get_player(player_idx).get_pokemon(source_slot)
	var counters := int(float(args.get("amount", 0)) / 10.0)
	if pokemon == null or counters <= 0:
		return VMResult.ok()
	pokemon.damage_counters += counters
	var causes: Dictionary = stack.context.get("knockout_causes", {})
	causes["%d:%s" % [player_idx, source_slot]] = {
		"source_kind": (
			"attack_effect" if bool(stack.context.get("finish_attack", false))
			else str(stack.context.get("effect_source_kind", "effect"))
		),
		"cause_kind": "damage_counters",
		"source_player": player_idx,
	}
	stack.context["knockout_causes"] = causes
	events.append({
		"event_type": "damage_counters_placed",
		"actor": player_idx,
		"source": {"player": player_idx, "slot": source_slot},
		"target": {"player": player_idx, "slot": source_slot},
		"amount": counters * 10,
		"data": {
			"player": player_idx,
			"slot": source_slot,
			"count": counters,
			"counter_count": counters,
		},
	})
	return VMResult.ok()


func cmd_place_counters_then_self_ko(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return choice.place_counters_then_self_ko(state, stack, player_idx, source_slot, args)


func cmd_set_attack_damage_formula(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return formula.attack_damage_formula(state, stack, player_idx, source_slot, args)

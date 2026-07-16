class_name VMCombatChoice
extends RefCounted

var catalog: CardCatalog
var board_commands: VMBoardCommands
var damage: VMCombatDamage


func _init(
	p_catalog: CardCatalog,
	p_board_commands: VMBoardCommands,
	p_damage: VMCombatDamage,
) -> void:
	catalog = p_catalog
	board_commands = p_board_commands
	damage = p_damage


func request_injured_target(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	amount: int,
) -> Dictionary:
	var options: Array[Dictionary] = []
	for row in state.get_player(player_idx).get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon and pokemon.damage_counters > 0:
			var slot := str(row["slot"])
			options.append({
				"option_id": "pokemon:%d:%s:%s" % [player_idx, slot, pokemon.card_id],
				"label": catalog.card_name(pokemon.card_id),
				"value": {"slot": slot, "card_id": pokemon.card_id},
			})
	if options.is_empty():
		return VMResult.fail("没有受伤的宝可梦。")
	stack.push_continuation("heal_target", {"player_idx": player_idx, "amount": amount})
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, player_idx, "heal_target"),
		"select_heal_target", player_idx, "选择回复目标。",
		options, 1, 1)
	return VMResult.ok()


func bench_damage(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	params: Dictionary,
	events: Array[Dictionary],
) -> Dictionary:
	var target_player_key := str(params.get("player", params.get("target_player", "opponent")))
	var target_idx := 1 - player_idx if target_player_key == "opponent" else player_idx
	if not bool(params.get("choose_targets", true)):
		var applied := 0
		for index in range(state.get_player(target_idx).bench.size()):
			if applied >= int(params.get("count", 1)):
				break
			var bench_pokemon: PokemonState = state.get_player(target_idx).bench[index]
			if bench_pokemon:
				damage.deal_attack_or_effect_damage(
					state, stack, player_idx, target_idx,
					"bench_%d" % index, int(params.get("amount", 0)), events)
				applied += 1
		return VMResult.ok("备战伤害已结算。")
	return board_commands.request_bench_target(
		state, stack, player_idx, target_idx, "bench_damage_target",
		{
			"amount": int(params.get("amount", 0)),
			"source_player": player_idx,
			"target_player": target_idx,
		},
		"选择1只对手备战宝可梦作为伤害目标。",
		int(params.get("count", 1)))


func choose_damage_target(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	params: Dictionary,
) -> Dictionary:
	var target_player_key := str(params.get("player", params.get("target_player", "opponent")))
	var target_idx := 1 - player_idx if target_player_key == "opponent" else player_idx
	return board_commands.request_board_target(
		state, stack, player_idx, target_idx, "damage_target",
		{
			"amount": int(params.get("amount", 0)),
			"source_player": player_idx,
			"target_player": target_idx,
		},
		"选择1只对手宝可梦作为伤害目标。")


func place_counters_then_self_ko(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	source_slot: String,
	params: Dictionary,
) -> Dictionary:
	var target_player_key := str(params.get("player", params.get("target_player", "opponent")))
	var target_idx := 1 - player_idx if target_player_key == "opponent" else player_idx
	return board_commands.request_board_target(
		state, stack, player_idx, target_idx, "place_counters_self_ko",
		{
			"counters": int(params.get("counters", 0)),
			"source_player": player_idx,
			"source_slot": source_slot,
			"target_player": target_idx,
		},
		"选择1只对手宝可梦放置伤害指示物。")
